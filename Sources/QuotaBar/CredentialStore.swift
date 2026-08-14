import Foundation

enum CredentialStorageError: LocalizedError {
    case applicationSupportUnavailable
    case invalidData

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法访问应用支持目录"
        case .invalidData:
            return "本机凭据文件格式无效"
        }
    }
}

final class CredentialStore: @unchecked Sendable {
    private static let legacyAccount = "api-credentials"
    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        directoryURL = applicationSupport.appending(path: "QuotaBar", directoryHint: .isDirectory)
        fileURL = directoryURL.appending(path: "credentials.json")
    }

    func load(for profileID: UUID) throws -> Credentials? {
        try load(account: account(for: profileID))
    }

    func loadLegacy() throws -> Credentials? {
        try load(account: Self.legacyAccount)
    }

    func save(_ credentials: Credentials, for profileID: UUID) throws {
        try save(credentials, account: account(for: profileID))
    }

    func delete(for profileID: UUID) throws {
        try delete(account: account(for: profileID))
    }

    func deleteLegacy() throws {
        try delete(account: Self.legacyAccount)
    }

    private func load(account: String) throws -> Credentials? {
        try lock.withLock {
            try readDocument().credentials[account]?.credentials
        }
    }

    private func save(_ credentials: Credentials, account: String) throws {
        try lock.withLock {
            var document = try readDocument()
            document.credentials[account] = StoredCredentials(credentials)
            try writeDocument(document)
        }
    }

    private func delete(account: String) throws {
        try lock.withLock {
            var document = try readDocument()
            guard document.credentials.removeValue(forKey: account) != nil else { return }
            try writeDocument(document)
        }
    }

    private func readDocument() throws -> CredentialDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else { return CredentialDocument() }
        do {
            return try JSONDecoder().decode(CredentialDocument.self, from: Data(contentsOf: fileURL))
        } catch {
            throw CredentialStorageError.invalidData
        }
    }

    private func writeDocument(_ document: CredentialDocument) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directoryURL.path
        )
        let data = try JSONEncoder.prettyPrinted.encode(document)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }

    private func account(for profileID: UUID) -> String {
        "station-\(profileID.uuidString.lowercased())"
    }
}

private struct CredentialDocument: Codable {
    var version = 1
    var credentials: [String: StoredCredentials] = [:]
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

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
