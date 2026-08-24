import UIKit

/// Narrow Swift-facing contract implemented by the Objective-C++ Gecko bridge.
/// Keeping this protocol free of Gecko types prevents C++ ABI details from
/// leaking into the application layer.
protocol GeckoEmbedding: AnyObject {
    var nativeView: UIView { get }
    var currentURL: URL? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var jitState: GeckoJITRuntimeState { get }

    func start(profileDirectory: URL, jitPolicy: GeckoJITPolicy, sessionContextId: String?) throws
    func load(_ url: URL) throws
    func reload()
    func reloadIgnoringCache()
    func stopLoading()
    func goBack()
    func goForward()
    func setActive(_ active: Bool)
    func setFocused(_ focused: Bool)
    func setRequestedLocales(_ locales: [String])
    func enterBackground()
    func enterForeground()
    func clearCache(baseDomain: String, completion: @escaping (Bool) -> Void)
    func clearCookies(baseDomain: String, completion: @escaping (Bool) -> Void)
    func migrateCookies(toShared: Bool, contextIds: [String], completion: @escaping (Bool) -> Void)
    func exportCookies(completion: @escaping (Data?) -> Void)
    func importCookies(_ jsonData: Data, completion: @escaping (Bool) -> Void)
    func setDiskCacheSmartSizeEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void)
    func setDiskCacheCapacityKB(_ capacityKB: Int, completion: @escaping (Bool) -> Void)
    func close()
}

enum GeckoJITPolicy: Equatable {
    /// Recovery/diagnostic mode. It is not the production performance target.
    case disabled

    /// Production target. Readiness is confirmed by the process-wide
    /// SpiderMonkey executable-memory/JIT probe.
    case required
}

enum GeckoJITRuntimeState: Equatable {
    case unresolved
    case enabled
    case degradedNoJIT(reason: Int32)
    case failed(reason: Int32)
}

final class GeckoEngine: WebEngine {
    private let embedding: GeckoEmbedding
    private let profileDirectory: URL
    private let jitPolicy: GeckoJITPolicy
    private let sessionContextId: String?
    private var started = false
    private var isClosed = false

    init(
        embedding: GeckoEmbedding,
        profileDirectory: URL,
        jitPolicy: GeckoJITPolicy = .required,
        sessionContextId: String? = nil
    ) {
        self.embedding = embedding
        self.profileDirectory = profileDirectory
        self.jitPolicy = jitPolicy
        self.sessionContextId = sessionContextId
    }

    var view: UIView { embedding.nativeView }
    var currentURL: URL? { embedding.currentURL }
    var canGoBack: Bool { embedding.canGoBack }
    var canGoForward: Bool { embedding.canGoForward }
    var jitState: GeckoJITRuntimeState { embedding.jitState }

    /// Start Gecko and create its native view without beginning navigation.
    /// The UIKit embedder uses this to attach/size the ChildView before the
    /// first document load so Gecko observes the real viewport from frame 0.
    func start() {
        guard !isClosed else { return }
        do {
            try ensureStarted()
        } catch {
            assertionFailure("Gecko start failed: \(error)")
        }
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        do {
            try ensureStarted()
            try embedding.load(url)
        } catch {
            assertionFailure("Gecko load failed: \(error)")
        }
    }

    func reload() { embedding.reload() }
    func reloadIgnoringCache() { embedding.reloadIgnoringCache() }
    func stopLoading() { embedding.stopLoading() }
    func goBack() { embedding.goBack() }
    func goForward() { embedding.goForward() }
    func setActive(_ active: Bool) { embedding.setActive(active) }
    func setFocused(_ focused: Bool) { embedding.setFocused(focused) }
    func setRequestedLocales(_ locales: [String]) { embedding.setRequestedLocales(locales) }
    func applicationDidEnterBackground() { embedding.enterBackground() }
    func applicationWillEnterForeground() { embedding.enterForeground() }
    func clearCache(baseDomain: String, completion: @escaping (Bool) -> Void) {
        embedding.clearCache(baseDomain: baseDomain, completion: completion)
    }
    func clearCookies(baseDomain: String, completion: @escaping (Bool) -> Void) {
        embedding.clearCookies(baseDomain: baseDomain, completion: completion)
    }
    func migrateCookies(toShared: Bool, contextIds: [String], completion: @escaping (Bool) -> Void) {
        embedding.migrateCookies(toShared: toShared, contextIds: contextIds, completion: completion)
    }
    func exportCookies(completion: @escaping (Data?) -> Void) {
        embedding.exportCookies(completion: completion)
    }
    func importCookies(_ jsonData: Data, completion: @escaping (Bool) -> Void) {
        embedding.importCookies(jsonData, completion: completion)
    }
    func setDiskCacheSmartSizeEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        embedding.setDiskCacheSmartSizeEnabled(enabled, completion: completion)
    }
    func setDiskCacheCapacityKB(_ capacityKB: Int, completion: @escaping (Bool) -> Void) {
        embedding.setDiskCacheCapacityKB(capacityKB, completion: completion)
    }

    func close() {
        guard !isClosed else { return }
        embedding.close()
        isClosed = true
        started = false
    }

    private func ensureStarted() throws {
        guard !started else { return }
        guard !isClosed else { throw WebEngineError.closed }

        try FileManager.default.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true
        )
        try embedding.start(profileDirectory: profileDirectory, jitPolicy: jitPolicy, sessionContextId: sessionContextId)
        started = true
    }

    static func defaultProfileDirectory(named name: String) throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WebEngineError.runtimeUnavailable("Application Support is unavailable")
        }
        return appSupport.appendingPathComponent(name, isDirectory: true)
    }

    static func defaultGeminiProfileDirectory() throws -> URL {
        try defaultProfileDirectory(named: "GeminiGeckoProfile")
    }
}
