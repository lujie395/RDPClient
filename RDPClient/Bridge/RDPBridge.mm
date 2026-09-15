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
#import <winpr/synch.h>
#import <winpr/wlog.h>

#import <map>
#import <mutex>
#import <string>

NSString * const RDPBridgeErrorDomain = @"RDPBridgeErrorDomain";

// ---------------------------------------------------------------------------
// C 侧上下文
// ---------------------------------------------------------------------------
struct BridgeContext;

static std::mutex g_contextMutex;
static std::map<rdpContext *, BridgeContext *> g_contextMap;

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
            bridge.desktopSize = size;
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
        bridge.desktopSize = size;
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
    *username = strdup(bridge.username.UTF8String);
    *password = strdup(bridge.password.UTF8String);
    *domain = bridge.domain.length > 0 ? strdup(bridge.domain.UTF8String) : nullptr;
    return (*username && *password) ? TRUE : FALSE;
}

// ---------------------------------------------------------------------------
// ObjC 接口
// ---------------------------------------------------------------------------
@interface RDPBridge ()
{
    BridgeContext *_ctx;
    NSThread *_thread;
    RDPModifierKey _sticky; // 由 setStickyModifiers 维护（供只读属性）
}
@property (nonatomic, readwrite) RDPBridgeState state;
@property (nonatomic, readwrite, copy, nullable) NSString *lastErrorMessage;
@property (nonatomic, readwrite) CGSize desktopSize;
@property (nonatomic, copy) NSString *username; // 连接期间持有（AuthenticateEx 兜底用）
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *domain;
@end

@implementation RDPBridge

@synthesize state = _state;
@synthesize lastErrorMessage = _lastErrorMessage;
@synthesize desktopSize = _desktopSize;
@synthesize username = _username;
@synthesize password = _password;
@synthesize domain = _domain;

- (instancetype)init
{
    if (self = [super init])
    {
        _state = RDPBridgeStateIdle;
    }
    return self;
}

- (RDPModifierKey)stickyModifiers
{
    return _sticky;
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
    if (self.state == RDPBridgeStateConnecting || self.state == RDPBridgeStateConnected)
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
        _ctx = new BridgeContext();
        _ctx->bridge = self;

        _ctx->instance = freerdp_new();
        if (!_ctx->instance || !freerdp_context_new(_ctx->instance))
        {
            [self failWithMessage:@"无法初始化 RDP 客户端上下文"];
            [self teardownContext];
            return;
        }
        _ctx->context = _ctx->instance->context;

        {
            std::lock_guard<std::mutex> lock(g_contextMutex);
            g_contextMap[_ctx->context] = _ctx;
        }

        _ctx->instance->PostConnect = bridge_post_connect;
        _ctx->instance->AuthenticateEx = bridge_authenticate_ex;

        // 凭据保留给 AuthenticateEx 兜底
        self.username = config[@"username"];
        self.password = config[@"password"];
        self.domain = config[@"domain"];

        // ---- 配置 settings（freerdp_settings_set_value_for_name 自 3.0.0 起稳定可用）----
        rdpSettings *settings = _ctx->context->settings;
        NSString *port = [config[@"port"] stringValue];
        NSString *w = [config[@"width"] stringValue];
        NSString *h = [config[@"height"] stringValue];

        BOOL ok = TRUE;
        ok &= [self setValue:config[@"host"] forSetting:@"FreeRDP_ServerHostname"];
        ok &= [self setValue:port forSetting:@"FreeRDP_ServerPort"];
        ok &= [self setValue:config[@"username"] forSetting:@"FreeRDP_Username"];
        ok &= [self setValue:config[@"password"] forSetting:@"FreeRDP_Password"];
        ok &= [self setValue:w forSetting:@"FreeRDP_DesktopWidth"];
        ok &= [self setValue:h forSetting:@"FreeRDP_DesktopHeight"];
        ok &= [self setValue:@"32" forSetting:@"FreeRDP_ColorDepth"];

        // 布尔值只接受 TRUE/FALSE（见 freerdp_settings_set_value_for_name 实现）
        ok &= [self setValue:@"TRUE" forSetting:@"FreeRDP_AutoLogonEnabled"];
        ok &= [self setValue:@"TRUE" forSetting:@"FreeRDP_SoftwareGdi"];
        ok &= [self setValue:@"TRUE" forSetting:@"FreeRDP_IgnoreCertificate"];
        ok &= [self setValue:@"FALSE" forSetting:@"FreeRDP_SupportGraphicsPipeline"];
        ok &= [self setValue:@"FALSE" forSetting:@"FreeRDP_NetworkAutoDetect"];
        ok &= [self setValue:@"FALSE" forSetting:@"FreeRDP_AudioPlayback"];
        ok &= [self setValue:@"FALSE" forSetting:@"FreeRDP_AudioCapture"];
        ok &= [self setValue:@"TRUE" forSetting:@"FreeRDP_FontSmoothing"];
        ok &= [self setValue:@"1033" forSetting:@"FreeRDP_KeyboardLayout"]; // en-US

        if (!ok)
        {
            [self failWithMessage:@"RDP 配置写入失败"];
            [self teardownContext];
            return;
        }

        // ---- 连接（阻塞在本线程）----
        if (!freerdp_connect(_ctx->instance))
        {
            UINT32 code = freerdp_get_last_error(_ctx->context);
            const char *name = freerdp_get_last_error_name(code);
            const char *desc = freerdp_get_last_error_string(code);
            NSString *message = [NSString stringWithFormat:@"连接失败：%@（%@）",
                                 desc ? [NSString stringWithUTF8String:desc] : @"未知错误",
                                 name ? [NSString stringWithUTF8String:name] : @"UNKNOWN"];
            [self failWithMessage:message];
            [self teardownContext];
            return;
        }

        [self setState:RDPBridgeStateConnected message:nil];

        // ---- 事件泵 ----
        [self pumpEvents];

        [self setState:RDPBridgeStateDisconnected message:nil];
        [self teardownContext];
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

    self.password = nil;
    self.username = nil;
    self.domain = nil;
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
        self.state = state;
        self.lastErrorMessage = message;
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
    [self setState:RDPBridgeStateFailed message:message];
}

- (BOOL)setValue:(NSString *)value forSetting:(NSString *)name
{
    BOOL ok = freerdp_settings_set_value_for_name(_ctx->context->settings,
                                                  name.UTF8String, value.UTF8String);
    if (!ok)
        WLog_ERR("RDPBridge", "设置 %s=%s 失败", name.UTF8String, value.UTF8String);
    return ok;
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
