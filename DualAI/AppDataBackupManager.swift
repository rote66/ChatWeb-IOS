import CryptoKit
import Foundation
import Security

enum AppDataBackupError: LocalizedError {
    case passwordTooShort
    case invalidBackup
    case unsupportedVersion
    case wrongPassword
    case archiveTooLarge
    case unsafePath
    case unavailableContainer

    var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            return "备份密码至少需要 8 个字符。"
        case .invalidBackup:
            return "备份文件格式无效或已损坏。"
        case .unsupportedVersion:
            return "备份文件版本不受当前应用支持。"
        case .wrongPassword:
            return "备份密码错误，或文件已损坏。"
        case .archiveTooLarge:
            return "可恢复数据过大，无法安全导出。"
        case .unsafePath:
            return "备份中包含不安全的文件路径。"
        case .unavailableContainer:
            return "应用数据目录不可用。"
        }
    }
}

/// Creates a password-encrypted, portable backup of account/session and app data.
/// Disposable Gecko caches are intentionally omitted: they are large, contain no
/// durable account state, and are regenerated automatically after restore.
final class AppDataBackupManager {
    static let shared = AppDataBackupManager()
    static let backupFileExtension = "dualaibackup"
    static let pendingRestoreDirectoryName = "DualAIBackupRestore.pending"
    static let pendingCookieRestoreFileName = "DualAICookieRestore.pending.json"

    private let fileManager = FileManager.default
    private let formatVersion = 2
    private let minimumSupportedFormatVersion = 1
    private let kdfRounds = 80_000
    private let maximumArchiveBytes = 256 * 1024 * 1024
    private let profileNames = ["GeminiGeckoProfile"]
    private let temporaryBackupPrefix = "DualAI-Backup-"

    private init() {}

    func createEncryptedBackup(password: String, cookieSnapshot: Data) throws -> URL {
        guard password.utf8.count >= 8 else { throw AppDataBackupError.passwordTooShort }
        removeStaleTemporaryBackups()
        let archive = try makeArchive(cookieSnapshot: cookieSnapshot)
        let archiveData = try PropertyListSerialization.data(
            fromPropertyList: archive,
            format: .binary,
            options: 0
        )
        guard archiveData.count <= maximumArchiveBytes else {
            throw AppDataBackupError.archiveTooLarge
        }

        let salt = randomData(count: 16)
        let key = deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(archiveData, using: key)
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        let wrapper: [String: Any] = [
            "magic": "DualAIEncryptedBackup",
            "formatVersion": formatVersion,
            "kdfRounds": kdfRounds,
            "salt": salt,
            "nonce": nonce,
            "ciphertext": sealed.ciphertext,
            "tag": sealed.tag,
        ]
        let output = try PropertyListSerialization.data(
            fromPropertyList: wrapper,
            format: .binary,
            options: 0
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "DualAI-Backup-\(formatter.string(from: Date())).\(Self.backupFileExtension)"
        let url = fileManager.temporaryDirectory.appendingPathComponent(filename)
        try output.write(to: url, options: .atomic)
        return url
    }

    func removeTemporaryBackup(at url: URL) {
        guard isManagedTemporaryBackup(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    func removeStaleTemporaryBackups() {
        let temporaryDirectory = fileManager.temporaryDirectory
        guard let urls = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where isManagedTemporaryBackup(url) {
            try? fileManager.removeItem(at: url)
        }
    }

    func stageRestore(from sourceURL: URL, password: String) throws {
        guard password.utf8.count >= 8 else { throw AppDataBackupError.passwordTooShort }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let encrypted = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let wrapperObject = try PropertyListSerialization.propertyList(
            from: encrypted,
            options: [],
            format: nil
        )
        guard let wrapper = wrapperObject as? [String: Any],
              wrapper["magic"] as? String == "DualAIEncryptedBackup",
              let version = wrapper["formatVersion"] as? Int,
              let salt = wrapper["salt"] as? Data,
              let nonceData = wrapper["nonce"] as? Data,
              let ciphertext = wrapper["ciphertext"] as? Data,
              let tag = wrapper["tag"] as? Data else {
            throw AppDataBackupError.invalidBackup
        }
        guard version >= minimumSupportedFormatVersion, version <= formatVersion else {
            throw AppDataBackupError.unsupportedVersion
        }

        let rounds = (wrapper["kdfRounds"] as? Int) ?? kdfRounds
        let key = deriveKey(password: password, salt: salt, rounds: rounds)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw AppDataBackupError.invalidBackup
        }
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let archiveData: Data
        do {
            archiveData = try AES.GCM.open(sealed, using: key)
        } catch {
            throw AppDataBackupError.wrongPassword
        }
        guard archiveData.count <= maximumArchiveBytes else {
            throw AppDataBackupError.archiveTooLarge
        }

        let archiveObject = try PropertyListSerialization.propertyList(
            from: archiveData,
            options: [],
            format: nil
        )
        guard let archive = archiveObject as? [String: Any],
              let archiveVersion = archive["formatVersion"] as? Int,
              archiveVersion >= minimumSupportedFormatVersion,
              archiveVersion <= formatVersion,
              let profiles = archive["profiles"] as? [String: [String: Data]],
              let defaults = archive["userDefaults"] as? [String: Any] else {
            throw AppDataBackupError.invalidBackup
        }

        let appSupport = try applicationSupportDirectory()
        let pending = appSupport.appendingPathComponent(Self.pendingRestoreDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: pending.path) {
            try fileManager.removeItem(at: pending)
        }
        try fileManager.createDirectory(at: pending, withIntermediateDirectories: true)

        let profilesRoot = pending.appendingPathComponent("Profiles", isDirectory: true)
        try fileManager.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        for (profileName, files) in profiles where profileNames.contains(profileName) {
            let profileRoot = profilesRoot.appendingPathComponent(profileName, isDirectory: true)
            try fileManager.createDirectory(at: profileRoot, withIntermediateDirectories: true)
            for (relativePath, data) in files {
                guard isSafeRelativePath(relativePath) else { throw AppDataBackupError.unsafePath }
                let destination = profileRoot.appendingPathComponent(relativePath, isDirectory: false)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
            }
        }

        let defaultsData = try PropertyListSerialization.data(
            fromPropertyList: defaults,
            format: .binary,
            options: 0
        )
        try defaultsData.write(
            to: pending.appendingPathComponent("UserDefaults.plist"),
            options: .atomic
        )
        if let cookieSnapshot = archive["cookieSnapshot"] as? Data, !cookieSnapshot.isEmpty {
            try cookieSnapshot.write(
                to: pending.appendingPathComponent("CookieSnapshot.json"),
                options: .atomic
            )
        }
        try Data("DualAIBackupRestore-v1".utf8).write(
            to: pending.appendingPathComponent("READY"),
            options: .atomic
        )
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: pending.path
        )
    }

    func pendingCookieRestoreData() -> Data? {
        guard let appSupport = try? applicationSupportDirectory() else { return nil }
        let url = appSupport.appendingPathComponent(Self.pendingCookieRestoreFileName)
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    func completePendingCookieRestore() {
        guard let appSupport = try? applicationSupportDirectory() else { return }
        let url = appSupport.appendingPathComponent(Self.pendingCookieRestoreFileName)
        try? fileManager.removeItem(at: url)
    }

    private func makeArchive(cookieSnapshot: Data) throws -> [String: Any] {
        let appSupport = try applicationSupportDirectory()
        var profiles: [String: [String: Data]] = [:]
        var totalBytes = 0
        for name in profileNames {
            let root = appSupport.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            var files: [String: Data] = [:]
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                if shouldSkip(relativePath: relative) {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let data: Data
                do {
                    data = try Data(contentsOf: url, options: .mappedIfSafe)
                } catch {
                    // Gecko can rotate transient files while the settings sheet
                    // is open. Ignore only those disappearing files; durable DBs
                    // normally remain stable and are copied together with WALs.
                    if !fileManager.fileExists(atPath: url.path) { continue }
                    throw error
                }
                totalBytes += data.count
                guard totalBytes <= maximumArchiveBytes else {
                    throw AppDataBackupError.archiveTooLarge
                }
                files[relative] = data
            }
            profiles[name] = files
        }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let defaults = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        return [
            "formatVersion": formatVersion,
            "createdAt": Date(),
            "bundleIdentifier": bundleID,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "userDefaults": defaults,
            "profiles": profiles,
            "cookieSnapshot": cookieSnapshot,
        ]
    }

    private func applicationSupportDirectory() throws -> URL {
        guard let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppDataBackupError.unavailableContainer
        }
        return url
    }

    private func isManagedTemporaryBackup(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let temporaryDirectory = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return url.isFileURL &&
            parent == temporaryDirectory &&
            url.pathExtension == Self.backupFileExtension &&
            url.lastPathComponent.hasPrefix(temporaryBackupPrefix)
    }

    private func shouldSkip(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let first = components.first else { return true }
        let disposableTopLevel: Set<String> = [
            "cache2", "startupCache", "shader-cache", "thumbnails",
            "minidumps", "crashes", "saved-telemetry-pings", "datareporting",
        ]
        if disposableTopLevel.contains(first) { return true }
        if let last = components.last,
           [".parentlock", "parent.lock", "lock"].contains(last) {
            return true
        }
        return false
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }

    private func deriveKey(password: String, salt: Data, rounds: Int? = nil) -> SymmetricKey {
        let count = max(10_000, min(rounds ?? kdfRounds, 250_000))
        var state = Data(SHA256.hash(data: Data(password.utf8) + salt))
        for index in 1..<count {
            var input = Data()
            input.reserveCapacity(state.count + salt.count + 4)
            input.append(state)
            input.append(salt)
            var counter = UInt32(index).bigEndian
            withUnsafeBytes(of: &counter) { input.append(contentsOf: $0) }
            state = Data(SHA256.hash(data: input))
        }
        return SymmetricKey(data: state)
    }
}
