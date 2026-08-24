import UIKit

struct WebNavigationState {
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    let currentURL: URL?
}

protocol WebContentController: AnyObject {
    var viewController: UIViewController { get }
    var service: WebService { get }
    var navigationState: WebNavigationState { get }
    var currentSafeURL: URL { get }

    func goBack()
    func goForward()
    func reload()
    func reloadIgnoringCache()
    func loadHome()
    func openAccount()
    func handleForeground()
    func handleBackground()
    func releaseWebViewForMemoryPressureIfBackgrounded()
    func clearCache(completion: @escaping (Bool) -> Void)
    func clearCookies(completion: @escaping (Bool) -> Void)
    func migrateLoginCookies(toShared: Bool, completion: @escaping (Bool) -> Void)
    func exportCookieSnapshot(completion: @escaping (Data?) -> Void)
    func applyUserAgentProfile(_ profile: WebUserAgentProfile) -> Bool
    func setDiskCacheSmartSizeEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void)
    func setDiskCacheCapacityKB(_ capacityKB: Int, completion: @escaping (Bool) -> Void)
}

/// ChatGPT uses the same Gecko controller implementation as Gemini. Keeping a
/// thin named subclass preserves the app coordinator/root-controller API while
/// ensuring both services share one engine architecture instead of maintaining
/// a second WKWebView implementation.
final class ChatGPTWebViewController: GeminiWebViewController {
    init(preferences: AppPreferences = .shared) {
        super.init(service: .chatGPT, preferences: preferences)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
