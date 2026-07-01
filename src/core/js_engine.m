// js_engine.m — 见 js_engine.h。
//
// 线程模型: 所有对 JSContext 的访问都串行化到 _jsQueue(JSContext 非线程安全)。
//   - runScript / stop: dispatch_sync 到 _jsQueue。
//   - log() 回调在 evaluateScript 的同线程(即 _jsQueue)触发 → emitEvent。
// 事件缓冲: 独立环形数组 + os_unfair_lock, 可被 HTTP worker 线程(eventsSince) 与
//   _jsQueue(emitEvent) 并发访问, 用锁而非队列, 避免高频轮询和脚本执行互相排队。

#import "js_engine.h"
#import "log_store.h"          // DHTimestampNow
#import "dh_health.h"          // dh_in_script
#import "hook_objc_engine.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <time.h>

// jsQueue 身份标记, 用于 dispatch_get_specific 判断「当前是否已在 jsQueue」以避免 dispatch_sync 自死锁。
static void *kJSQueueKey = &kJSQueueKey;

@interface DHJSEngine (Internal)
- (BOOL)runProtected:(void (^)(void))block;   // jsQueue + dh_in_script 内跑 block; 返回 NO=抛异常
- (void)_jsRegisterObjCHook:(JSValue *)cfg;
@end

#pragma mark - NSInvocation 参数/返回值 → JS 值 解码 (Step 1: 只读)

// 把一个对象转成对 JS 友好的可读表示。调用方须已在 dh_in_script 保护内(可能触发被 hook 方法)。
static id DHDescribeObject(id o) {
    if (!o) return @"nil";
    if ([o isKindOfClass:[NSString class]]) { NSString *s = o; return (s.length > 512) ? [[s substringToIndex:512] stringByAppendingString:@"…"] : s; }
    if ([o isKindOfClass:[NSNumber class]]) return o;
    if ([o isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"<NSData %lu bytes>", (unsigned long)[(NSData *)o length]];
    if ([o isKindOfClass:[NSArray class]] || [o isKindOfClass:[NSDictionary class]]) {
        NSString *s = [o description];
        return (s.length > 200) ? [[s substringToIndex:200] stringByAppendingString:@"…"] : s;
    }
    return [NSString stringWithFormat:@"<%@: %p>", NSStringFromClass(object_getClass(o)), (void *)o];
}

// 单个值按类型编码解码(先跳过 r/n/N/... 限定符)。
static id DHDecodeOne(const char *type, void *buf) {
    if (!type || !type[0]) return @"?";
    while (*type=='r'||*type=='n'||*type=='N'||*type=='o'||*type=='O'||*type=='R'||*type=='V') type++;
    switch (type[0]) {
        case '@': { __unsafe_unretained id o = *(__unsafe_unretained id *)buf; return DHDescribeObject(o); }
        case '#': { Class c = *(Class *)buf; return c ? NSStringFromClass(c) : @"(nil Class)"; }
        case ':': { SEL s = *(SEL *)buf; return s ? NSStringFromSelector(s) : @"(null SEL)"; }
        case 'c': return @(*(char *)buf);
        case 'C': return @(*(unsigned char *)buf);
        case 's': return @(*(short *)buf);
        case 'S': return @(*(unsigned short *)buf);
        case 'i': return @(*(int *)buf);
        case 'I': return @(*(unsigned int *)buf);
        case 'l': return @(*(long *)buf);
        case 'L': return @(*(unsigned long *)buf);
        case 'q': return @(*(long long *)buf);
        case 'Q': return @(*(unsigned long long *)buf);
        case 'f': return @(*(float *)buf);
        case 'd': return @(*(double *)buf);
        case 'B': return @(*(bool *)buf ? YES : NO);
        case '*': { char *s = *(char **)buf; return s ? [NSString stringWithUTF8String:s] : @"(null char*)"; }
        case '^': { void *p = *(void **)buf; return [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)p]; }
        case '{': return [NSString stringWithFormat:@"(struct %s)", type];
        case '(': return [NSString stringWithFormat:@"(union %s)", type];
        case '[': return @"(array)";
        default:  return [NSString stringWithFormat:@"(?%s)", type];
    }
}

static id DHDecodeArgAt(NSInvocation *inv, NSUInteger idx) {
    const char *type = [inv.methodSignature getArgumentTypeAtIndex:idx];
    NSUInteger sz = 0, al = 0;
    @try { NSGetSizeAndAlignment(type, &sz, &al); } @catch (__unused NSException *e) { sz = sizeof(void *); }
    if (sz == 0) sz = sizeof(void *);
    void *buf = calloc(1, sz + 16);
    id r;
    @try { [inv getArgument:buf atIndex:idx]; r = DHDecodeOne(type, buf); }
    @catch (__unused NSException *e) { r = @"(读取失败)"; }
    free(buf);
    return r ?: [NSNull null];
}

static NSArray *DHDecodeArgs(NSInvocation *inv) {
    NSMutableArray *a = [NSMutableArray array];
    NSUInteger n = inv.methodSignature.numberOfArguments;   // 0=self 1=_cmd, 业务参数从 2 起
    for (NSUInteger i = 2; i < n; i++) [a addObject:DHDecodeArgAt(inv, i)];
    return a;
}

static id DHDecodeRet(NSInvocation *inv) {
    const char *type = inv.methodSignature.methodReturnType;
    if (!type || type[0] == 'v') return @"(void)";
    NSUInteger sz = inv.methodSignature.methodReturnLength;
    if (sz == 0) sz = sizeof(void *);
    void *buf = calloc(1, sz + 16);
    id r;
    @try { [inv getReturnValue:buf]; r = DHDecodeOne(type, buf); }
    @catch (__unused NSException *e) { r = @"(读取失败)"; }
    free(buf);
    return r ?: [NSNull null];
}

static NSDictionary *DHInvInfo(NSInvocation *inv, NSString *cn, NSString *sn) {
    return @{@"class": cn ?: @"?", @"selector": sn ?: @"?", @"self": DHDescribeObject(inv.target)};
}

#pragma mark - ObjC 类/方法枚举 (供 ObjC.trace) + 上层 adapter prelude

// 跳过系统 image 的类, 只留目标 App/注入 dylib 自己的类(否则 trace 会打爆)。
static BOOL DHIsSystemClass(Class c) {
    const char *img = class_getImageName(c);
    if (!img) return YES;   // 动态生成/无镜像 → 视为系统, 跳过
    return strstr(img, "/System/") != NULL || strstr(img, "/usr/") != NULL || strstr(img, "/Library/") != NULL;
}

// 遍历非系统类, 按类名/方法名正则匹配实例方法, 返回 [{cls, sel}] (限 limit)。
static NSArray *DHEnumerateMatches(NSString *classPat, NSString *selPat, NSInteger limit) {
    if (limit <= 0 || limit > 2000) limit = 300;
    NSRegularExpression *cre = classPat.length ? [NSRegularExpression regularExpressionWithPattern:classPat options:0 error:nil] : nil;
    NSRegularExpression *sre = selPat.length  ? [NSRegularExpression regularExpressionWithPattern:selPat  options:0 error:nil] : nil;
    NSMutableArray *out = [NSMutableArray array];
    unsigned int nc = 0;
    Class *classes = objc_copyClassList(&nc);
    for (unsigned int i = 0; i < nc && (NSInteger)out.count < limit; i++) {
        Class c = classes[i];
        if (DHIsSystemClass(c)) continue;
        NSString *cn = NSStringFromClass(c);
        if (!cn) continue;
        if (cre && [cre numberOfMatchesInString:cn options:0 range:NSMakeRange(0, cn.length)] == 0) continue;
        unsigned int nm = 0;
        Method *methods = class_copyMethodList(c, &nm);
        for (unsigned int j = 0; j < nm && (NSInteger)out.count < limit; j++) {
            NSString *sn = NSStringFromSelector(method_getName(methods[j]));
            if (!sn) continue;
            if (sre && [sre numberOfMatchesInString:sn options:0 range:NSMakeRange(0, sn.length)] == 0) continue;
            [out addObject:@{@"cls": cn, @"sel": sn}];
        }
        if (methods) free(methods);
    }
    if (classes) free(classes);
    return out;
}

// 纯 JS 上层 adapter, 每次(重)建 context 后注入。建在 native 原语 ObjC.hook / ObjC.enumerate 之上。
static NSString *const kDHPrelude =
    @"(function(){\n"
    "  ObjC.trace = function(cfg){\n"
    "    cfg = cfg || {};\n"
    "    var lim = cfg.limit || 300;\n"
    "    var matches = ObjC.enumerate(cfg.classRegex||'', cfg.selectorRegex||'', lim);\n"
    "    var oe = cfg.onEnter, ol = cfg.onLeave, n = 0;\n"
    "    for (var i=0;i<matches.length;i++){\n"
    "      ObjC.hook({class:matches[i].cls, selector:matches[i].sel,\n"
    "        onEnter: oe || function(a,info){ log('→ ['+info.class+' '+info.selector+']'); },\n"
    "        onLeave: ol});\n"
    "      n++;\n"
    "    }\n"
    "    log('ObjC.trace: 匹配并 hook '+n+' 个方法'+(matches.length>=lim?' (已达上限 '+lim+', 用更精确正则缩小)':''));\n"
    "    return n;\n"
    "  };\n"
    "  var Notification = { trace: function(cfg){\n"
    "    cfg = cfg || {};\n"
    "    var re = cfg.nameRegex ? new RegExp(cfg.nameRegex) : null, onPost = cfg.onPost;\n"
    "    ObjC.hook({class:'NSNotificationCenter', selector:'- postNotificationName:object:userInfo:',\n"
    "      onEnter:function(a,info){ var name=a[0];\n"
    "        if (re && !re.test(name)) return;\n"
    "        if (onPost) onPost({name:name, object:a[1], userInfo:a[2]});\n"
    "        else log('📢 '+name+' userInfo='+a[2]); }});\n"
    "    log('Notification.trace 已挂 NSNotificationCenter.postNotificationName');\n"
    "  }};\n"
    "  var TargetAction = { trace: function(cfg){\n"
    "    cfg = cfg || {};\n"
    "    var onSend = cfg.onSend;\n"
    "    ObjC.hook({class:'UIApplication', selector:'- sendAction:to:from:forEvent:',\n"
    "      onEnter:function(a,info){\n"
    "        if (onSend) onSend({action:a[0], target:a[1], sender:a[2]});\n"
    "        else log('🎯 action='+a[0]+' target='+a[1]); }});\n"
    "    log('TargetAction.trace 已挂 UIApplication.sendAction (仅 iOS 有效)');\n"
    "  }};\n"
    "  this.Notification = Notification; this.TargetAction = TargetAction;\n"
    "})();\n";

#pragma mark - JS 值 → NSInvocation 参数/返回值 写回 (Step 2: 改参 + 改返回)

// 把一个 JS 值按类型编码写回(argIdx>=0 写参数, <0 写返回值)。返回是否支持写回。
// 第一版支持: id(@, 用 JSValue.toObject → NSString/NSNumber/NSArray/NSDictionary/NSDate) + 全部数值/bool;
// SEL/Class/C字符串/裸指针/结构体 不支持写回(只读)。
static BOOL DHWriteValue(NSInvocation *inv, JSValue *val, const char *type, NSInteger argIdx) {
    if (!type) return NO;
    while (*type=='r'||*type=='n'||*type=='N'||*type=='o'||*type=='O'||*type=='R'||*type=='V') type++;
    if (type[0] == '@') {
        id o = [val toObject];
        if (argIdx >= 0) [inv setArgument:&o atIndex:argIdx]; else [inv setReturnValue:&o];
        return YES;
    }
    NSNumber *num = [val toNumber];
    if (!num) return NO;
#define DH_SET(T, EXPR) do { T _v = (T)(EXPR); \
    if (argIdx >= 0) [inv setArgument:&_v atIndex:argIdx]; else [inv setReturnValue:&_v]; } while (0)
    switch (type[0]) {
        case 'c': case 'B': DH_SET(char, num.charValue); return YES;
        case 'C': DH_SET(unsigned char, num.unsignedCharValue); return YES;
        case 's': DH_SET(short, num.shortValue); return YES;
        case 'S': DH_SET(unsigned short, num.unsignedShortValue); return YES;
        case 'i': DH_SET(int, num.intValue); return YES;
        case 'I': DH_SET(unsigned int, num.unsignedIntValue); return YES;
        case 'l': DH_SET(long, num.longValue); return YES;
        case 'L': DH_SET(unsigned long, num.unsignedLongValue); return YES;
        case 'q': DH_SET(long long, num.longLongValue); return YES;
        case 'Q': DH_SET(unsigned long long, num.unsignedLongLongValue); return YES;
        case 'f': DH_SET(float, num.floatValue); return YES;
        case 'd': DH_SET(double, num.doubleValue); return YES;
        default: return NO;
    }
#undef DH_SET
}

// onEnter 返回数组 → 逐位写回业务参数(undefined/null 元素跳过, 不改该位)。
static void DHApplyArgOverrides(NSInvocation *inv, JSValue *result) {
    if (!result || !result.isArray) return;
    NSUInteger n = inv.methodSignature.numberOfArguments;
    NSUInteger len = [[result[@"length"] toNumber] unsignedIntegerValue];
    BOOL retained = NO;
    for (NSUInteger i = 0; i + 2 < n && i < len; i++) {
        JSValue *v = result[i];
        if (v.isUndefined || v.isNull) continue;
        if (!retained) { [inv retainArguments]; retained = YES; }   // 保参数(尤其 id)存活到 invoke
        DHWriteValue(inv, v, [inv.methodSignature getArgumentTypeAtIndex:i + 2], (NSInteger)(i + 2));
    }
}

// onLeave 返回非 undefined/null → 用作新返回值。
static void DHApplyReturnOverride(NSInvocation *inv, JSValue *result) {
    if (!result || result.isUndefined || result.isNull) return;
    const char *t = inv.methodSignature.methodReturnType;
    if (!t || t[0] == 'v') return;
    [inv retainArguments];
    DHWriteValue(inv, result, t, -1);
}

#pragma mark - DHScriptHook: 把引擎回调桥接到 JS onEnter/onLeave (含限频 / 自动禁用)

static const int    kHookMaxPerSec   = 100;   // 每规则每秒最多触发 JS 次数, 超出放行不调 JS
static const int    kHookMaxErrors   = 5;     // 连续异常达此数 → 自动禁用该规则
static const double kHookWatchdogSec = 1.0;   // 单次回调耗时超此值告警(JS 无法强杀, 仅提示)

static double DHMonoNow(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

@interface DHScriptHook : NSObject <DHInvocationHandler>
- (instancetype)initWithEngine:(DHJSEngine *)e className:(NSString *)cn selector:(NSString *)sn
                       onEnter:(nullable JSValue *)oe onLeave:(nullable JSValue *)ol;
@end

@implementation DHScriptHook {
    __weak DHJSEngine *_engine;
    NSString *_className, *_selName;
    JSValue  *_onEnter, *_onLeave;
    BOOL      _disabled;
    int       _errCount;
    os_unfair_lock _rateLock;
    double    _windowStart;
    int       _windowCount, _windowDropped;
}
- (instancetype)initWithEngine:(DHJSEngine *)e className:(NSString *)cn selector:(NSString *)sn
                       onEnter:(JSValue *)oe onLeave:(JSValue *)ol {
    if ((self = [super init])) {
        _engine = e; _className = [cn copy]; _selName = [sn copy]; _onEnter = oe; _onLeave = ol;
        _rateLock = OS_UNFAIR_LOCK_INIT; _windowStart = DHMonoNow();
    }
    return self;
}
// 每秒限频窗口: 超额返回 NO(放行不调 JS)。跨线程并发用锁保护计数。
- (BOOL)_rateOK {
    double now = DHMonoNow();
    os_unfair_lock_lock(&_rateLock);
    if (now - _windowStart >= 1.0) {
        int dropped = _windowDropped;
        _windowStart = now; _windowCount = 0; _windowDropped = 0;
        os_unfair_lock_unlock(&_rateLock);
        if (dropped > 0) [_engine emitEvent:@"warn" text:[NSString stringWithFormat:@"⏱ 规则 [%@] 上一秒限频丢弃 %d 次触发", _selName, dropped]];
        os_unfair_lock_lock(&_rateLock);
    }
    BOOL ok = (_windowCount < kHookMaxPerSec);
    if (ok) _windowCount++; else _windowDropped++;
    os_unfair_lock_unlock(&_rateLock);
    return ok;
}
- (void)_afterRun:(BOOL)ok {
    if (ok) { _errCount = 0; return; }
    if (++_errCount >= kHookMaxErrors) {
        _disabled = YES;
        [_engine emitEvent:@"warn" text:[NSString stringWithFormat:@"⛔ 规则 [%@ %@] 连续 %d 次异常, 已自动禁用", _className, _selName, _errCount]];
    }
}
- (void)dhOnEnter:(NSInvocation *)inv {
    DHJSEngine *e = _engine; if (!e || !_onEnter || _disabled) return;
    if (![self _rateOK]) return;
    JSValue *fn = _onEnter; NSString *cn = _className, *sn = _selName;
    BOOL ok = [e runProtected:^{
        JSValue *res = [fn callWithArguments:@[DHDecodeArgs(inv), DHInvInfo(inv, cn, sn)]];
        DHApplyArgOverrides(inv, res);
    }];
    [self _afterRun:ok];
}
- (void)dhOnLeave:(NSInvocation *)inv {
    DHJSEngine *e = _engine; if (!e || !_onLeave || _disabled) return;
    if (![self _rateOK]) return;
    JSValue *fn = _onLeave; NSString *cn = _className, *sn = _selName;
    BOOL ok = [e runProtected:^{
        JSValue *res = [fn callWithArguments:@[DHDecodeRet(inv), DHInvInfo(inv, cn, sn)]];
        DHApplyReturnOverride(inv, res);
    }];
    [self _afterRun:ok];
}
@end

static const NSUInteger kMaxEvents = 5000;   // 事件环形缓冲上限, 超出丢最旧

@implementation DHJSEngine {
    dispatch_queue_t   _jsQueue;
    JSContext         *_ctx;
    NSString          *_pendingError;   // 仅 _jsQueue 内访问: 本次 evaluateScript 是否抛异常
    NSMutableArray    *_hooks;          // 强引用所有 DHScriptHook, 防释放; stop 时清

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
        dispatch_queue_set_specific(_jsQueue, kJSQueueKey, kJSQueueKey, NULL);
        _evLock  = OS_UNFAIR_LOCK_INIT;
        _events  = [NSMutableArray array];
        _hooks   = [NSMutableArray array];
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

    // ObjC 命名空间: ObjC.hook({class, selector, onEnter, onLeave})
    JSValue *objcNS = [JSValue valueWithNewObjectInContext:_ctx];
    objcNS[@"hook"] = ^(JSValue *cfg) {
        DHJSEngine *s = ws; if (!s) return;
        [s _jsRegisterObjCHook:cfg];
    };
    objcNS[@"enumerate"] = ^id(JSValue *classRe, JSValue *selRe, JSValue *limit) {
        NSString *cp = classRe.isString ? [classRe toString] : nil;
        NSString *sp = selRe.isString  ? [selRe toString]  : nil;
        NSInteger lim = limit.isNumber ? (NSInteger)[limit toInt32] : 300;
        return DHEnumerateMatches(cp, sp, lim);
    };
    _ctx[@"ObjC"] = objcNS;

    // 上层 adapter(纯 JS): ObjC.trace / Notification.trace / TargetAction.trace
    [_ctx evaluateScript:kDHPrelude];
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
    [[DHObjCEngine shared] unhookAll];        // 先停止一切 hook 触发
    dispatch_sync(_jsQueue, ^{
        [self->_hooks removeAllObjects];
        [self _setupContextLocked];           // 重建 context, 丢弃用户全局态
    });
    [self emitEvent:@"event" text:@"⏹ 已停止并复位引擎(卸载全部 hook)"];
}

- (NSDictionary *)status {
    os_unfair_lock_lock(&_evLock);
    NSUInteger cnt = _events.count; uint64_t seq = _evSeq;
    os_unfair_lock_unlock(&_evLock);
    return @{@"initialized": @YES, @"eventCount": @(cnt), @"lastSeq": @(seq),
             @"hooks": @([[DHObjCEngine shared] activeHookCount])};
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

// 在 jsQueue + dh_in_script 保护下调用一个 JS hook 回调。argsBuilder 也在保护内执行
// (解码 NSInvocation 可能触发被 hook 的方法, 需同一保护防重入)。
// 在 jsQueue + dh_in_script 保护下同步执行 block(调 JS + 解码 + 写回都在内)。返回 NO=block 抛异常。
- (BOOL)runProtected:(void (^)(void))block {
    if (dh_in_script) return YES;   // 已在脚本上下文(重入): 放行, 不重复执行
    __block BOOL ok = YES;
    dispatch_block_t work = ^{
        if (dh_in_script) return;
        dh_in_script = 1;
        double t0 = DHMonoNow();
        @try {
            block();
        } @catch (NSException *ex) {
            ok = NO;
            [self emitEvent:@"error" text:[NSString stringWithFormat:@"hook 回调异常: %@", ex.reason ?: @"?"]];
        }
        double dt = DHMonoNow() - t0;
        if (dt > kHookWatchdogSec)
            [self emitEvent:@"warn" text:[NSString stringWithFormat:@"⏱ 一次 hook 回调耗时 %.2fs (JS 无法强制中断, 当心死循环)", dt]];
        dh_in_script = 0;
    };
    if (dispatch_get_specific(kJSQueueKey)) work();   // 已在 jsQueue: 直接跑, 避免自死锁
    else dispatch_sync(_jsQueue, work);
    return ok;
}

// ObjC.hook 的 native 落地: 在 jsQueue 上解析 cfg, 交 DHObjCEngine 安装, 记录 DHScriptHook。
- (void)_jsRegisterObjCHook:(JSValue *)cfg {
    if (!cfg || !cfg.isObject) { [self emitEvent:@"error" text:@"ObjC.hook 需要一个配置对象"]; return; }
    NSString *className = [cfg[@"class"] toString];
    NSString *rawSel    = [cfg[@"selector"] toString];
    JSValue  *onEnter   = cfg[@"onEnter"];
    JSValue  *onLeave   = cfg[@"onLeave"];
    if (className.length == 0 || rawSel.length == 0) {
        [self emitEvent:@"error" text:@"ObjC.hook 需要 class 与 selector"]; return;
    }
    BOOL isClass = NO;
    NSCharacterSet *wsp = [NSCharacterSet whitespaceCharacterSet];
    NSString *selName = [rawSel stringByTrimmingCharactersInSet:wsp];
    if ([selName hasPrefix:@"+"]) { isClass = YES; selName = [[selName substringFromIndex:1] stringByTrimmingCharactersInSet:wsp]; }
    else if ([selName hasPrefix:@"-"]) { selName = [[selName substringFromIndex:1] stringByTrimmingCharactersInSet:wsp]; }
    JSValue *cm = cfg[@"classMethod"];
    if (cm && cm.isBoolean && [cm toBool]) isClass = YES;

    DHScriptHook *hook = [[DHScriptHook alloc] initWithEngine:self
                                                    className:className
                                                     selector:selName
                                                      onEnter:(onEnter.isUndefined ? nil : onEnter)
                                                      onLeave:(onLeave.isUndefined ? nil : onLeave)];
    NSString *err = [[DHObjCEngine shared] hookClass:className selector:selName classMethod:isClass handler:hook];
    if (err) { [self emitEvent:@"error" text:[NSString stringWithFormat:@"ObjC.hook 失败: %@", err]]; return; }
    [_hooks addObject:hook];
    [self emitEvent:@"event" text:[NSString stringWithFormat:@"✔ 已 hook %@[%@ %@]", isClass ? @"+" : @"-", className, selName]];
}

@end
