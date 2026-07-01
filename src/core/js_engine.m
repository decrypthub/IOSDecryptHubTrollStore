// js_engine.m — 见 js_engine.h。
//
// 线程模型: 所有对 JSContext 的访问都串行化到 _jsQueue(JSContext 非线程安全)。
//   - runScript / stop: dispatch_sync 到 _jsQueue。
//   - log() 回调在 evaluateScript 的同线程(即 _jsQueue)触发 → emitEvent。
// 事件缓冲: 独立环形数组 + os_unfair_lock, 可被 HTTP worker 线程(eventsSince) 与
//   _jsQueue(emitEvent) 并发访问, 用锁而非队列, 避免高频轮询和脚本执行互相排队。

#import "js_engine.h"
#import "log_store.h"          // DHTimestampNow
#import <JavaScriptCore/JavaScriptCore.h>
#import <os/lock.h>

static const NSUInteger kMaxEvents = 5000;   // 事件环形缓冲上限, 超出丢最旧

@implementation DHJSEngine {
    dispatch_queue_t   _jsQueue;
    JSContext         *_ctx;
    NSString          *_pendingError;   // 仅 _jsQueue 内访问: 本次 evaluateScript 是否抛异常

    os_unfair_lock     _evLock;
    NSMutableArray<NSDictionary *> *_events;   // 受 _evLock 保护
    uint64_t           _evSeq;                 // 事件自增序号, 受 _evLock 保护
    uint64_t           _evTotal;               // 累计事件数(含已丢弃), 受 _evLock 保护
}

+ (instancetype)shared {
    static DHJSEngine *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[DHJSEngine alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _jsQueue = dispatch_queue_create("com.decrypthelper.jsengine", DISPATCH_QUEUE_SERIAL);
        _evLock  = OS_UNFAIR_LOCK_INIT;
        _events  = [NSMutableArray array];
        _evSeq   = 0;
        _evTotal = 0;
        dispatch_sync(_jsQueue, ^{ [self _setupContextLocked]; });
    }
    return self;
}

// 建立/重建 JSContext, 注入基础 API。须在 _jsQueue 内调用。
- (void)_setupContextLocked {
    _ctx = [[JSContext alloc] init];
    __weak DHJSEngine *ws = self;

    // log(...) —— 变参, 用 currentArguments 取全部实参拼接。
    _ctx[@"log"] = ^{
        DHJSEngine *s = ws; if (!s) return;
        NSArray *args = [JSContext currentArguments];
        NSMutableArray *parts = [NSMutableArray array];
        for (JSValue *a in args) [parts addObject:(a.isUndefined ? @"undefined" : ([a toString] ?: @""))];
        [s emitEvent:@"log" text:[parts componentsJoinedByString:@" "]];
    };

    _ctx.exceptionHandler = ^(JSContext *c, JSValue *e) {
        DHJSEngine *s = ws; if (!s) return;
        NSString *msg = [e toString] ?: @"(unknown)";
        JSValue *line = [e valueForProperty:@"line"];
        NSString *ln = (line && !line.isUndefined) ? [NSString stringWithFormat:@" (行 %@)", line] : @"";
        [s emitEvent:@"error" text:[NSString stringWithFormat:@"JS 异常: %@%@", msg, ln]];
        s->_pendingError = msg;
    };
}

- (NSDictionary *)runScript:(NSString *)src {
    if (src.length == 0) return @{@"ok": @NO, @"error": @"empty script"};
    __block BOOL ok = YES;
    dispatch_sync(_jsQueue, ^{
        self->_pendingError = nil;
        JSValue *r = [self->_ctx evaluateScript:src];
        if (self->_pendingError) {
            ok = NO;   // exceptionHandler 已 emit error 事件
        } else {
            NSString *rs = (r && !r.isUndefined && !r.isNull) ? ([r toString] ?: @"") : @"undefined";
            [self emitEvent:@"run" text:[NSString stringWithFormat:@"脚本已执行 → %@", rs]];
        }
    });
    return @{@"ok": @(ok)};
}

- (void)stop {
    dispatch_sync(_jsQueue, ^{
        [self _setupContextLocked];   // 重建 context, 丢弃用户全局态 (后续 Step 还会在此卸载 hook)
    });
    [self emitEvent:@"event" text:@"⏹ 已停止并复位引擎"];
}

- (NSDictionary *)status {
    os_unfair_lock_lock(&_evLock);
    NSUInteger cnt = _events.count; uint64_t seq = _evSeq;
    os_unfair_lock_unlock(&_evLock);
    return @{@"initialized": @YES, @"eventCount": @(cnt), @"lastSeq": @(seq)};
}

- (void)emitEvent:(NSString *)level text:(NSString *)text {
    NSString *ts = DHTimestampNow();
    os_unfair_lock_lock(&_evLock);
    uint64_t seq = ++_evSeq;
    _evTotal++;
    [_events addObject:@{@"seq": @(seq), @"ts": ts ?: @"", @"level": level ?: @"log", @"text": text ?: @""}];
    if (_events.count > kMaxEvents)
        [_events removeObjectsInRange:NSMakeRange(0, _events.count - kMaxEvents)];
    os_unfair_lock_unlock(&_evLock);
}

- (NSDictionary *)eventsSince:(uint64_t)sinceSeq max:(NSUInteger)maxCount {
    if (maxCount == 0) maxCount = 500;
    NSMutableArray *out = [NSMutableArray array];
    os_unfair_lock_lock(&_evLock);
    uint64_t lastSeq = _evSeq;
    uint64_t total = _evTotal;
    for (NSDictionary *e in _events) {
        if ([e[@"seq"] unsignedLongLongValue] > sinceSeq) {
            [out addObject:e];
            if (out.count >= maxCount) break;
        }
    }
    os_unfair_lock_unlock(&_evLock);
    return @{@"events": out, @"lastSeq": @(lastSeq), @"total": @(total)};
}

@end
