//
//  ScancodeMap.swift
//  RDPClient
//
//  RDP 使用 IBM PC Set-1 扫描码。
//  文本字符走 Unicode 事件（兼容中文等），扫描码只用于：
//    1. 控制键（Esc/Tab/Enter/方向键/F1-F12 等）
//    2. 带修饰键的快捷键（Ctrl+C 之类必须走扫描码）
//

import Foundation

/// 一个 RDP 按键：扫描码 + 扩展键标志
struct RDPSendscan: Equatable {
    var code: UInt8
    var extended: Bool
}

enum RDPKey: UInt8 {
    // 基础控制键（非扩展）
    case escape    = 0x01
    case tab       = 0x0F
    case backspace = 0x0E
    case enter     = 0x1C
    case leftCtrl  = 0x1D
    case leftShift = 0x2A
    case leftAlt   = 0x38
    case space     = 0x39

    // 扩展键
    case insert    = 0x52
    case delete    = 0x53
    case home      = 0x47
    case end       = 0x4F
    case pageUp    = 0x49
    case pageDown  = 0x51
    case up        = 0x48
    case down      = 0x50
    case left      = 0x4B
    case right     = 0x4D

    // 功能键
    case f1 = 0x3B, f2 = 0x3C, f3 = 0x3D, f4 = 0x3E
    case f5 = 0x3F, f6 = 0x40, f7 = 0x41, f8 = 0x42
    case f9 = 0x43, f10 = 0x44, f11 = 0x57, f12 = 0x58

    // 常用快捷键字母
    case a = 0x1E, c = 0x2E, v = 0x2F, x = 0x2D, z = 0x2C
    case s = 0x1F, w = 0x11, n = 0x31, f = 0x21, d = 0x20

    var isExtended: Bool {
        switch self {
        case .insert, .delete, .home, .end, .pageUp, .pageDown,
             .up, .down, .left, .right:
            return true
        default:
            return false
        }
    }

    var sendscan: RDPSendscan {
        RDPSendscan(code: rawValue, extended: isExtended)
    }
}

enum ScancodeMap {
    /// US 布局下可打印 ASCII 字符 -> 扫描码（用于“sticky 修饰键 + 字符”的快捷键路径）
    private static let asciiMap: [Character: UInt8] = [
        "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
        "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,
        "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
        "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
        "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
        "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
        "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
        "z": 0x2C,
        " ": 0x39,
        "-": 0x0C, "=": 0x0D, "[": 0x1A, "]": 0x1B, "\\": 0x2B,
        ";": 0x27, "'": 0x28, "`": 0x29, ",": 0x33, ".": 0x34, "/": 0x35,
    ]

    /// ASCII 字符 -> 扫描码（大小写都接受）；无法映射返回 nil（改走 Unicode 路径）
    static func scanCode(for character: Character) -> RDPSendscan? {
        let lower = character.lowercased().first ?? character
        guard let code = asciiMap[lower] else { return nil }
        return RDPSendscan(code: code, extended: false)
    }
}
