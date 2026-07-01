// js_engine.h — 进程内 JavaScriptCore 引擎, 「JS 规则驱动的 Hook 调试器」的核心。
//
// 用户在 Web「脚本」页写 JS, POST /api/script/run 交到这里的 JSContext 执行。
// 第一版(Step 0)只提供 log(...) 输出 + 独立环形事件缓冲, 事件经 /api/script/events
// 键集分页回流网页。后续 Step 在此之上注入 ObjC/Symbol/... 命名空间做动态 hook。
//
// 事件缓冲独立于 DHLogStore(取证日志), 脚本高频事件不污染落盘取证记录。

#ifndef DH_JS_ENGINE_H
#define DH_JS_ENGINE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DHJSEngine : NSObject

+ (instancetype)shared;

// 同步执行一段用户 JS 源码(在专用串行 jsQueue 上)。返回 @{@"ok":@(BOOL)}。
// 执行中的 log()/异常都会进事件缓冲, 前端从 /api/script/events 拉。
- (NSDictionary *)runScript:(NSString *)src;

// 停止: 清空已装规则(后续 Step) 并重建 JSContext(丢弃用户全局态)。不清事件缓冲。
- (void)stop;

// 引擎状态: @{@"initialized":@(BOOL), @"eventCount":@(n), @"lastSeq":@(seq)}。
- (NSDictionary *)status;

// 拉取 seq > sinceSeq 的事件(最旧在前, 最多 maxCount 条)。
// 返回 @{@"events":@[@{seq,ts,level,text}...], @"lastSeq":@(n), @"total":@(累计事件数)}。
- (NSDictionary *)eventsSince:(uint64_t)sinceSeq max:(NSUInteger)maxCount;

// 供 native hook adapter(Step 1+) 回流事件。level 约定: log/warn/error/event/run。
// 线程安全, 可在任意线程(含 hook 现场)调用。
- (void)emitEvent:(NSString *)level text:(nullable NSString *)text;

@end

NS_ASSUME_NONNULL_END

#endif // DH_JS_ENGINE_H
