# v1.27.6 — 巨魔版独立维护更新

- 作为 decrypthub/IOSDecryptHubTrollStore 独立项目发布，README 明确与 IOSDecryptHubJB 的维护边界。
- 采用已核对的组织正式 v1 引擎基线，保持现有 fishhook / ObjC、Web / MCP 与脱壳能力。
- 正式下载指向本仓 v1.27.6，避免继承的旧 Release 被误认为最新版本。

产物：decrypt_helper-1.27.6.dylib（arm64，trollstore 变体）。Mac Xcode 编译及产物检查通过；尚未进行真机注入验收。

越狱版仅从 IOSDecryptHubJB 获取完整 deb，常驻分析服务、Inline Hook 和 Trace 在越狱项目继续开发。
