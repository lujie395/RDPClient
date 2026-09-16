//
//  RDPBridge.mm
//  RDPClient
//
//  FreeRDP 3.x 桥接实现。
//
//  设计要点：
//   - 一条后台线程完成 freerdp_connect + 事件泵（WaitForMultipleObjects）
//   - GDI 软渲染：gdi_init(BGRA32) 后，在 EndPaint 回调里把 primary_buffer
//     拷贝为 CGImage，节流后派发到主线程
//   - DesktopResize 包装 GDI 默认实现，尺寸变化时通知 Swift 重建图层
//   - 证书校验：IgnoreCertificate=TRUE（局域网自用，见 README 安全说明）
//   - NLA（CredSSP）凭据直接来自 settings；AuthenticateEx 兜底返回同一凭据
//
#import "RDPBridge.h"

#import <freerdp/freerdp.h>
#import <freerdp/gdi/gdi.h>
#import <freerdp/input.h>
#import <freerdp/error.h>
#import <freerdp/settings.h>
#import <winpr/synch.h>
#import <winpr/wlog.h>
#import <winpr/collections.h>
#import <winpr/environment.h>
#import <winpr/path.h>
#import <winpr/sysinfo.h>
#import <winpr/rpc.h>

#import <openssl/opensslv.h>
#import <openssl/provider.h>
#import <openssl/rand.h>

#import <map>
#import <mutex>
#import <string>

#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <netdb.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <time.h>
#import <UIKit/UIKit.h>

NSString * const RDPBridgeErrorDomain = @"RDPBridgeErrorDomain";

// ---------------------------------------------------------------------------
// C 侧上下文
// ---------------------------------------------------------------------------
struct BridgeContext;

static std::mutex g_contextMutex;
static std::map<rdpContext *, BridgeContext *> g_contextMap;

// winpr 原语自检：context_new 在 iOS 上静默失败时，用这些探针定位
// 是哪个底层子系统（InitOnce/Event/HashTable/Queue/WLog）不工作。
static BOOL bridge_diag_once_fn(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    return TRUE;
}

static NSString *bridge_run_winpr_diag(void)
{
    NSMutableString *d = [NSMutableString string];

    wLog *rl = WLog_GetRoot();
    [d appendFormat:@"WLog:%@ ", rl ? @"ok" : @"NULL"];

    HANDLE ev = CreateEvent(NULL, TRUE, FALSE, NULL);
    BOOL evOk = (ev && ev != INVALID_HANDLE_VALUE);
    [d appendFormat:@"Event:%@ ", evOk ? @"ok" : @"FAIL"];
    if (evOk)
        CloseHandle(ev);

    wHashTable *ht = HashTable_New(FALSE);
    [d appendFormat:@"HT:%@ ", ht ? @"ok" : @"NULL"];
    if (ht)
        HashTable_Free(ht);

    wMessageQueue *mq = MessageQueue_New(NULL);
    [d appendFormat:@"MQ:%@ ", mq ? @"ok" : @"NULL"];
    if (mq)
        MessageQueue_Free(mq);

    static INIT_ONCE s_diag_once = INIT_ONCE_STATIC_INIT;
    BOOL onceOk = InitOnceExecuteOnce(&s_diag_once, bridge_diag_once_fn, NULL, NULL);
    [d appendFormat:@"Once:%@ ", onceOk ? @"ok" : @"FAIL"];

    // 日志文件是否真的被 FileAppender 创建（setupWLogCapture 的 marker 应已写入）
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wlog/rdp-wlog.log"];
    BOOL logExists = [[NSFileManager defaultManager] fileExistsAtPath:logPath];
    [d appendFormat:@"LogFile:%@", logExists ? @"ok" : @"none"];

    return d;
}

// 分步诊断：按 freerdp_context_new 的内部依赖链逐层探测。
// Linux 实验已证明：环境贫瘠（如 HOME 缺失）时 settings_new 会静默
// goto out_fail（无任何日志）。这里把每一层依赖用 public API 跑一遍，
// 弹窗直接报告哪一层失败。
static NSString *bridge_run_context_diag(void)
{
    NSMutableString *d = [NSMutableString string];

    // 1. 环境变量（iOS 沙盒进程环境极简，winpr 非 __IOS__ 分支读 HOME/TMPDIR）
    const char *home = getenv("HOME");
    const char *tmpdir = getenv("TMPDIR");
    [d appendFormat:@"env[HOME:%@ TMPDIR:%@] ",
                   home ? @"set" : @"NULL", tmpdir ? @"set" : @"NULL"];

    // 2. GetKnownPath 全系列（settings_new 里 HomePath/ConfigPath 的来源）
    {
        const eKnownPathTypes ids[] = {
            KNOWN_PATH_HOME,           KNOWN_PATH_TEMP,
            KNOWN_PATH_XDG_CONFIG_HOME, KNOWN_PATH_XDG_DATA_HOME,
            KNOWN_PATH_XDG_CACHE_HOME,  KNOWN_PATH_XDG_RUNTIME_DIR,
            KNOWN_PATH_SYSTEM_CONFIG_HOME
        };
        const char *names[] = { "home", "tmp", "cfg", "data", "cache", "rtdir", "syscfg" };
        [d appendString:@"paths["];
        for (size_t i = 0; i < sizeof(ids) / sizeof(ids[0]); i++)
        {
            char *p = GetKnownPath(ids[i]);
            [d appendFormat:@"%s:%@ ", names[i],
                             p ? @"ok" : @"NULL"];
            free(p);
        }
        [d appendString:@"] "];
    }

    // 3. 计算机名（settings_init_computer_name 的依赖）
    {
        CHAR cn[MAX_COMPUTERNAME_LENGTH + 1] = { 0 };
        DWORD cnLen = (DWORD)sizeof(cn);
        BOOL cnOk = GetComputerNameExA(ComputerNameNetBIOS, cn, &cnLen);
        [d appendFormat:@"CompName:%@ ", cnOk ? @"ok" : @"FAIL"];
    }

    // 4. OpenSSL RAND（UuidCreate 的依赖，settings_new 末尾会用到）
    {
        unsigned char buf[16] = { 0 };
        int randOk = (RAND_bytes(buf, (int)sizeof(buf)) == 1);
        [d appendFormat:@"RAND:%@ ", randOk ? @"ok" : @"FAIL"];
    }

    // 5. UuidCreate（settings_new 尾部的静默 out_fail 点）
    {
        UUID uuid;
        RPC_STATUS us = UuidCreate(&uuid);
        [d appendFormat:@"Uuid:%@ ", (us == RPC_S_OK) ? @"ok" : @"FAIL"];
    }

    // 6. 核心：freerdp_settings_new —— context_new 内 rdp_new 的第一步实质依赖。
    //    若它 FAIL 而 2~5 全 ok，失败点在 settings_new 内部其它分支；
    //    若它 ok，失败点在 rdp_new 后半 / channels / stream_dump 等更深处。
    {
        rdpSettings *st = freerdp_settings_new(0);
        [d appendFormat:@"settings_new:%@ ", st ? @"ok" : @"FAIL"];
        if (st)
            freerdp_settings_free(st);
    }

    // 7. 独立实例重试一次完整 context_new：
    //    与主流程相同的调用、独立的 instance。若它 ok 而主流程 FAIL，
    //    说明是时序/一次性初始化问题；若同样 FAIL，是确定性失败。
    {
        freerdp *probe = freerdp_new();
        if (probe)
        {
            BOOL probeOk = freerdp_context_new(probe);
            [d appendFormat:@"probe_ctx:%@", probeOk ? @"ok" : @"FAIL"];
            if (probeOk)
                freerdp_context_free(probe);
            freerdp_free(probe);
        }
    }

    return d;
}

struct BridgeContext
{
    freerdp *instance = nullptr;
    rdpContext *context = nullptr;

    pEndPaint origEndPaint = nullptr;
    pDesktopResize origDesktopResize = nullptr;

    CFAbsoluteTime lastFrameTime = 0.0;

    __strong RDPBridge *bridge = nil; // ARC 管理强引用

    ~BridgeContext()
    {
        std::lock_guard<std::mutex> lock(g_contextMutex);
        if (context)
            g_contextMap.erase(context);
    }
};

static BridgeContext *ContextFor(rdpContext *context)
{
    std::lock_guard<std::mutex> lock(g_contextMutex);
    auto it = g_contextMap.find(context);
    return it == g_contextMap.end() ? nullptr : it->second;
}

// 前向声明
static BOOL bridge_post_connect(freerdp *instance);

// 内部方法（C 回调需要调用，先声明避免编译顺序问题）
@interface RDPBridge (InternalAccess)
- (NSString *)savedUsername;
- (NSString *)savedPassword;
- (NSString *)savedDomain;
- (void)setDesktopSize:(CGSize)size;
@end

// ---------------------------------------------------------------------------
// 帧推送：GDI primary buffer -> CGImage -> 主线程
// ---------------------------------------------------------------------------
static void PushFrame(BridgeContext *bc)
{
    if (!bc || !bc->context || !bc->context->gdi)
        return;

    RDPBridge *bridge = bc->bridge;
    if (!bridge || !bridge.frameHandler)
        return;

    // 节流：约 30 FPS
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (bc->lastFrameTime > 0 && (now - bc->lastFrameTime) < 0.033)
        return;
    bc->lastFrameTime = now;

    rdpGdi *gdi = bc->context->gdi;
    const NSUInteger width = (NSUInteger)gdi->width;
    const NSUInteger height = (NSUInteger)gdi->height;
    const NSUInteger stride = (NSUInteger)gdi->stride;
    BYTE *buffer = gdi->primary_buffer;
    if (!buffer || width == 0 || height == 0)
        return;

    // 必须拷贝：primary_buffer 会被后续更新覆盖
    CFIndex length = (CFIndex)(stride * height);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, buffer, length);
    if (!data)
        return;

    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = nullptr;
    if (provider && colorSpace)
    {
        image = CGImageCreate(width, height, 8, 32, stride, colorSpace,
                              (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little),
                              provider, nullptr, false, kCGRenderingIntentDefault);
    }
    if (colorSpace)
        CFRelease(colorSpace);
    if (provider)
        CFRelease(provider);
    CFRelease(data);

    if (!image)
        return;

    CGImageRef retained = (CGImageRef)CFRetain(image);
    CGImageRelease(image);

    dispatch_async(dispatch_get_main_queue(), ^{
        bridge.frameHandler(retained);
        CGImageRelease(retained);
    });
}

// ---------------------------------------------------------------------------
// FreeRDP 回调
// ---------------------------------------------------------------------------
static BOOL bridge_end_paint(rdpContext *context)
{
    BridgeContext *bc = ContextFor(context);
    if (!bc)
        return FALSE;

    BOOL result = TRUE;
    if (bc->origEndPaint)
        result = bc->origEndPaint(context); // GDI 默认实现：把脏区绘制进 primary buffer

    if (result)
        PushFrame(bc);
    return result;
}

static BOOL bridge_desktop_resize(rdpContext *context)
{
    BridgeContext *bc = ContextFor(context);
    if (!bc)
        return FALSE;

    BOOL result = TRUE;
    if (bc->origDesktopResize)
        result = bc->origDesktopResize(context); // GDI 默认实现：按协商尺寸重建 buffer

    if (result && bc->context->gdi)
    {
        rdpGdi *gdi = bc->context->gdi;
        RDPBridge *bridge = bc->bridge;
        CGSize size = CGSizeMake((CGFloat)gdi->width, (CGFloat)gdi->height);
        dispatch_async(dispatch_get_main_queue(), ^{
            [bridge setDesktopSize:size];
            if (bridge.resizeHandler)
                bridge.resizeHandler(size);
        });
        PushFrame(bc);
    }
    return result;
}

static BOOL bridge_post_connect(freerdp *instance)
{
    BridgeContext *bc = ContextFor(instance->context);
    if (!bc)
        return FALSE;

    // GDI 软渲染，BGRA32 与 CGImage 的 little-endian BGRA 直接对应
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;

    rdpContext *context = instance->context;

    // gdi_init 内部已注册默认绘制回调；先保存再包装
    bc->origEndPaint = context->update->EndPaint;
    bc->origDesktopResize = context->update->DesktopResize;
    context->update->EndPaint = bridge_end_paint;
    context->update->DesktopResize = bridge_desktop_resize;

    rdpGdi *gdi = context->gdi;
    RDPBridge *bridge = bc->bridge;
    CGSize size = CGSizeMake((CGFloat)gdi->width, (CGFloat)gdi->height);
    dispatch_async(dispatch_get_main_queue(), ^{
        [bridge setDesktopSize:size];
        if (bridge.resizeHandler)
            bridge.resizeHandler(size);
    });
    return TRUE;
}

// NLA 交互式认证兜底：正常情况下凭据来自 settings，不会走到这里
static BOOL bridge_authenticate_ex(freerdp *instance, char **username, char **password,
                                   char **domain, rdp_auth_reason reason)
{
    (void)reason;
    BridgeContext *bc = ContextFor(instance->context);
    if (!bc || !bc->bridge)
        return FALSE;

    RDPBridge *bridge = bc->bridge;
    NSString *u = [bridge savedUsername];
    NSString *p = [bridge savedPassword];
    NSString *d = [bridge savedDomain];
    *username = strdup(u.UTF8String ?: "");
    *password = strdup(p.UTF8String ?: "");
    *domain = d.length > 0 ? strdup(d.UTF8String) : nullptr;
    return (*username && *password) ? TRUE : FALSE;
}

// ---------------------------------------------------------------------------
// ObjC 接口
// ---------------------------------------------------------------------------
@interface RDPBridge ()
{
    BridgeContext *_ctx;
    NSThread *_thread;
    RDPModifierKey _sticky; // 由 setStickyModifiers 维护

    // 诊断：context_new 之前的 winpr 原语基线（失败时拼进弹窗）
    NSString *_winprBaseline;

    // 以下为内部状态（对外只读，通过 getter 方法暴露，不使用属性合成）
    RDPBridgeState _state;
    NSString *_lastErrorMessage;
    CGSize _desktopSize;
    NSString *_savedUsername;
    NSString *_savedPassword;
    NSString *_savedDomain;
}

// 内部方法（声明必须在 ivar block 之外）
- (void)prepareProcessEnvironment;
- (void)setupWLogCapture;
- (NSString *)attemptConnectWithConfig:(NSDictionary *)config profile:(int)profile;

@end

@implementation RDPBridge

// ---- 只读属性的 getter（手写，避免 @synthesize 依赖）----

- (RDPBridgeState)state
{
    return _state;
}

- (NSString *)lastErrorMessage
{
    return _lastErrorMessage;
}

- (CGSize)desktopSize
{
    return _desktopSize;
}

- (RDPModifierKey)stickyModifiers
{
    return _sticky;
}

// ---- 内部使用（供 C 回调读取凭据）----

- (NSString *)savedUsername
{
    return _savedUsername;
}

- (NSString *)savedPassword
{
    return _savedPassword;
}

- (NSString *)savedDomain
{
    return _savedDomain;
}

// ---- 内部 setter ----

- (void)setDesktopSize:(CGSize)size
{
    _desktopSize = size;
}

- (instancetype)init
{
    if (self = [super init])
    {
        _state = RDPBridgeStateIdle;
    }
    return self;
}

- (BOOL)isConnected
{
    return _state == RDPBridgeStateConnected;
}

// ------------------------------ 连接 ------------------------------

- (BOOL)connectToHost:(NSString *)host
                 port:(NSUInteger)port
             username:(NSString *)username
             password:(NSString *)password
               domain:(NSString *)domain
         desktopWidth:(NSUInteger)width
        desktopHeight:(NSUInteger)height
                error:(NSError **)error
{
    if (_state == RDPBridgeStateConnecting || _state == RDPBridgeStateConnected)
    {
        if (error)
            *error = [NSError errorWithDomain:RDPBridgeErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"已有连接在进行中"}];
        return NO;
    }
    if (host.length == 0 || username.length == 0)
    {
        if (error)
            *error = [NSError errorWithDomain:RDPBridgeErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"主机地址与用户名不能为空"}];
        return NO;
    }

    NSDictionary *config = @{
        @"host" : host,
        @"port" : @(port),
        @"username" : username,
        @"password" : password ?: @"",
        @"domain" : domain ?: @"",
        @"width" : @(MAX(width, 640)),
        @"height" : @(MAX(height, 480)),
    };

    [self setState:RDPBridgeStateConnecting message:nil];
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(connectThreadMain:) object:config];
    _thread.name = @"RDPBridge";
    [_thread start];
    return YES;
}

- (void)connectThreadMain:(NSDictionary *)config
{
    @autoreleasepool
    {
        // 进程环境准备 + FreeRDP 底层日志：FileAppender 到文件 + DEBUG 级别，
        // 失败时（failWithMessage）把日志尾部复制进剪贴板供排障。
        [self prepareProcessEnvironment];
        [self setupWLogCapture];

        // ---- TCP 预检：区分「网络层不通」与「RDP/TLS 协商失败」----
        NSString *probeErr = nil;
        if (![self tcpProbe:config[@"host"]
                       port:[config[@"port"] unsignedIntegerValue]
                     timeout:5.0
                      error:&probeErr])
        {
            [self failWithMessage:
                      [NSString stringWithFormat:@"网络层失败：无法建立 TCP 连接到 %@:%@（%@）",
                                                 config[@"host"] ?: @"?",
                                                 [config[@"port"] stringValue], probeErr]];
            return;
        }

        // ---- 协议层：两套安全层配置依次自动尝试 ----
        // profile 0：标准协商（NLA/CredSSP + TLS，FreeRDP 默认）
        // profile 1：纯 TLS（跳过 NLA 协商；服务器强制 NLA 时此模式会被拒）
        NSString *lastError = nil;
        BOOL connected = NO;
        for (int profile = 0; profile < 2 && !connected; profile++)
        {
            lastError = [self attemptConnectWithConfig:config profile:profile];
            connected = (_state == RDPBridgeStateConnected);
        }

        if (!connected)
        {
            [self failWithMessage:(lastError ?: @"连接失败")];
            return;
        }

        // ---- 事件泵（阻塞至断开）----
        [self pumpEvents];

        [self setState:RDPBridgeStateDisconnected message:nil];
        [self teardownContext];
    }
}

// 进程环境准备：补齐 winpr/freerdp 隐式依赖的环境变量。
//
// 根因（Linux 复现实验确认）：freerdp_settings_new 内部依赖
// GetKnownPath(KNOWN_PATH_HOME) 等路径探测；当 HOME 环境变量缺失
// （且 __IOS__ 未定义走 GetEnvAlloc("HOME") 分支）时，HomePath 为
// NULL，settings_new 直接 goto out_fail —— 整个过程【零日志】，
// 表现为 freerdp_context_new 静默失败。
// env -i 复现：缺 HOME → context_new FAIL；补 HOME/TMPDIR → ok。
- (void)prepareProcessEnvironment
{
    static BOOL prepared = NO;
    if (prepared)
        return;
    prepared = YES;

    if (!getenv("HOME"))
        setenv("HOME", NSHomeDirectory().fileSystemRepresentation, 1);
    if (!getenv("TMPDIR"))
        setenv("TMPDIR", NSTemporaryDirectory().fileSystemRepresentation, 1);
    if (!getenv("TZ"))
    {
        // iOS 无 /etc/localtime、/usr/share/zoneinfo，winpr timezone 探测链
        // 全部静默失败。显式设 TZ 让第一来源（winpr_time_zone_from_env）
        // 直接命中，DynamicDSTTimeZoneKeyName 才能正常填充。
        NSString *tz = [NSTimeZone localTimeZone].name ?: @"Asia/Shanghai";
        setenv("TZ", tz.fileSystemRepresentation, 1);
        tzset();
    }
}

- (void)setupWLogCapture
{
    // OpenSSL 3.x 把 MD4/RC4（NTLM 必需）移入 legacy provider。
    // 编译 OpenSSL 时已加 no-module：legacy provider 以 STATIC_LEGACY
    // 方式内置进 libcrypto.a（含 ossl_legacy_provider_init 入口），
    // 这里主动加载一次即可；winpr 之后加载同名 provider 会直接复用。
    // 缺了它：NLA/CredSSP 认证必然失败（SEC_E_NO_CREDENTIALS）。
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        OSSL_PROVIDER *legacy = OSSL_PROVIDER_load(NULL, "legacy");
        if (!legacy)
            NSLog(@"[RDPBridge] 警告：legacy provider 加载失败，NLA 认证将不可用");
    });
#endif

    // WinPR 的 ConsoleAppender 在 iOS 沙盒里几乎没用（stdout/stderr
    // 不指向文件，且 DEBUG/INFO 走 stdout、ERROR/WARN 走 stderr 分裂）。
    // 改用 FileAppender：所有 WLog 子 logger（包括 FreeRDP 的）都会写到这里。
    // 注意 WLog_GetRoot 必须先调（首次调会触发全局 root logger 初始化），
    // 否则后续 SetLogAppenderType / ConfigureAppender 会作用于未初始化的 root。
    static BOOL configured = NO;
    if (!configured)
    {
        configured = YES;
        NSString *logDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wlog"];
        NSString *logFile = @"rdp-wlog.log";
        wLog *rootLog = WLog_GetRoot();
        if (rootLog)
        {
            if (WLog_SetLogAppenderType(rootLog, WLOG_APPENDER_FILE))
            {
                wLogAppender *app = WLog_GetLogAppender(rootLog);
                if (app)
                {
                    // 第三参数是 void *：ObjC++ 下 const char * 必须显式强转
                    WLog_ConfigureAppender(app, "outputfilepath",
                                           (void *)logDir.fileSystemRepresentation);
                    WLog_ConfigureAppender(app, "outputfilename",
                                           (void *)logFile.fileSystemRepresentation);
                    WLog_OpenAppender(rootLog);
                    WLog_SetStringLogLevel(rootLog, "DEBUG");

                    // marker：验证 FileAppender 真的能写。若失败，说明
                    // appender 配置有问题，后续日志为空是配置问题而非
                    // 「context_new 恰好无日志可打」。
                    WLog_Print(rootLog, WLOG_INFO, "=== RDPBridge WLog marker: appender OK ===");
                }
            }
        }
    }
}

// TCP 连通性预探（非阻塞 connect + select 超时）
- (BOOL)tcpProbe:(NSString *)host
             port:(NSUInteger)port
           timeout:(NSTimeInterval)timeout
             error:(NSString **)errOut
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *res = nullptr;
    NSString *portStr = [NSString stringWithFormat:@"%lu", (unsigned long)port];
    int rc = getaddrinfo(host.UTF8String, portStr.UTF8String, &hints, &res);
    if (rc != 0 || !res)
    {
        if (errOut)
            *errOut = [NSString stringWithFormat:@"地址解析失败（%s）", gai_strerror(rc)];
        return NO;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0)
    {
        if (errOut)
            *errOut = [NSString stringWithFormat:@"创建 socket 失败（errno=%d）", errno];
        freeaddrinfo(res);
        return NO;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    BOOL ok = NO;
    NSString *err = nil;
    if (connect(fd, res->ai_addr, res->ai_addrlen) == 0)
    {
        ok = YES;
    }
    else if (errno == EINPROGRESS)
    {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);
        struct timeval tv;
        tv.tv_sec = (long)timeout;
        tv.tv_usec = 0;
        int sr = select(fd + 1, nullptr, &wfds, nullptr, &tv);
        if (sr > 0)
        {
            int soerr = 0;
            socklen_t len = sizeof(soerr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
            if (soerr == 0)
            {
                ok = YES;
            }
            else
            {
                err = [NSString stringWithFormat:@"连接被拒绝或不可达（%s）", strerror(soerr)];
            }
        }
        else if (sr == 0)
        {
            err = [NSString stringWithFormat:@"超时（%g 秒无响应）", timeout];
        }
        else
        {
            err = [NSString stringWithFormat:@"select 失败（errno=%d）", errno];
        }
    }
    else
    {
        err = [NSString stringWithFormat:@"connect 立即失败（%s）", strerror(errno)];
    }

    close(fd);
    freeaddrinfo(res);
    if (!ok && errOut)
        *errOut = err ?: @"未知错误";
    return ok;
}

// 单次连接尝试（含完整 settings 配置），成功返回 nil，失败返回错误描述
- (NSString *)attemptConnectWithConfig:(NSDictionary *)config profile:(int)profile
{
    @autoreleasepool
    {
    [self teardownContext];

    _ctx = new BridgeContext();
    _ctx->bridge = self;

    _ctx->instance = freerdp_new();
    if (!_ctx->instance)
    {
        NSLog(@"[RDPBridge] freerdp_new 失败（malloc 失败？）");
        [self teardownContext];
        return @"无法创建 RDP 客户端实例（freerdp_new 失败）";
    }

    // 基线自检：context_new 之前先确认 winpr 原语全部正常。
    // 若这里就 FAIL，问题在原语本身；若这里 ok 而后面 context_new 失败，
    // 问题在 FreeRDP 内部某个子系统的初始化。
    _winprBaseline = bridge_run_winpr_diag();
    NSLog(@"[RDPBridge] winpr 基线自检（profile %d）：%@", profile, _winprBaseline);

    if (!freerdp_context_new(_ctx->instance))
    {
        // 注意：freerdp_context_new 失败时，其内部 fail 分支会调用
        // freerdp_context_free()，该函数末尾会把 instance->context 置为
        // NULL。所以这里【绝对不能】再访问 _ctx->instance->context——
        // freerdp_get_last_error(NULL) 会因 WINPR_ASSERT 直接 abort 闪退。
        // 失败原因靠分步诊断（结果直接拼进弹窗，不依赖日志文件）。
        NSString *diag = bridge_run_context_diag();
        NSLog(@"[RDPBridge] freerdp_context_new 失败，分步诊断：%@", diag);
        [self teardownContext];
        return [NSString stringWithFormat:@"无法初始化 RDP 客户端上下文\n诊断:%@\n基线:%@",
                                          diag, _winprBaseline];
    }
    _ctx->context = _ctx->instance->context;

    {
        std::lock_guard<std::mutex> lock(g_contextMutex);
        g_contextMap[_ctx->context] = _ctx;
    }

    _ctx->instance->PostConnect = bridge_post_connect;
    _ctx->instance->AuthenticateEx = bridge_authenticate_ex;

    // 凭据保留给 AuthenticateEx 兜底
    _savedUsername = [config[@"username"] copy];
    _savedPassword = [config[@"password"] copy];
    _savedDomain = [config[@"domain"] copy];

    // ---- 配置 settings ----
    // 直接用类型化 setter（freerdp_settings_set_string/uint32/bool）。
    // 不用 freerdp_settings_set_value_for_name：它依赖编译期生成的
    // 「名字 -> key」映射表，裁剪版 FreeRDP（关闭 H264/FFmpeg 等）下
    // 部分 key 不在表里，会莫名返回 FALSE。
    // 注意：3.x 的 key 是按值类型分组的强类型枚举，key 类型必须与 setter 对应。
    NSString *nsHost = config[@"host"] ?: @"";
    NSString *nsUser = config[@"username"] ?: @"";
    NSString *nsPass = config[@"password"] ?: @"";
    NSString *nsDomain = config[@"domain"] ?: @"";
    NSString *nsPort = [config[@"port"] stringValue];
    NSString *nsW = [config[@"width"] stringValue];
    NSString *nsH = [config[@"height"] stringValue];
    rdpSettings *settings = _ctx->context->settings;

        BOOL ok = TRUE;
        NSString *failedSetting = nil;
#define BRIDGE_SET(expr)                    \
    do                                      \
    {                                       \
        if (!(expr))                        \
        {                                   \
            if (!failedSetting)             \
                failedSetting = @#expr;     \
            ok = FALSE;                     \
            WLog_ERR("RDPBridge", "设置失败: %s", #expr); \
        }                                   \
    } while (0)

        BRIDGE_SET(freerdp_settings_set_string(settings, FreeRDP_ServerHostname,
                                               nsHost.UTF8String ?: ""));
        BRIDGE_SET(freerdp_settings_set_uint32(settings, FreeRDP_ServerPort,
                                               (UINT32)nsPort.intValue));
        BRIDGE_SET(freerdp_settings_set_string(settings, FreeRDP_Username,
                                               nsUser.UTF8String ?: ""));
        BRIDGE_SET(freerdp_settings_set_string(settings, FreeRDP_Password,
                                               nsPass.UTF8String ?: ""));
        BRIDGE_SET(freerdp_settings_set_string(settings, FreeRDP_Domain,
                                               nsDomain.UTF8String ?: ""));
        BRIDGE_SET(freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth,
                                               (UINT32)nsW.intValue));
        BRIDGE_SET(freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight,
                                               (UINT32)nsH.intValue));
        BRIDGE_SET(freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32));

        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_AutoLogonEnabled, TRUE));
        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE));
        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, TRUE));
        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE));
        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, FALSE));
        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE));
        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE));
        BRIDGE_SET(freerdp_settings_set_bool(settings, FreeRDP_AllowFontSmoothing, TRUE));
        BRIDGE_SET(freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, 0x0409)); // en-US
#undef BRIDGE_SET

        // ---- 安全层策略 ----
        if (profile >= 1)
        {
            // profile 1：正常协商，但只提议 TLS（不请求 NLA/CredSSP）。
            // 保持 NegotiateSecurityLayer=TRUE：完全关闭协商时 FreeRDP 发出的
            // X.224 请求不带协议标志，Win11 24H2 会在 TLS 层直接回 alert。
            // 服务器关闭 NLA 后会接受「仅 SSL」提议，走 TLS 加密的标准登录。
            freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE);
            freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
            freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE);
        }

        if (!ok)
        {
            NSString *msg = failedSetting
                                ? [NSString stringWithFormat:@"RDP 配置写入失败（%@）", failedSetting]
                                : @"RDP 配置写入失败";
            [self teardownContext];
            return msg;
        }

        // ---- 连接（阻塞在本线程）----
        if (!freerdp_connect(_ctx->instance))
        {
            UINT32 code = freerdp_get_last_error(_ctx->context);
            const char *name = freerdp_get_last_error_name(code);
            const char *desc = freerdp_get_last_error_string(code);
            NSString *message = [NSString stringWithFormat:@"%@：%@（%@）",
                                 profile >= 1 ? @"纯 TLS 模式失败" : @"标准模式（NLA+TLS）失败",
                                 desc ? [NSString stringWithUTF8String:desc] : @"未知错误",
                                 name ? [NSString stringWithUTF8String:name] : @"UNKNOWN"];
            [self teardownContext];
            return message;
        }

        [self setState:RDPBridgeStateConnected message:nil];
        return nil;
    }
}

- (void)pumpEvents
{
    while (_ctx && _ctx->context && !freerdp_shall_disconnect_context(_ctx->context))
    {
        HANDLE handles[64] = {};
        DWORD count = freerdp_get_event_handles(_ctx->context, handles, 64);
        if (count == 0)
        {
            [NSThread sleepForTimeInterval:0.05];
            continue;
        }
        DWORD rc = WaitForMultipleObjects(count, handles, FALSE, 200);
        if (rc == WAIT_FAILED)
            break;
        if (!freerdp_check_event_handles(_ctx->context))
            break;
    }
}

- (void)disconnect
{
    if (_ctx && _ctx->instance && _ctx->context)
    {
        if (!freerdp_shall_disconnect_context(_ctx->context))
            freerdp_disconnect(_ctx->instance); // 唤醒事件泵并走正常退出流程
    }
}

// ------------------------------ 清理 ------------------------------

- (void)teardownContext
{
    if (!_ctx)
        return;

    _savedPassword = nil;
    _savedUsername = nil;
    _savedDomain = nil;
    _sticky = 0;

    if (_ctx->instance)
    {
        if (_ctx->context && !freerdp_shall_disconnect_context(_ctx->context))
            freerdp_disconnect(_ctx->instance);
        gdi_free(_ctx->instance);
        {
            std::lock_guard<std::mutex> lock(g_contextMutex);
            g_contextMap.erase(_ctx->context);
        }
        freerdp_free(_ctx->instance);
        _ctx->instance = nullptr;
        _ctx->context = nullptr;
    }
    delete _ctx;
    _ctx = nullptr;
    _thread = nil;
}

- (void)dealloc
{
    // 只发断开信号：连接线程通过 _ctx->bridge 强持有 self，
    // 真正的 teardownContext 在线程退出时执行，避免与运行中的线程并发访问。
    [self disconnect];
}

// ------------------------------ 状态 ------------------------------

- (void)setState:(RDPBridgeState)state message:(nullable NSString *)message
{
    void (^block)(void) = ^{
        self->_state = state;
        self->_lastErrorMessage = [message copy];
        if (self.stateHandler)
            self.stateHandler(state, message);
    };
    if ([NSThread isMainThread])
        block();
    else
        dispatch_async(dispatch_get_main_queue(), block);
}

- (void)failWithMessage:(NSString *)message
{
    // 把 FreeRDP 底层日志尾部复制进剪贴板，用户可直接粘贴给 AI 排障
    @autoreleasepool
    {
        NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wlog/rdp-wlog.log"];
        NSData *data = [NSData dataWithContentsOfFile:logPath];
        if (data.length > 0)
        {
            NSUInteger readLen = MIN(data.length, (NSUInteger)10000);
            NSData *tailData = [data subdataWithRange:NSMakeRange(data.length - readLen, readLen)];
            NSString *tail = [[NSString alloc] initWithData:tailData encoding:NSUTF8StringEncoding] ?: @"";
            NSString *full = [NSString stringWithFormat:@"[RDPClient 底层日志]\n%@\n\n[错误摘要]\n%@", tail, message ?: @""];
            [UIPasteboard generalPasteboard].string = full;
            message = [message stringByAppendingString:@"\n\n（底层日志已复制到剪贴板，可直接粘贴发送）"];
        }
    }
    [self setState:RDPBridgeStateFailed message:message];
}

// ------------------------------ 输入 ------------------------------

- (rdpInput *)input
{
    return (_ctx && _ctx->context) ? _ctx->context->input : nullptr;
}

- (void)sendMouseMoveAtX:(NSUInteger)x y:(NSUInteger)y
{
    rdpInput *input = [self input];
    if (!input)
        return;
    freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
}

- (void)sendMouseButton:(RDPMouseButton)button down:(BOOL)down x:(NSUInteger)x y:(NSUInteger)y
{
    rdpInput *input = [self input];
    if (!input)
        return;
    UINT16 flags = PTR_FLAGS_MOVE;
    if (down)
        flags |= PTR_FLAGS_DOWN;
    switch (button)
    {
    case RDPMouseButtonLeft:
        flags |= PTR_FLAGS_BUTTON1;
        break;
    case RDPMouseButtonRight:
        flags |= PTR_FLAGS_BUTTON2;
        break;
    case RDPMouseButtonMiddle:
        flags |= PTR_FLAGS_BUTTON3;
        break;
    }
    freerdp_input_send_mouse_event(input, flags, (UINT16)x, (UINT16)y);
}

- (void)sendScrollVerticalDelta:(NSInteger)delta
{
    [self sendWheelDelta:delta horizontal:NO];
}

- (void)sendScrollHorizontalDelta:(NSInteger)delta
{
    [self sendWheelDelta:delta horizontal:YES];
}

- (void)sendWheelDelta:(NSInteger)delta horizontal:(BOOL)horizontal
{
    rdpInput *input = [self input];
    if (!input || delta == 0)
        return;

    // MS-RDPBCGR：9 位二进制补码旋转量 + 方向标志；一格 = 120
    UINT16 flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
    UINT32 rotation = (UINT32)labs(delta);
    if (delta < 0)
    {
        flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        rotation = 0x200 - rotation;
    }
    flags |= (UINT16)(rotation & WheelRotationMask);
    freerdp_input_send_mouse_event(input, flags, 0, 0);
}

- (void)sendKeyScancode:(UInt8)scancode extended:(BOOL)extended down:(BOOL)down
{
    rdpInput *input = [self input];
    if (!input)
        return;
    UINT16 flags = extended ? KBD_FLAGS_EXTENDED : 0;
    if (!down)
        flags |= KBD_FLAGS_RELEASE;
    freerdp_input_send_keyboard_event(input, flags, scancode);
}

- (void)sendUnicodeCharacter:(UniChar)unit down:(BOOL)down
{
    rdpInput *input = [self input];
    if (!input)
        return;
    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    freerdp_input_send_unicode_keyboard_event(input, flags, unit);
}

- (void)setStickyModifiers:(RDPModifierKey)modifiers previous:(RDPModifierKey)previous
{
    _sticky = modifiers;

    static const struct
    {
        RDPModifierKey key;
        UINT8 scancode;
        BOOL extended;
    } kMap[] = {
        {RDPModifierCtrl, 0x1D, NO},   // Left Ctrl
        {RDPModifierShift, 0x2A, NO},  // Left Shift
        {RDPModifierAlt, 0x38, NO},    // Left Alt
        {RDPModifierWin, 0x5B, YES},   // Left Win
    };

    RDPModifierKey added = modifiers & ~previous;
    RDPModifierKey removed = previous & ~modifiers;
    for (const auto &entry : kMap)
    {
        if (added & entry.key)
            [self sendKeyScancode:entry.scancode extended:entry.extended down:YES];
        if (removed & entry.key)
            [self sendKeyScancode:entry.scancode extended:entry.extended down:NO];
    }
}

- (void)sendCtrlAltDelete
{
    rdpInput *input = [self input];
    if (!input)
        return;

    // Del = 0x53（扩展键）
    freerdp_input_send_keyboard_event(input, 0, 0x1D);            // Ctrl down
    freerdp_input_send_keyboard_event(input, 0, 0x38);            // Alt down
    freerdp_input_send_keyboard_event(input, KBD_FLAGS_EXTENDED, 0x53); // Del down
    freerdp_input_send_keyboard_event(input, KBD_FLAGS_EXTENDED | KBD_FLAGS_RELEASE, 0x53); // Del up
    freerdp_input_send_keyboard_event(input, KBD_FLAGS_RELEASE, 0x38);
    freerdp_input_send_keyboard_event(input, KBD_FLAGS_RELEASE, 0x1D);
}

@end
