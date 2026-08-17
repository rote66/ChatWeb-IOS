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
    func loadHome()
    func startLogin()
    func showLegacyMediaCompatibilityNotice()
    func handleForeground()
    func handleBackground()
    func releaseWebViewForMemoryPressureIfBackgrounded()
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
