// log_store.h - IOSDecryptHub
// 公共日志记录中心：所有 hook 模块都把抓到的明文/密文/算法信息丢到这里。
// 严格遵守约束：悬浮窗只用 entry_count 这种统计数据，不显示明细。

#ifndef DECRYPT_HELPER_LOG_STORE_H
#define DECRYPT_HELPER_LOG_STORE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 算法分类 —— 用于过滤和着色
typedef NS_ENUM(NSInteger, DHCategory) {
    DHCategoryDigest = 0,        // MD2/4/5, SHA*
    DHCategoryHMAC,              // HMAC-*
    DHCategorySymmetric,         // AES / DES / 3DES / CAST / RC2 / RC4 / Blowfish
    DHCategoryAsymmetric,        // RSA / EC sign / encrypt / verify / decrypt
    DHCategoryFile,              // open / write / unlink / rename
    DHCategorySystem,            // dlopen 载入模块
    DHCategoryOther,
};

// 单条日志
@interface DHLogEntry : NSObject
@property (nonatomic, assign) DHCategory category;
@property (nonatomic, copy)   NSString *algorithm;          // e.g. "MD5" / "AES-128-CBC" / "HMAC-SHA256" / "RSA-SIGN-PKCS1v15-SHA256"
@property (nonatomic, copy)   NSString *operation;          // "encrypt" / "decrypt" / "sign" / "verify" / "digest"
@property (nonatomic, copy, nullable) NSData *key;          // 对称 key / HMAC key (二进制)
@property (nonatomic, copy, nullable) NSData *iv;           // CBC/CTR 等模式的 IV
@property (nonatomic, copy, nullable) NSData *input;        // 输入 (明文/密文/待签数据)
@property (nonatomic, copy, nullable) NSData *output;       // 输出 (摘要/密文/明文/签名)
@property (nonatomic, copy, nullable) NSString *publicKeyInfo;  // RSA 公钥摘要描述
@property (nonatomic, copy, nullable) NSString *detail;         // 通用详情: 网络 IP:port / 文件路径 / 系统库路径
@property (nonatomic, copy)   NSString *timestamp;          // 格式化时间
@property (nonatomic, copy)   NSString *callStack;          // 应用层调用栈 (已过滤)
@property (nonatomic, assign) uint64_t seq;                 // 自增序号
@end

@interface DHLogStore : NSObject

+ (instancetype)shared;

// 写入一条日志 (线程安全)
- (void)append:(DHLogEntry *)entry;

// native 事件旁路观察者 (供 JS Native.onEvent 订阅): 每条 append 成功入库(赋 seq 后)在日志串行队列
// 内回调一次。为 nil 时零开销。设置方(DHJSEngine)负责把线程切到自己的队列。
@property (nonatomic, copy, nullable) void (^eventObserver)(DHLogEntry *entry);

// 当前所有日志快照 (按 seq 升序; 限制最近 N 条以防 UI 卡顿)
- (NSArray<DHLogEntry *> *)snapshot;
- (NSArray<DHLogEntry *> *)snapshotMatching:(nullable NSString *)keyword
                                   category:(NSInteger)categoryOrMinusOne;

// 单条查询 (用于 web detail 端点)
- (nullable DHLogEntry *)entryWithSeq:(uint64_t)seq;

// 统计
- (NSUInteger)totalCount;
- (NSUInteger)countForCategory:(DHCategory)cat;

// 暂停/恢复 (全局总开关)
@property (atomic, assign) BOOL paused;

// 每类暂停 (高频的文件类可单独停掉, 不影响其它板块继续记录)
- (void)setPaused:(BOOL)paused forCategory:(DHCategory)cat;
- (BOOL)isPausedForCategory:(DHCategory)cat;

// 清空 (内存 + 文件)
- (void)clearAll;
// 仅清某分类的内存日志 (0..7 或 -2 加密组), 不动落盘文件
- (void)clearCategory:(NSInteger)cat;

// 日志文件路径 (落盘文件用于 share/导出)
- (NSString *)logFilePath;

// ===== 日志保留/落盘配置 (持久化到沙箱 .dh_logcfg.conf, 重启/重注入仍生效) =====
// 每类内存保留条数 (替代旧的写死 2000)。setter 立即裁剪各桶并存盘。
- (NSUInteger)maxPerCategory;
- (void)setMaxPerCategory:(NSUInteger)n;
// 单个落盘文件滚动上限 (字节); 0 = 不限。超限滚动为 .1/.2/.3 (最多 3 个备份)。setter 存盘。
- (unsigned long long)maxLogFileBytes;
- (void)setMaxLogFileBytes:(unsigned long long)bytes;
// 当前落盘总字节 = 当前段 + 所有滚动备份段之和 (供 /api/stats 与设置页展示)。
- (unsigned long long)totalLogBytes;

// 把某分类(0..7, 或 -2=加密组, -1=全部)的内存日志导出成可读文本, 供「按板块下载」。
- (NSString *)exportTextForCategory:(NSInteger)cat;

// 当前宿主进程信息 (pid/进程名/bundle/系统版本/设备型号), 一次性采集并缓存
- (NSDictionary *)processInfo;

// 大小过滤快照: 仅保留 input 或 output 字节数 >= minBytes 的条目 (keyword/category 同 snapshotMatching)
- (NSArray<DHLogEntry *> *)snapshotMatching:(nullable NSString *)keyword
                                   category:(NSInteger)categoryOrMinusOne
                                    minSize:(NSUInteger)minBytes;

@end

// ===== 工具函数 =====
NSString *DHHexFromData(NSData * _Nullable d);
NSString *DHHexDumpFromData(NSData * _Nullable d);
NSString *DHUTF8FromData(NSData * _Nullable d);
NSString *DHCallStackFiltered(void);   // 已过滤系统 / 自身的调用栈
NSString *DHTimestampNow(void);

// 分类机器名 ("digest"/"hmac"/"sym"/"asym"/"file"/"sys"/"other")
NSString *DHCategoryName(NSInteger cat);
// DHLogEntry → 结构化 JSON 事件。full=NO 为列表版(seq/category/algorithm/preview/…);
// YES 追加 key/iv/input/output 的 hex/utf8/dump + publicKeyInfo + callStack。
// 供 /api/logs、/api/logs/{seq} 与 JS Native.onEvent 共用同一份转换。
NSDictionary *DHEntryToJSON(DHLogEntry *e, BOOL full);

NS_ASSUME_NONNULL_END
#endif
