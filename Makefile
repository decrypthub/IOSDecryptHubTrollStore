# 解密助手 (Decrypt Helper) — iOS dylib
#
# 提供两条编译路径:
#   1) macOS xcrun (默认): 在 GitHub Actions / macOS 本机用
#       make                       -> decrypt_helper.dylib
#   2) Linux 交叉编译 (WSL): 需要环境变量 IOS_SDK 指向 iPhoneOS SDK 路径,
#       并且 CROSS_CC 指向支持 Apple target 的 clang.
#       export IOS_SDK=/path/to/iPhoneOS17.x.sdk
#       export CROSS_CC=/path/to/theos/toolchain/linux/iphone/bin/clang
#       make linux                 -> decrypt_helper.dylib

VERSION := 1.10.0
TARGET  := decrypt_helper.dylib
SRC     := src/core/fishhook.c \
           src/core/dh_health.c \
           src/core/dh_capture.c \
           src/core/dh_symtab.c \
           src/core/js_engine.m \
           src/core/log_store.m \
           src/core/zip_writer.c \
           src/core/macho_dump.m \
           src/core/dump_manager.m \
           src/hooks/crypto/hook_digest.m \
           src/hooks/crypto/hook_hmac.m \
           src/hooks/crypto/hook_symmetric.m \
           src/hooks/crypto/hook_asymmetric.m \
           src/hooks/crypto/hook_kdf.m \
           src/hooks/behavior/hook_file.m \
           src/hooks/behavior/hook_system.m \
           src/hooks/objc/hook_objc_engine.m \
           src/hooks/objc/hook_symbol_api.m \
           src/server/http_server.m \
           src/ui/ui_float.m \
           src/ui/ui_logview.m \
           src/core/main.m

FRAMEWORKS := -framework Foundation -framework UIKit -framework CoreGraphics -framework Security -framework JavaScriptCore
INCLUDES   := -Isrc/core -Isrc/server -Isrc/ui -Isrc/hooks/objc
ARCH       := arm64
MIN_IOS    := 14.0

# ---------- 1) macOS xcrun ----------
SDK     ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CC      ?= $(shell xcrun --find clang 2>/dev/null)

CFLAGS  := -arch $(ARCH) \
           -isysroot $(SDK) \
           -miphoneos-version-min=$(MIN_IOS) \
           -dynamiclib \
           -install_name @executable_path/$(TARGET) \
           -Xlinker -current_version -Xlinker $(VERSION) \
           -Xlinker -compatibility_version -Xlinker 1.0.0 \
           -ObjC -fobjc-arc \
           -Wall -Wno-deprecated-declarations -Wno-nullability-completeness \
           -Os \
           $(INCLUDES) \
           $(FRAMEWORKS)

all: $(TARGET)

# 前端: 改 web/index.html 后自动重生成内嵌头(字节数组), 不再手刮 C 字符串。
WEB_HEADER := src/server/web_index_html.h
$(WEB_HEADER): web/index.html tools/gen_web.py
	@echo "[*] 生成前端内嵌头 $(WEB_HEADER) ..."
	python3 tools/gen_web.py web/index.html $(WEB_HEADER)

$(TARGET): $(WEB_HEADER) $(SRC) $(wildcard src/*/*.h)
	@echo "[*] 使用 $(CC) 编译..."
	$(CC) $(CFLAGS) $(SRC) -o $(TARGET)
	@echo "✅ 编译完成: $(TARGET)"

# ---------- 2) Linux 交叉编译 (WSL) ----------
linux:
	@if [ -z "$$IOS_SDK" ]; then echo "❌ 请先 export IOS_SDK=/path/to/iPhoneOS17.x.sdk"; exit 1; fi
	@if [ -z "$$CROSS_CC" ]; then echo "❌ 请先 export CROSS_CC=/path/to/clang (支持 apple target)"; exit 1; fi
	$$CROSS_CC \
	    -target arm64-apple-ios$(MIN_IOS) \
	    -isysroot $$IOS_SDK \
	    -dynamiclib \
	    -install_name @executable_path/$(TARGET) \
	    -Xlinker -current_version -Xlinker $(VERSION) \
	    -Xlinker -compatibility_version -Xlinker 1.0.0 \
	    -ObjC -fobjc-arc \
	    -Wall -Wno-deprecated-declarations -Wno-nullability-completeness \
	    -Os \
	    $(INCLUDES) \
	    $(FRAMEWORKS) \
	    $(SRC) -o $(TARGET)
	@command -v ldid >/dev/null 2>&1 && ldid -S $(TARGET) && echo "✅ 已用 ldid 自签" || echo "⚠️ 未找到 ldid, 请手动签名"
	@echo "✅ 交叉编译完成: $(TARGET)"

# ---------- 3) macOS native (用于 Mac 上灰度测试) ----------
# 不带 UIKit (UI 代码自己用 __has_include 隔离了, 没 UIKit 就只编 stub),
# 只保留 hook + HTTP 服务. 浏览器开 http://127.0.0.1:8088 看效果.
MAC_TARGET := decrypt_helper.mac.dylib
MAC_SDK    := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
MAC_ARCH   := $(shell uname -m)
MAC_MIN    := 11.0
MAC_FRAMEWORKS := -framework Foundation -framework CoreFoundation -framework Security -framework JavaScriptCore
MAC_CFLAGS := -arch $(MAC_ARCH) \
              -isysroot $(MAC_SDK) \
              -mmacosx-version-min=$(MAC_MIN) \
              -dynamiclib \
              -install_name @rpath/$(MAC_TARGET) \
              -Xlinker -current_version -Xlinker $(VERSION) \
              -ObjC -fobjc-arc \
              -Wall -Wno-deprecated-declarations -Wno-nullability-completeness \
              -O0 -g \
              $(INCLUDES) \
              $(MAC_FRAMEWORKS)

mac: $(MAC_TARGET)

$(MAC_TARGET): $(SRC)
	@if [ -z "$(MAC_SDK)" ]; then echo "❌ 没找到 macOS SDK, 请先装 Xcode 或 CommandLineTools"; exit 1; fi
	@echo "[*] macOS 原生编译 (arch=$(MAC_ARCH), min=$(MAC_MIN))..."
	$(CC) $(MAC_CFLAGS) $(SRC) -o $(MAC_TARGET)
	@echo "✅ macOS dylib: $(MAC_TARGET)"

# ---------- 4) Mac 灰度测试 ----------
# 编 dylib + 编 exercise_runner + DYLD_INSERT_LIBRARIES 跑.
# 跑完浏览器开 http://127.0.0.1:8088 应该能看到 ~12 条日志.
TEST_BIN := tests/exercise_runner

test-mac: $(MAC_TARGET) $(TEST_BIN)
	@echo "[*] 启动测试: DYLD_INSERT_LIBRARIES=$(MAC_TARGET) $(TEST_BIN)"
	@echo "[*] 一秒后请打开 http://127.0.0.1:8088"
	DYLD_INSERT_LIBRARIES=./$(MAC_TARGET) ./$(TEST_BIN)

$(TEST_BIN): tests/exercise_runner.m
	@if [ -z "$(MAC_SDK)" ]; then echo "❌ 没找到 macOS SDK"; exit 1; fi
	@echo "[*] 编 exercise_runner ..."
	$(CC) -arch $(MAC_ARCH) -isysroot $(MAC_SDK) -mmacosx-version-min=$(MAC_MIN) \
	      -ObjC -fobjc-arc -Wall -Wno-deprecated-declarations -O0 -g \
	      -framework Foundation -framework CoreFoundation -framework Security \
	      tests/exercise_runner.m -o $(TEST_BIN)
	@echo "✅ test runner: $(TEST_BIN)"

# ---------- 5) 发布产物: 带版本号的 dylib ----------
# release 资产用带版本号的文件名, 方便区分不同版本的下载。
# 文件名与 install_name(LC_ID) 都带版本; inject.sh 从文件名推导 LC_LOAD_DYLIB, 故注入仍自洽。
# 主构建产物保持 decrypt_helper.dylib 不变(测试 IPA / inject 默认名不受影响)。
DIST_DYLIB := decrypt_helper-$(VERSION).dylib
dist: $(TARGET)
	cp $(TARGET) $(DIST_DYLIB)
	install_name_tool -id @executable_path/$(DIST_DYLIB) $(DIST_DYLIB)
	@echo "✅ 发布产物: $(DIST_DYLIB)"

clean:
	rm -f $(TARGET) $(MAC_TARGET) $(TEST_BIN) decrypt_helper-*.dylib

.PHONY: all linux mac test-mac dist clean
