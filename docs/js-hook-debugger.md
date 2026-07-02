# JS 脚本 Hook 调试器 — 使用、架构与风险

在注入 dylib 的能力边界内,做一个「JS 规则驱动的 App 行为调试器」:native 当传感器(稳定抓
crypto/file/system 的 C 符号),JS 当规则层(动态 hook ObjC、过滤/加工事件),统一事件流呈现。

## 一、快速开始

```bash
# 真机(TrollStore)
make dist                         # 产出 decrypt_helper-<VERSION>.dylib
#  → 用 inject.sh 注入目标 IPA → TrollStore 安装 → 打开 App

# 模拟器(自测)
make sim                          # 产出 decrypt_helper.sim.dylib (arm64 + adhoc 签名)
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(pwd)/decrypt_helper.sim.dylib" \
  xcrun simctl launch booted <bundleId>

# 打开 App 后浏览器访问 http://<设备IP>:8088  →「脚本」tab
```

界面只有三个 tab:**事件流**(native 抓取的一切,type 过滤 + 结构化详情) / **砸壳** / **脚本**。

## 二、脚本 API 速查

在「脚本」tab 写 JS,点运行。事件输出到下方。

```js
log(...)                          // 输出到事件区

// ── ObjC 动态 hook(任意类/方法) ──
ObjC.hook({
  class: 'APIClient', selector: '- signParams:',
  onEnter: function(args, info){ log(args[0]); return ['改后的参数']; },  // 返回数组改参数
  onLeave: function(ret, info){ return '伪造返回'; }                       // 返回值改返回值
});
ObjC.trace({ classRegex: '.*Manager', selectorRegex: '.*sign.*', limit: 200 });  // 正则批量(仅非系统类)

// ── 订阅 native 抓取的结构化事件(crypto/file/system) ──
Native.onEvent(function(e){ log(e.categoryName, e.algorithm, e.inputUtf8); });
Native.subscribe({ type:'file', pathRegex:'token|db', onEvent:function(e){ log(e.detail); } });

// ── 一键开抓取 + 订阅 ──
Trace.crypto({ onEvent:function(e){ log(e.algorithm, e.inputUtf8); } });   // 摘要/HMAC/对称/非对称/KDF
Trace.file({ pathRegex:'token', onEvent:function(e){ log(e.operation, e.detail); } });
Trace.system({ onEvent:function(e){ log(e.detail); } });                    // dlopen

// ── 符号导入表查询(替代旧的符号 tab) ──
Sym.images();                     // [{idx,name,main,imports}]
Sym.list('', 'SSL');              // 查含 SSL 的导入符号 [{image,symbol}]
Sym.hookKnown('recv', { onEnter:function(a,i){ log(a); } });  // C 符号只读: send/recv/SecItemCopyMatching

// ── 事件链观测(仅 iOS 真机有效) ──
Notification.trace({ nameRegex:'.*login.*', onPost:function(e){ log(e.name, e.userInfo); } });
TargetAction.trace({ onSend:function(e){ log(e.action, e.target); } });
```

事件对象字段:`seq / category / categoryName / algorithm / operation / timestamp / detail /
inLen / outLen / preview`;详情另有 `keyHex / ivHex / inputHex / inputUtf8 / inputDump /
outputHex / outputUtf8 / callStack`(超 4KB 的 hex/dump 截断,带 `inputTruncated/outputTruncated`)。

## 三、架构

```
浏览器(3 tab) ── HTTP :8088 ── DHJSEngine(JavaScriptCore + 串行 jsQueue)
                                 ├─ DHObjCEngine: swizzle + _objc_msgForward + forwardInvocation
                                 ├─ hook_symbol_api: fishhook + C 符号模板
                                 └─ Native EventBus ◄─ DHLogStore.eventObserver
DHLogStore(append = 单一真相源) ◄─ 固定 native C hook(crypto/file/system, fishhook)
```

三条数据流:①native C hook → append →(内存/落盘 + eventObserver → Native.onEvent);
②DHLogStore → /api/logs → 事件流 tab;③脚本 → ObjC.hook/Sym → 触发回调 JS → 脚本控制台。
native 结构化事件与脚本 log 走两套独立缓冲,互不污染。

## 四、能力边界与风险(自检修正版)

### 平台约束(无法消除,不是 bug)
- **C 函数必须 native thunk**:iOS 不允许运行时生成机器码,任意 C 函数不能纯 JS hook;
  C 符号观测靠固定 native hook + `Sym.hookKnown` 模板表。ObjC 方法则可纯 JS 动态 hook。
- **fishhook 的覆盖边界**:它改的是 Mach-O 里 `__la_symbol_ptr`/`__got`(lazy / non-lazy
  symbol pointer)这类**导入符号的调用点**,不是 inline 改函数本体。因此**静态链接进来的函数、
  同镜像内部直接调用、已被缓存的函数指针**都覆盖不到。后加载镜像会被 fishhook 的
  `_dyld_register_func_for_add_image` 回调自动重放 rebind,无需手动处理。
- **纯 Swift 方法 hook 不到**:`ObjC.hook` 只拦走 `objc_msgSend` 的方法;非 `@objc` 的
  Swift 静态派发/witness table 方法无法拦截。
- **只能 hook「已存在」的 ObjC 方法**:安装时 `class_getInstanceMethod` 找不到即拒绝。
  故 NSProxy 虚拟方法 / 纯动态 selector / 靠 `methodSignatureForSelector:` 动态构造签名的方法
  不在支持范围(也因此无需接管 `methodSignatureForSelector:` —— 被 hook 的方法签名天然可用)。

### 改参 / 改返回的类型能力分层
`onEnter` 返回数组改参数、`onLeave` 返回值改返回值,底层用 `NSInvocation` 写回,能力**分层**:
- ✅ **可改**:ObjC 对象(`id`/`NSString`/`NSNumber`/`NSArray`/`NSDictionary`/`NSDate`)、`BOOL`
  及全部整型/浮点标量。
- 🔒 **只读**:`struct`/`union`、`void*`/`char*` 裸指针、block、C++ 对象、SIMD 向量——可读取展示,
  写回不支持(静默忽略,不崩)。

> 措辞校准:**不是**"任意参数和返回值都能改",而是"**多数 ObjC 对象与基础标量可改,复杂 C 类型以只读/展示为主**"。

### 风险评估
| 风险 | 结论 |
|---|---|
| iOS 15+ **chained fixups** 下 C 符号 hook 失效 | ✅ **已实测证伪**。fishhook 依赖 indirect symbol table(chained fixups 保留),不依赖 bind opcodes。用 `-fixup_chains` 编的可执行注入后 crypto 全抓到,与传统格式一致。 |
| **arm64e PAC**(真机 A12+) | 🟡 真机唯一较大未知。模拟器/mac 是 arm64 非 arm64e。fishhook 改 GOT 数据指针、`class_replaceMethod` 走 runtime API(内部处理 PAC),理论安全,但需真机确认。 |
| 纯 Swift / SwiftUI 覆盖率 | 🟡 固有,见上。 |
| 反调试 / 反注入 App | 🟡 金融/安全 App 会检测注入 dylib、IMP=`_objc_msgForward`、fishhook 改过的 GOT。 |
| 多进程(Extension/WebContent) | 🟡 dylib 只在主进程,子进程 hook 不到。 |

### 已落地的安全护栏(防崩/防卡)
- **黑名单**:`dealloc/retain/release` 等内存管理、`alloc/copy/new/mutableCopy` 等 +1 工厂
  (改返回值会 over-release)、`stringWithFormat:` 等可变参数方法(NSInvocation 无法表达 va_list)。
- **高频熔断**:单方法 >5000/s 自动恢复 IMP 卸载 + 告警,防手滑 hook `layoutSubviews` 之类卡死。
- **限频**:每规则 100/s、native 事件 200/s,超出丢弃并告警。
- **看门狗**:单次 JS 回调 >1s 告警(JS 死循环无法强杀,只跑可信脚本)。
- **重入保护**:`dh_in_script` 线程局部,防 JS 回调触发被 hook 方法递归。
- **payload 截断**:事件 hex/dump 上限 4KB。
- **异常语义(观察而不改变)**:JS 回调(onEnter/onLeave)抛异常 → 吞掉记录,不影响宿主;原方法
  自身抛的 `NSException` → 原样透传回 App(不吞,保持 App 原有 try/catch 语义);原实现全程只执行
  一次,hook 出异常也绝不重复副作用(杜绝"发两次请求 / 写两次文件"类 bug)。

## 五、真机验证必测清单(TrollStore 注入后逐条对照)

- [ ] **arm64e PAC**:注入 A12+ 真机的 App,`Trace.crypto`/`Trace.file` 能否抓到(验证 fishhook GOT 覆写 + swizzle 在 PAC 下不崩)。
- [ ] **chained fixups 真机确认**:虽已在 mac 实测证伪,真机 arm64e 再确认一次 C 符号 hook。
- [ ] **改返回值稳定性**:`ObjC.hook` onLeave 改真实业务方法的返回值,观察不崩(结构体返回已 fail-loud 拒绝、+1 工厂已黑名单)。
- [ ] **高频不卡死**:`ObjC.trace` 宽正则匹配大量方法、hook 高频 UI 方法,确认限频 + 熔断生效、App 不卡死。
- [ ] **事件链**:`TargetAction.trace`(点按钮)、`Notification.trace`(触发通知)在真实 UIKit 下触发。
- [ ] **file 高频**:hook 大文件 write,确认 4KB 截断 + 限频、payload 不刷爆。
- [ ] **反调试 App**:在带检测的 App 上观察是否被发现/反制(评估适用范围)。
- [ ] **回归**:砸壳、下载全部日志、审查日志、设置不受影响。

已在 iOS Simulator(iPhone 17 Pro / iOS 26.3)注入真实第三方 App 验证:crypto/file(带路径大小)/
dlopen 全抓、Native.onEvent 订阅、ObjC.hook 真实 UIKit、ObjC.trace 扫业务类、黑名单/熔断——均通过。
