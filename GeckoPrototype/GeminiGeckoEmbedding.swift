import UIKit

final class GeminiGeckoEmbedding: GeckoEmbedding {
    private let bridge = GeminiGeckoBridge()
    private let placeholderView = UIView()

    var onProgressChange: ((Double) -> Void)? {
        didSet {
            bridge.progressHandler = onProgressChange
        }
    }

    var onSafeLogoutRequested: (() -> Void)? {
        didSet {
            bridge.safeLogoutHandler = onSafeLogoutRequested
        }
    }

    var onExternalURLRequest: ((URL, Bool, Bool) -> Bool)? {
        didSet {
            bridge.externalURLHandler = { [weak self] url, isNewWindow, userInitiated in
                self?.onExternalURLRequest?(url, isNewWindow, userInitiated) ?? false
            }
        }
    }

    var onDownloadRequest: ((URL, URL, String?, String?, Int64) -> Bool)? {
        didSet {
            bridge.downloadRequestHandler = {
                [weak self] remoteURL, localFileURL, suggestedFilename, mimeType, contentLength in
                self?.onDownloadRequest?(
                    remoteURL,
                    localFileURL,
                    suggestedFilename,
                    mimeType,
                    contentLength
                ) ?? true
            }
        }
    }

    var onDownloadCompleted: ((URL, String?, Bool) -> Void)? {
        didSet {
            bridge.downloadCompletionHandler = { [weak self] localFileURL, suggestedFilename, success in
                self?.onDownloadCompleted?(localFileURL, suggestedFilename, success)
            }
        }
    }

    var nativeView: UIView {
        bridge.nativeView ?? placeholderView
    }

    var currentURL: URL? { bridge.currentURL }
    var canGoBack: Bool { bridge.canGoBack }
    var canGoForward: Bool { bridge.canGoForward }

    var jitState: GeckoJITRuntimeState {
        switch bridge.jitState.rawValue {
        case 1:
            return .enabled
        case 2:
            return .degradedNoJIT(reason: Int32(clamping: bridge.jitReason))
        case 3:
            return .failed(reason: Int32(clamping: bridge.jitReason))
        default:
            return .unresolved
        }
    }

    func start(profileDirectory: URL,
               jitPolicy: GeckoJITPolicy,
               sessionContextId: String?,
               userAgentConfiguration: WebUserAgentConfiguration,
               contentConfiguration: WebContentConfiguration) throws {
        let objcPolicy = GeminiGeckoJITPolicy(
            rawValue: jitPolicy == .required ? 1 : 0
        )!
        try bridge.start(
            profileDirectory: profileDirectory,
            jitPolicy: objcPolicy,
            sessionContextId: sessionContextId,
            userAgent: userAgentConfiguration.userAgent,
            platform: userAgentConfiguration.platform,
            appVersion: userAgentConfiguration.appVersion,
            oscpu: userAgentConfiguration.oscpu,
            useDesktopViewport: userAgentConfiguration.usesDesktopViewport,
            textZoom: contentConfiguration.textZoom,
            autoplayDefault: contentConfiguration.autoplayDefault,
            suspendMediaWhenInactive: contentConfiguration.suspendMediaWhenInactive,
            cookieBehavior: contentConfiguration.cookieBehavior,
            useTrackingProtection: contentConfiguration.usesTrackingProtection,
            useStrictTrackingList: contentConfiguration.usesStrictTrackingList
        )
        let preferredLanguages = Locale.preferredLanguages
        let rawLocales = preferredLanguages.isEmpty
            ? [Locale.current.identifier.replacingOccurrences(of: "_", with: "-")]
            : preferredLanguages
        let requestedLocales = Self.normalizedRequestedLocales(rawLocales)
        bridge.setRequestedLocales(requestedLocales)
        // Required means this state is a production acceptance gate, not that
        // diagnostic startup must abort. The Gecko-side fallback deliberately
        // keeps the browser usable without JIT so we can report/measure the
        // failure and let the user relaunch through TrollStore's JIT path.
    }

    func load(_ url: URL) throws {
        try bridge.load(url: url)
    }

    func reload() { bridge.reload() }
    func reloadIgnoringCache() { bridge.reloadIgnoringCache() }
    func stopLoading() { bridge.stopLoading() }
    func goBack() { bridge.goBack() }
    func goForward() { bridge.goForward() }
    func setActive(_ active: Bool) { bridge.setActive(active) }
    func setFocused(_ focused: Bool) { bridge.setFocused(focused) }
    func setUserAgentConfiguration(_ configuration: WebUserAgentConfiguration) -> Bool {
        bridge.setUserAgent(
            configuration.userAgent,
            platform: configuration.platform,
            appVersion: configuration.appVersion,
            oscpu: configuration.oscpu,
            useDesktopViewport: configuration.usesDesktopViewport
        )
    }
    func setContentConfiguration(_ configuration: WebContentConfiguration,
                                 completion: @escaping (Bool) -> Void) {
        bridge.setContentConfiguration(
            textZoom: configuration.textZoom,
            autoplayDefault: configuration.autoplayDefault,
            suspendMediaWhenInactive: configuration.suspendMediaWhenInactive,
            cookieBehavior: configuration.cookieBehavior,
            useTrackingProtection: configuration.usesTrackingProtection,
            useStrictTrackingList: configuration.usesStrictTrackingList,
            completion: completion
        )
    }
    func setRequestedLocales(_ locales: [String]) { bridge.setRequestedLocales(locales) }

    private static func normalizedRequestedLocales(_ locales: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in locales {
            let locale = Locale(identifier: identifier.replacingOccurrences(of: "-", with: "_"))
            guard let language = locale.languageCode, !language.isEmpty else { continue }
            let normalized: String
            if let region = locale.regionCode, !region.isEmpty {
                normalized = "\(language)-\(region)"
            } else {
                normalized = language
            }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
        }
        return result.isEmpty ? ["en-US"] : result
    }
    func enterBackground() { bridge.enterBackground() }
    func enterForeground() { bridge.enterForeground() }
    func clearCache(baseDomain: String, completion: @escaping (Bool) -> Void) {
        bridge.clearCache(forBaseDomain: baseDomain, completion: completion)
    }
    func clearCookies(baseDomain: String, completion: @escaping (Bool) -> Void) {
        bridge.clearCookies(forBaseDomain: baseDomain, completion: completion)
    }
    func clearPermissions(baseDomain: String, completion: @escaping (Bool) -> Void) {
        bridge.clearPermissions(forBaseDomain: baseDomain, completion: completion)
    }
    func migrateCookies(toShared: Bool, contextIds: [String], completion: @escaping (Bool) -> Void) {
        bridge.migrateCookies(toShared: toShared, contextIds: contextIds, completion: completion)
    }
    func exportCookies(completion: @escaping (Data?) -> Void) {
        bridge.exportCookies(completion: completion)
    }
    func importCookies(_ jsonData: Data, completion: @escaping (Bool) -> Void) {
        bridge.importCookies(fromJSONData: jsonData, completion: completion)
    }
    func setDiskCacheSmartSizeEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        bridge.setDiskCacheSmartSizeEnabled(enabled, completion: completion)
    }
    func setDiskCacheCapacityKB(_ capacityKB: Int, completion: @escaping (Bool) -> Void) {
        bridge.setDiskCacheCapacityKB(capacityKB, completion: completion)
    }
    func close() { bridge.close() }
}
