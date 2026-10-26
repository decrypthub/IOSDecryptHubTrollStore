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

VERSION := 1.27.6
TARGET  := decrypt_helper.dylib

# Capstone 反汇编库源文件（仅 ARM/ARM64 架构）
CAPSTONE_SRC := src/core/capstone/cs.c \
                src/core/capstone/utils.c \
                src/core/capstone/SStream.c \
                src/core/capstone/MCInst.c \
                src/core/capstone/MCInstrDesc.c \
                src/core/capstone/MCRegisterInfo.c \
                src/core/capstone/Mapping.c \
                src/core/capstone/arch/ARM/ARMDisassembler.c \
                src/core/capstone/arch/ARM/ARMInstPrinter.c \
                src/core/capstone/arch/ARM/ARMMapping.c \
                src/core/capstone/arch/ARM/ARMModule.c \
                src/core/capstone/arch/AArch64/AArch64BaseInfo.c \
                src/core/capstone/arch/AArch64/AArch64Disassembler.c \
                src/core/capstone/arch/AArch64/AArch64InstPrinter.c \
                src/core/capstone/arch/AArch64/AArch64Mapping.c \
                src/core/capstone/arch/AArch64/AArch64Module.c

SRC     := src/core/fishhook.c \
           src/core/dh_health.c \
           src/core/dh_capture.c \
           src/core/dh_capability.c \
           src/core/dh_thunk.m \
           src/core/dh_noise.m \
           src/core/dh_spoof.m \
           src/core/dh_symtab.c \
           src/core/dh_dlsym_redirect.c \
           src/core/log_store.m \
           src/core/zip_writer.c \
           src/core/macho_dump.m \
           src/core/dump_manager.m \
           src/core/dh_files.m \
           src/core/analysis.m \
           src/hooks/crypto/hook_digest.m \
           src/hooks/crypto/hook_hmac.m \
           src/hooks/crypto/hook_symmetric.m \
           src/hooks/crypto/hook_asymmetric.m \
           src/hooks/crypto/hook_kdf.m \
           src/hooks/crypto/hook_evp.m \
           src/hooks/behavior/hook_file.m \
           src/hooks/behavior/hook_system.m \
           src/hooks/behavior/hook_keychain.m \
           src/hooks/behavior/hook_env.m \
           src/hooks/behavior/hook_spoof_objc.m \
           src/hooks/behavior/hook_dyld.m \
           src/hooks/behavior/hook_network.m \
           src/hooks/behavior/hook_webkit.m \
           src/server/http_server.m \
           src/server/mcp_server.m \
           src/server/dh_log_json.m \
           src/ui/ui_float.m \
           src/core/main.m \
           $(CAPSTONE_SRC)

FRAMEWORKS := -framework Foundation -framework UIKit -framework CoreGraphics -framework Security

# Capstone 编译宏 (缺一不可, 否则运行时失败):
#   CAPSTONE_USE_SYS_DYN_MEM — 用系统 malloc/free, 否则 cs_open 返回 CS_ERR_MEMSETUP
#   CAPSTONE_HAS_ARM / _ARM64 — 注册 ARM/AArch64 架构, 否则 cs_open 返回 CS_ERR_ARCH
CAPSTONE_DEF := -DCAPSTONE_USE_SYS_DYN_MEM -DCAPSTONE_HAS_ARM -DCAPSTONE_HAS_ARM64
VERSION_DEF := -DDH_VERSION_STR=\"$(VERSION)\"

# ---------- 打包变体矩阵 ----------
# 一份源码产出 2 变体, 差异仅: DH_VARIANT 编号。
#   make                       -> dev  (开发者 / DYLD_INSERT 注入, arm64)
#   make VARIANT=trollstore    -> 巨魔 (arm64, TrollStore 持久化)
VARIANT ?= dev

ifeq ($(VARIANT),dev)
    DH_VARIANT_NUM := 0
    ARCH    := arm64
    MIN_IOS := 14.0
else ifeq ($(VARIANT),trollstore)
    DH_VARIANT_NUM := 1
    ARCH    := arm64
    MIN_IOS := 14.0
else ifeq ($(VARIANT),rootless)
    DH_VARIANT_NUM := 2
    ARCH    := arm64
    MIN_IOS := 14.0
else
    $(error 未知 VARIANT=$(VARIANT); 可选: dev / trollstore / rootless)
endif

# ---------- 1) iOS 真机 dylib (默认 target) ----------
SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CC      := $(shell xcrun --find clang)
ARCHS   ?= $(ARCH)
ARCH_FLAGS := $(foreach A,$(ARCHS),-arch $(A))
INCLUDES := -Isrc/core -Isrc/core/capstone/include -Isrc/hooks/crypto -Isrc/hooks/behavior -Isrc/server -Isrc/ui
WEB_HEADER := src/server/web_index_html.h
WECHAT_HEADER := src/server/web_wechat_png.h
WEB_ASSETS := $(WEB_HEADER) $(WECHAT_HEADER)

CFLAGS  := $(ARCH_FLAGS) \
           -isysroot $(SDK) \
           -miphoneos-version-min=$(MIN_IOS) \
           -dynamiclib \
           -install_name @executable_path/$(TARGET) \
           -ObjC -fobjc-arc \
           -Wall -Wno-deprecated-declarations -Wno-nullability-completeness \
           -O2 \
           $(INCLUDES) \
           $(CAPSTONE_DEF) \
           $(VERSION_DEF) \
           -DDH_VARIANT=$(DH_VARIANT_NUM) \
           $(FRAMEWORKS)

all: $(TARGET)

$(WEB_HEADER): web/index.html tools/gen_web.py
	python3 tools/gen_web.py web/index.html $(WEB_HEADER)

$(WECHAT_HEADER): web/wechat-follow.png tools/gen_web.py
	python3 tools/gen_web.py web/wechat-follow.png $(WECHAT_HEADER) kDHWeChatPNG

$(TARGET): $(WEB_ASSETS) $(SRC) Makefile
	@if [ -z "$(SDK)" ]; then echo "❌ 没找到 iPhoneOS SDK (xcrun --sdk iphoneos)"; exit 1; fi
	@echo "[*] 编译 iOS dylib (VARIANT=$(VARIANT), archs=$(ARCHS), min=$(MIN_IOS))..."
	$(CC) $(CFLAGS) $(SRC) -o $(TARGET)
	@echo "✅ $(TARGET)"

# ---------- 2) Linux 交叉编译 (WSL) ----------
linux:
	@if [ -z "$(IOS_SDK)" ] || [ -z "$(CROSS_CC)" ]; then \
		echo "❌ 需设置 IOS_SDK 和 CROSS_CC, 参考 scripts/wsl_setup_toolchain.sh"; exit 1; fi
	@echo "[*] Linux 交叉编译 (VARIANT=$(VARIANT))..."
	python3 tools/gen_web.py web/index.html $(WEB_HEADER)
	python3 tools/gen_web.py web/wechat-follow.png $(WECHAT_HEADER) kDHWeChatPNG
	$(CROSS_CC) $(ARCH_FLAGS) -isysroot $(IOS_SDK) -miphoneos-version-min=$(MIN_IOS) \
		-dynamiclib -install_name @executable_path/$(TARGET) \
		-ObjC -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-nullability-completeness \
		-O2 $(INCLUDES) $(CAPSTONE_DEF) $(VERSION_DEF) -DDH_VARIANT=$(DH_VARIANT_NUM) $(FRAMEWORKS) \
		$(SRC) -o $(TARGET)
	@echo "✅ $(TARGET) (linux cross)"

# ---------- 3a) macOS 灰度测试 ----------
MAC_TARGET := decrypt_helper.mac.dylib
MAC_SDK    := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
MAC_ARCH   := $(shell uname -m)
MAC_MIN    := 12.0
MAC_CFLAGS := -target $(MAC_ARCH)-apple-macos$(MAC_MIN) \
              -isysroot $(MAC_SDK) \
              -dynamiclib \
              -install_name @executable_path/$(MAC_TARGET) \
              -ObjC -fobjc-arc \
              -Wall -Wno-deprecated-declarations -Wno-nullability-completeness \
              -O0 -g \
              $(INCLUDES) \
              $(CAPSTONE_DEF) \
              $(VERSION_DEF) \
              -DDH_VARIANT=0 \
              -framework Foundation -framework CoreGraphics -framework Security

mac: $(WEB_ASSETS) $(MAC_TARGET)

$(MAC_TARGET): $(WEB_ASSETS) $(SRC) Makefile
	@if [ -z "$(MAC_SDK)" ]; then echo "❌ 没找到 macOS SDK"; exit 1; fi
	@echo "[*] macOS 编译 (arch=$(MAC_ARCH))..."
	$(CC) $(MAC_CFLAGS) $(SRC) -o $(MAC_TARGET)
	@echo "✅ macOS dylib: $(MAC_TARGET)"

# ---------- 3b) iOS Simulator (真 UIKit / file / dlopen 环境, 注入模拟器 App 测试) ----------
SIM_TARGET := decrypt_helper.sim.dylib
SIM_SDK    := $(shell xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
SIM_ARCH   := $(shell uname -m)
SIM_MIN    := 14.0
SIM_CFLAGS := -target $(SIM_ARCH)-apple-ios$(SIM_MIN)-simulator \
              -isysroot $(SIM_SDK) \
              -dynamiclib \
              -install_name @executable_path/$(SIM_TARGET) \
              -ObjC -fobjc-arc \
              -Wall -Wno-deprecated-declarations -Wno-nullability-completeness \
              -O0 -g \
              $(INCLUDES) \
              $(CAPSTONE_DEF) \
              $(VERSION_DEF) \
              $(FRAMEWORKS)

sim: $(WEB_ASSETS) $(SIM_TARGET)

$(SIM_TARGET): $(WEB_ASSETS) $(SRC) Makefile
	@if [ -z "$(SIM_SDK)" ]; then echo "❌ 没找到 iPhoneSimulator SDK"; exit 1; fi
	@echo "[*] iOS Simulator 编译 (arch=$(SIM_ARCH), min=$(SIM_MIN))..."
	$(CC) $(SIM_CFLAGS) $(SRC) -o $(SIM_TARGET)
	codesign -s - -f $(SIM_TARGET) 2>/dev/null || true
	@echo "✅ simulator dylib: $(SIM_TARGET)"

# ---------- 4) Mac 灰度测试 ----------
# 编 dylib + 编 exercise_runner + DYLD_INSERT_LIBRARIES 跑.
# 跑完浏览器开 http://127.0.0.1:8088 应该能看到 ~12 条日志.
TEST_BIN := tests/exercise_runner
OPENSSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null)
TEST_OPENSSL_CFLAGS :=
TEST_OPENSSL_LIBS :=
ifneq ($(OPENSSL_PREFIX),)
ifneq ($(wildcard $(OPENSSL_PREFIX)/include/openssl/evp.h),)
TEST_OPENSSL_CFLAGS := -I$(OPENSSL_PREFIX)/include -DHAVE_OPENSSL=1
TEST_OPENSSL_LIBS := -L$(OPENSSL_PREFIX)/lib -lcrypto
endif
endif

test-mac: $(MAC_TARGET) $(TEST_BIN)
	@echo "[*] 启动测试: DYLD_INSERT_LIBRARIES=$(MAC_TARGET) $(TEST_BIN)"
	@echo "[*] 一秒后请打开 http://127.0.0.1:8088"
	DYLD_INSERT_LIBRARIES=./$(MAC_TARGET) ./$(TEST_BIN)

# 自动化集成测试: 注入 dylib 到 runner, 驱动真实 MCP/HTTP 端点断言 (认证/工具/查询/关联/诊断)。
.PHONY: test-mcp
test-mcp:
	@chmod +x tests/mcp_test.sh
	./tests/mcp_test.sh

.PHONY: test-persistence
test-persistence:
	@chmod +x tests/persistence_test.sh
	./tests/persistence_test.sh

.PHONY: test-unit
test-unit:
	python3 -m unittest tests.test_patch_info_plist tests.test_scenarios

.PHONY: verify-architecture
verify-architecture:
	@chmod +x tests/verify_architecture.sh
	./tests/verify_architecture.sh

.PHONY: test-audit-mac
test-audit-mac: test-unit verify-architecture test-mcp test-persistence

.PHONY: test-audit-sim
test-audit-sim: test-unit verify-architecture
	@chmod +x tests/sim_test.sh
	./tests/sim_test.sh

.PHONY: verify-fast
verify-fast: test-unit verify-architecture test-mcp test-persistence

$(TEST_BIN): tests/exercise_runner.m
	@if [ -z "$(MAC_SDK)" ]; then echo "❌ 没找到 macOS SDK"; exit 1; fi
	@echo "[*] 编 exercise_runner ..."
	$(CC) -arch $(MAC_ARCH) -isysroot $(MAC_SDK) -mmacosx-version-min=$(MAC_MIN) \
	      -ObjC -fobjc-arc -Wall -Wno-deprecated-declarations -O0 -g \
	      $(TEST_OPENSSL_CFLAGS) \
	      -framework Foundation -framework CoreFoundation -framework Security -framework Network \
	      tests/exercise_runner.m -o $(TEST_BIN) $(TEST_OPENSSL_LIBS)
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

# ---------- 7) TrollStore IPA (管理器 App + dylib 打包) ----------
# 参考 TrollFools 方案: App 直接 patch 目标 App 的 Mach-O 二进制。
# 不依赖 daemon / plist / Substrate, 全程非越狱。
ipa:
	@chmod +x app-trollstore/build_ipa.sh
	./app-trollstore/build_ipa.sh

# ---------- 8) 越狱 deb 包 (rootless / roothide) ----------
# 本仓只编译闭源 dylib。加载器 / 设置面板 / 打包在并列开源仓 IOSDecryptHubJB。
# jailbreak/build_deb.sh 会把成品拷进 ../IOSDecryptHubJB/vendor/dylib/ 再调用其打包脚本。
deb:
	@chmod +x jailbreak/build_deb.sh
	./jailbreak/build_deb.sh all

deb-rootless:
	@chmod +x jailbreak/build_deb.sh
	./jailbreak/build_deb.sh rootless

deb-roothide:
	@chmod +x jailbreak/build_deb.sh
	./jailbreak/build_deb.sh roothide

clean:
	rm -f $(TARGET) $(MAC_TARGET) $(SIM_TARGET) $(TEST_BIN) decrypt_helper-*.dylib
	rm -rf build/

.PHONY: all linux mac sim test-mac test-mcp test-unit test-audit-mac test-audit-sim \
	verify-architecture verify-fast dist clean ipa deb deb-rootless deb-roothide
