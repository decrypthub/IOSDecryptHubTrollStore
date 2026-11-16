# 历史越狱入口

越狱版由独立 [IOSDecryptHub](https://github.com/decrypthub/IOSDecryptHub) 主仓维护（2026-11-16 承接原 IOSDecryptHubJB），使用自己的 main、版本与整包发布。

本目录旧跨仓脚本保留追溯，不再作为新产品开发和打包入口。新版设计由一次任务构建常驻 daemon、Manager UI、Loader 和 Agent 并打入完整 deb，通过 APT 源统一更新，用户无需单独处理 dylib。

新整包与高级能力尚未实现；状态见独立项目文档。
