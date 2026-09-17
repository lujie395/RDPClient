//
//  RDPViewController.swift
//  RDPClient
//
//  远程会话视图控制器：
//    - UIScrollView + ScreenContentView（CALayer）渲染远程帧
//    - 手势 -> RDP 输入映射（见 README 手势表）
//    - 隐藏 UITextField 捕获软/硬键盘输入
//    - iPad 指针 / Magic Trackpad 支持（UIPointerInteraction）
//

import UIKit

// MARK: - 远程画面视图（layer 承载 CGImage）

final class ScreenContentView: UIView {
    override class var layerClass: AnyClass { CALayer.self }

    func updateImage(_ image: CGImage) {
        layer.contents = image
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
    }
}

// MARK: - 键盘捕获输入框

/// 借助 UITextField 的 first responder 地位捕获键盘输入。
/// 文本字符走 insertText（软/硬键盘统一），控制键走 pressesBegan/Ended（HID 码映射）。
final class KeyboardCaptureField: UITextField {
    var onInsertText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    /// 物理键按下/抬起（已映射为 RDP 扫描码；不可映射的键返回 false 走默认路径）
    var onPhysicalKey: ((RDPSendscan, Bool) -> Bool)?

    /// HID usage -> RDP 扫描码（只映射控制键与修饰键；
    /// 可打印字符不在此表，由 UIKit 转成 insertText，避免重复输入）
    private static let hidMap: [UInt: RDPSendscan] = [
        0x29: RDPSendscan(code: 0x01, extended: false), // Esc
        0x2B: RDPSendscan(code: 0x0F, extended: false), // Tab
        0x2A: RDPSendscan(code: 0x0E, extended: false), // Backspace
        0x4F: RDPSendscan(code: 0x4D, extended: true),  // Right
        0x50: RDPSendscan(code: 0x4B, extended: true),  // Left
        0x51: RDPSendscan(code: 0x50, extended: true),  // Down
        0x52: RDPSendscan(code: 0x48, extended: true),  // Up
        0x4A: RDPSendscan(code: 0x47, extended: true),  // Home
        0x4D: RDPSendscan(code: 0x4F, extended: true),  // End
        0x4B: RDPSendscan(code: 0x49, extended: true),  // PageUp
        0x4E: RDPSendscan(code: 0x51, extended: true),  // PageDown
        0x4C: RDPSendscan(code: 0x53, extended: true),  // Delete (Forward)
        0x3A: RDPSendscan(code: 0x3B, extended: false), // F1
        0x3B: RDPSendscan(code: 0x3C, extended: false), // F2
        0x3C: RDPSendscan(code: 0x3D, extended: false), // F3
        0x3D: RDPSendscan(code: 0x3E, extended: false), // F4
        0x3E: RDPSendscan(code: 0x3F, extended: false), // F5
        0x3F: RDPSendscan(code: 0x40, extended: false), // F6
        0x40: RDPSendscan(code: 0x41, extended: false), // F7
        0x41: RDPSendscan(code: 0x42, extended: false), // F8
        0x42: RDPSendscan(code: 0x43, extended: false), // F9
        0x43: RDPSendscan(code: 0x44, extended: false), // F10
        0x44: RDPSendscan(code: 0x57, extended: false), // F11
        0x45: RDPSendscan(code: 0x58, extended: false), // F12
        0xE0: RDPSendscan(code: 0x1D, extended: false), // Left Ctrl
        0xE1: RDPSendscan(code: 0x2A, extended: false), // Left Shift
        0xE2: RDPSendscan(code: 0x38, extended: false), // Left Alt
        0xE3: RDPSendscan(code: 0x5B, extended: true),  // Left Win
        0xE4: RDPSendscan(code: 0x1D, extended: true),  // Right Ctrl
        0xE5: RDPSendscan(code: 0x2A, extended: true),  // Right Shift
        0xE6: RDPSendscan(code: 0x38, extended: true),  // Right Alt
        0xE7: RDPSendscan(code: 0x5C, extended: true),  // Right Win
    ]

    override var hasText: Bool { true }

    override func insertText(_ text: String) {
        onInsertText?(text) // 不调用 super：保持输入框始终为空
    }

    override func deleteBackward() {
        onBackspace?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if dispatchPresses(presses, down: true) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if dispatchPresses(presses, down: false) { return }
        super.pressesEnded(presses, with: event)
    }

    private func dispatchPresses(_ presses: Set<UIPress>, down: Bool) -> Bool {
        guard let onPhysicalKey else { return false }
        var handledAny = false
        for press in presses {
            guard let key = press.key else { continue }
            if let scan = Self.hidMap[UInt(key.keyCode.rawValue)] {
                handledAny = onPhysicalKey(scan, down) || handledAny
            }
        }
        return handledAny
    }
}

// MARK: - 视图控制器

final class RDPViewController: UIViewController {

    // MARK: 对外接口

    /// 状态变化（主线程）
    var onStateChange: ((RDPBridgeState, String?) -> Void)?
    /// sticky 快捷键被消费后的通知（SwiftUI 侧同步清零视觉状态）
    var onStickyConsumed: (() -> Void)?

    let bridge = RDPBridge()

    private(set) var desktopSize: CGSize = .zero

    // MARK: 视图

    private let scrollView = UIScrollView()
    private let screenView = ScreenContentView()
    private let hiddenField = KeyboardCaptureField()

    // MARK: 交互状态

    private var interactionMode: TouchInputMapper.InteractionMode = .mouse
    private let wheelAccumulator = TouchInputMapper.WheelAccumulator()
    private var lastMoveSentAt: TimeInterval = 0
    private var isKeyboardOn = false

    /// 需要重新适配视口（新桌面尺寸 / 旋转后）；用户手动捏合缩放后置 false
    private var needsFit = false

    /// 布局完成前收到的连接请求（等 viewDidLayoutSubviews 再发起，bounds 才准）
    private var pendingConnection: RDPHost?

    /// 当前（或最近一次）连接的主机，回前台自动重连用
    private var currentHost: RDPHost?
    /// 回前台重连进行中（屏蔽中间状态回调，避免 UI 闪「已断开」）
    private var isReconnecting = false

    /// 帧渲染循环：每 vsync 从桥接层拉取最新帧（无新帧则跳过）
    private var displayLink: CADisplayLink?

    // MARK: 手势引用（delegate 需要按实例区分）
    private var oneFingerPanRef: UIPanGestureRecognizer?
    private var twoFingerPanRef: UIPanGestureRecognizer?

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupScrollView()
        setupHiddenField()
        setupGestures()
        setupBridgeCallbacks()
        // mouse 模式下禁用 UIScrollView 自带 pan，避免与单指移动光标抢事件
        setScrollPanEnabled(interactionMode == .pan)

        // iOS 挂起 App 时无法发送 RDP 断开包，TCP 变成半开的「僵尸连接」：
        // 它会占住 Windows 的用户会话，之后重连要抢同一个会话，
        // 轻则黑屏连不上，重则把服务端图形栈和本机控制台一起拖死。
        // 所以回前台时一律断开重连，保证每次拿到干净的会话。
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reconnectForCleanSession()
        }

        // 渲染循环随视图生命周期运行（而非随连接）。
        // 桌面尺寸变化（旋转 / DesktopResize）产生的帧不会被丢掉，
        // 连接完成后第一帧也能立刻显示。
        startRenderLoop()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startRenderLoop()
        // 兜底：若布局轮次都早于连接请求，这里 bounds 已就绪，补发
        if let host = pendingConnection, view.bounds.width > 10, view.bounds.height > 10 {
            pendingConnection = nil
            startConnection(to: host)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 布局回调统一处理：初始布局、旋转、safeArea 变化都会走到这里。
        // 缩放本身不能触发 fitAndCenter（会导致「每转一次缩小一次」的累积），
        // 只有 needsFit 置位时才重新适配。
        guard desktopSize != .zero else {
            // 布局完成且尚无桌面：如果连接请求还在排队（等 bounds），现在发起
            if let host = pendingConnection, view.bounds.width > 10, view.bounds.height > 10 {
                pendingConnection = nil
                startConnection(to: host)
            }
            return
        }
        if needsFit {
            needsFit = false
            fitAndCenter()
        } else {
            centerContent(animated: false)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // 旋转：视口尺寸变了，重新适配（画面完整显示并居中，随屏幕方向转换）。
        // 转屏时 safeArea 与导航栏高度也在变，若在转场开始时就算会用到旧 bounds，
        // 所以放到转场结束、布局稳定后再执行。
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.view.layoutIfNeeded()
            self.needsFit = true
            self.view.setNeedsLayout()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 只停渲染循环，不动连接：连接的生命周期由 SessionController 管
        // （断开按钮 -> session.disconnect()，退出页面 -> onDisappear）。
        stopRenderLoop()
    }

    // MARK: 对外动作

    /// 发起连接。视图尚未完成布局时挂起，待 viewDidLayoutSubviews 再真正开始。
    func startConnection(to host: RDPHost) {
        guard view.bounds.width > 10, view.bounds.height > 10 else {
            pendingConnection = host
            return
        }
        doConnect(to: host)
    }

    private func doConnect(to host: RDPHost) {
        currentHost = host
        guard let password = KeychainService.shared.loadPassword(account: host.passwordRef.uuidString) else {
            onStateChange?(.failed, "未找到已保存的密码，请返回主机列表重新编辑保存")
            return
        }

        var width = host.desktopWidth
        var height = host.desktopHeight
        if width == 0 || height == 0 {
            // 自动分辨率：按「实际可见区域」的逻辑尺寸协商。
            // view.bounds 已避让导航栏/控制条（RemoteScreenView 未用 ignoresSafeArea），
            // 桌面比例与可见区域一致 → 等比例缩放后正好铺满屏幕（RD Client 效果）。
            // 注意必须在布局完成后才走到这里，bounds 才是准确值。
            let visible = view.bounds.size
            width = min(UInt32(max(640, Int(visible.width.rounded()))), 2560)
            height = min(UInt32(max(480, Int(visible.height.rounded()))), 1600)
        }

        do {
            try bridge.connectToHost(host.host, port: UInt(host.port),
                                     username: host.username, password: password,
                                     domain: host.domain, desktopWidth: UInt(width),
                                     desktopHeight: UInt(height))
            // 渲染循环在 viewDidLoad 已启动，这里不再重复启动
        } catch {
            onStateChange?(.failed, error.localizedDescription)
        }
    }

    func disconnect() {
        bridge.disconnect()
    }

    /// 切换软键盘（隐藏输入框 first responder）
    func toggleKeyboard() {
        isKeyboardOn.toggle()
        if isKeyboardOn {
            hiddenField.becomeFirstResponder()
        } else {
            hiddenField.resignFirstResponder()
        }
    }

    func setInteractionMode(_ mode: TouchInputMapper.InteractionMode) {
        interactionMode = mode
        setScrollPanEnabled(mode == .pan)
    }

    func sendSpecialKey(_ key: RDPKey) {
        let scan = key.sendscan
        bridge.sendKeyScancode(scan.code, extended: scan.extended, down: true)
        bridge.sendKeyScancode(scan.code, extended: scan.extended, down: false)
    }

    /// 发送「当前 sticky 修饰键 + 字符扫描码」快捷键（如 Ctrl+C）
    func sendShortcutCharacter(_ character: Character) {
        guard let scan = ScancodeMap.scanCode(for: character) else { return }
        bridge.sendKeyScancode(scan.code, extended: scan.extended, down: true)
        bridge.sendKeyScancode(scan.code, extended: scan.extended, down: false)
        onStickyConsumed?()
    }

    func sendCtrlAltDelete() {
        bridge.sendCtrlAltDelete()
    }

    // MARK: 设置

    private func setupScrollView() {
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        // UIScrollView 自带 pan 的触点数由 setScrollPanEnabled 统一设置
        // （mouse 模式直接禁用，避免与单指移动光标抢事件）。
        scrollView.minimumZoomScale = 0.1
        scrollView.maximumZoomScale = 5
        // 点击延迟：UIScrollView 在存在 pan/pinch 时需要等约 150ms 才能判断
        // 「这是点击还是拖动」。禁用其内部 pan 延迟判定，单击立刻下发。
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        scrollView.addSubview(screenView)
        scrollView.addInteraction(UIPointerInteraction(delegate: self))
        // 右键/长按入口：iOS 13+ 把外接鼠标右键与触屏长按都路由到
        // UIContextMenuInteraction（不产生 touch），不注册就会被系统吞掉。
        scrollView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func setupHiddenField() {
        hiddenField.keyboardAppearance = .dark
        hiddenField.autocorrectionType = .no
        hiddenField.spellCheckingType = .no
        hiddenField.autocapitalizationType = .none
        hiddenField.smartQuotesType = .no
        hiddenField.smartDashesType = .no
        hiddenField.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        hiddenField.alpha = 0.01
        view.addSubview(hiddenField)

        hiddenField.onInsertText = { [weak self] text in
            self?.routeInsertedText(text)
        }
        hiddenField.onBackspace = { [weak self] in
            self?.sendSpecialKey(.backspace)
        }
        hiddenField.onPhysicalKey = { [weak self] scan, down in
            guard let self, self.bridge.isConnected() else { return false }
            self.bridge.sendKeyScancode(scan.code, extended: scan.extended, down: down)
            return true
        }
    }

    private func setupGestures() {
        // 双击判定不在本地做：单击立即发送，连续两次快速单击由 Windows
        // 按自己的 GetDoubleClickTime 判定（合成双击因间隔为 0 无法触发）。
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))

        // 双指点按 = 右键（触屏）
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        // 三指平移视口：不参与 pinch 的触点数，和缩放/点击都无冲突
        let threeFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3

        // 双指拖动 = 远程滚轮
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        // 双指拖动与 pinch 同为双指起手，必须允许同时识别，
        // 否则稍微有点方向差异就会被 pinch 抢占，滚轮时灵时不灵
        twoFingerPan.delegate = self

        // 单指拖动移动远程光标
        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        oneFingerPan.delegate = self

        [singleTap, twoFingerTap, threeFingerPan, twoFingerPan, oneFingerPan]
            .forEach { scrollView.addGestureRecognizer($0) }

        oneFingerPanRef = oneFingerPan
        twoFingerPanRef = twoFingerPan
    }

    /// 切换 UIScrollView 自带 pan（平移）的启用状态。
    /// mouse 模式下关闭它，避免和「单指移动光标」抢事件。
    private func setScrollPanEnabled(_ enabled: Bool) {
        scrollView.panGestureRecognizer.isEnabled = enabled
        if enabled {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 3
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 3
        }
    }

    private func setupBridgeCallbacks() {
        bridge.stateHandler = { [weak self] state, message in
            // 重连窗口期屏蔽中间状态（断开→连接中之间的闪烁），只透传结果
            if let self, !self.isReconnecting {
                self.onStateChange?(state, message)
            } else if state == .failed || state == .connected {
                self?.onStateChange?(state, message)
            }
        }
        bridge.resizeHandler = { [weak self] size in
            self?.configureDesktop(size)
        }
    }

    /// 回前台：上一次连接的 TCP 大概率已被 iOS 挂起杀死（僵尸连接）。
    /// 主动断开并重连，避免僵尸会话占住 Windows 端导致黑屏/服务端卡顿。
    /// 「连接中」状态不打断（连接线程仍在正常推进，失败会自然报错）。
    private func reconnectForCleanSession() {
        guard !isReconnecting, let host = currentHost else { return }
        guard bridge.state == .connected else { return }
        isReconnecting = true
        bridge.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.isReconnecting = false
            // 等待期间用户可能已退出会话页，此时不再重连
            guard self.viewIfLoaded?.window != nil else { return }
            self.startConnection(to: host)
        }
    }

    // MARK: 帧渲染循环（CADisplayLink 拉取模式）

    /// 开始渲染循环。桥接层把最新帧存入 pending，这里每 vsync 拉取一次：
    /// 无帧堆积、跳过重复帧，主线程永远只渲染最新画面。
    private func startRenderLoop() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(pullFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopRenderLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func pullFrame() {
        // takePendingFrame 标注 CF_RETURNS_RETAINED，Swift 自动接管引用计数
        guard let image = bridge.takePendingFrame() else { return }
        if desktopSize == .zero ||
           desktopSize.width != CGFloat(image.width) ||
           desktopSize.height != CGFloat(image.height) {
            configureDesktop(CGSize(width: image.width, height: image.height))
        }
        screenView.updateImage(image)
    }

    // MARK: 帧与桌面尺寸

    private func configureDesktop(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let sizeChanged = (size != desktopSize)
        desktopSize = size
        if sizeChanged {
            // 先撤掉旧的缩放，再换尺寸：
            // 否则 zoomScale 会按新 contentSize 重新换算，把画面放大到超出屏幕
            scrollView.minimumZoomScale = 0.01
            scrollView.maximumZoomScale = 1
            scrollView.zoomScale = 1
            screenView.frame = CGRect(origin: .zero, size: size)
            screenView.center = CGPoint(x: size.width / 2, y: size.height / 2)
            scrollView.contentSize = size
            resetContentInset()
        }
        needsFit = true
        // 尺寸变化通常伴随布局未完成（如旋转动画中），强制走一遍布局回调
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// 让远程画面等比例完整显示（RD Client 效果）。
    /// 协商的桌面比例 = 可见区域比例（见 doConnect），contain 缩放后正好铺满；
    /// 旋转后比例不再匹配时，等比例显示并留边（完整桌面优先）。
    private func fitAndCenter() {
        guard desktopSize.width > 0, desktopSize.height > 0,
              scrollView.bounds.width > 10, scrollView.bounds.height > 10 else { return }
        let boundsW = scrollView.bounds.width
        let boundsH = scrollView.bounds.height
        // contain：完整显示、等比例，不裁切
        let contain = min(boundsW / desktopSize.width, boundsH / desktopSize.height)
        // 先更新缩放边界，再设 zoomScale（否则会被旧的 min/max 截断——
        // 这正是之前画面缩放/位置错乱的原因）
        scrollView.minimumZoomScale = contain * 0.5
        scrollView.maximumZoomScale = max(5, contain * 12)
        scrollView.zoomScale = contain
        resetContentInset()
        centerContent(animated: false)
    }

    /// 清空 contentInset。
    /// UIScrollView 的 contentInset 会参与 zoomScale 的换算，
    /// 用它做居中会在缩放时累积
    ///   scale = (bounds - 2*inset) / bounds
    /// 的误差，表现为每旋转一次画面就缩小一点、越转越偏。
    /// 居中改用 screenView.center 直接定位（见 centerContent），与缩放无关。
    private func resetContentInset() {
        if scrollView.contentInset != .zero {
            scrollView.contentInset = .zero
        }
    }

    /// 缩放后画面小于视口时保持居中。
    /// 直接移动 screenView 的中心点：不参与 UIScrollView 的缩放换算，结果精确。
    /// 画面大于视口时（用户放大后）清除位移，交回正常的滚动行为。
    private func centerContent(animated: Bool) {
        guard desktopSize.width > 0, desktopSize.height > 0 else { return }
        let zoom = scrollView.zoomScale
        guard zoom > 0 else { return }
        let visible = scrollView.bounds.size
        let contentW = desktopSize.width * zoom
        let contentH = desktopSize.height * zoom

        let dx = contentW < visible.width ? (visible.width - contentW) / 2 : 0
        let dy = contentH < visible.height ? (visible.height - contentH) / 2 : 0
        let target = CGPoint(x: dx + contentW / 2, y: dy + contentH / 2)

        guard screenView.center != target else { return }
        if animated {
            UIView.animate(withDuration: 0.2) { self.screenView.center = target }
        } else {
            screenView.center = target
        }
    }

    // MARK: 坐标与输入路由

    /// 手势位置 -> 远程桌面像素坐标
    private func remotePoint(of gesture: UIGestureRecognizer) -> CGPoint {
        let location = gesture.location(in: screenView)
        return TouchInputMapper.remotePoint(from: location, desktopSize: desktopSize)
    }

    private func sendClick(_ button: RDPMouseButton, at point: CGPoint) {
        bridge.sendMouseButton(button, down: true, x: UInt(point.x), y: UInt(point.y))
        bridge.sendMouseButton(button, down: false, x: UInt(point.x), y: UInt(point.y))
    }

    /// 节流发送光标位置：约 60Hz 上限，避免拖动时把事件队列灌满。
    /// force=true 时无视节流（手势结束必须补发最终位置，否则光标会停在半路）。
    private func sendMoveThrottled(_ point: CGPoint, force: Bool = false) {
        let now = CACurrentMediaTime()
        if !force {
            guard now - lastMoveSentAt >= 0.016 else { return }
        }
        lastMoveSentAt = now
        bridge.sendMouseMoveAtX(UInt(point.x), y: UInt(point.y))
    }

    /// 软/硬键盘输入的文本 -> RDP
    private func routeInsertedText(_ text: String) {
        let sticky = bridge.stickyModifiers
        for character in text {
            if character == "\n" {
                sendSpecialKey(.enter)
                continue
            }
            // 有 sticky 修饰键时走扫描码路径，让修饰键与字符真正组合（Ctrl+C 等）
            if sticky != [] {
                if let scan = ScancodeMap.scanCode(for: character) {
                    bridge.sendKeyScancode(scan.code, extended: scan.extended, down: true)
                    bridge.sendKeyScancode(scan.code, extended: scan.extended, down: false)
                    onStickyConsumed?()
                    continue
                }
            }
            // 其余走 Unicode 路径（含中文等非拉丁字符）
            for unit in String(character).utf16 {
                bridge.sendUnicodeCharacter(unit, down: true)
                bridge.sendUnicodeCharacter(unit, down: false)
            }
        }
    }

    // MARK: 手势处理

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard bridge.isConnected() else { return }
        sendClick(.left, at: remotePoint(of: gesture))
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard bridge.isConnected() else { return }
        sendClick(.right, at: remotePoint(of: gesture))
    }

    /// 单指拖动：mouse 模式移动远程光标，pan 模式平移视口
    @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard bridge.isConnected() else { return }
        guard interactionMode == .mouse else { return }
        // 手势结束时补发最终位置，否则节流会把「最后一段」丢掉，光标停在半路
        let isFinal = (gesture.state == .ended || gesture.state == .cancelled)
        sendMoveThrottled(remotePoint(of: gesture), force: isFinal)
    }

    /// 三指拖动 / pan 模式单指拖动：平移本地视口（滚动由 UIScrollView 自己处理）
    @objc private func handleThreeFingerPan(_ gesture: UIPanGestureRecognizer) {
        panViewport(by: gesture.translation(in: scrollView))
        gesture.setTranslation(.zero, in: scrollView)
    }

    /// 按像素平移视口，边界以 contentSize 计算
    private func panViewport(by translation: CGPoint) {
        let zoom = scrollView.zoomScale
        guard zoom > 0 else { return }
        // 居中时 screenView.center 右移了 inset/2，那一半也属于可滚动范围
        //（contentInset 恒为 0，不能再用它算边界）。
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        var offset = scrollView.contentOffset
        offset.x = min(max(0, offset.x - translation.x / zoom), maxX)
        offset.y = min(max(0, offset.y - translation.y / zoom), maxY)
        scrollView.contentOffset = offset
    }

    /// 双指拖动 = 远程滚轮（自然方向：内容跟随手指）
    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard bridge.isConnected() else { return }
        let translation = gesture.translation(in: scrollView)
        gesture.setTranslation(.zero, in: scrollView)
        let delta = wheelAccumulator.consume(translationDelta: translation.y)
        if delta != 0 {
            bridge.sendScrollVerticalDelta(delta)
        }
        if gesture.state == .ended || gesture.state == .cancelled {
            wheelAccumulator.reset()
        }
    }
}

// MARK: - UIGestureRecognizerDelegate（并行识别）

extension RDPViewController: UIGestureRecognizerDelegate {
    /// 允许单指/双指拖动与 UIScrollView 自带的 pinch 同时识别。
    /// 默认行为下两者互斥，稍有一点方向偏移就会被 pinch 抢占，
    /// 表现为光标移动/滚轮「时灵时不灵」。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let mine: [UIGestureRecognizer] = [oneFingerPanRef, twoFingerPanRef].compactMap { $0 }
        return mine.contains(gestureRecognizer) || mine.contains(other)
    }

    /// 点击类手势不因其它手势识别而被阻止，保证单击始终能送到远程桌面。
    /// 单指拖动一旦触发，点击会自然失败（这是期望行为：拖动 ≠ 点击）。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        false
    }
}

// MARK: - UIScrollViewDelegate

extension RDPViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        screenView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 捏合缩放过程中同步居中；viewDidLayoutSubviews 不一定会被触发
        centerContent(animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 滚动（含惯性）时 contentOffset 被系统改写；画面小于视口时补回居中
        guard scrollView.zoomScale > 0 else { return }
        let contentW = desktopSize.width * scrollView.zoomScale
        let contentH = desktopSize.height * scrollView.zoomScale
        if contentW <= scrollView.bounds.width + 0.5 || contentH <= scrollView.bounds.height + 0.5 {
            centerContent(animated: false)
        }
    }
}

// MARK: - UIContextMenuInteractionDelegate（鼠标右键 / 触屏长按）

extension RDPViewController: UIContextMenuInteractionDelegate {
    /// 外接鼠标右键按下、触屏长按到达阈值时调用。
    /// 返回 nil 不显示系统菜单，位置转发为远程右键点击。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard bridge.isConnected() else { return nil }
        let remote = TouchInputMapper.remotePoint(from: scrollView.convert(location, to: screenView),
                                                  desktopSize: desktopSize)
        sendClick(.right, at: remote)
        return nil
    }
}

// MARK: - UIPointerInteractionDelegate（iPad / Magic Trackpad）

extension RDPViewController: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion?) -> UIPointerRegion? {
        // 指针每次移动都会请求 region：借机把位置同步给远程桌面
        guard bridge.isConnected() else { return defaultRegion }
        let remote = TouchInputMapper.remotePoint(from: scrollView.convert(request.location, to: screenView),
                                                  desktopSize: desktopSize)
        sendMoveThrottled(remote)
        return defaultRegion
    }
}
