// hook_objc_engine.h — 通用 ObjC 方法 hook 引擎(swizzle + forwardInvocation: trampoline)。
//
// 能 hook 任意类的任意实例/类方法, 无需汇编/libffi(Aspects 路线):
//   目标 SEL 原 IMP 存到别名 SEL → 目标 SEL 指向 _objc_msgForward → 接管该类
//   forwardInvocation:, 命中时把 NSInvocation 交给 handler(onEnter/onLeave)再 invoke 原实现。
//
// 本引擎只负责「机制」, 不认识 JS。参数解码/回调 JS 由上层(js_engine.m 的 DHScriptHook)做。

#ifndef DH_HOOK_OBJC_ENGINE_H
#define DH_HOOK_OBJC_ENGINE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// hook 命中时引擎的回调: onEnter 在跑原实现前, onLeave 在跑原实现后。
// 传入的 NSInvocation.selector 已被指向别名(invoke 即跑原实现); 读写参数/返回值即在此 inv 上进行。
@protocol DHInvocationHandler <NSObject>
- (void)dhOnEnter:(NSInvocation *)inv;
- (void)dhOnLeave:(NSInvocation *)inv;
@end

@interface DHObjCEngine : NSObject

+ (instancetype)shared;

// hook className 的实例(isClassMethod=NO)或类(YES)方法 selectorName。
// 成功返回 nil; 失败返回中文错误描述(类/方法不存在、黑名单、签名不支持等)。
// 同一 (类,方法) 重复 hook 只更新 handler。handler 被强引用直到 unhookAll。
- (nullable NSString *)hookClass:(NSString *)className
                        selector:(NSString *)selectorName
                     classMethod:(BOOL)isClassMethod
                         handler:(id<DHInvocationHandler>)handler;

// 恢复所有被 hook 方法的原 IMP 并清空规则(stop 时调用)。
- (void)unhookAll;

- (NSUInteger)activeHookCount;

@end

// 熔断告警回调: 某方法触发频率爆表被自动卸载时调用(供 DHJSEngine 转成脚本事件)。
void dh_objc_set_fuse_notify(void (*fn)(NSString *className, NSString *selName));

NS_ASSUME_NONNULL_END

#endif // DH_HOOK_OBJC_ENGINE_H
