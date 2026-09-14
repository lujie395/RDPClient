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

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupScrollView()
        setupHiddenField()
        setupGestures()
        setupBridgeCallbacks()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 只做居中，不重置缩放（避免覆盖用户的捏合缩放）
        if desktopSize != .zero {
            centerContent()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.fitAndCenter()
        }
    }

    // MARK: 对外动作

    /// 发起连接
    func startConnection(to host: RDPHost) {
        guard let password = KeychainService.shared.loadPassword(account: host.passwordRef.uuidString) else {
            onStateChange?(.failed, "未找到已保存的密码，请返回主机列表重新编辑保存")
            return
        }

        var width = host.desktopWidth
        var height = host.desktopHeight
        if width == 0 || height == 0 {
            // 自动分辨率：当前视口 × 屏幕像素密度（不超过 4K）
            let scale = view.window?.screen.scale ?? 2
            width = min(UInt32(max(1024, view.bounds.width * scale)), 3840)
            height = min(UInt32(max(768, view.bounds.height * scale)), 2160)
        }

        do {
            try bridge.connectToHost(host.host, port: UInt(host.port),
                                     username: host.username, password: password,
                                     domain: host.domain, desktopWidth: UInt(width),
                                     desktopHeight: UInt(height))
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
        // 三指拖动 = 平移视口；一指/两指留给鼠标移动与滚轮
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 3
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 3
        scrollView.minimumZoomScale = 0.1
        scrollView.maximumZoomScale = 5
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
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5

        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2

        [doubleTap, singleTap, twoFingerTap, longPress, oneFingerPan, twoFingerPan]
            .forEach { scrollView.addGestureRecognizer($0) }
    }

    private func setupBridgeCallbacks() {
        bridge.stateHandler = { [weak self] state, message in
            self?.onStateChange?(state, message)
        }
        bridge.frameHandler = { [weak self] image in
            self?.handleFrame(image)
        }
        bridge.resizeHandler = { [weak self] size in
            self?.configureDesktop(size)
        }
    }

    // MARK: 帧与桌面尺寸

    private func handleFrame(_ image: CGImage) {
        if desktopSize == .zero {
            configureDesktop(CGSize(width: image.width, height: image.height))
        }
        screenView.updateImage(image)
    }

    private func configureDesktop(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        desktopSize = size
        let origin = screenView.frame.origin
        screenView.frame = CGRect(origin: origin, size: size)
        scrollView.contentSize = size
        fitAndCenter()
    }

    /// 让远程画面完整适配当前视口并居中
    private func fitAndCenter() {
        guard desktopSize.width > 0, desktopSize.height > 0, scrollView.bounds.width > 0 else { return }
        let fit = min(scrollView.bounds.width / desktopSize.width,
                      scrollView.bounds.height / desktopSize.height)
        scrollView.minimumZoomScale = fit / 4
        scrollView.maximumZoomScale = 5
        scrollView.zoomScale = fit
        centerContent()
    }

    /// 缩放后画面小于视口时保持居中
    private func centerContent() {
        var inset = scrollView.contentInset
        let bounds = scrollView.bounds.inset(by: inset).size
        let contentWidth = desktopSize.width * scrollView.zoomScale
        let contentHeight = desktopSize.height * scrollView.zoomScale

        inset.left = contentWidth < bounds.width ? (bounds.width - contentWidth) / 2 : 0
        inset.top = contentHeight < bounds.height ? (bounds.height - contentHeight) / 2 : 0
        if scrollView.contentInset != inset {
            scrollView.contentInset = inset
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

    private func sendMoveThrottled(_ point: CGPoint) {
        let now = CACurrentMediaTime()
        guard now - lastMoveSentAt >= 0.016 else { return }
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

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard bridge.isConnected() else { return }
        let point = remotePoint(of: gesture)
        sendClick(.left, at: point)
        sendClick(.left, at: point)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard bridge.isConnected() else { return }
        sendClick(.right, at: remotePoint(of: gesture))
    }

    /// 长按 = 右键；按住拖动 = 右键拖动
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard bridge.isConnected() else { return }
        let point = remotePoint(of: gesture)
        switch gesture.state {
        case .began:
            bridge.sendMouseButton(.right, down: true, x: UInt(point.x), y: UInt(point.y))
        case .changed:
            sendMoveThrottled(point)
        case .ended, .cancelled:
            bridge.sendMouseButton(.right, down: false, x: UInt(point.x), y: UInt(point.y))
        default:
            break
        }
    }

    /// 单指拖动：mouse 模式移动光标，pan 模式平移视口
    @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard bridge.isConnected() else { return }
        switch interactionMode {
        case .mouse:
            sendMoveThrottled(remotePoint(of: gesture))
        case .pan:
            let translation = gesture.translation(in: scrollView)
            gesture.setTranslation(.zero, in: scrollView)
            var offset = scrollView.contentOffset
            offset.x = max(-scrollView.contentInset.left,
                           min(offset.x - translation.x / scrollView.zoomScale,
                               scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right))
            offset.y = max(-scrollView.contentInset.top,
                           min(offset.y - translation.y / scrollView.zoomScale,
                               scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom))
            scrollView.contentOffset = offset
        }
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

// MARK: - UIScrollViewDelegate

extension RDPViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        screenView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
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
