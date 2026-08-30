import Foundation

enum WebService: Int {
    case chatGPT = 0
    case gemini = 1
}

struct WebUserAgentConfiguration: Equatable {
    let userAgent: String
    let platform: String
    let appVersion: String
    let oscpu: String
    let usesDesktopViewport: Bool
}

enum WebUserAgentProfile: Int, CaseIterable {
    case defaultMobile = 0
    case androidFirefox = 1
    case macOSFirefox = 2
    case windowsFirefox = 3
    case iOSFirefox = 4

    var displayName: String {
        switch self {
        case .defaultMobile: return "默认（iPhone Gecko）"
        case .androidFirefox: return "Android Firefox（兼容）"
        case .macOSFirefox: return "macOS Firefox"
        case .windowsFirefox: return "Windows Firefox"
        case .iOSFirefox: return "iOS Firefox（FxiOS/Safari）"
        }
    }

    var configuration: WebUserAgentConfiguration {
        switch self {
        case .defaultMobile:
            return WebUserAgentConfiguration(
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X; Mobile; rv:153.0) Gecko/153.0 Firefox/153.0",
                platform: "iPhone",
                appVersion: "5.0 (iPhone)",
                oscpu: "iPhone",
                usesDesktopViewport: false
            )
        case .androidFirefox:
            return WebUserAgentConfiguration(
                userAgent: "Mozilla/5.0 (Android 10; Mobile; rv:153.0) Gecko/153.0 Firefox/153.0",
                platform: "Linux armv81",
                appVersion: "5.0 (Android 10)",
                oscpu: "Linux armv81",
                usesDesktopViewport: false
            )
        case .macOSFirefox:
            return WebUserAgentConfiguration(
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:153.0) Gecko/20100101 Firefox/153.0",
                platform: "MacIntel",
                appVersion: "5.0 (Macintosh)",
                oscpu: "Intel Mac OS X 10.15",
                usesDesktopViewport: true
            )
        case .windowsFirefox:
            return WebUserAgentConfiguration(
                userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:153.0) Gecko/20100101 Firefox/153.0",
                platform: "Win32",
                appVersion: "5.0 (Windows)",
                oscpu: "Windows NT 10.0; Win64; x64",
                usesDesktopViewport: true
            )
        case .iOSFirefox:
            return WebUserAgentConfiguration(
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/153.0 Mobile/15E148 Safari/605.1.15",
                platform: "iPhone",
                appVersion: "5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/153.0 Mobile/15E148 Safari/605.1.15",
                oscpu: "iPhone",
                usesDesktopViewport: false
            )
        }
    }
}

enum WebTextSize: Int, CaseIterable {
    case percent80 = 80
    case percent100 = 100
    case percent120 = 120
    case percent140 = 140
    case percent160 = 160

    var displayName: String { "\(rawValue)%" }
    var zoom: Double { Double(rawValue) / 100.0 }
}

enum WebAutoplayPolicy: Int, CaseIterable {
    case blockAudible = 1
    case allow = 0
    case blockAll = 5

    var displayName: String {
        switch self {
        case .blockAudible: return "阻止有声自动播放（推荐）"
        case .allow: return "允许自动播放"
        case .blockAll: return "阻止所有自动播放"
        }
    }
}

enum WebPrivacyProtectionLevel: Int, CaseIterable {
    case standard = 1
    case compatibility = 0
    case strict = 2

    var displayName: String {
        switch self {
        case .standard: return "标准"
        case .compatibility: return "兼容"
        case .strict: return "严格"
        }
    }

    var cookieBehavior: Int {
        switch self {
        case .standard: return 5
        case .compatibility: return 0
        case .strict: return 1
        }
    }

    var usesTrackingProtection: Bool { self != .compatibility }
    var usesStrictTrackingList: Bool { self == .strict }
}

struct WebContentConfiguration: Equatable {
    let textZoom: Double
    let autoplayDefault: Int
    let suspendMediaWhenInactive: Bool
    let cookieBehavior: Int
    let usesTrackingProtection: Bool
    let usesStrictTrackingList: Bool
}

final class AppPreferences {
    static let shared = AppPreferences()

    private enum Key {
        static let lastService = "lastService"
        static let lastSafeChatGPTURL = "lastSafeChatGPTURL"
        static let lastSafeGeminiURL = "lastSafeGeminiURL"
        static let geckoDiskCacheSmartSizeEnabled = "geckoDiskCacheSmartSizeEnabled"
        static let geckoDiskCacheCapacityKB = "geckoDiskCacheCapacityKB"
        static let userAgentProfile = "userAgentProfile"
        static let webTextSize = "webTextSize"
        static let webAutoplayPolicy = "webAutoplayPolicy"
        static let suspendMediaWhenInactive = "suspendMediaWhenInactive"
        static let webPrivacyProtectionLevel = "webPrivacyProtectionLevel"
        static let shareGeckoLoginCookies = "shareGeckoLoginCookies"
        static let didSanitizeIsolatedGPTIdentityCookiesV1 = "didSanitizeIsolatedGPTIdentityCookiesV1"
        static let didSeedIsolatedCookieContexts = "didSeedIsolatedCookieContexts"
    }

    var didSanitizeIsolatedGPTIdentityCookiesV1: Bool {
        get { defaults.bool(forKey: Key.didSanitizeIsolatedGPTIdentityCookiesV1) }
        set { defaults.set(newValue, forKey: Key.didSanitizeIsolatedGPTIdentityCookiesV1) }
    }

    var didSeedIsolatedCookieContexts: Bool {
        get { defaults.bool(forKey: Key.didSeedIsolatedCookieContexts) }
        set { defaults.set(newValue, forKey: Key.didSeedIsolatedCookieContexts) }
    }

    private let defaults: UserDefaults
    private let policy = NavigationPolicy()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastService: WebService {
        get { WebService(rawValue: defaults.integer(forKey: Key.lastService)) ?? .chatGPT }
        set { defaults.set(newValue.rawValue, forKey: Key.lastService) }
    }

    var lastSafeChatGPTURL: URL? {
        get {
            guard let value = defaults.string(forKey: Key.lastSafeChatGPTURL),
                  let url = URL(string: value) else { return nil }
            return policy.safeURLForPersistence(url)
        }
        set {
            guard let url = newValue.flatMap(policy.safeURLForPersistence) else {
                defaults.removeObject(forKey: Key.lastSafeChatGPTURL)
                return
            }
            defaults.set(url.absoluteString, forKey: Key.lastSafeChatGPTURL)
        }
    }

    var lastSafeGeminiURL: URL? {
        get {
            guard let value = defaults.string(forKey: Key.lastSafeGeminiURL),
                  let url = URL(string: value) else { return nil }
            return NavigationPolicy(service: .gemini).safeURLForPersistence(url)
        }
        set {
            let policy = NavigationPolicy(service: .gemini)
            guard let url = newValue.flatMap(policy.safeURLForPersistence) else {
                defaults.removeObject(forKey: Key.lastSafeGeminiURL)
                return
            }
            defaults.set(url.absoluteString, forKey: Key.lastSafeGeminiURL)
        }
    }

    var geckoDiskCacheSmartSizeEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.geckoDiskCacheSmartSizeEnabled) != nil else {
                return false
            }
            return defaults.bool(forKey: Key.geckoDiskCacheSmartSizeEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.geckoDiskCacheSmartSizeEnabled)
        }
    }

    var userAgentProfile: WebUserAgentProfile {
        get {
            guard defaults.object(forKey: Key.userAgentProfile) != nil else {
                return .defaultMobile
            }
            return WebUserAgentProfile(rawValue: defaults.integer(forKey: Key.userAgentProfile))
                ?? .defaultMobile
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.userAgentProfile)
        }
    }

    var shareGeckoLoginCookies: Bool {
        get {
            guard defaults.object(forKey: Key.shareGeckoLoginCookies) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.shareGeckoLoginCookies)
        }
        set {
            defaults.set(newValue, forKey: Key.shareGeckoLoginCookies)
        }
    }

    var webTextSize: WebTextSize {
        get {
            guard defaults.object(forKey: Key.webTextSize) != nil else {
                return .percent100
            }
            return WebTextSize(rawValue: defaults.integer(forKey: Key.webTextSize))
                ?? .percent100
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.webTextSize)
        }
    }

    var webAutoplayPolicy: WebAutoplayPolicy {
        get {
            guard defaults.object(forKey: Key.webAutoplayPolicy) != nil else {
                return .blockAudible
            }
            return WebAutoplayPolicy(rawValue: defaults.integer(forKey: Key.webAutoplayPolicy))
                ?? .blockAudible
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.webAutoplayPolicy)
        }
    }

    var suspendMediaWhenInactive: Bool {
        get {
            guard defaults.object(forKey: Key.suspendMediaWhenInactive) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.suspendMediaWhenInactive)
        }
        set {
            defaults.set(newValue, forKey: Key.suspendMediaWhenInactive)
        }
    }

    var webPrivacyProtectionLevel: WebPrivacyProtectionLevel {
        get {
            guard defaults.object(forKey: Key.webPrivacyProtectionLevel) != nil else {
                return .standard
            }
            return WebPrivacyProtectionLevel(
                rawValue: defaults.integer(forKey: Key.webPrivacyProtectionLevel)
            ) ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.webPrivacyProtectionLevel)
        }
    }

    var webContentConfiguration: WebContentConfiguration {
        let privacy = webPrivacyProtectionLevel
        return WebContentConfiguration(
            textZoom: webTextSize.zoom,
            autoplayDefault: webAutoplayPolicy.rawValue,
            suspendMediaWhenInactive: suspendMediaWhenInactive,
            cookieBehavior: privacy.cookieBehavior,
            usesTrackingProtection: privacy.usesTrackingProtection,
            usesStrictTrackingList: privacy.usesStrictTrackingList
        )
    }

    var geckoDiskCacheCapacityKB: Int {
        get {
            guard defaults.object(forKey: Key.geckoDiskCacheCapacityKB) != nil else {
                return 32 * 1024
            }
            return max(0, defaults.integer(forKey: Key.geckoDiskCacheCapacityKB))
        }
        set {
            defaults.set(max(0, newValue), forKey: Key.geckoDiskCacheCapacityKB)
        }
    }
}
