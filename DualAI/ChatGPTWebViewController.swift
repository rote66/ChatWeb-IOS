import os.log
import UIKit
import WebKit


struct WebNavigationState {
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    let currentURL: URL?
}

protocol EmbeddedWebViewControllerDelegate: AnyObject {
    func embeddedWebViewController(_ controller: EmbeddedWebViewController,
                                   didUpdate state: WebNavigationState)
    func embeddedWebViewController(_ controller: EmbeddedWebViewController,
                                   requestsSafari url: URL)
    func embeddedWebViewController(_ controller: EmbeddedWebViewController,
                                   didChangeConnectivity isOnline: Bool)
}

class EmbeddedWebViewController: UIViewController {
    weak var delegate: EmbeddedWebViewControllerDelegate?
    let service: WebService

    private let policy: NavigationPolicy
    private let preferences: AppPreferences
    private let networkMonitor = NetworkMonitor()
    private let logger = OSLog(subsystem: "com.chatweb.DualAI", category: "WebView")
    private let webContainer = UIView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private var webView: WKWebView?
    private var popupWebView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var errorController: WebErrorViewController?
    private var lastInMemorySafeURL: URL?
    private var isOnline = false
    private var hasReceivedNetworkStatus = false
    private var pendingLoadURL: URL?
    private var lastContentProcessTerminationAt: Date?
    private var consecutiveContentProcessTerminations = 0
    private var contentProcessStabilityReset: DispatchWorkItem?
    private lazy var permissionManager = PermissionManager(presenter: self, service: service)

    private static let rapidContentProcessTerminationWindow: TimeInterval = 30

    private static let legacyLoginNavigationScript = #"""
    (function () {
        document.addEventListener('click', function (event) {
            if (window.location.protocol !== 'https:' ||
                window.location.hostname !== 'chatgpt.com' ||
                window.location.pathname !== '/') {
                return;
            }

            var path = typeof event.composedPath === 'function' ? event.composedPath() : [];
            var element = null;
            for (var index = 0; index < path.length; index += 1) {
                var candidate = path[index];
                var candidateRole = candidate.getAttribute && candidate.getAttribute('role');
                if (candidate.tagName === 'BUTTON' || candidate.tagName === 'A' || candidateRole === 'button') {
                    element = candidate;
                    break;
                }
            }
            if (!element) {
                element = event.target;
                while (element && element !== document.documentElement) {
                    var role = element.getAttribute && element.getAttribute('role');
                    if (element.tagName === 'BUTTON' || element.tagName === 'A' || role === 'button') {
                        break;
                    }
                    element = element.parentElement;
                }
            }
            if (!element || element === document.documentElement) { return; }

            var label = (element.getAttribute('aria-label') || element.textContent || '')
                .replace(/\s+/g, ' ')
                .trim()
                .toLowerCase();
            if (label !== '登录' && label !== 'log in' && label !== 'sign in') { return; }

            event.preventDefault();
            event.stopImmediatePropagation();
            window.location.assign('/auth/login');
        }, true);
    })();
    """#

    private static let legacyGeminiLoginNavigationScript = #"""
    (function () {
        document.addEventListener('click', function (event) {
            if (window.location.protocol !== 'https:' ||
                window.location.hostname !== 'gemini.google.com' ||
                (window.location.pathname !== '/' && window.location.pathname !== '/app')) {
                return;
            }

            var element = event.target;
            while (element && element !== document.documentElement) {
                var role = element.getAttribute && element.getAttribute('role');
                if (element.tagName === 'BUTTON' || element.tagName === 'A' || role === 'button') {
                    break;
                }
                element = element.parentElement;
            }
            if (!element || element === document.documentElement) { return; }

            var label = (element.getAttribute('aria-label') || element.textContent || '')
                .replace(/\s+/g, ' ')
                .trim()
                .toLowerCase();
            if (label !== '登录' && label !== 'log in' && label !== 'sign in') { return; }

            event.preventDefault();
            event.stopImmediatePropagation();
            window.location.assign('https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fapp');
        }, true);
    })();
    """#

    private var downloadManagerStorage: NSObject?

    init(service: WebService, preferences: AppPreferences = .shared) {
        self.service = service
        self.preferences = preferences
        policy = NavigationPolicy(service: service)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureLayout()
        configureNetworkMonitoring()
        ensureWebView(loadIfNeeded: true)
    }

    deinit {
        progressObservation?.invalidate()
        contentProcessStabilityReset?.cancel()
        networkMonitor.cancel()
    }

    private var activeWebView: WKWebView? {
        popupWebView ?? webView
    }

    var navigationState: WebNavigationState {
        let active = activeWebView
        return WebNavigationState(
            canGoBack: popupWebView != nil || (active?.canGoBack ?? false),
            canGoForward: active?.canGoForward ?? false,
            isLoading: active?.isLoading ?? false,
            currentURL: active?.url
        )
    }

    var currentSafeURL: URL {
        if let url = activeWebView?.url, let safe = policy.safeURLForPersistence(url) { return safe }
        if let url = lastInMemorySafeURL { return url }
        if let url = persistedSafeURL { return url }
        return policy.homeURL
    }

    private var persistedSafeURL: URL? {
        get {
            switch service {
            case .chatGPT: return preferences.lastSafeChatGPTURL
            case .gemini: return preferences.lastSafeGeminiURL
            }
        }
        set {
            switch service {
            case .chatGPT: preferences.lastSafeChatGPTURL = newValue
            case .gemini: preferences.lastSafeGeminiURL = newValue
            }
        }
    }

    func goBack() {
        if let popup = popupWebView {
            if popup.canGoBack {
                popup.goBack()
            } else {
                closePopupWebView()
            }
        } else {
            webView?.goBack()
        }
    }

    func goForward() { activeWebView?.goForward() }

    func reload() {
        hideError()
        guard isOnline else {
            showOfflineError()
            return
        }
        if activeWebView?.url != nil {
            activeWebView?.reload()
        } else {
            load(currentSafeURL)
        }
    }

    func loadHome() {
        hideError()
        closePopupWebView()
        load(policy.homeURL)
    }

    func startLogin() {
        hideError()
        closePopupWebView()
        load(policy.loginURL)
    }

    func handleForeground() {
        guard isViewLoaded else { return }
        ensureWebView(loadIfNeeded: true)
        notifyNavigationState()
    }

    func handleBackground() {
        persistIfSafe(webView?.url)
    }

    func releaseWebViewForMemoryPressureIfBackgrounded() {
        guard UIApplication.shared.applicationState == .background else { return }
        lastInMemorySafeURL = currentSafeURL
        removeWebView()
    }

    func showLegacyMediaCompatibilityNotice() {
        let message: String
        if #available(iOS 15.0, *) {
            message = "网页发起请求时，ChatWeb 会核对来源并逐次询问相机或麦克风权限。"
        } else {
            message = "iOS 14 以文本聊天和普通文件上传为主。网页语音、摄像头或实时通话不可用时，请在 Safari 中继续。"
        }
        let alert = UIAlertController(title: "媒体兼容性", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        if #unavailable(iOS 15.0) {
            alert.addAction(UIAlertAction(title: "在 Safari 中打开", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.delegate?.embeddedWebViewController(self, requestsSafari: self.currentSafeURL)
            })
        }
        present(alert, animated: true)
    }

    func clearChatGPTWebsiteData(completion: @escaping (Bool) -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { record in
                let name = record.displayName.lowercased()
                return name == "chatgpt.com" || name.hasSuffix(".chatgpt.com") ||
                    name == "openai.com" || name.hasSuffix(".openai.com")
            }
            guard !matching.isEmpty else {
                DispatchQueue.main.async { completion(true) }
                return
            }
            store.removeData(ofTypes: types, for: matching) {
                DispatchQueue.main.async { completion(true) }
            }
        }
    }

    private func configureLayout() {
        webContainer.backgroundColor = .systemBackground
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        progressView.progressTintColor = .systemBlue
        progressView.isHidden = true
        progressView.accessibilityLabel = "网页加载进度"

        view.addSubview(webContainer)
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureNetworkMonitoring() {
        networkMonitor.onStatusChange = { [weak self] isOnline in
            guard let self = self else { return }
            let hadStatus = self.hasReceivedNetworkStatus
            let wasOnline = self.isOnline
            self.hasReceivedNetworkStatus = true
            self.isOnline = isOnline
            self.delegate?.embeddedWebViewController(self, didChangeConnectivity: isOnline)

            if !isOnline {
                if self.webView?.url == nil {
                    self.showOfflineError()
                }
                return
            }

            if let pendingURL = self.pendingLoadURL {
                self.pendingLoadURL = nil
                self.hideError()
                self.performLoad(pendingURL)
            } else if hadStatus, !wasOnline, self.errorController != nil {
                self.reload()
            } else if !hadStatus, self.webView?.url == nil {
                self.load(self.lastInMemorySafeURL ?? self.persistedSafeURL ?? self.policy.homeURL)
            }
        }
        networkMonitor.start()
    }

    private func ensureWebView(loadIfNeeded: Bool) {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #unavailable(iOS 16.0) {
            let source = service == .chatGPT
                ? Self.legacyLoginNavigationScript
                : Self.legacyGeminiLoginNavigationScript
            let loginFallback = WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(loginFallback)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.accessibilityLabel = "\(policy.serviceName) 网页"
        webContainer.insertSubview(webView, at: 0)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        self.webView = webView
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.progressView.progress = Float(webView.estimatedProgress)
                self?.progressView.isHidden = webView.estimatedProgress >= 1
            }
        }

        if loadIfNeeded {
            load(lastInMemorySafeURL ?? persistedSafeURL ?? policy.homeURL)
        }
    }

    private func removeWebView() {
        closePopupWebView(notify: false)
        contentProcessStabilityReset?.cancel()
        contentProcessStabilityReset = nil
        progressObservation?.invalidate()
        progressObservation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        notifyNavigationState()
    }

    private func createPopupWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        closePopupWebView(notify: false)
        hideError()

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        popup.scrollView.keyboardDismissMode = .interactive
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.accessibilityLabel = "\(policy.serviceName) 弹出网页"
        webContainer.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: webContainer.topAnchor),
            popup.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            popup.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        popupWebView = popup
        notifyNavigationState()
        return popup
    }

    private func closePopupWebView(notify: Bool = true) {
        guard let popup = popupWebView else { return }
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popup.removeFromSuperview()
        popupWebView = nil
        progressView.isHidden = true
        if notify { notifyNavigationState() }
    }

    private func rebuildWebView(restoring url: URL) {
        removeWebView()
        lastInMemorySafeURL = policy.safeURLForPersistence(url) ?? policy.homeURL
        ensureWebView(loadIfNeeded: true)
    }

    private func retryAfterContentProcessFailure(restoring url: URL) {
        hideError()
        lastContentProcessTerminationAt = Date()
        consecutiveContentProcessTerminations = 1
        lastInMemorySafeURL = policy.safeURLForPersistence(url) ?? policy.homeURL
        ensureWebView(loadIfNeeded: false)
        load(lastInMemorySafeURL ?? policy.homeURL)
    }

    private func recordContentProcessTermination() -> Bool {
        let now = Date()
        if let previous = lastContentProcessTerminationAt,
           now.timeIntervalSince(previous) <= Self.rapidContentProcessTerminationWindow {
            consecutiveContentProcessTerminations += 1
        } else {
            consecutiveContentProcessTerminations = 1
        }
        lastContentProcessTerminationAt = now
        contentProcessStabilityReset?.cancel()
        contentProcessStabilityReset = nil
        return consecutiveContentProcessTerminations > 1
    }

    private func scheduleContentProcessStabilityReset(for loadedWebView: WKWebView) {
        contentProcessStabilityReset?.cancel()
        let reset = DispatchWorkItem { [weak self, weak loadedWebView] in
            guard let self = self, let loadedWebView = loadedWebView,
                  self.activeWebView === loadedWebView else { return }
            self.lastContentProcessTerminationAt = nil
            self.consecutiveContentProcessTerminations = 0
            self.contentProcessStabilityReset = nil
        }
        contentProcessStabilityReset = reset
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.rapidContentProcessTerminationWindow,
            execute: reset
        )
    }

    private func load(_ url: URL) {
        ensureWebView(loadIfNeeded: false)
        guard hasReceivedNetworkStatus, isOnline else {
            pendingLoadURL = url
            if hasReceivedNetworkStatus {
                showOfflineError()
            }
            return
        }
        pendingLoadURL = nil
        performLoad(url)
    }

    private func performLoad(_ url: URL) {
        webView?.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60))
    }

    private func notifyNavigationState() {
        delegate?.embeddedWebViewController(self, didUpdate: navigationState)
    }

    private func persistIfSafe(_ url: URL?) {
        guard let url = url, let safe = policy.safeURLForPersistence(url) else { return }
        lastInMemorySafeURL = safe
        persistedSafeURL = safe
    }

    private func showOfflineError() {
        showError(
            kind: .offline,
            headline: "当前离线",
            detail: "网络恢复后可以重新加载\(policy.serviceName)。",
            primaryTitle: "重试",
            secondaryTitle: nil,
            primary: { [weak self] in self?.reload() }
        )
    }

    private func showLoadFailure(error: Error, failingURL: URL?) {
        let isLogin = failingURL.map(policy.isAuthenticationURL) ?? false
        if isLogin {
            showError(
                kind: .loginBlocked,
                headline: "登录页面未能在 WebView 中完成",
                detail: "部分登录提供方会限制嵌入式浏览器。ChatWeb 不会绕过限制，也不会转移 Safari 登录数据。可在 Safari 中打开\(policy.serviceName)后按网站提示继续。",
                primaryTitle: "重试",
                secondaryTitle: "在 Safari 中打开\(policy.serviceName)",
                primary: { [weak self] in self?.reload() },
                secondary: { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.embeddedWebViewController(self, requestsSafari: self.policy.homeURL)
                }
            )
            return
        }

        showError(
            kind: isOnline ? .loadFailed : .offline,
            headline: isOnline ? "网页加载失败" : "当前离线",
            detail: isOnline ? "请检查网络后重试，或在 Safari 中继续。" : "网络恢复后可以重新加载\(policy.serviceName)。",
            primaryTitle: "重试",
            secondaryTitle: isOnline ? "在 Safari 中打开" : nil,
            primary: { [weak self] in self?.reload() },
            secondary: { [weak self] in
                guard let self = self else { return }
                self.delegate?.embeddedWebViewController(self, requestsSafari: self.currentSafeURL)
            }
        )
        os_log("Navigation failed for host: %{public}@; code: %{public}d",
               log: logger,
               type: .error,
               policy.sanitizedDescription(for: failingURL),
               (error as NSError).code)
    }

    private func showDownloadFallback(url: URL?, isBlob: Bool) {
        showError(
            kind: .downloadUnavailable,
            headline: isBlob ? "此 Blob 下载无法安全接管" : "此系统版本无法可靠下载",
            detail: isBlob
                ? "ChatWeb 不注入脚本读取认证信息。请使用网页提供的其他导出方式，或在 Safari 中重新执行下载。"
                : "iOS 14.5 以下缺少 WKDownload。请在 Safari 中重新执行下载。",
            primaryTitle: "返回页面",
            secondaryTitle: "在 Safari 中继续",
            primary: { [weak self] in self?.hideError() },
            secondary: { [weak self] in
                guard let self = self else { return }
                self.delegate?.embeddedWebViewController(self, requestsSafari: url ?? self.currentSafeURL)
            }
        )
    }

    private func isUserInitiated(_ navigationAction: WKNavigationAction) -> Bool {
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted:
            return true
        default:
            return false
        }
    }

    private func openSystemURL(_ url: URL, showFailure: Bool) {
        guard UIApplication.shared.canOpenURL(url) else {
            if showFailure { showUnsupportedLink() }
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened, showFailure { self?.showUnsupportedLink() }
        }
    }

    private func showUnsupportedLink() {
        showError(
            kind: .unsupported,
            headline: "无法打开此链接",
            detail: "该链接协议不能在应用内安全处理。",
            primaryTitle: "返回页面",
            secondaryTitle: nil,
            primary: { [weak self] in self?.hideError() }
        )
    }

    private func showError(kind: WebErrorKind,
                           headline: String,
                           detail: String,
                           primaryTitle: String,
                           secondaryTitle: String?,
                           primary: @escaping () -> Void,
                           secondary: (() -> Void)? = nil) {
        hideError()
        let controller = WebErrorViewController(
            kind: kind,
            headline: headline,
            detail: detail,
            primaryTitle: primaryTitle,
            secondaryTitle: secondaryTitle,
            primaryAction: primary,
            secondaryAction: secondary
        )
        addChild(controller)
        webContainer.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: webContainer.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        errorController = controller
    }

    private func hideError() {
        guard let controller = errorController else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        errorController = nil
    }

    @available(iOS 14.5, *)
    private func manageDownload(_ download: WKDownload) {
        let manager: DownloadManager
        if let existing = downloadManagerStorage as? DownloadManager {
            manager = existing
        } else {
            manager = DownloadManager { [weak self] in self }
            downloadManagerStorage = manager
        }
        manager.manage(download)
    }
}

extension EmbeddedWebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let navigationDecision = policy.decision(for: url)
        let userInitiated = isUserInitiated(navigationAction)
        switch navigationDecision {
        case .allowInWebView:
            if #available(iOS 14.5, *), navigationAction.shouldPerformDownload {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        case .openInSafari:
            decisionHandler(.cancel)
            if policy.shouldOpenExternally(navigationDecision, userInitiated: userInitiated) {
                delegate?.embeddedWebViewController(self, requestsSafari: url)
            }
        case .openInSystem:
            decisionHandler(.cancel)
            if policy.shouldOpenExternally(navigationDecision, userInitiated: userInitiated) {
                openSystemURL(url, showFailure: true)
            }
        case .blobDownloadUnavailable:
            decisionHandler(.cancel)
            var shouldExplain = isUserInitiated(navigationAction)
            if #available(iOS 14.5, *), navigationAction.shouldPerformDownload {
                shouldExplain = true
            }
            if shouldExplain { showDownloadFallback(url: nil, isBlob: true) }
        case .rejectUnsupported:
            decisionHandler(.cancel)
            if userInitiated { showUnsupportedLink() }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response as? HTTPURLResponse
        let disposition = response?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.contains("attachment")
        guard isAttachment || !navigationResponse.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }

        if #available(iOS 14.5, *) {
            decisionHandler(.download)
        } else {
            decisionHandler(.cancel)
            showDownloadFallback(url: navigationResponse.response.url, isBlob: false)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressView.isHidden = false
        notifyNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideError()
        notifyNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressView.isHidden = true
        persistIfSafe(webView.url)
        scheduleContentProcessStabilityReset(for: webView)
        notifyNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error, webView: webView)
    }

    private func handleNavigationError(_ error: Error, webView: WKWebView) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        progressView.isHidden = true
        showLoadFailure(error: error, failingURL: nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url)
        notifyNavigationState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === popupWebView {
            closePopupWebView()
            showError(
                kind: .processTerminated,
                headline: "弹出页面已关闭",
                detail: "弹出页面的 WebKit 内容进程意外结束，主\(policy.serviceName)页面仍保持。",
                primaryTitle: "继续",
                secondaryTitle: nil,
                primary: { [weak self] in self?.hideError() }
            )
            return
        }
        let recoveryURL = policy.safeURLForPersistence(webView.url ?? currentSafeURL) ?? currentSafeURL
        lastInMemorySafeURL = recoveryURL
        if recordContentProcessTermination() {
            removeWebView()
            let detail = "网页内容进程短时间内连续崩溃。自动恢复已停止；可以手动重试或在 Safari 中打开。"
            showError(
                kind: .processTerminated,
                headline: "网页内容进程连续崩溃",
                detail: detail,
                primaryTitle: "手动重试",
                secondaryTitle: "在 Safari 中打开",
                primary: { [weak self] in self?.retryAfterContentProcessFailure(restoring: recoveryURL) },
                secondary: { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.embeddedWebViewController(self, requestsSafari: recoveryURL)
                }
            )
            return
        }
        rebuildWebView(restoring: recoveryURL)
        let recoveryDetail = "WebKit 网页内容进程意外结束，ChatWeb 正在重新加载最后一个安全页面。若短时间再次崩溃，将停止自动恢复。"
        showError(
            kind: .processTerminated,
            headline: "正在恢复网页",
            detail: recoveryDetail,
            primaryTitle: "继续",
            secondaryTitle: nil,
            primary: { [weak self] in self?.hideError() }
        )
    }

    @available(iOS 14.5, *)
    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        manageDownload(download)
    }

    @available(iOS 14.5, *)
    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        manageDownload(download)
    }
}

extension EmbeddedWebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        guard let url = navigationAction.request.url else {
            return createPopupWebView(configuration: configuration)
        }
        let navigationDecision = policy.decision(for: url)
        let userInitiated = isUserInitiated(navigationAction)
        switch navigationDecision {
        case .allowInWebView:
            if policy.isServiceLoginURL(url) {
                closePopupWebView(notify: false)
                self.webView?.load(navigationAction.request)
                notifyNavigationState()
                return nil
            }
            return createPopupWebView(configuration: configuration)
        case .openInSafari:
            if policy.shouldOpenExternally(navigationDecision, userInitiated: userInitiated) {
                delegate?.embeddedWebViewController(self, requestsSafari: url)
            }
        case .openInSystem:
            if policy.shouldOpenExternally(navigationDecision, userInitiated: userInitiated) {
                openSystemURL(url, showFailure: true)
            }
        case .blobDownloadUnavailable:
            showDownloadFallback(url: nil, isBlob: true)
        case .rejectUnsupported:
            if userInitiated { showUnsupportedLink() }
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView {
            closePopupWebView()
        } else if webView.canGoBack {
            webView.goBack()
        } else {
            loadHome()
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: webView.title ?? "网页提示", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: webView.title ?? "网页确认", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: webView.title ?? "网页输入", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard frame.isMainFrame else {
            decisionHandler(.deny)
            return
        }
        permissionManager.requestWebMediaPermission(
            originHost: origin.host,
            type: type,
            completion: decisionHandler
        )
    }
}

final class ChatGPTWebViewController: EmbeddedWebViewController {
    init(preferences: AppPreferences = .shared) {
        super.init(service: .chatGPT, preferences: preferences)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
