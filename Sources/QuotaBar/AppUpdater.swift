import AppKit
import CryptoKit
import Foundation

struct SemanticVersion: Comparable, Equatable, Sendable {
    private let components: [Int]

    init?(_ rawValue: String) {
        let version = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parsed = version.split(separator: ".").map { component in
            Int(component.prefix(while: \Character.isNumber)) ?? 0
        }
        guard !parsed.isEmpty, parsed.contains(where: { $0 > 0 }) else { return nil }
        components = parsed
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let downloadAPIURL: URL
    let checksumURL: URL
    let checksumAPIURL: URL
    let fileName: String
    let releaseURL: URL
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latestVersion: String)
    case available(UpdateRelease)
}

enum AppUpdaterError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidCurrentVersion
    case invalidReleaseVersion
    case missingDMG
    case missingChecksum
    case checksumMismatch
    case downloadsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回了无法识别的响应"
        case .httpStatus(let status):
            return status == 404 ? "暂未发布可用版本" : "检查更新失败（HTTP \(status)）"
        case .invalidCurrentVersion:
            return "无法识别当前应用版本"
        case .invalidReleaseVersion:
            return "无法识别最新发布版本"
        case .missingDMG:
            return "最新版本没有可用的 DMG 安装包"
        case .missingChecksum:
            return "最新版本缺少 SHA-256 校验文件"
        case .checksumMismatch:
            return "安装包校验失败，已取消打开"
        case .downloadsUnavailable:
            return "无法访问下载文件夹"
        }
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let url: URL
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, url
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

enum ReleaseResolver {
    static func resolve(_ release: GitHubRelease, currentVersion: String) throws -> UpdateCheckResult {
        guard let current = SemanticVersion(currentVersion) else {
            throw AppUpdaterError.invalidCurrentVersion
        }
        guard let latest = SemanticVersion(release.tagName) else {
            throw AppUpdaterError.invalidReleaseVersion
        }
        let normalizedVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard current < latest else {
            return .upToDate(latestVersion: normalizedVersion)
        }

        let dmg = release.assets.first {
            let name = $0.name.lowercased()
            return name.hasSuffix(".dmg") && name.contains("universal")
        } ?? release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        guard let dmg else { throw AppUpdaterError.missingDMG }
        let checksum = release.assets.first {
            $0.name == "\(dmg.name).sha256"
        } ?? release.assets.first { $0.name.lowercased().hasSuffix(".sha256") }
        guard let checksum else { throw AppUpdaterError.missingChecksum }
        return .available(UpdateRelease(
            version: normalizedVersion,
            downloadURL: dmg.browserDownloadURL,
            downloadAPIURL: dmg.url,
            checksumURL: checksum.browserDownloadURL,
            checksumAPIURL: checksum.url,
            fileName: dmg.name,
            releaseURL: release.htmlURL
        ))
    }
}

actor AppUpdater {
    private let session: URLSession
    private let latestReleaseURL: URL
    private let fileManager: FileManager

    init(
        session: URLSession = .shared,
        latestReleaseURL: URL = URL(
            string: "https://api.github.com/repos/vincent-liuc/QuotaBar/releases/latest"
        )!,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.latestReleaseURL = latestReleaseURL
        self.fileManager = fileManager
    }

    func checkForUpdate(currentVersion: String) async throws -> UpdateCheckResult {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("QuotaBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataWithRetry(request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdaterError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppUpdaterError.httpStatus(response.statusCode)
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return try ReleaseResolver.resolve(release, currentVersion: currentVersion)
    }

    func download(_ release: UpdateRelease) async throws -> URL {
        let expectedChecksum = try await fetchChecksum(for: release)
        var request = assetRequest(url: release.downloadAPIURL, version: release.version)
        request.timeoutInterval = 600
        let (temporaryURL, response) = try await downloadWithRetry(request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdaterError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppUpdaterError.httpStatus(response.statusCode)
        }
        guard let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw AppUpdaterError.downloadsUnavailable
        }

        let destination = uniqueDestination(in: downloads, fileName: release.fileName)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        guard try sha256(of: destination) == expectedChecksum else {
            try? fileManager.removeItem(at: destination)
            throw AppUpdaterError.checksumMismatch
        }
        return destination
    }

    private func fetchChecksum(for release: UpdateRelease) async throws -> String {
        var request = assetRequest(url: release.checksumAPIURL, version: release.version)
        request.timeoutInterval = 20
        let (data, response) = try await dataWithRetry(request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdaterError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode),
              let body = String(data: data, encoding: .utf8),
              let checksum = body.split(whereSeparator: \Character.isWhitespace).first,
              checksum.count == 64,
              checksum.allSatisfy({ $0.isHexDigit }) else {
            throw AppUpdaterError.invalidResponse
        }
        return checksum.lowercased()
    }

    private func assetRequest(url: URL, version: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("QuotaBar/\(version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func downloadWithRetry(_ request: URLRequest) async throws -> (URL, URLResponse) {
        var resumeData: Data?
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                if let resumeData {
                    return try await session.download(resumeFrom: resumeData)
                }
                return try await session.download(for: request)
            } catch {
                lastError = error
                guard attempt < 3, Self.isRetryable(error) else { throw error }
                resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw lastError ?? AppUpdaterError.invalidResponse
    }

    private func dataWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                guard attempt < 2, Self.isRetryable(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw lastError ?? AppUpdaterError.invalidResponse
    }

    private static func isRetryable(_ error: Error) -> Bool {
        let code = (error as? URLError)?.code
        return code == .timedOut
            || code == .networkConnectionLost
            || code == .cannotConnectToHost
            || code == .cannotFindHost
            || code == .dnsLookupFailed
            || code == .secureConnectionFailed
            || code == .notConnectedToInternet
    }

    private func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func uniqueDestination(in directory: URL, fileName: String) -> URL {
        let original = directory.appending(path: fileName)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let base = original.deletingPathExtension().lastPathComponent
        let fileExtension = original.pathExtension
        var index = 2
        while true {
            let candidate = directory.appending(path: "\(base)-\(index).\(fileExtension)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

@MainActor
enum AppVersionInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
