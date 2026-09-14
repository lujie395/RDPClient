//
//  KeychainService.swift
//  RDPClient
//
//  Keychain 封装：kSecClassGenericPassword
//  service 固定为 "com.rdpclient.credentials"，account 为 RDPHost.passwordRef 的 UUID 字符串。
//  可访问性：解锁后可用（AfterFirstUnlock）。
//

import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.rdpclient.credentials"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "Keychain 操作失败（\(status)）：\(text)"
            }
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - API

    /// 保存（存在则覆盖）
    func savePassword(account: String, password: String) throws {
        let data = Data(password.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 读取；不存在时返回 nil
    func loadPassword(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除（不存在时静默成功）
    func deletePassword(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
