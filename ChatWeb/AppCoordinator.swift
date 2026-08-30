import SafariServices
import UIKit

final class AppCoordinator: NSObject {
    private let window: UIWindow
    private let preferences: AppPreferences
    private let chatGPTViewController: ChatGPTWebViewController
    private let geminiViewController: GeminiWebViewController
    private let rootViewController: RootViewController
    private let navigationController: UINavigationController

    init(window: UIWindow, preferences: AppPreferences = .shared) {
        self.window = window
        self.preferences = preferences
        chatGPTViewController = ChatGPTWebViewController(preferences: preferences)
        geminiViewController = GeminiWebViewController(preferences: preferences)
        rootViewController = RootViewController(chatGPTViewController: chatGPTViewController,
                                                geminiViewController: geminiViewController,
                                                preferences: preferences)
        navigationController = UINavigationController(rootViewController: rootViewController)
        super.init()
    }

    func start() {
        navigationController.navigationBar.prefersLargeTitles = false
        navigationController.navigationBar.tintColor = .label
        rootViewController.onSafariRequested = { [weak self] url in self?.presentSafari(url: url) }
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
    }

    func applicationWillEnterForeground() {
        chatGPTViewController.handleForeground()
        geminiViewController.handleForeground()
    }

    func applicationDidEnterBackground() {
        chatGPTViewController.handleBackground()
        geminiViewController.handleBackground()
    }

    func applicationDidReceiveMemoryWarning() {
        chatGPTViewController.releaseWebViewForMemoryPressureIfBackgrounded()
        geminiViewController.releaseWebViewForMemoryPressureIfBackgrounded()
    }

    private func presentSafari(url: URL) {
        guard navigationController.presentedViewController == nil else { return }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let safari = SFSafariViewController(url: url, configuration: configuration)
        safari.dismissButtonStyle = .close
        safari.preferredControlTintColor = .systemBlue
        navigationController.present(safari, animated: true)
    }
}
