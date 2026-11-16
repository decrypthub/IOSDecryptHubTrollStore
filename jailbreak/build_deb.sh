#!/bin/bash
# 兼容旧 deb 入口，转交 IOSDecryptHub 自己的完整构建。
# 不修改其它仓库版本，不跨仓复制引擎或产物。
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "[x] 用法: $0 [all|rootless|roothide]" >&2
    exit 1
fi

case "${1:-all}" in
    all) MAKE_TARGET=deb ;;
    rootless) MAKE_TARGET=deb-rootless ;;
    roothide) MAKE_TARGET=deb-roothide ;;
    *) echo "[x] 未知目标: $1 (可选: all / rootless / roothide)" >&2; exit 1 ;;
esac

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
JB_DIR="${DH_JB_DIR:-$WORKSPACE/IOSDecryptHub}"
if [ ! -f "$JB_DIR/Makefile" ] || [ ! -f "$JB_DIR/build_deb.sh" ]; then
    echo "[x] 找不到 IOSDecryptHub 越狱主仓: $JB_DIR；请放在并列目录或设置 DH_JB_DIR。" >&2
    exit 1
fi

exec make -C "$JB_DIR" "$MAKE_TARGET"
