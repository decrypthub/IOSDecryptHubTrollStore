# IOSDecryptHub

<div align="right">
  <b>中文</b> | <a href="./README.en.md">English</a>
</div>


IOSDecryptHub 是一个注入到 iOS App 进程中的运行时分析 dylib，可捕获加解密、文件、网络、Keychain 与动态加载行为，并提供 Web 面板、脱壳和 MCP 分析能力。

完整能力与效果演示请访问：[ios.decrypthub.com](https://ios.decrypthub.com/)

## 两个独立项目

本仓库维护 **巨魔版（TrollStore）**，能力基本定型，重点维护兼容性、稳定性和现有注入 / Web / MCP 使用方式。

越狱版已迁为独立项目 [IOSDecryptHubJB](https://github.com/taisuii/IOSDecryptHubJB)，采用手机常驻守护程序、管理 UI、注入 Loader 与 Agent 的完整 deb，规划逐应用注入开关、越狱源统一更新以及 Inline Hook / Trace。

两个项目各自维护 main、版本和发布，不再通过本仓的两个长期分支区分产品；历史 jailbreak 分支保留追溯，不再作为开发入口。适用修复按需移植。

越狱版目前处于独立工程与设计迁移阶段，新整包和高级能力尚未实现。详见 [越狱产品架构](https://github.com/taisuii/IOSDecryptHubJB/blob/main/docs/PRODUCT_ARCHITECTURE.md)。

## 获取 dylib

从 [官网首页](https://ios.decrypthub.com/) 或 [GitHub Releases](https://github.com/taisuii/IOSDecryptHub/releases) 下载 `decrypt_helper.dylib`，或自行编译：

```bash
make
```

编译产物位于项目根目录：`decrypt_helper.dylib`。

## 使用方法

### 方式一：巨魔注入器（推荐）

适用于已通过 TrollStore 安装巨魔注入器的设备：

1. 在巨魔注入器中选择目标 App。
2. 添加 `decrypt_helper.dylib` 并执行注入。
3. 启动目标 App。
4. 在同一局域网的浏览器中访问 `http://<设备 IP>:8088`。

不同注入器的界面可能略有差异，核心操作都是将 dylib 注入目标 App 后重新启动 App。

### 方式二：IPA 重打包

macOS 先安装 `insert_dylib`：

```bash
brew install insert_dylib
```

执行仓库内置脚本：

```bash
./scripts/inject.sh <input.ipa> decrypt_helper.dylib
```

脚本会生成 `hooked_<input>.ipa`。使用 TrollStore、Sideloadly 或 AltStore 安装/重签后启动 App，再访问：

```text
http://<设备 IP>:8088
```

### 方式三：TrollStore 管理器 App

编译并安装专用管理器 IPA：

```bash
make ipa
```

产物位于 `build/trollstore/`，通过 TrollStore 安装后可在 App 内直接选择目标并注入。

### PC 端连接与 MCP 网关

在电脑上安装 `idh`，手动连接设备（设备 IP 从 App 面板或局域网内获取）：

```bash
pip install ios-decrypt-hub
idh connect <设备 IP>:8088
idh mcp
```

`idh mcp` 将设备上的 HTTP MCP 转换为本机 stdio MCP，可作为 Codex、Claude 等客户端的固定 MCP 配置。`connect` 会把设备保存为持久连接，之后 `devices` / `watch` / `open` / `mcp` 直接使用；也可以临时用 `--endpoint http://<设备 IP>:8088` 指定。

## 编译变体

| 变体 | 命令 | 用途 |
|------|------|------|
| dev（默认） | `make` | 开发者手动注入 / 本地调试 |
| trollstore | `make VARIANT=trollstore` | 巨魔注入器 / 管理器 IPA |

### 越狱版

越狱完整 deb 的构建、安装与源更新由 [IOSDecryptHubJB](https://github.com/taisuii/IOSDecryptHubJB) 独立项目负责。本仓历史 rootless / deb 入口保留兼容记录，不作为新产品构建流程。

## 注意事项

- Web 与 MCP 服务默认监听 `0.0.0.0:8088`，且没有身份认证，请仅在可信网络中使用。
- 注入、重签和脱壳能力受设备环境及目标 App 保护机制影响。
- 请勿将捕获到的 Key、口令、明文或其他敏感数据提交到公开 Issue。

遇到问题可在 [GitHub Issues](https://github.com/taisuii/IOSDecryptHub/issues/new/choose) 反馈。

## 协议

[MIT](./LICENSE)

内嵌 [fishhook](https://github.com/facebook/fishhook) 与 [Capstone](https://www.capstone-engine.org/)（均为 BSD-3-Clause），版权声明见 [NOTICE](./NOTICE)。
