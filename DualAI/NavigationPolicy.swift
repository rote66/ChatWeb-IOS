import Foundation
import WebKit

enum NavigationDecision: Equatable {
    case allowInWebView
    case openInSafari
    case openInSystem
    case rejectUnsupported
    case blobDownloadUnavailable
}

struct NavigationPolicy {
    static let chatGPTHomeURL = URL(string: "https://chatgpt.com/")!
    static let chatGPTLoginURL = URL(string: "https://chatgpt.com/auth/login")!
    static let geminiHomeURL = URL(string: "https://gemini.google.com/app")!
    static let geminiLoginURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fapp")!

    let service: WebService

    private let authenticationHosts: Set<String> = [
        "accounts.google.com",
        "appleid.apple.com",
        "login.live.com",
        "login.microsoftonline.com"
    ]
    private let webInfrastructureHosts: Set<String> = ["challenges.cloudflare.com"]
    private let authenticationBaseDomains = ["auth0.com"]
    private let sensitiveQueryNames: Set<String> = [
        "access_token", "auth", "authorization", "code", "credential", "email",
        "id_token", "key", "nonce", "password", "refresh_token", "session",
        "state", "ticket", "token"
    ]
    private let sensitivePathFragments = [
        "/api/auth/callback", "/auth/callback", "/oauth/callback", "/auth/login",
        "/auth/log-in", "/logout", "/log-out", "/signout", "/sign-out"
    ]

    init(service: WebService = .chatGPT) {
        self.service = service
    }

    var homeURL: URL {
        switch service {
        case .chatGPT: return Self.chatGPTHomeURL
        case .gemini: return Self.geminiHomeURL
        }
    }

    var loginURL: URL {
        switch service {
        case .chatGPT: return Self.chatGPTLoginURL
        case .gemini: return Self.geminiLoginURL
        }
    }

    var serviceName: String {
        switch service {
        case .chatGPT: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }

    func decision(for url: URL) -> NavigationDecision {
        guard let scheme = url.scheme?.lowercased() else {
            return .rejectUnsupported
        }
        if scheme == "blob" {
            return .blobDownloadUnavailable
        }
        if scheme == "about", isBlankWebKitURL(url) {
            return .allowInWebView
        }
        if ["mailto", "tel", "sms"].contains(scheme) {
            return .openInSystem
        }
        guard scheme == "https" || scheme == "http", let host = normalizedHost(url) else {
            return .rejectUnsupported
        }
        if isTrustedHost(host) || isAuthenticationHost(host) ||
            (service == .chatGPT && webInfrastructureHosts.contains(host)) {
            return .allowInWebView
        }
        return .openInSafari
    }

    func shouldOpenExternally(_ decision: NavigationDecision,
                              userInitiated: Bool) -> Bool {
        guard userInitiated else { return false }
        return decision == .openInSafari || decision == .openInSystem
    }

    func isTrustedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = normalizedHost(url) else {
            return false
        }
        return isTrustedHost(host)
    }

    func isAuthenticationURL(_ url: URL) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        return isAuthenticationHost(host) || isServiceLoginURL(url)
    }

    func isServiceLoginURL(_ url: URL) -> Bool {
        switch service {
        case .chatGPT:
            return isChatGPTLoginURL(url)
        case .gemini:
            return normalizedHost(url) == "accounts.google.com"
        }
    }

    func isChatGPTLoginURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              normalizedHost(url) == "chatgpt.com" else { return false }
        let path = url.path.lowercased()
        return path == "/auth/login" || path == "/auth/log-in"
    }

    func safeURLForPersistence(_ url: URL) -> URL? {
        guard isTrustedURL(url) else { return nil }
        let loweredPath = url.path.lowercased()
        guard !sensitivePathFragments.contains(where: loweredPath.contains) else { return nil }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let names = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        guard names.isDisjoint(with: sensitiveQueryNames),
              names.isSubset(of: persistableQueryNames) else { return nil }
        components.fragment = nil
        return components.url
    }

    func sanitizedDescription(for url: URL?) -> String {
        guard let url = url, let host = normalizedHost(url) else { return "unknown-host" }
        return host
    }

    private func normalizedHost(_ url: URL) -> String? {
        url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func isBlankWebKitURL(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value == "about:blank" || value.hasPrefix("about:blank#")
    }

    private func isTrustedHost(_ host: String) -> Bool {
        trustedBaseDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func isAuthenticationHost(_ host: String) -> Bool {
        switch service {
        case .chatGPT:
            return authenticationHosts.contains(host) ||
                authenticationBaseDomains.contains { host == $0 || host.hasSuffix("." + $0) }
        case .gemini:
            return host == "accounts.google.com"
        }
    }

    private var trustedBaseDomains: [String] {
        switch service {
        case .chatGPT: return ["chatgpt.com", "openai.com"]
        case .gemini: return ["gemini.google.com"]
        }
    }

    private var persistableQueryNames: Set<String> {
        switch service {
        case .chatGPT: return ["model", "temporary-chat"]
        case .gemini: return ["hl"]
        }
    }
}
