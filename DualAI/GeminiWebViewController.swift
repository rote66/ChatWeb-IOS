import UIKit

protocol GeminiWebViewControllerDelegate: AnyObject {
    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didUpdate state: WebNavigationState)
    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didChangeConnectivity isOnline: Bool)
}

class GeminiWebViewController: UIViewController, WebContentController {
    weak var delegate: GeminiWebViewControllerDelegate?
    let service: WebService

    private let policy: NavigationPolicy
    private let networkMonitor = NetworkMonitor()
    private let embedding = GeminiGeckoEmbedding()
    private lazy var engine: GeckoEngine = {
        let profileName = service == .chatGPT ? "ChatGPTGeckoProfile" : "GeminiGeckoProfile"
        let profile = (try? GeckoEngine.defaultProfileDirectory(named: profileName)) ??
            FileManager.default.temporaryDirectory.appendingPathComponent(profileName)
        return GeckoEngine(embedding: embedding,
                           profileDirectory: profile,
                           jitPolicy: .required)
    }()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let containerView = UIView()
    private let statusLabel = UILabel()
    private var containerBottomConstraint: NSLayoutConstraint?
    private var keyboardObserverTokens: [NSObjectProtocol] = []
    private var didStart = false
    private var pendingInitialURL: URL?
    private var isLoading = false
    private var isOnline = true
    private var isBackgrounded = false

    init(service: WebService = .gemini, preferences: AppPreferences = .shared) {
        self.service = service
        self.policy = NavigationPolicy(service: service)
        _ = preferences
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for token in keyboardObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var viewController: UIViewController { self }
    var navigationState: WebNavigationState {
        WebNavigationState(canGoBack: engine.canGoBack,
                           canGoForward: engine.canGoForward,
                           isLoading: isLoading,
                           currentURL: engine.currentURL)
    }
    var currentSafeURL: URL { engine.currentURL ?? policy.homeURL }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        configureKeyboardAvoidance()
        configureGeckoProgress()
        configureNetworkMonitor()
        startIfNeededAndLoad(policy.homeURL)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadPendingInitialURLIfReady()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadPendingInitialURLIfReady()
    }

    private func configureViews() {
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        progressView.progressTintColor = .systemBlue
        progressView.isHidden = true
        let serviceName = service == .chatGPT ? "ChatGPT" : "Gemini"
        progressView.accessibilityLabel = "\(serviceName) 网页加载进度"
        containerView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        view.addSubview(progressView)
        view.addSubview(containerView)
        view.addSubview(statusLabel)
        let bottomConstraint = containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        containerBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func configureKeyboardAvoidance() {
        let center = NotificationCenter.default
        keyboardObserverTokens.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.updateForKeyboard(notification, hiding: false)
        })
        keyboardObserverTokens.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.updateForKeyboard(notification, hiding: true)
        })
    }

    private func updateForKeyboard(_ notification: Notification, hiding: Bool) {
        guard isViewLoaded,
              let bottomConstraint = containerBottomConstraint,
              let window = view.window else { return }

        let userInfo = notification.userInfo ?? [:]
        let screenEndFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let windowEndFrame = window.convert(screenEndFrame, from: window.screen.coordinateSpace)
        let localEndFrame = view.convert(windowEndFrame, from: window)
        let intersection = view.bounds.intersection(localEndFrame)
        let overlap = hiding || intersection.isNull ? 0 : max(0, intersection.height)

        bottomConstraint.constant = -overlap

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let rawCurve = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let options = UIView.AnimationOptions(rawValue: rawCurve << 16)

        NSLog("[GeminiGecko][Keyboard] hiding=%d screen=%@ local=%@ overlap=%.1f view=%@",
              hiding ? 1 : 0,
              NSCoder.string(for: screenEndFrame),
              NSCoder.string(for: localEndFrame),
              overlap,
              NSCoder.string(for: view.bounds))

        UIView.animate(withDuration: duration,
                       delay: 0,
                       options: [options, .beginFromCurrentState, .allowUserInteraction],
                       animations: {
                           self.view.layoutIfNeeded()
                           self.engine.view.setNeedsLayout()
                           self.engine.view.layoutIfNeeded()
                       },
                       completion: { _ in
                           NSLog("[GeminiGecko][Keyboard] applied overlap=%.1f container=%@ gecko=%@",
                                 overlap,
                                 NSCoder.string(for: self.containerView.bounds),
                                 NSCoder.string(for: self.engine.view.bounds))
                       })
    }

    private func configureGeckoProgress() {
        embedding.onProgressChange = { [weak self] progress in
            DispatchQueue.main.async {
                self?.handleGeckoProgress(progress)
            }
        }
    }

    private func beginLoadingUI() {
        isLoading = true
        progressView.isHidden = false
        progressView.setProgress(0.05, animated: false)
        delegate?.geminiWebViewController(self, didUpdate: navigationState)
    }

    private func handleGeckoProgress(_ value: Double) {
        let progress = max(0.0, min(1.0, value))
        if progress >= 1.0 {
            progressView.setProgress(1.0, animated: true)
            progressView.isHidden = true
            progressView.progress = 0
            isLoading = false
        } else {
            isLoading = true
            progressView.isHidden = false
            progressView.setProgress(Float(max(0.05, progress)), animated: progress > 0)
        }
        delegate?.geminiWebViewController(self, didUpdate: navigationState)
    }

    private func configureNetworkMonitor() {
        networkMonitor.onStatusChange = { [weak self] isOnline in
            guard let self else { return }
            self.isOnline = isOnline
            self.delegate?.geminiWebViewController(self, didChangeConnectivity: isOnline)
        }
        networkMonitor.start()
    }

    private func startIfNeededAndLoad(_ url: URL) {
        if !didStart {
            // Create/attach the UIKit ChildView first. Loading before the view
            // has a real window and final Auto Layout bounds leaves the UIKit
            // Gecko port with its bootstrap viewport, which caused the first
            // document to stay black and reloads to render at the wrong size.
            engine.start()
            didStart = true
            let geckoView = engine.view
            geckoView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(geckoView)
            NSLayoutConstraint.activate([
                geckoView.topAnchor.constraint(equalTo: containerView.topAnchor),
                geckoView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                geckoView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                geckoView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
            engine.setActive(!isBackgrounded)
            engine.setFocused(!isBackgrounded)
            pendingInitialURL = url
            view.setNeedsLayout()
            if case .enabled = engine.jitState {
                statusLabel.isHidden = true
            } else {
                statusLabel.text = "Gecko JIT 未启用。请通过 TrollStore 的 JIT 启动入口重新打开 ChatWeb。"
                statusLabel.isHidden = false
            }
        } else if pendingInitialURL != nil {
            pendingInitialURL = url
            view.setNeedsLayout()
        } else {
            beginLoadingUI()
            engine.load(url)
        }
        delegate?.geminiWebViewController(self, didUpdate: navigationState)
    }

    private func loadPendingInitialURLIfReady() {
        guard let url = pendingInitialURL,
              isViewLoaded,
              view.window != nil,
              containerView.bounds.width > 0,
              containerView.bounds.height > 0 else { return }

        containerView.layoutIfNeeded()
        let geckoView = engine.view
        guard geckoView.window != nil,
              geckoView.bounds.width > 0,
              geckoView.bounds.height > 0 else { return }

        // Force ChildView.layoutSubviews now so nsWindow::DoResize and
        // ReportSizeEvent run before the content docshell is asked to load.
        geckoView.setNeedsLayout()
        geckoView.layoutIfNeeded()
        NSLog("[GeminiGecko][View] first-load-layout container=%@ gecko=%@ scale=%.2f window=yes",
              NSCoder.string(for: containerView.bounds),
              NSCoder.string(for: geckoView.bounds),
              geckoView.contentScaleFactor)

        pendingInitialURL = nil
        beginLoadingUI()
        engine.load(url)
    }

    func goBack() {
        beginLoadingUI()
        engine.goBack()
        delegate?.geminiWebViewController(self, didUpdate: navigationState)
    }

    func goForward() {
        beginLoadingUI()
        engine.goForward()
        delegate?.geminiWebViewController(self, didUpdate: navigationState)
    }

    func reload() {
        if pendingInitialURL != nil {
            loadPendingInitialURLIfReady()
            return
        }
        beginLoadingUI()
        engine.reload()
    }

    func reloadIgnoringCache() {
        if pendingInitialURL != nil {
            loadPendingInitialURLIfReady()
            return
        }
        beginLoadingUI()
        engine.reloadIgnoringCache()
    }
    func loadHome() { startIfNeededAndLoad(policy.homeURL) }
    func openAccount() { startIfNeededAndLoad(policy.accountURL) }

    func handleForeground() {
        isBackgrounded = false
        engine.applicationWillEnterForeground()
        engine.setActive(true)
        engine.setFocused(viewIfLoaded?.window != nil)
    }

    func handleBackground() {
        isBackgrounded = true
        engine.setFocused(false)
        engine.setActive(false)
        engine.applicationDidEnterBackground()
    }

    func releaseWebViewForMemoryPressureIfBackgrounded() {
        // The Gecko runtime is process-wide and cannot be safely torn down and
        // recreated like WKWebView. Keep the session alive to preserve login.
    }

    func clearCache(completion: @escaping (Bool) -> Void) {
        engine.clearCache(completion: completion)
    }

    func clearCookies(completion: @escaping (Bool) -> Void) {
        let baseDomain = service == .chatGPT ? "chatgpt.com" : "google.com"
        NSLog("[GeminiGecko][Storage] service=%@ cookie-base-domain=%@",
              service == .chatGPT ? "ChatGPT" : "Gemini", baseDomain)
        engine.clearCookies(baseDomain: baseDomain, completion: completion)
    }

}
