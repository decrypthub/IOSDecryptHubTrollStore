// hook_symbol_api.h — Sym.hookKnown 的 native 落地: 用 fishhook 挂一批「已知签名」的 C 符号。
//
// 任意 C 符号无 runtime 元信息、无签名, 无法通用读参; 因此第一版只做内置签名模板表, 每个符号
// 一个编译期 thunk(保存 orig, 调 JS 回调, 再调 orig)。默认只开放与现有 crypto/file hook 不冲突
// 的符号(send/recv/SecItemCopyMatching), 避免二次 fishhook rebind 冲突。第一版只读观测。

#ifndef DH_HOOK_SYMBOL_API_H
#define DH_HOOK_SYMBOL_API_H

#import <Foundation/Foundation.h>

// name 是否在内置模板表内。
BOOL dh_symbol_known(const char *name);

// 用 fishhook 安装该符号的 thunk(幂等; 每符号只 rebind 一次防自递归)。
void dh_symbol_install(const char *name);

#endif // DH_HOOK_SYMBOL_API_H
