// hook_objc_engine.m — 见 hook_objc_engine.h。
//
// 关键点与坑位:
//   - 类方法: target 取元类(object_getClass(cls)), 其上的「实例方法」forwardInvocation:
//     即类的 +forwardInvocation:; 一切逻辑与实例方法同构。
//   - 继承方法: 若目标类自身未实现该方法, class_replaceMethod 会在该类新增(=固化父类实现),
//     只影响该类及子类, 不污染父类的其它实例。
//   - KVO 派生子类: trampoline 里从 object_getClass(self) 沿 superclass 链向上查 hook 记录,
//     命中声明该方法的那层。
//   - 未命中转发: 若目标类原本自带 forwardInvocation:, 我们保存到别名并在未命中时链回, 保持语义。
//   - dealloc/retain/release 等: 黑名单硬拒。

#import "hook_objc_engine.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <time.h>

extern void _objc_msgForward(void);   // 运行时转发入口, 用作 IMP

static const uint64_t kFuseThreshold = 5000;   // 单方法每秒触发超此值 → 熔断(自动卸载), 防手滑 hook 高频方法卡死
static void (*gFuseNotify)(NSString *className, NSString *selName) = NULL;
void dh_objc_set_fuse_notify(void (*fn)(NSString *, NSString *)) { gFuseNotify = fn; }
static uint64_t dh_mono_sec(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec; }

// ---- hook 记录 ----
@interface DHHookInfo : NSObject
@property (nonatomic) Class cls;                 // 实际被改的类(实例方法=类, 类方法=元类)
@property (nonatomic) SEL sel;                   // 目标 selector
@property (nonatomic) SEL alias;                 // 承载原 IMP 的别名 selector
@property (nonatomic) IMP origIMP;               // 原实现(unhook 时还原)
@property (nonatomic, copy) NSString *types;     // 方法类型编码
@property (nonatomic, strong) id<DHInvocationHandler> handler;
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *selName;
@property (nonatomic) BOOL classMethod;
@property (nonatomic) uint64_t fuseHits;         // 当前窗口内触发次数(gLock 保护, 熔断用)
@property (nonatomic) uint64_t fuseWindowSec;    // 当前窗口整秒时间戳
@end
@implementation DHHookInfo
@end

// ---- 全局注册表 ----
// Class → (selName → DHHookInfo)。用 NSMapTable(Class 指针 key) 替代字符串 key, 去掉热路径 stringWithFormat 拼接。
static NSMapTable<Class, NSMutableDictionary<NSString *, DHHookInfo *> *> *gClassHooks;
static NSMutableSet<NSValue *>                                            *gSwizzled;   // 已接管 forwardInvocation: 的类
static os_unfair_lock                                                      gLock = OS_UNFAIR_LOCK_INIT;

static BOOL DHSelBlacklisted(NSString *sel) {
    static NSSet *bl; static dispatch_once_t once;
    dispatch_once(&once, ^{
        bl = [NSSet setWithArray:@[
            // 内存管理: hook 破坏引用计数语义
            @"dealloc", @"release", @"retain", @"autorelease", @"retainCount", @"_tryRetain", @"allowsWeakReference",
            // 转发/自省: 与引擎自身 forwardInvocation 机制冲突
            @"forwardInvocation:", @"methodSignatureForSelector:", @"forwardingTargetForSelector:",
            @"respondsToSelector:", @"class", @"self", @"isKindOfClass:",
            // +1 所有权工厂方法: 改返回值会 ARC over-release 崩溃
            @"alloc", @"allocWithZone:", @"new", @"copy", @"copyWithZone:", @"mutableCopy", @"mutableCopyWithZone:",
            // 可变参数方法: NSInvocation 无法表达 va_list, hook 后 invoke 会读野指针/行为错乱
            @"stringWithFormat:", @"stringByAppendingFormat:", @"appendFormat:", @"initWithFormat:",
            @"localizedStringWithFormat:", @"predicateWithFormat:",
            @"arrayWithObjects:", @"dictionaryWithObjectsAndKeys:", @"setWithObjects:",
        ]];
    });
    return [bl containsObject:sel];
}

// 沿 superclass 链查 hook 记录 + 高频熔断统计(受 gLock 保护)。
// 命中后统计当前秒触发次数, 超 kFuseThreshold 则就地卸载(恢复 IMP + 移除表)并置 *outFused,
// 防手滑 hook 高频方法把 App 卡死。恢复 IMP 是原子替换, 正在执行的本次调用走 alias 不受影响。
static DHHookInfo *lookupHook(Class start, SEL sel, BOOL *outFused) {
    if (outFused) *outFused = NO;
    NSString *sn = NSStringFromSelector(sel);
    DHHookInfo *found = nil;
    os_unfair_lock_lock(&gLock);
    for (Class c = start; c; c = class_getSuperclass(c)) {
        NSMutableDictionary *m = [gClassHooks objectForKey:c];
        if (m) { found = m[sn]; if (found) break; }
    }
    if (found) {
        uint64_t nowSec = dh_mono_sec();
        if (found.fuseWindowSec != nowSec) { found.fuseWindowSec = nowSec; found.fuseHits = 0; }
        if (++found.fuseHits > kFuseThreshold) {
            if (found.cls && found.origIMP)
                class_replaceMethod(found.cls, found.sel, found.origIMP, found.types.UTF8String ?: "v@:@");
            NSMutableDictionary *bucket = [gClassHooks objectForKey:found.cls];
            [bucket removeObjectForKey:found.selName];
            if (outFused) *outFused = YES;
        }
    }
    os_unfair_lock_unlock(&gLock);
    return found;
}

// 统一 forwardInvocation: trampoline。
//
// 异常语义(关键, 三段式): 严格区分"谁抛的异常"——
//   ① onEnter / ③ onLeave 是 JS hook 侧回调: 抛异常吞掉(下层 runProtected 已记录), 绝不影响宿主;
//   ② 原实现 [inv invoke]: **不包 @try**, 让原方法自身的 NSException 沿栈透传回 App。
//      hook 调试器的天职是"观察而不改变": 若吞掉原方法异常, 上层本该 catch 的就 catch 不到,
//      等于悄悄改了 App 行为(最难查的海森堡 bug), 还让本该崩的进程带损坏状态续命。
//   原实现全程只在 ② 处 invoke 一次(不再有 catch 里的兜底 invoke)→ 从根上杜绝原方法重复执行/重复副作用。
static void dh_forwardInvocation(id self, SEL _cmd, NSInvocation *inv) {
    SEL sel = inv.selector;
    BOOL fused = NO;
    DHHookInfo *info = lookupHook(object_getClass(self), sel, &fused);
    if (info) {
        // alias 一定在(hookClass 安装时已校验 class_addMethod 成功); 沿链查 Method 直调,
        // 不走 respondsToSelector: 的动态解析(可能被目标类重写, 且是多余的一层)。
        Method aliasMethod = class_getInstanceMethod(info.cls, info.alias);
        inv.selector = info.alias;                  // invoke 即跑原实现
        if (fused) {   // 已熔断卸载: 本次仍跑原实现一次(原方法异常照样透传), 之后调用走恢复的 IMP(不再进 trampoline)
            if (gFuseNotify) gFuseNotify(info.className, info.selName);
            if (aliasMethod) [inv invoke];
            return;
        }
        id<DHInvocationHandler> h = info.handler;
        @try { [h dhOnEnter:inv]; }                 // ① JS onEnter 异常: 吞, 继续跑原实现(App 不因 hook 挂了就少执行)
        @catch (__unused NSException *e) {}
        if (aliasMethod) [inv invoke];              // ② 原实现: 不 catch, 异常透传保宿主语义; 全程只此一次
        @try { [h dhOnLeave:inv]; }                 // ③ JS onLeave 异常: 吞; 原方法已执行, 绝不重复
        @catch (__unused NSException *e) {}
        return;
    }
    // 未命中: 链回目标类原本的 forwardInvocation:(若有, 沿链取 IMP 直调, 继承安全且省一层动态派发), 否则标准报错
    SEL origFwd = @selector(__dh_orig_forwardInvocation:);
    Method om = class_getInstanceMethod(object_getClass(self), origFwd);
    if (om) {
        ((void (*)(id, SEL, NSInvocation *))method_getImplementation(om))(self, origFwd, inv);
    } else {
        [self doesNotRecognizeSelector:sel];
    }
}

@implementation DHObjCEngine

+ (instancetype)shared {
    static DHObjCEngine *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [DHObjCEngine new];
        gClassHooks = [NSMapTable strongToStrongObjectsMapTable];
        gSwizzled = [NSMutableSet set];
    });
    return s;
}

// 接管某类的 forwardInvocation:(每类一次)。须在 gLock 内调用。
- (void)_ensureForwardSwizzled:(Class)cls {
    NSValue *k = [NSValue valueWithNonretainedObject:cls];
    if ([gSwizzled containsObject:k]) return;
    SEL fwd = @selector(forwardInvocation:);
    SEL origFwd = @selector(__dh_orig_forwardInvocation:);
    Method fm = class_getInstanceMethod(cls, fwd);      // 至少继承自 NSObject
    IMP oldFwd = fm ? method_getImplementation(fm) : NULL;
    const char *fwdTypes = fm ? method_getTypeEncoding(fm) : "v@:@";
    if (oldFwd) class_addMethod(cls, origFwd, oldFwd, fwdTypes);
    class_replaceMethod(cls, fwd, (IMP)dh_forwardInvocation, "v@:@");
    [gSwizzled addObject:k];
}

- (NSString *)hookClass:(NSString *)className
               selector:(NSString *)selectorName
            classMethod:(BOOL)isClassMethod
                handler:(id<DHInvocationHandler>)handler {
    if (className.length == 0 || selectorName.length == 0) return @"类名或方法名为空";
    if (DHSelBlacklisted(selectorName))
        return [NSString stringWithFormat:@"方法 %@ 在黑名单, 禁止 hook", selectorName];

    Class cls = objc_getClass(className.UTF8String);
    if (!cls) return [NSString stringWithFormat:@"找不到类 %@", className];
    Class target = isClassMethod ? object_getClass(cls) : cls;   // 类方法在元类上
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(target, sel);
    if (!m) return [NSString stringWithFormat:@"%@ 没有%@方法 %@", className, isClassMethod ? @"类" : @"实例", selectorName];

    const char *types = method_getTypeEncoding(m);
    if (!types) return @"无法取得方法类型编码";
    NSMethodSignature *sig = nil;
    @try { sig = [NSMethodSignature signatureWithObjCTypes:types]; } @catch (__unused NSException *e) {}
    if (!sig) return @"方法签名不受支持, 拒绝 hook";

    os_unfair_lock_lock(&gLock);
    NSMutableDictionary *bucket = [gClassHooks objectForKey:target];
    DHHookInfo *existing = bucket[selectorName];
    if (existing) { existing.handler = handler; os_unfair_lock_unlock(&gLock); return nil; }

    SEL alias = NSSelectorFromString([@"__dh_orig_" stringByAppendingString:selectorName]);
    IMP origIMP = method_getImplementation(m);
    // 先保存原实现到别名; 若别名已存在(addMethod 返回 NO)则无法保存, 直接拒绝——
    // 否则继续把 sel 换成 _objc_msgForward 会永久丢失原实现。保证"hook 成功 ⟹ alias 一定在",
    // trampoline 热路径的 aliasMethod 检查因此成为纯防御。
    if (!class_addMethod(target, alias, origIMP, types)) {
        os_unfair_lock_unlock(&gLock);
        return [NSString stringWithFormat:@"无法保存 %@ 的原实现(别名冲突), 拒绝 hook", selectorName];
    }
    class_replaceMethod(target, sel, (IMP)_objc_msgForward, types);  // 目标 → 转发
    [self _ensureForwardSwizzled:target];

    DHHookInfo *info = [DHHookInfo new];
    info.cls = target; info.sel = sel; info.alias = alias; info.origIMP = origIMP;
    info.types = [NSString stringWithUTF8String:types];
    info.handler = handler; info.className = className; info.selName = selectorName;
    info.classMethod = isClassMethod;
    if (!bucket) { bucket = [NSMutableDictionary dictionary]; [gClassHooks setObject:bucket forKey:target]; }
    bucket[selectorName] = info;
    os_unfair_lock_unlock(&gLock);
    return nil;
}

- (void)unhookAll {
    os_unfair_lock_lock(&gLock);
    for (NSMutableDictionary *bucket in [gClassHooks objectEnumerator]) {
        for (DHHookInfo *info in bucket.allValues) {
            if (info.cls && info.origIMP)
                class_replaceMethod(info.cls, info.sel, info.origIMP, info.types.UTF8String ?: "v@:@");
        }
    }
    [gClassHooks removeAllObjects];
    // forwardInvocation: 的接管保持(表空 → 未命中 → 链回原实现), 下次 hook 可复用。
    os_unfair_lock_unlock(&gLock);
}

- (NSUInteger)activeHookCount {
    os_unfair_lock_lock(&gLock);
    NSUInteger n = 0;
    for (NSMutableDictionary *bucket in [gClassHooks objectEnumerator]) n += bucket.count;
    os_unfair_lock_unlock(&gLock);
    return n;
}

@end
