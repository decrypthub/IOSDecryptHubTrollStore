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

extern void _objc_msgForward(void);   // 运行时转发入口, 用作 IMP

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
@end
@implementation DHHookInfo
@end

// ---- 全局注册表 ----
static NSMutableDictionary<NSString *, DHHookInfo *> *gHooks;      // key = "cls指针#selName"
static NSMutableSet<NSValue *>                       *gSwizzled;   // 已接管 forwardInvocation: 的类
static os_unfair_lock                                 gLock = OS_UNFAIR_LOCK_INIT;

static NSString *hookKey(Class cls, NSString *selName) {
    return [NSString stringWithFormat:@"%p#%@", (void *)cls, selName];
}

static BOOL DHSelBlacklisted(NSString *sel) {
    static NSSet *bl; static dispatch_once_t once;
    dispatch_once(&once, ^{
        bl = [NSSet setWithArray:@[
            @"dealloc", @"release", @"retain", @"autorelease", @"retainCount", @"_tryRetain",
            @"forwardInvocation:", @"methodSignatureForSelector:", @"forwardingTargetForSelector:",
            @"respondsToSelector:", @"class", @"self", @"isKindOfClass:", @"allowsWeakReference",
        ]];
    });
    return [bl containsObject:sel];
}

// 沿 superclass 链查 hook 记录(受 gLock 保护)。
static DHHookInfo *lookupHook(Class start, SEL sel) {
    NSString *sn = NSStringFromSelector(sel);
    DHHookInfo *found = nil;
    os_unfair_lock_lock(&gLock);
    for (Class c = start; c; c = class_getSuperclass(c)) {
        DHHookInfo *h = gHooks[hookKey(c, sn)];
        if (h) { found = h; break; }
    }
    os_unfair_lock_unlock(&gLock);
    return found;
}

// 统一 forwardInvocation: trampoline。
static void dh_forwardInvocation(id self, SEL _cmd, NSInvocation *inv) {
    SEL sel = inv.selector;
    DHHookInfo *info = lookupHook(object_getClass(self), sel);
    if (info) {
        @try {
            id<DHInvocationHandler> h = info.handler;
            inv.selector = info.alias;          // 之后 invoke 即跑原实现
            [h dhOnEnter:inv];
            if ([self respondsToSelector:info.alias]) [inv invoke];
            [h dhOnLeave:inv];
        } @catch (NSException *ex) {
            // hook 出错绝不崩目标: 尽力把原实现跑掉以保语义
            @try {
                if (inv.selector != info.alias) inv.selector = info.alias;
                if ([self respondsToSelector:info.alias]) [inv invoke];
            } @catch (__unused NSException *e2) {}
        }
        return;
    }
    // 未命中: 链回目标类原本的 forwardInvocation:(若有), 否则标准报错
    SEL origFwd = @selector(__dh_orig_forwardInvocation:);
    if ([object_getClass(self) instancesRespondToSelector:origFwd]) {
        ((void (*)(id, SEL, NSInvocation *))objc_msgSend)(self, origFwd, inv);
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
        gHooks = [NSMutableDictionary dictionary];
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
    NSString *key = hookKey(target, selectorName);
    DHHookInfo *existing = gHooks[key];
    if (existing) { existing.handler = handler; os_unfair_lock_unlock(&gLock); return nil; }

    SEL alias = NSSelectorFromString([@"__dh_orig_" stringByAppendingString:selectorName]);
    IMP origIMP = method_getImplementation(m);
    class_addMethod(target, alias, origIMP, types);                  // 原实现 → 别名
    class_replaceMethod(target, sel, (IMP)_objc_msgForward, types);  // 目标 → 转发
    [self _ensureForwardSwizzled:target];

    DHHookInfo *info = [DHHookInfo new];
    info.cls = target; info.sel = sel; info.alias = alias; info.origIMP = origIMP;
    info.types = [NSString stringWithUTF8String:types];
    info.handler = handler; info.className = className; info.selName = selectorName;
    info.classMethod = isClassMethod;
    gHooks[key] = info;
    os_unfair_lock_unlock(&gLock);
    return nil;
}

- (void)unhookAll {
    os_unfair_lock_lock(&gLock);
    for (DHHookInfo *info in gHooks.allValues) {
        if (info.cls && info.origIMP)
            class_replaceMethod(info.cls, info.sel, info.origIMP, info.types.UTF8String ?: "v@:@");
    }
    [gHooks removeAllObjects];
    // forwardInvocation: 的接管保持(gHooks 空 → 未命中 → 链回原实现), 下次 hook 可复用。
    os_unfair_lock_unlock(&gLock);
}

- (NSUInteger)activeHookCount {
    os_unfair_lock_lock(&gLock);
    NSUInteger n = gHooks.count;
    os_unfair_lock_unlock(&gLock);
    return n;
}

@end
