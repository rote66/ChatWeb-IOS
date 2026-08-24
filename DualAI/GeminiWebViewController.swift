import UIKit

protocol GeminiWebViewControllerDelegate: AnyObject {
    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didUpdate state: WebNavigationState)
    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didChangeConnectivity isOnline: Bool)
}

class GeminiWebViewController: UIViewController, WebContentController {
    private static let chatGPTSessionContextId = "gvctxc001"
    private static let geminiSessionContextId = "gvctxc002"
    private static var didAttemptPendingCookieRestoreThisProcess = false
    weak var delegate: GeminiWebViewControllerDelegate?
    let service: WebService

    private let policy: NavigationPolicy
    private let preferences: AppPreferences
    private let networkMonitor = NetworkMonitor()
    private let embedding = GeminiGeckoEmbedding()
    private lazy var engine: GeckoEngine = {
        let profileName = service == .chatGPT ? "ChatGPTGeckoProfile" : "GeminiGeckoProfile"
        let profile = (try? GeckoEngine.defaultProfileDirectory(named: profileName)) ??
            FileManager.default.temporaryDirectory.appendingPathComponent(profileName)
        let sessionContextId: String?
        if preferences.shareGeckoLoginCookies {
            sessionContextId = nil
        } else {
            sessionContextId = service == .chatGPT
                ? Self.chatGPTSessionContextId
                : Self.geminiSessionContextId
        }
        return GeckoEngine(embedding: embedding,
                           profileDirectory: profile,
                           jitPolicy: .required,
                           sessionContextId: sessionContextId,
                           userAgentConfiguration: preferences.userAgentProfile.configuration)
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
    private var safeLogoutInProgress = false
    private var isolatedGPTIdentitySanitizeInFlight = false

    init(service: WebService = .gemini, preferences: AppPreferences = .shared) {
        self.service = service
        self.policy = NavigationPolicy(service: service)
        self.preferences = preferences
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

#if DEBUG
        NSLog("[GeminiGecko][Keyboard] hiding=%d screen=%@ local=%@ overlap=%.1f view=%@",
              hiding ? 1 : 0,
              NSCoder.string(for: screenEndFrame),
              NSCoder.string(for: localEndFrame),
              overlap,
              NSCoder.string(for: view.bounds))
#endif

        UIView.animate(withDuration: duration,
                       delay: 0,
                       options: [options, .beginFromCurrentState, .allowUserInteraction],
                       animations: {
                           self.view.layoutIfNeeded()
                           self.engine.view.setNeedsLayout()
                           self.engine.view.layoutIfNeeded()
                       },
                       completion: { _ in
#if DEBUG
                           NSLog("[GeminiGecko][Keyboard] applied overlap=%.1f container=%@ gecko=%@",
                                 overlap,
                                 NSCoder.string(for: self.containerView.bounds),
                                 NSCoder.string(for: self.engine.view.bounds))
#endif
                       })
    }

    private func configureGeckoProgress() {
        embedding.onProgressChange = { [weak self] progress in
            DispatchQueue.main.async {
                self?.handleGeckoProgress(progress)
            }
        }
        embedding.onSafeLogoutRequested = { [weak self] in
            self?.performSafeChatGPTLogout()
        }
    }

    private func beginLoadingUI() {
        isLoading = true
        progressView.isHidden = false
        progressView.setProgress(0.05, animated: false)
        delegate?.geminiWebViewController(self, didUpdate: navigationState)
    }

    private func performSafeChatGPTLogout() {
        guard service == .chatGPT, !safeLogoutInProgress else { return }
        safeLogoutInProgress = true
        NSLog("[GeminiGecko][Auth] safe logout begin context=%@",
              preferences.shareGeckoLoginCookies ? "(shared)" : Self.chatGPTSessionContextId)
        engine.stopLoading()
        engine.load(URL(string: "about:blank")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.safeLogoutInProgress else { return }
            self.clearCookieDomains(["chatgpt.com", "openai.com"]) { [weak self] success in
                guard let self else { return }
                self.safeLogoutInProgress = false
                NSLog("[GeminiGecko][Auth] safe logout done success=%d", success ? 1 : 0)
                self.engine.load(self.policy.homeURL)
            }
        }
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

        if service == .chatGPT,
           !preferences.shareGeckoLoginCookies,
           !preferences.didSanitizeIsolatedGPTIdentityCookiesV1 {
            guard !isolatedGPTIdentitySanitizeInFlight else { return }
            isolatedGPTIdentitySanitizeInFlight = true
            NSLog("[GeminiGecko][Storage] isolated-gpt identity sanitize start context=%@",
                  Self.chatGPTSessionContextId)
            sanitizeIsolatedGPTIdentityCookies(baseDomains: ["google.com", "youtube.com"]) { [weak self] success in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.isolatedGPTIdentitySanitizeInFlight = false
                    if success {
                        self.preferences.didSanitizeIsolatedGPTIdentityCookiesV1 = true
                    }
                    NSLog("[GeminiGecko][Storage] isolated-gpt identity sanitize done success=%d",
                          success ? 1 : 0)
                    self.loadPendingInitialURLIfReady()
                }
            }
            return
        }

        if !GeminiWebViewController.didAttemptPendingCookieRestoreThisProcess,
           let cookieSnapshot = AppDataBackupManager.shared.pendingCookieRestoreData() {
            GeminiWebViewController.didAttemptPendingCookieRestoreThisProcess = true
            NSLog("[GeminiGecko][Backup] logical cookie restore start bytes=%lu",
                  cookieSnapshot.count)
            engine.importCookies(cookieSnapshot) { [weak self] success in
                guard let self else { return }
                if success {
                    AppDataBackupManager.shared.completePendingCookieRestore()
                }
                NSLog("[GeminiGecko][Backup] logical cookie restore done success=%d",
                      success ? 1 : 0)
                self.loadPendingInitialURLIfReady()
            }
            return
        }

        pendingInitialURL = nil
        beginLoadingUI()
        engine.load(url)
    }

    private func sanitizeIsolatedGPTIdentityCookies(baseDomains: [String],
                                                    completion: @escaping (Bool) -> Void) {
        guard let first = baseDomains.first else {
            completion(true)
            return
        }
        engine.clearCookies(baseDomain: first) { [weak self] success in
            guard let self else { return }
            guard success else {
                completion(false)
                return
            }
            self.sanitizeIsolatedGPTIdentityCookies(
                baseDomains: Array(baseDomains.dropFirst()),
                completion: completion
            )
        }
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
        let restoreURL = currentSafeURL
        let baseDomain = service == .chatGPT ? "chatgpt.com" : "google.com"
        NSLog("[GeminiGecko][Storage] prepare-clear service=%@ base=%@ restore=%@",
              service == .chatGPT ? "ChatGPT" : "Gemini",
              baseDomain,
              restoreURL.absoluteString)
        engine.stopLoading()
        engine.load(URL(string: "about:blank")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.engine.clearCache(baseDomain: baseDomain) { [weak self] success in
                guard let self else { return }
                NSLog("[GeminiGecko][Storage] restore-after-clear success=%d url=%@",
                      success ? 1 : 0,
                      restoreURL.absoluteString)
                self.engine.load(restoreURL)
                completion(success)
            }
        }
    }

    func clearCookies(completion: @escaping (Bool) -> Void) {
        let domains = service == .chatGPT
            ? ["chatgpt.com", "openai.com"]
            : ["google.com"]
        clearCookieDomains(domains, completion: completion)
    }

    private func performCookieClear(completion: @escaping (Bool) -> Void) {
        let domains = service == .chatGPT
            ? ["chatgpt.com", "openai.com"]
            : ["google.com"]
        clearCookieDomains(domains, completion: completion)
    }

    private func clearCookieDomains(_ baseDomains: [String],
                                    completion: @escaping (Bool) -> Void) {
        guard let first = baseDomains.first else {
            completion(true)
            return
        }
        NSLog("[GeminiGecko][Storage] service=%@ cookie-base-domain=%@",
              service == .chatGPT ? "ChatGPT" : "Gemini", first)
        engine.clearCookies(baseDomain: first) { [weak self] success in
            guard let self else { return }
            guard success else {
                completion(false)
                return
            }
            self.clearCookieDomains(Array(baseDomains.dropFirst()), completion: completion)
        }
    }

    func migrateLoginCookies(toShared: Bool, completion: @escaping (Bool) -> Void) {
        NSLog("[GeminiGecko][Storage] migrate login cookies toShared=%d contexts=%@,%@",
              toShared ? 1 : 0,
              Self.chatGPTSessionContextId,
              Self.geminiSessionContextId)
        engine.migrateCookies(
            toShared: toShared,
            contextIds: [Self.chatGPTSessionContextId, Self.geminiSessionContextId],
            completion: completion
        )
    }

    func exportCookieSnapshot(completion: @escaping (Data?) -> Void) {
        engine.exportCookies(completion: completion)
    }

    func applyUserAgentProfile(_ profile: WebUserAgentProfile) -> Bool {
        let applied = engine.setUserAgentConfiguration(profile.configuration)
        guard applied else { return false }
        NSLog("[GeminiGecko][UA] service=%@ profile=%@",
              service == .chatGPT ? "ChatGPT" : "Gemini",
              profile.displayName)
        if didStart {
            reloadIgnoringCache()
        }
        return true
    }

    func setDiskCacheSmartSizeEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        engine.setDiskCacheSmartSizeEnabled(enabled, completion: completion)
    }

    func setDiskCacheCapacityKB(_ capacityKB: Int, completion: @escaping (Bool) -> Void) {
        engine.setDiskCacheCapacityKB(capacityKB, completion: completion)
    }

}
