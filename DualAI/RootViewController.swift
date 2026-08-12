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
    private var loginItem: UIBarButtonItem!
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
        loginItem = makeItem(symbol: "person.crop.circle", label: "登录 ChatGPT", action: #selector(loginToCurrentService))
        let share = makeItem(symbol: "square.and.arrow.up", label: "分享当前页面", action: #selector(sharePage))
        let safari = makeItem(symbol: "safari", label: "在 Safari 中打开", action: #selector(openSafari))
        let more = makeItem(symbol: "ellipsis.circle", label: "更多操作", action: #selector(showMore))
        let flexible = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbar.items = [backItem, flexible, forwardItem, flexible, reloadItem, flexible,
                         loginItem, flexible, share, flexible, safari, flexible, more]
    }

    private func mount(_ controller: EmbeddedWebViewController) {
        let needsParentAttachment = controller.parent == nil
        if needsParentAttachment {
            addChild(controller)
        }
        guard controller.view.superview == nil else { return }
        contentView.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        if needsParentAttachment {
            controller.didMove(toParent: self)
        }
    }

    private func unmount(_ controller: EmbeddedWebViewController) {
        guard let controllerView = controller.viewIfLoaded,
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

    private var activeWebViewController: EmbeddedWebViewController {
        switch selectedService {
        case .chatGPT: return chatGPTViewController
        case .gemini: return geminiViewController
        }
    }

    private func showService(_ service: WebService) {
        let selectedController: EmbeddedWebViewController
        let inactiveController: EmbeddedWebViewController
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
        serviceControl.selectedSegmentIndex = service.rawValue
        preferences.lastService = service
        loginItem?.accessibilityLabel = service == .chatGPT ? "登录 ChatGPT" : "登录 Gemini"
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
    @objc private func loginToCurrentService() { activeWebViewController.startLogin() }

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
        sheet.addAction(UIAlertAction(title: "媒体兼容性", style: .default) { [weak controller] _ in
            controller?.showLegacyMediaCompatibilityNotice()
        })
        if controller.service == .chatGPT {
            sheet.addAction(UIAlertAction(title: "清除 ChatGPT 网站数据", style: .destructive) { [weak self] _ in
                self?.confirmWebsiteDataClearFirstStep()
            })
        }
        sheet.addAction(UIAlertAction(title: "打开系统设置", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = toolbar.items?.last
        present(sheet, animated: true)
    }

    private func confirmWebsiteDataClearFirstStep() {
        let alert = UIAlertController(
            title: "清除 ChatGPT 网站数据？",
            message: "这会删除 ChatGPT/OpenAI 在 WebKit 中保存的登录和站点数据，不影响 Safari。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "继续", style: .destructive) { [weak self] _ in
            self?.confirmWebsiteDataClearSecondStep()
        })
        present(alert, animated: true)
    }

    private func confirmWebsiteDataClearSecondStep() {
        let alert = UIAlertController(
            title: "再次确认",
            message: "清除后需要重新登录 ChatGPT。此操作无法撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "保留数据", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认清除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.chatGPTViewController.clearChatGPTWebsiteData { [weak self] success in
                guard let self = self else { return }
                self.preferences.lastSafeChatGPTURL = nil
                self.chatGPTViewController.loadHome()
                let done = UIAlertController(
                    title: success ? "已清除" : "未能清除",
                    message: success ? "ChatGPT/OpenAI 网站数据已删除。" : "请稍后重试。",
                    preferredStyle: .alert
                )
                done.addAction(UIAlertAction(title: "好", style: .default))
                self.present(done, animated: true)
            }
        })
        present(alert, animated: true)
    }
}

extension RootViewController: EmbeddedWebViewControllerDelegate {
    func embeddedWebViewController(_ controller: EmbeddedWebViewController,
                                   didUpdate state: WebNavigationState) {
        if controller === activeWebViewController {
            updateToolbar(with: state)
        }
    }

    func embeddedWebViewController(_ controller: EmbeddedWebViewController,
                                   requestsSafari url: URL) {
        onSafariRequested?(url)
    }

    func embeddedWebViewController(_ controller: EmbeddedWebViewController,
                                   didChangeConnectivity isOnline: Bool) {
        if controller.service == .chatGPT {
            chatGPTIsOnline = isOnline
        } else {
            geminiIsOnline = isOnline
        }
        if controller === activeWebViewController {
            updateConnectivity(isOnline: isOnline)
        }
    }

}
