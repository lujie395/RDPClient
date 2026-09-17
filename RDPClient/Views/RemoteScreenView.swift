//
//  RemoteScreenView.swift
//  RDPClient
//
//  远程会话的 SwiftUI 外壳：
//    - 全屏远程画面（RDPViewController）
//    - 顶部工具条（断开）+ 底部控制条（键盘/模式）+ 按键快捷栏
//    - 连接状态覆盖层（连接中 / 失败重试）
//

import SwiftUI

// MARK: - 会话控制器（SwiftUI 状态 ↔ RDPViewController 桥梁）

@MainActor
final class SessionController: ObservableObject {
    let host: RDPHost

    @Published var state: RDPBridgeState = .idle
    @Published var errorMessage: String?
    @Published var sticky: RDPModifierKey = []
    @Published var isKeyboardOn = false
    @Published var mode: TouchInputMapper.InteractionMode = .mouse

    weak var viewController: RDPViewController?

    init(host: RDPHost) {
        self.host = host
    }

    func start() {
        errorMessage = nil
        viewController?.startConnection(to: host)
    }

    func disconnect() {
        viewController?.disconnect()
    }

    func toggleSticky(_ key: RDPModifierKey) {
        let previous = sticky
        let next = previous.symmetricDifference(key)
        sticky = next
        viewController?.bridge.setStickyModifiers(next, previous: previous)
    }

    func clearSticky() {
        guard sticky != [] else { return }
        let previous = sticky
        sticky = []
        viewController?.bridge.setStickyModifiers([], previous: previous)
    }

    func toggleKeyboard() {
        isKeyboardOn.toggle()
        viewController?.toggleKeyboard()
    }

    func setMode(_ newMode: TouchInputMapper.InteractionMode) {
        mode = newMode
        viewController?.setInteractionMode(newMode)
    }

    func sendSpecialKey(_ key: RDPKey) {
        viewController?.sendSpecialKey(key)
    }

    func sendShortcutCharacter(_ character: Character) {
        viewController?.sendShortcutCharacter(character)
        clearSticky() // 快捷键已消费，sticky 复位
    }

    func sendCtrlAltDelete() {
        viewController?.sendCtrlAltDelete()
    }
}

// MARK: - UIViewControllerRepresentable

struct RemoteScreen: UIViewControllerRepresentable {
    @ObservedObject var session: SessionController
    let onConnected: () -> Void

    func makeUIViewController(context: Context) -> RDPViewController {
        let controller = RDPViewController()
        session.viewController = controller
        controller.onStateChange = { state, message in
            session.state = state
            session.errorMessage = message
            if state == .connected {
                onConnected()
            }
        }
        controller.onStickyConsumed = { [weak session] in
            session?.clearSticky()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: RDPViewController, context: Context) {}
}

// MARK: - 主视图

struct RemoteScreenView: View {
    let host: RDPHost

    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session: SessionController

    init(host: RDPHost) {
        self.host = host
        _session = StateObject(wrappedValue: SessionController(host: host))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 不加 ignoresSafeArea：让视图避让顶部导航栏与底部控制条，
            // 这样 RDPViewController 的 bounds 就是「实际可见区域」，
            // 连接协商的桌面比例与可见区域一致 → 等比例缩放后正好铺满（RD Client 效果）。
            RemoteScreen(session: session, onConnected: {
                store.markConnected(id: host.id)
            })

            statusOverlay
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(host.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session.disconnect()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel("断开连接")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if session.isKeyboardOn {
                    KeyboardBarView(sticky: session.sticky,
                                    onToggleSticky: { session.toggleSticky($0) },
                                    onSpecialKey: { session.sendSpecialKey($0) },
                                    onShortcutCharacter: { session.sendShortcutCharacter($0) },
                                    onCtrlAltDelete: { session.sendCtrlAltDelete() })
                }
                controlBar
            }
            .background(.thinMaterial)
        }
        .onAppear {
            session.start()
        }
        .onDisappear {
            session.disconnect()
        }
    }

    // MARK: 底部控制条

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                session.toggleKeyboard()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(session.isKeyboardOn ? Color.accentColor : Color.primary)
            }
            .accessibilityLabel("键盘")

            Button {
                session.setMode(session.mode == .mouse ? .pan : .mouse)
            } label: {
                Image(systemName: session.mode == .mouse ? "cursorarrow.rays" : "hand.draw")
                    .font(.system(size: 17, weight: .medium))
            }
            .accessibilityLabel(session.mode == .mouse ? "切换为视口平移" : "切换为鼠标模式")

            Spacer()

            switch session.state {
            case .connected:
                Label("已连接", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .connecting:
                Label("连接中", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 状态覆盖层

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.state {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在连接 \(host.host):\(host.port) …")
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

        case .failed, .disconnected:
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.yellow)
                Text(session.errorMessage ?? "连接已断开")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("重试") { session.start() }
                        .buttonStyle(.borderedProminent)
                    Button("返回") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 32)

        default:
            EmptyView()
        }
    }
}
