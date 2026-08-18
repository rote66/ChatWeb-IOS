import UIKit

final class RootViewController: UIViewController {
    var onSafariRequested: ((URL) -> Void)?

    let chatGPTViewController: ChatGPTWebViewController
    let geminiViewController: GeminiWebViewController

    private let preferences: AppPreferences
    private let serviceControl = UISegmentedControl(items: ["GPT", "Gemini"])
    private let connectivityLabel = UILabel()
    private let contentView = UIView()
    private let toolbar = UIToolbar()
    private var connectivityHeightConstraint: NSLayoutConstraint!
    private var backItem: UIBarButtonItem!
    private var forwardItem: UIBarButtonItem!
    private var reloadItem: UIBarButtonItem!
    private var accountItem: UIBarButtonItem!
    private var chatGPTIsOnline = true
    private var geminiIsOnline = true

    init(chatGPTViewController: ChatGPTWebViewController,
         geminiViewController: GeminiWebViewController,
         preferences: AppPreferences = .shared) {
        self.chatGPTViewController = chatGPTViewController
        self.geminiViewController = geminiViewController
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNavigationBar()
        configureHierarchy()
        configureToolbar()
        chatGPTViewController.delegate = self
        geminiViewController.delegate = self
        showService(preferences.lastService)
    }

    func showChatGPTSelected() {
        showService(.chatGPT)
    }

    func showGeminiSelected() {
        showService(.gemini)
    }

    private func configureNavigationBar() {
        serviceControl.selectedSegmentIndex = WebService.chatGPT.rawValue
        serviceControl.addTarget(self, action: #selector(serviceChanged), for: .valueChanged)
        serviceControl.accessibilityLabel = "网页服务"
        serviceControl.setContentHuggingPriority(.required, for: .horizontal)
        serviceControl.widthAnchor.constraint(equalToConstant: 210).isActive = true
        navigationItem.titleView = serviceControl
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
    }

    private func configureHierarchy() {
        connectivityLabel.text = "当前离线"
        connectivityLabel.font = .preferredFont(forTextStyle: .caption1)
        connectivityLabel.textAlignment = .center
        connectivityLabel.textColor = .white
        connectivityLabel.backgroundColor = .systemRed
        connectivityLabel.isHidden = true
        connectivityLabel.accessibilityLabel = "网络不可用"
        connectivityLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(connectivityLabel)
        view.addSubview(contentView)
        view.addSubview(toolbar)
        connectivityHeightConstraint = connectivityLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            connectivityLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            connectivityLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectivityLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectivityHeightConstraint,
            contentView.topAnchor.constraint(equalTo: connectivityLabel.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    private func configureToolbar() {
        backItem = makeItem(symbol: "chevron.backward", label: "后退", action: #selector(goBack))
        forwardItem = makeItem(symbol: "chevron.forward", label: "前进", action: #selector(goForward))
        reloadItem = makeItem(symbol: "arrow.clockwise", label: "刷新", action: #selector(reloadPage))
        accountItem = makeItem(symbol: "person.crop.circle", label: "ChatGPT 账户", action: #selector(openCurrentAccount))
        let share = makeItem(symbol: "square.and.arrow.up", label: "分享当前页面", action: #selector(sharePage))
        let safari = makeItem(symbol: "safari", label: "在 Safari 中打开", action: #selector(openSafari))
        let more = makeItem(symbol: "ellipsis.circle", label: "更多操作", action: #selector(showMore))
        let flexible = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbar.items = [backItem, flexible, forwardItem, flexible, reloadItem, flexible,
                         accountItem, flexible, share, flexible, safari, flexible, more]
    }

    private func mount(_ controller: WebContentController) {
        let viewController = controller.viewController
        let needsParentAttachment = viewController.parent == nil
        if needsParentAttachment {
            addChild(viewController)
        }
        guard viewController.view.superview == nil else { return }
        contentView.addSubview(viewController.view)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        if needsParentAttachment {
            viewController.didMove(toParent: self)
        }
    }

    private func unmount(_ controller: WebContentController) {
        guard let controllerView = controller.viewController.viewIfLoaded,
              controllerView.superview === contentView else { return }
        controllerView.removeFromSuperview()
    }

    private func makeItem(symbol: String, label: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.accessibilityLabel = label
        return item
    }

    private func updateToolbar(with state: WebNavigationState) {
        backItem?.isEnabled = state.canGoBack
        forwardItem?.isEnabled = state.canGoForward
        reloadItem?.accessibilityLabel = state.isLoading ? "页面正在加载" : "刷新"
    }

    private var selectedService: WebService {
        WebService(rawValue: serviceControl.selectedSegmentIndex) ?? .chatGPT
    }

    private var activeWebViewController: WebContentController {
        switch selectedService {
        case .chatGPT: return chatGPTViewController
        case .gemini: return geminiViewController
        }
    }

    private func showService(_ service: WebService) {
        let selectedController: WebContentController
        let inactiveController: WebContentController
        switch service {
        case .chatGPT:
            selectedController = chatGPTViewController
            inactiveController = geminiViewController
        case .gemini:
            selectedController = geminiViewController
            inactiveController = chatGPTViewController
        }
        unmount(inactiveController)
        mount(selectedController)
        inactiveController.handleBackground()
        selectedController.handleForeground()
        serviceControl.selectedSegmentIndex = service.rawValue
        preferences.lastService = service
        accountItem?.accessibilityLabel = service == .chatGPT ? "ChatGPT 账户" : "Gemini 账户"
        updateToolbar(with: activeWebViewController.navigationState)
        updateConnectivity(isOnline: service == .chatGPT ? chatGPTIsOnline : geminiIsOnline)
    }

    private func updateConnectivity(isOnline: Bool) {
        connectivityLabel.isHidden = isOnline
        connectivityHeightConstraint.constant = isOnline ? 0 : 26
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    @objc private func serviceChanged() {
        guard let service = WebService(rawValue: serviceControl.selectedSegmentIndex) else { return }
        showService(service)
    }

    @objc private func goBack() { activeWebViewController.goBack() }
    @objc private func goForward() { activeWebViewController.goForward() }
    @objc private func reloadPage() { activeWebViewController.reload() }
    @objc private func goHome() { activeWebViewController.loadHome() }
    @objc private func openCurrentAccount() { activeWebViewController.openAccount() }

    @objc private func sharePage() {
        let activity = UIActivityViewController(
            activityItems: [activeWebViewController.currentSafeURL],
            applicationActivities: nil
        )
        activity.popoverPresentationController?.barButtonItem = toolbar.items?.first { $0.accessibilityLabel == "分享当前页面" }
        present(activity, animated: true)
    }

    @objc private func openSafari() {
        onSafariRequested?(activeWebViewController.currentSafeURL)
    }

    @objc private func showMore() {
        let controller = activeWebViewController
        let serviceName = controller.service == .chatGPT ? "ChatGPT" : "Gemini"
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "返回\(serviceName)首页", style: .default) { [weak controller] _ in
            controller?.loadHome()
        })
        sheet.addAction(UIAlertAction(title: "清除缓存", style: .default) { [weak self, weak controller] _ in
            controller?.clearCache { success in
                guard let self, let controller else { return }
                if success {
                    NSLog("[GeminiGecko][Storage] cache clear accepted; bypass-cache reload")
                    controller.reloadIgnoringCache()
                } else {
                    self.showStorageResult(title: "清除缓存", success: false)
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "清除 Cookie", style: .destructive) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            let confirm = UIAlertController(
                title: "清除\(serviceName) Cookie？",
                message: controller.service == .chatGPT
                    ? "仅清除 ChatGPT（chatgpt.com）的 Cookie，不会清除 Gemini。"
                    : "仅清除 Gemini/Google（google.com）的 Cookie，不会清除 ChatGPT；同一 Gecko 配置中的 Google 登录状态也会受到影响。",
                preferredStyle: .alert
            )
            confirm.addAction(UIAlertAction(title: "取消", style: .cancel))
            confirm.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self, weak controller] _ in
                controller?.clearCookies { success in
                    guard let self, let controller else { return }
                    if success {
                        NSLog("[GeminiGecko][Storage] scoped cookie clear accepted service=%@",
                              controller.service == .chatGPT ? "ChatGPT" : "Gemini")
                        // deleteDataFromSite is asynchronous inside Gecko. Its
                        // callback is not reliable on the current UIKit bridge,
                        // so give it a short head start before reloading. The
                        // request itself is already dispatched synchronously.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in
                            NSLog("[GeminiGecko][Storage] scoped cookie reload service=%@",
                                  controller?.service == .chatGPT ? "ChatGPT" : "Gemini")
                            controller?.reloadIgnoringCache()
                        }
                    } else {
                        self.showStorageResult(title: "清除 Cookie", success: false)
                    }
                }
            })
            self.present(confirm, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = toolbar.items?.last
        present(sheet, animated: true)
    }

    private func showStorageResult(title: String, success: Bool) {
        let alert = UIAlertController(
            title: success ? "已完成" : "操作失败",
            message: success ? "\(title)完成。" : "\(title)未完成，请稍后重试。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

}

extension RootViewController: GeminiWebViewControllerDelegate {
    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didUpdate state: WebNavigationState) {
        if controller === activeWebViewController.viewController {
            updateToolbar(with: state)
        }
    }

    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didChangeConnectivity isOnline: Bool) {
        if controller.service == .chatGPT {
            chatGPTIsOnline = isOnline
        } else {
            geminiIsOnline = isOnline
        }
        if controller === activeWebViewController.viewController {
            updateConnectivity(isOnline: isOnline)
        }
    }
}
