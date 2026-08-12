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
}
