//
//  TouchInputMapper.swift
//  RDPClient
//
//  手势 -> RDP 输入的纯逻辑部分：
//    - 触点坐标换算（ScrollView 缩放下的远程像素坐标）
//    - 双指滚动 -> 滚轮格数的累积换算
//

import UIKit

enum TouchInputMapper {

    /// 交互模式：mouse = 单指移动远程光标；pan = 单指平移本地视口
    enum InteractionMode {
        case mouse
        case pan
    }

    /// 滚动多少本地像素算一格滚轮
    static let wheelNotchPixels: CGFloat = 40
    /// 每格滚轮对应的 RDP 旋转量（Windows WHEEL_DELTA）
    static let wheelDeltaPerNotch: Int = 120

    /// 把「屏幕视图上的触点」换算为「远程桌面像素坐标」。
    ///
    /// ScreenContentView 的 bounds 尺寸 = 远程桌面原始像素尺寸（缩放由 ScrollView 的
    /// zoomScale 承担），因此 location(in: contentView) 天然就是未缩放的远程坐标。
    static func remotePoint(from locationInContentView: CGPoint,
                            desktopSize: CGSize) -> CGPoint {
        guard desktopSize.width > 0, desktopSize.height > 0 else { return .zero }
        return CGPoint(x: max(0, min(locationInContentView.x, desktopSize.width - 1)),
                       y: max(0, min(locationInContentView.y, desktopSize.height - 1)))
    }

    /// 双指滚动累积器：把手势位移换算成整格滚轮数（带余量记忆，避免小步移动丢事件）
    final class WheelAccumulator {
        private var residual: CGFloat = 0

        /// translationDelta：本次手势位移增量。返回应发送的 RDP wheel delta（格数 * 120）。
        /// 手势结束时应调用 reset()。
        func consume(translationDelta: CGFloat) -> Int {
            residual += translationDelta
            let notches = Int(residual / wheelNotchPixels)
            residual -= CGFloat(notches) * wheelNotchPixels
            guard notches != 0 else { return 0 }
            return notches * wheelDeltaPerNotch
        }

        func reset() {
            residual = 0
        }
    }
}
