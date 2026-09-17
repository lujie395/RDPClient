//
//  RDPBridge.h
//  RDPClient
//
//  FreeRDP 3.x 的 Objective-C 桥接层。
//  负责与 libfreerdp/libwinpr 静态库交互，向 Swift 暴露：
//    - 连接/断开（用户名密码认证）
//    - 远程桌面帧回调（CGImage）
//    - 鼠标/滚轮/键盘输入发送
//    - 修饰键（Ctrl/Shift/Alt/Win）sticky 状态
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 连接状态
typedef NS_ENUM(NSInteger, RDPBridgeState) {
    RDPBridgeStateIdle = 0,
    RDPBridgeStateConnecting,
    RDPBridgeStateConnected,
    RDPBridgeStateFailed,
    RDPBridgeStateDisconnected,
};

/// 修饰键（sticky 组合键用）
typedef NS_OPTIONS(NSUInteger, RDPModifierKey) {
    RDPModifierCtrl  = 1 << 0,
    RDPModifierShift = 1 << 1,
    RDPModifierAlt   = 1 << 2,
    RDPModifierWin   = 1 << 3,
};

/// 鼠标按键
typedef NS_ENUM(NSInteger, RDPMouseButton) {
    RDPMouseButtonLeft   = 0,
    RDPMouseButtonRight  = 1,
    RDPMouseButtonMiddle = 2,
};

FOUNDATION_EXPORT NSString * const RDPBridgeErrorDomain;

@interface RDPBridge : NSObject

/// 当前状态（变更时通过 stateHandler 回调，主线程）
@property (nonatomic, assign, readonly) RDPBridgeState state;

/// 会话是否处于活跃连接（输入 API 的前置条件）
- (BOOL)isConnected;

/// 失败时的错误描述（中文，可直接展示）
@property (nonatomic, copy, readonly, nullable) NSString *lastErrorMessage;

/// 协商后的远程桌面尺寸（像素），连接后有效
@property (nonatomic, assign, readonly) CGSize desktopSize;

/// 回调：状态变化（主线程）
@property (nonatomic, copy, nullable) void (^stateHandler)(RDPBridgeState state,
                                                           NSString * _Nullable message);
/// 回调：远程桌面尺寸变化（主线程）
@property (nonatomic, copy, nullable) void (^resizeHandler)(CGSize newSize);

/// 拉取暂存的最新帧（渲染循环每帧调用；所有权转移给调用方，Swift 侧自动管理）。
/// 无新帧返回 NULL。连续帧在桥接层自动合并，只保留最新一帧。
- (nullable CGImageRef)takePendingFrame CF_RETURNS_RETAINED NS_SWIFT_NAME(takePendingFrame());

/// 建立连接。同步校验参数并启动后台连接线程。
/// @return NO 表示参数/状态非法（error 会带原因）
- (BOOL)connectToHost:(NSString *)host
                 port:(NSUInteger)port
             username:(NSString *)username
             password:(NSString *)password
               domain:(NSString *)domain
         desktopWidth:(NSUInteger)width
        desktopHeight:(NSUInteger)height
                error:(NSError **)error NS_SWIFT_NAME(connectToHost(_:port:username:password:domain:desktopWidth:desktopHeight:));

/// 断开连接（幂等；未连接时调用无副作用）
- (void)disconnect;

// ------------------------- 输入 API -------------------------

/// 鼠标移动（x/y 为远程桌面像素坐标）
- (void)sendMouseMoveAtX:(NSUInteger)x y:(NSUInteger)y NS_SWIFT_NAME(sendMouseMoveAtX(_:y:));

/// 按下/抬起鼠标按键
- (void)sendMouseButton:(RDPMouseButton)button down:(BOOL)down x:(NSUInteger)x y:(NSUInteger)y NS_SWIFT_NAME(sendMouseButton(_:down:x:y:));

/// 滚轮。delta 为旋转量：一格 = 120；正值向“上/左”，负值向“下/右”
- (void)sendScrollVerticalDelta:(NSInteger)delta NS_SWIFT_NAME(sendScrollVerticalDelta(_:));
- (void)sendScrollHorizontalDelta:(NSInteger)delta NS_SWIFT_NAME(sendScrollHorizontalDelta(_:));

/// 发送键盘扫描码事件（控制键、快捷键用）
/// @param scancode Set-1 扫描码（如 Esc=0x01、Enter=0x1C、Del=0x53）
/// @param extended 是否为扩展键（方向键/Del/Win 等为 YES）
- (void)sendKeyScancode:(UInt8)scancode extended:(BOOL)extended down:(BOOL)down NS_SWIFT_NAME(sendKeyScancode(_:extended:down:));

/// 发送 Unicode 字符事件（文本输入用，支持中文）
/// @param utf16Unit UTF-16 码元（代理对需逐个发送 down+up）
- (void)sendUnicodeCharacter:(UniChar)utf16Unit down:(BOOL)down NS_SWIFT_NAME(sendUnicodeCharacter(_:down:));

/// 更新 sticky 修饰键。previous 为变更前状态；新增的按下、移除的抬起。
- (void)setStickyModifiers:(RDPModifierKey)modifiers previous:(RDPModifierKey)previous NS_SWIFT_NAME(setStickyModifiers(_:previous:));

/// 当前 sticky 修饰键
@property (nonatomic, readonly) RDPModifierKey stickyModifiers;

/// 发送 Ctrl+Alt+Del（内部自管按键时序，不影响 sticky 状态）
- (void)sendCtrlAltDelete;

@end

NS_ASSUME_NONNULL_END
