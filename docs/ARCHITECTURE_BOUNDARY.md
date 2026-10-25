# IOSDecryptHub 架构边界文档（铁律）

> **本仓现只维护巨魔版**，以下双轨/越狱条款保留为旧共享引擎的历史边界。巨魔版继续遵守 fishhook + ObjC swizzle 与宿主稳定性约束。
> 新越狱产品在独立 [IOSDecryptHubJB](https://github.com/decrypthub/IOSDecryptHubJB) 开发，以其产品架构为准；本仓不再要求共享核心，不再通过 jailbreak 分支发布新产品。
> 最后更新：2026-10-25

---

## 一、设计原则

项目采用 **TrollStore（巨魔）+ Jailbreak（越狱）两个长期分支独立维护**，复用公共 dylib 核心引擎：

- `main` 为巨魔版维护分支，`jailbreak` 为越狱版维护分支；平台专属能力分别演进。
- 公共核心修复按提交同步并分别验证，不通过整分支合并将越狱专属依赖带入巨魔版。
- `src/` 是共享核心，只通过编译期 `DH_VARIANT` 宏感知变体。
- TrollStore 管理器负责 patch 目标 App 的 Mach-O。
- 越狱加载器只负责读取偏好并 `dlopen` 主 dylib。
- 两条路线的 C hook 都使用 fishhook，ObjC hook 都使用 method swizzle。

越狱环境的高级能力在 `jailbreak` 分支推进，由越狱侧独立扩展承载；公共核心不引入第二套 hook 实现。

---

## 二、三种变体

| 变体 | 注入载体 | 门控 | 产物 |
|------|----------|------|------|
| `dev` (`DH_VARIANT=0`) | 开发者手动注入 | 手动注入即明确意图 | 裸 dylib |
| `trollstore` (`DH_VARIANT=1`) | 管理器 App patch Mach-O | 管理器内 per-app Toggle | 管理器 IPA + dylib |
| `rootless` (`DH_VARIANT=2`) | ElleKit 加载器 | Settings + 内置应用选择器 | rootless deb |

### 2.1 TrollStore 路线

- 不需要 root，不依赖越狱路径。
- 管理器 App 的 patch 逻辑位于 `app-trollstore/IOSDecryptHubTS/macho_patch.c`。
- 管理器向目标 Mach-O 写入 `LC_LOAD_DYLIB`，并复制共享 dylib。
- dylib 核心不得感知管理器的 patch 实现。

### 2.2 越狱路线

- 允许 ElleKit 作为 dylib 加载机制。
- 允许 rootless deb 打包和 plist 偏好门控。
- 允许加载器依赖 `/var/jb` 下的 rootless 越狱路径。
- 越狱加载器必须保持为独立薄层，仅做：读偏好 -> 判断目标进程 -> `dlopen` 主 dylib。
- 加载器、管理器 App 与 updater daemon 的源码位于并列开源仓 `../IOSDecryptHubJB/`。
  （设置面板已于 2026-09-13 移除：与管理器 App 功能重复，只保留 App 一个入口。）本仓库 `make deb` 只编译闭源成品 dylib 并拷进开源仓 `vendor/dylib/`，不得把 `src/` 引擎源码放进开源仓。
- 不得使用 `MSHookFunction`、`%hook` 或其他越狱框架 hook API。
- 不得引用 daemon / `dh_server` 的代码或接口。

### 2.3 开发者路线

- 用于本地开发、手动注入、macOS 灰度和模拟器测试。
- 不引入面向生产目标 App 的额外门控逻辑。

---

## 三、Hook 技术边界

允许：

- fishhook（GOT / 符号指针改写），用于 C 函数。
  - 经典路径：间接符号表（`__DATA` / `__DATA_CONST` 的 `S_LAZY_SYMBOL_POINTERS` / `S_NON_LAZY_SYMBOL_POINTERS`）。
  - 新路径：`LC_DYLD_CHAINED_FIXUPS`（iOS 15+ / arm64e），支持 `DYLD_CHAINED_PTR_64`、`ARM64E`、`ARM64E_USERLAND`、`ARM64E_USERLAND24` 四种指针格式。
  - arm64e PAC 感知：strip 原始指针、按 key/diversity 重签名替换指针。
  - `__AUTH_CONST` 段扫描（authenticated GOT）。
  - 两种路径并行执行，覆盖混合格式。
- ObjC method swizzle，用于 Objective-C 方法。

绝对禁止（适用于 `src/` 共享核心，以及 `dev` / `trollstore` 两条路线）：

- inline hook、trampoline、运行时生成机器码。
- `MSHookFunction`、`%hook` 等越狱框架 hook API。
- QBDI、Frida Stalker 等 DBI 框架。

原因：免越狱侧拿不到 `dynamic-codesigning` entitlement，无法可靠分配可执行内存。统一使用指针改写才能保证两条路线行为一致。chained fixups 仍然只改函数指针（bind 条目），不改指令，不生成可执行内存。

### 3.1 越狱路线的 inline hook 例外（2026-09-13 决议）

越狱设备天然具备可执行内存权限，inline hook 能覆盖"没有导入符号可改"的调用点
（静态链接、LTO、同镜像内直接调用）。经决议**仅对越狱路线**开放，附带硬性约束：

位置约束：

- inline hook 实现**不得进入 `src/`**。核心继续只用 fishhook + swizzle；`src/` 中不得
  出现 trampoline、可执行内存分配或机器码生成。
- 实现由越狱侧（`../IOSDecryptHubJB/`）以独立扩展 dylib 提供，由加载器随引擎一起
  `dlopen`；宿主环境不满足条件时该 dylib 根本不加载。
- 事件出口不变：扩展把结果构造成既有事件条目写入 `DHLogStore`，WebUI 与 MCP 不需要
  知道来源。事件新增 `mechanism` 字段（`pointer` / `inline`）用于区分与排查。

隔离条件（缺一不可）：

1. 只有探针确认可写代码段时才安装（`CS_HARD` / `CS_KILL` 等）；失败静默放弃并上报原因。
2. 同一进程内同一符号不得被两种机制同时 hook：先注册者生效，后来者记一条事件说明跳过。
3. 不崩原则同样适用：hook 入口不得阻塞、不得发起 I/O，异常必须就地兜住。
4. 必须保留原始指令字节，支持卸载与恢复。
5. `dev` 与 `trollstore` 变体的行为与产物**不得**因此改变 —— 这是每次合并的回归判据。

为什么不让核心也上 inline hook：那等于维护两套 hook 引擎，两条路线行为开始分叉，
与"一份核心"的初衷相反。例外只开在越狱侧扩展里，核心不动。

### 3.2 越狱分支的 Trace 规划（2026-10-25）

- `jailbreak` 后续开发 Inline Hook、函数调用 Trace / 调用链分析，并探索指令级执行追踪。
- 这些是开发规划，本次分支拆分不新增相关运行时实现，也不将其标记为已有能力。
- Trace 与 Inline Hook 一样，只能在越狱侧独立扩展中实现；涉及 DBI、代码页修改或可执行内存的依赖不得进入 `src/` 或 `main` 的巨魔产物。
- 启用前必须检测设备权限、架构与运行环境，支持显式启停、过滤和资源限制；不可用时上报原因，不影响已有监控。
- 扩展事件复用已有日志、Web 与 MCP 通路；导出的能力状态必须反映实际实现与运行环境，不能仅因位于越狱分支就宣称支持。

---

## 四、共享核心边界

以下目录属于共享 dylib 核心：

```
src/core/       fishhook、capture、日志、配置、Capstone、脱壳
src/hooks/      crypto 与 behavior hook
src/server/     HTTP、MCP 和 Web 面板
src/ui/         iOS 悬浮窗
```

共享核心中允许的变体感知仅限编译期能力标识，例如 `dh_variant_current()`。

共享核心中不得出现：

- TrollStore Mach-O patch 逻辑。
- Substrate / ElleKit / libhooker API。
- `/var/jb` 等越狱路径探测。
- daemon 通信或 root 服务接口。

---

## 五、不崩溃原则

dylib 运行在目标 App 进程中，任何异常都会直接终止宿主 App：

- 所有不可信内存读取必须使用 `vm_read_overwrite` 或等价防护。
- ObjC 边界按需使用 `@try/@catch`，不可读地址返回错误。
- hook 函数内不得执行网络请求或其他耗时 I/O。
- 内存分配失败必须检查，日志和网络失败必须静默降级。
- 不得改变 constructor 启动顺序：预热 Foundation -> 加载配置 -> 安装 hook -> 启动 HTTP -> 创建悬浮窗。

---

## 六、服务与协议边界

- HTTP 与 MCP 共用 `0.0.0.0:8088`。
- MCP 端点固定为 `POST /api/mcp`，不得改成 WebSocket 或新增端口。
- 设备连接由 PC 端 idh 手动指定（`idh connect <设备 IP>:8088` / `--endpoint`），无自动发现。
- 服务无身份认证，仅限可信网络，不得在文档中建议暴露到公网。

---

## 七、目录与构建目标

| 路径 / Target | 归属 | 说明 |
|---------------|------|------|
| `src/` | 共享 | 同一份 dylib 核心引擎 |
| `app-trollstore/` | TrollStore | 管理器 App 与 Mach-O patch |
| `jailbreak/` | Jailbreak | 私有入口：编译 dylib → 拷进开源仓 vendor → 打包 |
| `../IOSDecryptHubJB/` | Jailbreak（开源） | 薄加载器、管理器 App、updater daemon、deb 打包；消费成品 dylib |
| `make` | dev | 默认开发 dylib |
| `make VARIANT=trollstore` | TrollStore | 管理器内嵌 dylib |
| `make VARIANT=rootless` | Jailbreak | 越狱加载器加载的共享 dylib |
| `make ipa` | TrollStore | 管理器 IPA |
| `make deb` / `make deb-rootless` / `make deb-roothide` | Jailbreak | rootless / roothide deb 包 |
| `make mac` / `make sim` | dev | 灰度和模拟器验证 |

---

## 八、版本控制边界

### 8.1 长期维护分支

| 分支 | 产品线 | 主要构建与维护范围 |
|------|--------|--------------------|
| `main`（默认） | TrollStore 巨魔版 | `make VARIANT=trollstore`、`make ipa`；免越狱兼容性与稳定性 |
| `jailbreak` | Jailbreak 越狱版 | `make VARIANT=rootless`、`make deb`；rootless / roothide 适配与高级分析扩展 |

两条分支从同一现有基线开始；保留已有目录与构建入口。平台专属功能从对应维护分支开发并回到该分支，公共修复用 `git cherry-pick -x <commit>` 按需同步，分别验证，不整分支合回。GitHub Actions 分别构建 `trollstore` / `rootless` 变体并区分产物名称；deb 打包仍需并列 `IOSDecryptHubJB` 仓库与对应工具链。

后续正式发布从对应分支打 `trollstore-v<版本号>` / `jailbreak-v<版本号>` 标签；历史 `v*` 标签保持不变。本次仅调整分支、文档与 CI，不增加功能版本号或发布二进制。

### 8.2 提交内容

应提交并保留：

- 架构、MCP、实现说明等项目文档。
- 发布、构建、注入和测试脚本。
- 测试宿主源码、仓库配置和 Issue 模板。
- `app-trollstore/tools/README.md` 等使用说明。

应加入 `.gitignore`，不提交：

- `src/server/web_index_html.h` 等可从源码生成的文件。
- `app-trollstore/tools/ct_bypass`、`app-trollstore/tools/ldid` 等自动下载的二进制。
- dylib、deb、IPA、dSYM、对象文件和 `build/`。
- 本机配置、临时文件、密钥、token 和捕获的敏感数据。

`.gitignore` 不能替代项目资料管理。不得通过删除文档、脚本或测试源码来清理工作区。

---

## 九、变更检查清单

- [ ] 核心 hook 是否仍只使用 fishhook + swizzle？
- [ ] inline hook 是否只存在于越狱侧扩展，`src/` 中没有任何可执行内存或机器码生成？
- [ ] `src/` 是否没有越狱框架 API、越狱路径或 daemon 接口？
- [ ] 越狱层是否仍只是薄加载器？
- [ ] TrollStore patch 是否仍只位于管理器 App？
- [ ] 内存读取、分配和异常是否具备不崩溃防护？
- [ ] 是否保持 8088 MCP/HTTP 和 8089 UDP 协议不变？
- [ ] 是否误删了 Agent 所需文档、脚本或测试源码？

---

## 十、决议记录

| 日期 | 决议 | 影响 |
|------|------|------|
| 2026-07-28 | 制定本文档 | — |
| 2026-09-13 | **越狱路线开放 inline hook**，限定在越狱侧扩展 dylib，核心与免越狱两条路线不变（见 §3.1） | 需新增隔离条件与回归判据；`src/` 边界不放宽 |
| 2026-09-13 | 环境与能力体检结果**只落越狱侧**（JB 仓的 App / daemon 展示），核心与 MCP 的 `get_capabilities` 仍只回答编译期变体 | 核心保持环境无关 |
| 2026-10-25 | **分支独立维护**：`main` 为巨魔版，`jailbreak` 为越狱版；越狱版规划 Inline Hook / Trace 等高级能力 | 公共修复按提交同步；高级实现继续隔离在越狱扩展中，巨魔版边界不放宽 |
| 2026-10-25 | **产品拆为独立项目**：本仓巨魔版定型维护；IOSDecryptHubJB 负责手机常驻服务、UI、Agent 整包及 APT 更新 | 历史 jailbreak 分支不再开发，跨项目修复按需移植 |
