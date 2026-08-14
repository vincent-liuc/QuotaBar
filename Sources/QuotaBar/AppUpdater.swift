import AppKit
import CryptoKit
import Darwin
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
    case updateInProgress
    case invalidResponse
    case httpStatus(Int)
    case invalidCurrentVersion
    case invalidReleaseVersion
    case missingDMG
    case missingChecksum
    case checksumMismatch
    case notInstalledInApplications
    case installationNotWritable
    case diskImageFailed
    case applicationMissing
    case invalidApplication
    case installerLaunchFailed
    case installerCommandTimedOut

    var errorDescription: String? {
        switch self {
        case .updateInProgress:
            return "更新正在进行"
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
            return "安装包校验失败，已取消安装"
        case .notInstalledInApplications:
            return "请先将 QuotaBar 安装到“应用程序”文件夹"
        case .installationNotWritable:
            return "没有更新“应用程序”中 QuotaBar 的权限"
        case .diskImageFailed:
            return "无法打开更新安装包"
        case .applicationMissing:
            return "安装包中没有找到 QuotaBar.app"
        case .invalidApplication:
            return "安装包中的应用身份、版本或签名无效"
        case .installerLaunchFailed:
            return "无法启动自动安装程序"
        case .installerCommandTimedOut:
            return "自动安装步骤超时，请稍后重试"
        }
    }
}

final class UpdateInstallationGate: @unchecked Sendable {
    static let shared = UpdateInstallationGate()

    private let lock = NSLock()
    private var isInstalling = false

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isInstalling else { return false }
        isInstalling = true
        return true
    }

    func release() {
        lock.lock()
        isInstalling = false
        lock.unlock()
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

        let expectedDMGName = "QuotaBar-\(normalizedVersion)-universal.dmg"
        let dmg = release.assets.first { $0.name == expectedDMGName }
        guard let dmg else { throw AppUpdaterError.missingDMG }
        let checksum = release.assets.first { $0.name == "\(expectedDMGName).sha256" }
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
    private let installationGate: UpdateInstallationGate

    init(
        session: URLSession = .shared,
        latestReleaseURL: URL = URL(
            string: "https://api.github.com/repos/vincent-liuc/QuotaBar/releases/latest"
        )!,
        fileManager: FileManager = .default,
        installationGate: UpdateInstallationGate = .shared
    ) {
        self.session = session
        self.latestReleaseURL = latestReleaseURL
        self.fileManager = fileManager
        self.installationGate = installationGate
    }

    func checkForUpdate(currentVersion: String) async throws -> UpdateCheckResult {
        try Task.checkCancellation()
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("QuotaBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataWithRetry(request)
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let expectedChecksum = try await fetchChecksum(for: release)
        try Task.checkCancellation()
        var request = assetRequest(url: release.downloadAPIURL, version: release.version)
        request.timeoutInterval = 600
        let (temporaryURL, response) = try await downloadWithRetry(request)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdaterError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppUpdaterError.httpStatus(response.statusCode)
        }
        let destination = fileManager.temporaryDirectory.appending(
            path: "QuotaBar-update-\(UUID().uuidString).dmg"
        )
        var keepDestination = false
        defer {
            if !keepDestination { try? fileManager.removeItem(at: destination) }
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        try Task.checkCancellation()
        guard try sha256(of: destination) == expectedChecksum else {
            throw AppUpdaterError.checksumMismatch
        }
        try Task.checkCancellation()
        keepDestination = true
        return destination
    }

    func installAndRelaunch(_ release: UpdateRelease) async throws {
        guard installationGate.acquire() else {
            throw AppUpdaterError.updateInProgress
        }
        defer { installationGate.release() }
        try Task.checkCancellation()

        let dmgURL = try await download(release)
        defer { try? fileManager.removeItem(at: dmgURL) }
        try Task.checkCancellation()
        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        guard currentApp.path.hasPrefix("/Applications/"), currentApp.pathExtension == "app" else {
            throw AppUpdaterError.notInstalledInApplications
        }
        guard fileManager.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else {
            throw AppUpdaterError.installationNotWritable
        }

        let mountDirectory = fileManager.temporaryDirectory
            .appending(path: "QuotaBar-update-mount-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: mountDirectory, withIntermediateDirectories: true)
        defer {
            try? Self.run("/usr/bin/hdiutil", ["detach", mountDirectory.path, "-quiet"])
            try? fileManager.removeItem(at: mountDirectory)
        }
        try Task.checkCancellation()
        do {
            try Self.run("/usr/bin/hdiutil", [
                "attach", dmgURL.path, "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", mountDirectory.path
            ])
        } catch {
            throw AppUpdaterError.diskImageFailed
        }
        try Task.checkCancellation()

        let mountedApp = mountDirectory.appending(path: "QuotaBar.app", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: mountedApp.path) else {
            throw AppUpdaterError.applicationMissing
        }
        guard Bundle(url: mountedApp)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              Bundle(url: mountedApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              (try? Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", mountedApp.path])) != nil else {
            throw AppUpdaterError.invalidApplication
        }
        try Task.checkCancellation()

        let parent = currentApp.deletingLastPathComponent()
        let stagedApp = parent.appending(path: ".QuotaBar-update-\(UUID().uuidString).app")
        var installerOwnsStagedApp = false
        defer {
            if !installerOwnsStagedApp { try? fileManager.removeItem(at: stagedApp) }
        }
        try Task.checkCancellation()
        try Self.run("/usr/bin/ditto", [mountedApp.path, stagedApp.path])
        try Task.checkCancellation()
        guard Bundle(url: stagedApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw AppUpdaterError.invalidApplication
        }
        try Task.checkCancellation()
        try Self.run("/usr/bin/hdiutil", ["detach", mountDirectory.path, "-quiet"])
        try? fileManager.removeItem(at: mountDirectory)
        try? fileManager.removeItem(at: dmgURL)
        try Task.checkCancellation()
        let installer = try launchInstaller(
            stagedApp: stagedApp,
            currentApp: currentApp,
            expectedVersion: release.version
        )
        do {
            try Task.checkCancellation()
            installerOwnsStagedApp = true
            try await MainActor.run {
                try Task.checkCancellation()
                NSApplication.shared.terminate(nil)
            }
        } catch {
            installerOwnsStagedApp = false
            installer.terminate()
            throw error
        }
    }

    private func fetchChecksum(for release: UpdateRelease) async throws -> String {
        var request = assetRequest(url: release.checksumAPIURL, version: release.version)
        request.timeoutInterval = 20
        let (data, response) = try await dataWithRetry(request)
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            do {
                if let resumeData {
                    return try await session.download(resumeFrom: resumeData)
                }
                return try await session.download(for: request)
            } catch {
                try Task.checkCancellation()
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
            try Task.checkCancellation()
            do {
                return try await session.data(for: request)
            } catch {
                try Task.checkCancellation()
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

    private func launchInstaller(
        stagedApp: URL,
        currentApp: URL,
        expectedVersion: String
    ) throws -> Process {
        try Task.checkCancellation()
        guard let helperURL = Bundle.main.url(forResource: "update-helper", withExtension: "sh") else {
            throw AppUpdaterError.installerLaunchFailed
        }
        let backupApp = currentApp.deletingLastPathComponent()
            .appending(path: ".QuotaBar-previous-\(UUID().uuidString).app")
        let logURL = fileManager.temporaryDirectory.appending(path: "QuotaBar-update.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            helperURL.path,
            stagedApp.path,
            currentApp.path,
            backupApp.path,
            expectedVersion,
            logURL.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        do {
            try Task.checkCancellation()
            try process.run()
        } catch is CancellationError {
            try? fileManager.removeItem(at: stagedApp)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: stagedApp)
            throw AppUpdaterError.installerLaunchFailed
        }
        return process
    }

    private nonisolated static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 120
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw AppUpdaterError.installerCommandTimedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdaterError.invalidApplication }
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
