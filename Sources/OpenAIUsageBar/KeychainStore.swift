import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败：\(message)"
        }
    }
}

final class CredentialStore: @unchecked Sendable {
    private let service = "dev.ruobin.OpenAIUsageBar"
    private let legacyAccount = "api-credentials"

    func load(for profileID: UUID) throws -> Credentials? {
        try load(account: account(for: profileID))
    }

    func loadLegacy() throws -> Credentials? {
        try load(account: legacyAccount)
    }

    private func load(account: String) throws -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return try JSONDecoder().decode(StoredCredentials.self, from: data).credentials
    }

    func save(_ credentials: Credentials, for profileID: UUID) throws {
        try save(credentials, account: account(for: profileID))
    }

    private func save(_ credentials: Credentials, account: String) throws {
        let data = try JSONEncoder().encode(StoredCredentials(credentials))
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func delete(for profileID: UUID) throws {
        try delete(account: account(for: profileID))
    }

    func deleteLegacy() throws {
        try delete(account: legacyAccount)
    }

    private func delete(account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func account(for profileID: UUID) -> String {
        "station-\(profileID.uuidString.lowercased())"
    }
}

private struct StoredCredentials: Codable {
    let email: String
    let password: String

    init(_ credentials: Credentials) {
        email = credentials.email
        password = credentials.password
    }

    var credentials: Credentials {
        Credentials(email: email, password: password)
    }
}
