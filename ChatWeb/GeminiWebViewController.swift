import QuickLook
import SafariServices
import UIKit

protocol GeminiWebViewControllerDelegate: AnyObject {
    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didUpdate state: WebNavigationState)
    func geminiWebViewController(_ controller: GeminiWebViewController,
                                 didChangeConnectivity isOnline: Bool)
}

extension GeminiWebViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        downloadedPreviewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        downloadedPreviewURL! as NSURL
    }
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
        let profileName = "GeminiGeckoProfile"
        let profile = (try? GeckoEngine.defaultGeminiProfileDirectory()) ??
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
                           userAgentConfiguration: preferences.userAgentProfile.configuration,
                           contentConfiguration: preferences.webContentConfiguration)
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
    private var downloadedPreviewURL: URL?

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
        embedding.onExternalURLRequest = { [weak self] url, isNewWindow, userInitiated in
            self?.handleExternalURLRequest(url,
                                           isNewWindow: isNewWindow,
                                           userInitiated: userInitiated) ?? false
        }
        embedding.onDownloadRequest = {
            [weak self] remoteURL, _, suggestedFilename, mimeType, contentLength in
            self?.handleDownloadRequest(
                remoteURL,
                suggestedFilename: suggestedFilename,
                mimeType: mimeType,
                contentLength: contentLength
            ) ?? true
        }
        embedding.onDownloadCompleted = { [weak self] localFileURL, suggestedFilename, success in
            self?.handleCompletedDownload(localFileURL,
                                          suggestedFilename: suggestedFilename,
                                          success: success)
        }
    }

    private func handleExternalURLRequest(_ url: URL,
                                          isNewWindow: Bool,
                                          userInitiated: Bool) -> Bool {
        let decision = policy.decision(for: url)
        let shouldHandOff: Bool
        if isNewWindow {
            // GeckoView cannot create a second embedded session for target=_blank.
            // Hand it to the temporary browser instead of silently returning NO.
            shouldHandOff = true
        } else {
            shouldHandOff = policy.shouldOpenExternally(decision, userInitiated: userInitiated)
        }
        guard shouldHandOff else { return false }

        NSLog("[GeminiGecko][Nav] handoff service=%ld new=%d user=%d mode=%ld host=%@",
              service.rawValue,
              isNewWindow ? 1 : 0,
              userInitiated ? 1 : 0,
              preferences.externalLinkOpenMode.rawValue,
              url.host ?? "(none)")
        DispatchQueue.main.async { [weak self] in
            self?.openHandedOffURL(url, decision: decision)
        }
        return true
    }

    private func handleDownloadRequest(_ remoteURL: URL,
                                       suggestedFilename: String?,
                                       mimeType: String?,
                                       contentLength: Int64) -> Bool {
        let name = suggestedFilename?.isEmpty == false ? suggestedFilename! : "(none)"
        NSLog("[GeminiGecko][Download] route mode=%ld file=%@ mime=%@ bytes=%lld host=%@",
              preferences.externalLinkOpenMode.rawValue,
              name,
              mimeType ?? "(none)",
              contentLength,
              remoteURL.host ?? "(none)")
        guard preferences.externalLinkOpenMode == .externalBrowser else {
            return true
        }
        guard let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return true
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(remoteURL, options: [:], completionHandler: nil)
        }
        return false
    }

    private func openHandedOffURL(_ url: URL, decision: NavigationDecision) {
        if decision == .openInSystem {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        switch preferences.externalLinkOpenMode {
        case .inApp:
            let browser = SFSafariViewController(url: url)
            browser.dismissButtonStyle = .done
            browser.modalPresentationStyle = .fullScreen
            topmostPresenter.present(browser, animated: true)
        case .externalBrowser:
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private var topmostPresenter: UIViewController {
        var presenter: UIViewController = self
        while let parent = presenter.parent {
            presenter = parent
        }
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }

    private func handleCompletedDownload(_ temporaryURL: URL,
                                         suggestedFilename: String?,
                                         success: Bool) {
        guard success else {
            showDownloadFailure()
            return
        }
        do {
            let destination = try persistCompletedDownload(temporaryURL,
                                                           suggestedFilename: suggestedFilename)
            presentCompletedDownload(destination)
        } catch {
            NSLog("[GeminiGecko][Download] persist failed error=%@", String(describing: error))
            showDownloadFailure()
        }
    }

    private func persistCompletedDownload(_ temporaryURL: URL,
                                          suggestedFilename: String?) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let requestedName = suggestedFilename?.isEmpty == false
            ? suggestedFilename!
            : (temporaryURL.lastPathComponent.isEmpty ? "download" : temporaryURL.lastPathComponent)
        let lastComponent = (requestedName as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.newlines).union(.controlCharacters)
        let cleaned = lastComponent.components(separatedBy: forbidden).joined(separator: "-")
        let safeName = cleaned.isEmpty ? "download" : String(cleaned.prefix(160))
        var destination = directory.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destination.path) {
            let ext = destination.pathExtension
            let base = destination.deletingPathExtension().lastPathComponent
            for index in 2...999 {
                let candidateName = ext.isEmpty
                    ? "\(base)-\(index)"
                    : "\(base)-\(index).\(ext)"
                let candidate = directory.appendingPathComponent(candidateName)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    destination = candidate
                    break
                }
            }
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        NSLog("[GeminiGecko][Download] stored file=%@", destination.lastPathComponent)
        return destination
    }

    private func presentCompletedDownload(_ url: URL) {
        let presenter = topmostPresenter
        let alert = UIAlertController(title: "下载完成",
                                      message: url.lastPathComponent,
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "在 App 内预览", style: .default) { [weak self] _ in
            guard let self else { return }
            self.downloadedPreviewURL = url
            let preview = QLPreviewController()
            preview.dataSource = self
            self.present(preview, animated: true)
        })
        alert.addAction(UIAlertAction(title: "分享或存储到文件", style: .default) { [weak self] _ in
            guard let self else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = self.view
            activity.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX,
                                                                          y: self.view.bounds.maxY - 24,
                                                                          width: 1,
                                                                          height: 1)
            self.present(activity, animated: true)
        })
        alert.addAction(UIAlertAction(title: "完成", style: .cancel))
        alert.popoverPresentationController?.sourceView = presenter.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                                                  y: presenter.view.bounds.maxY - 24,
                                                                  width: 1,
                                                                  height: 1)
        presenter.present(alert, animated: true)
    }

    private func showDownloadFailure() {
        let presenter = topmostPresenter
        let alert = UIAlertController(title: "下载失败",
                                      message: "文件没有完成下载，请重试。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter.present(alert, animated: true)
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
        let baseDomain = service == .chatGPT ? "chatgpt.com" : "google.com"
        NSLog("[GeminiGecko][Storage] prepare-clear service=%@ base=%@",
              service == .chatGPT ? "ChatGPT" : "Gemini",
              baseDomain)
        engine.clearCache(baseDomain: baseDomain) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    NSLog("[GeminiGecko][Storage] clear-finished success=1 reload=ignoring-cache")
                    self?.reloadIgnoringCache()
                } else {
                    NSLog("[GeminiGecko][Storage] clear-finished success=0 reload=skipped")
                }
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

    func clearWebsitePermissions(completion: @escaping (Bool) -> Void) {
        let domains = service == .chatGPT
            ? ["chatgpt.com", "openai.com"]
            : ["google.com"]
        clearPermissionDomains(domains, completion: completion)
    }

    private func clearPermissionDomains(_ baseDomains: [String],
                                        completion: @escaping (Bool) -> Void) {
        guard let first = baseDomains.first else {
            completion(true)
            return
        }
        NSLog("[GeminiGecko][Permission] service=%@ reset-base-domain=%@",
              service == .chatGPT ? "ChatGPT" : "Gemini", first)
        engine.clearPermissions(baseDomain: first) { [weak self] success in
            guard let self else { return }
            guard success else {
                completion(false)
                return
            }
            self.clearPermissionDomains(Array(baseDomains.dropFirst()), completion: completion)
        }
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
        return true
    }

    func reloadAfterUserAgentChange() {
        guard didStart else { return }
        NSLog("[GeminiGecko][UA] reload service=%@ mode=standard",
              service == .chatGPT ? "ChatGPT" : "Gemini")
        reload()
    }

    func applyContentConfiguration(_ configuration: WebContentConfiguration,
                                   completion: @escaping (Bool) -> Void) {
        engine.setContentConfiguration(configuration, completion: completion)
    }

    func setDiskCacheSmartSizeEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        engine.setDiskCacheSmartSizeEnabled(enabled, completion: completion)
    }

    func setDiskCacheCapacityKB(_ capacityKB: Int, completion: @escaping (Bool) -> Void) {
        engine.setDiskCacheCapacityKB(capacityKB, completion: completion)
    }

}
