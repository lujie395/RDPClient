//
//  HostStore.swift
//  RDPClient
//
//  主机列表持久化：Application Support/RDPClient/hosts.json
//  注意：这里只有主机元数据，密码在 KeychainService 中。
//

import Foundation
import SwiftUI

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [RDPHost] = []

    static let shared = HostStore()

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("RDPClient", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("hosts.json")
        load()
    }

    // MARK: - CRUD

    func upsert(_ host: RDPHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    func remove(id: UUID) {
        if let host = hosts.first(where: { $0.id == id }) {
            // 删除主机时同步清理 Keychain 中的密码
            try? KeychainService.shared.deletePassword(account: host.passwordRef.uuidString)
        }
        hosts.removeAll { $0.id == id }
        save()
    }

    func markConnected(id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnectedAt = Date()
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([RDPHost].self, from: data) {
            hosts = loaded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
