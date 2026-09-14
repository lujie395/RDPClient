//
//  RDPHost.swift
//  RDPClient
//
//  连接配置数据模型。密码本身只存 Keychain，
//  这里保存 passwordRef（Keychain 里的 account 标识）。
//

import Foundation

struct RDPHost: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    /// 显示名称
    var name: String = ""
    /// 主机 IP / 主机名
    var host: String = ""
    /// RDP 端口（默认 3389）
    var port: UInt16 = 3389
    /// Windows 用户名
    var username: String = ""
    /// 域名（可空；本机账户可填机器名或留空）
    var domain: String = ""
    /// Keychain 密码条目标识
    var passwordRef: UUID = UUID()
    /// 远程桌面分辨率（0 表示跟随服务器默认协商）
    var desktopWidth: UInt32 = 0
    var desktopHeight: UInt32 = 0
    /// 最近一次成功连接时间
    var lastConnectedAt: Date?

    var displayName: String {
        name.isEmpty ? host : name
    }

    var subtitle: String {
        "\(host):\(port) · \(username)"
    }
}
