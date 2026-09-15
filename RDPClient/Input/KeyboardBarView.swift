//
//  KeyboardBarView.swift
//  RDPClient
//
//  远程会话底部的按键快捷栏：
//    行 1：sticky 修饰键（Ctrl/Alt/Shift/Win）+ 控制键（Esc/Tab/Del/Enter）
//    行 2：常用快捷键（Ctrl+C/V/X/Z/A/S/W）+ 导航键 + Ctrl+Alt+Del
//

import SwiftUI

struct KeyboardBarView: View {
    /// 当前 sticky 修饰键（视觉状态）
    let sticky: RDPModifierKey
    var onToggleSticky: (RDPModifierKey) -> Void
    var onSpecialKey: (RDPKey) -> Void
    /// 发送“当前 sticky + 字符扫描码”的快捷键（如 Ctrl+C）
    var onShortcutCharacter: (Character) -> Void
    var onCtrlAltDelete: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            row1
            row2
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    // MARK: - 行 1

    private var row1: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                stickyButton("Ctrl", key: .ctrl)
                stickyButton("Alt", key: .alt)
                stickyButton("Shift", key: .shift)
                stickyButton("Win", key: .win)

                divider

                keyButton("Esc") { onSpecialKey(.escape) }
                keyButton("Tab") { onSpecialKey(.tab) }
                keyButton("⌫") { onSpecialKey(.backspace) }
                keyButton("⏎") { onSpecialKey(.enter) }
            }
        }
    }

    // MARK: - 行 2

    private var row2: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(["C", "V", "X", "Z", "A", "S", "W"], id: \.self) { letter in
                    keyButton(letter) { onShortcutCharacter(Character(letter.lowercased())) }
                }

                divider

                keyButton("Home") { onSpecialKey(.home) }
                keyButton("End") { onSpecialKey(.end) }
                keyButton("PgUp") { onSpecialKey(.pageUp) }
                keyButton("PgDn") { onSpecialKey(.pageDown) }

                divider

                keyButton("↑") { onSpecialKey(.up) }
                keyButton("↓") { onSpecialKey(.down) }
                keyButton("←") { onSpecialKey(.left) }
                keyButton("→") { onSpecialKey(.right) }

                divider

                keyButton("Ctrl+Alt+Del", prominent: true) { onCtrlAltDelete() }
            }
        }
    }

    // MARK: - 子视图

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.4)) // iOS 16 兼容（.separator 需要 iOS 17+）
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }

    private func stickyButton(_ title: String, key: RDPModifierKey) -> some View {
        let active = sticky.contains(key)
        return Button {
            onToggleSticky(key)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15))
                .foregroundStyle(active ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func keyButton(_ title: String, prominent: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, prominent ? 12 : 10)
                .padding(.vertical, 6)
                .background(prominent ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.15))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
