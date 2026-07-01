// hook_symbol_api.m — 见 hook_symbol_api.h。
//
// 每个模板符号一个编译期 thunk: 先调 orig 拿结果, 再把「参数快照 + 返回值」交给 DHJSEngine
// 分发到已注册的 Sym.hookKnown 回调(只读)。thunk 用 dh_in_script 防重入(JS 回调里再触发同符号
// 时直接放行)。fishhook rebind 每符号一次(防重复 rebind 把 orig 指回 thunk 造成自递归)。

#import "hook_symbol_api.h"
#import "js_engine.h"
#import "fishhook.h"
#import "dh_health.h"          // dh_in_script
#import <Security/Security.h>
#import <sys/socket.h>
#import <string.h>

// buf 十六进制预览(前 64 字节)。
static NSString *DHBufPreview(const void *buf, size_t len) {
    if (!buf || len == 0) return @"";
    size_t n = len < 64 ? len : 64;
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2 + 1];
    const unsigned char *p = (const unsigned char *)buf;
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", p[i]];
    if (len > n) [s appendString:@"…"];
    return s;
}

// ---- send ----
static ssize_t (*orig_send)(int, const void *, size_t, int);
static ssize_t hooked_send(int fd, const void *buf, size_t len, int flags) {
    ssize_t r = orig_send(fd, buf, len, flags);
    if (!dh_in_script) { @autoreleasepool {
        [[DHJSEngine shared] symbolEvent:@"send" args:@[@(fd), DHBufPreview(buf, len), @((long)len), @(flags), @((long)r)]];
    }}
    return r;
}

// ---- recv ----
static ssize_t (*orig_recv)(int, void *, size_t, int);
static ssize_t hooked_recv(int fd, void *buf, size_t len, int flags) {
    ssize_t r = orig_recv(fd, buf, len, flags);
    if (!dh_in_script) { @autoreleasepool {
        NSString *hex = (r > 0) ? DHBufPreview(buf, (size_t)r) : @"";
        [[DHJSEngine shared] symbolEvent:@"recv" args:@[@(fd), hex, @((long)len), @(flags), @((long)r)]];
    }}
    return r;
}

// ---- SecItemCopyMatching (keychain 查询) ----
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus s = orig_SecItemCopyMatching(query, result);
    if (!dh_in_script) { @autoreleasepool {
        NSString *q = query ? [(__bridge NSDictionary *)query description] : @"(null)";
        if (q.length > 300) q = [[q substringToIndex:300] stringByAppendingString:@"…"];
        [[DHJSEngine shared] symbolEvent:@"SecItemCopyMatching" args:@[q, @((int)s)]];
    }}
    return s;
}

BOOL dh_symbol_known(const char *name) {
    return name && (!strcmp(name, "send") || !strcmp(name, "recv") || !strcmp(name, "SecItemCopyMatching"));
}

void dh_symbol_install(const char *name) {
    static bool sent = false, recvd = false, secd = false;
    if (!name) return;
    if (!strcmp(name, "send") && !sent) {
        struct rebinding r = {"send", (void *)hooked_send, (void **)&orig_send};
        rebind_symbols(&r, 1); sent = true;
    } else if (!strcmp(name, "recv") && !recvd) {
        struct rebinding r = {"recv", (void *)hooked_recv, (void **)&orig_recv};
        rebind_symbols(&r, 1); recvd = true;
    } else if (!strcmp(name, "SecItemCopyMatching") && !secd) {
        struct rebinding r = {"SecItemCopyMatching", (void *)hooked_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching};
        rebind_symbols(&r, 1); secd = true;
    }
}
