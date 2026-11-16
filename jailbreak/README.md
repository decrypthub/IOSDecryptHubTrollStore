# 越狱整包兼容入口

越狱版由独立 [IOSDecryptHub](https://github.com/decrypthub/IOSDecryptHub) 主仓维护（2026-11-16 承接原 IOSDecryptHubJB），使用自己的 main、版本与整包发布。

本仓正式维护巨魔版。旧 `make deb` / `deb-rootless` / `deb-roothide` 入口现在只转交并列 `../IOSDecryptHub` 的对应完整构建，不编译巨魔引擎、不覆盖越狱版 Makefile 版本，也不跨仓复制 dylib 或 deb。自定义越狱工作区可用 `DH_JB_DIR` 指定。

建议直接进入 [IOSDecryptHub](https://github.com/decrypthub/IOSDecryptHub) 准备依赖并构建；实现与验证状态以该仓文档为准。
