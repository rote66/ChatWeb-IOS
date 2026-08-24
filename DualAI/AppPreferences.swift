import Foundation

enum WebService: Int {
    case chatGPT = 0
    case gemini = 1
}

final class AppPreferences {
    static let shared = AppPreferences()

    private enum Key {
        static let lastService = "lastService"
        static let lastSafeChatGPTURL = "lastSafeChatGPTURL"
        static let lastSafeGeminiURL = "lastSafeGeminiURL"
        static let geckoDiskCacheSmartSizeEnabled = "geckoDiskCacheSmartSizeEnabled"
        static let geckoDiskCacheCapacityKB = "geckoDiskCacheCapacityKB"
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
