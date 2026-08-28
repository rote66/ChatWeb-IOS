import UIKit

final class RootViewController: UIViewController, UIDocumentPickerDelegate {
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
        sheet.addAction(UIAlertAction(title: "设置&数据", style: .default) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.showSettingsMenu(for: controller)
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
                        NSLog("[GeminiGecko][Storage] scoped cookie clear completed service=%@",
                              controller.service == .chatGPT ? "ChatGPT" : "Gemini")
                        NSLog("[GeminiGecko][Storage] scoped cookie reload service=%@",
                              controller.service == .chatGPT ? "ChatGPT" : "Gemini")
                        controller.reloadIgnoringCache()
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

    private func showSettingsMenu(for controller: WebContentController) {
        let sharedCookies = preferences.shareGeckoLoginCookies
        let menu = UIAlertController(
            title: "设置 & 数据",
            message: sharedCookies
                ? "当前 GPT 与 Gemini 共用 Gecko 登录 Cookie。关闭后两边会使用独立 session context；需要重新启动 App 后生效。"
                : "当前 GPT 与 Gemini 使用独立 session context，Google/站点登录 Cookie 与站点存储互不复用；需要重新启动 App 后生效。",
            preferredStyle: .alert
        )
        menu.addAction(UIAlertAction(
            title: "用户代理：\(preferences.userAgentProfile.displayName)",
            style: .default
        ) { [weak self] _ in
            self?.showUserAgentMenu()
        })
        menu.addAction(UIAlertAction(
            title: "网页文字大小：\(preferences.webTextSize.displayName)",
            style: .default
        ) { [weak self] _ in
            self?.showWebTextSizeMenu()
        })
        menu.addAction(UIAlertAction(
            title: "媒体播放设置",
            style: .default
        ) { [weak self] _ in
            self?.showMediaSettingsMenu()
        })
        menu.addAction(UIAlertAction(
            title: "隐私保护：\(preferences.webPrivacyProtectionLevel.displayName)",
            style: .default
        ) { [weak self] _ in
            self?.showPrivacyProtectionMenu()
        })
        let serviceName = controller.service == .chatGPT ? "ChatGPT" : "Gemini"
        menu.addAction(UIAlertAction(
            title: "重置\(serviceName)网站权限",
            style: .destructive
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.showResetWebsitePermissionsConfirmation(for: controller)
        })
        menu.addAction(UIAlertAction(title: "缓存设置与清理", style: .default) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.showCacheSettingsMenu(for: controller)
        })
        menu.addAction(UIAlertAction(
            title: "GPT/Gemini 共用登录 Cookie = \(sharedCookies ? "开" : "关")",
            style: .default
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            let newValue = !sharedCookies
            let progress = UIAlertController(
                title: newValue ? "正在合并登录状态" : "正在拆分登录状态",
                message: newValue
                    ? "正在把 GPT 与 Gemini 两个独立 context 的当前登录 Cookie 合并回共享 context。"
                    : "正在按服务把共享 Cookie 迁移到 GPT 与 Gemini 两个独立 context；Google 身份 Cookie 不会复制到 GPT。",
                preferredStyle: .alert
            )
            self.present(progress, animated: true)
            controller.migrateLoginCookies(toShared: newValue) { [weak self, weak controller, weak progress] success in
                guard let self, let controller else { return }
                progress?.dismiss(animated: true) {
                    if success {
                        self.applySharedCookieSetting(newValue, controller: controller)
                    } else {
                        self.showStorageResult(title: "迁移登录 Cookie", success: false)
                    }
                }
            }
        })
        menu.addAction(UIAlertAction(title: "导出加密备份", style: .default) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.showBackupExportPasswordPrompt(for: controller)
        })
        menu.addAction(UIAlertAction(title: "导入加密备份", style: .default) { [weak self] _ in
            self?.showBackupImportPicker()
        })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func showUserAgentMenu() {
        let currentProfile = preferences.userAgentProfile
        let menu = UIAlertController(
            title: "用户代理",
            message: "该设置同时用于 GPT 与 Gemini。切换后，已打开的页面会重新加载。",
            preferredStyle: .alert
        )
        for profile in WebUserAgentProfile.allCases {
            let selectedPrefix = profile == currentProfile ? "✓ " : ""
            menu.addAction(UIAlertAction(
                title: selectedPrefix + profile.displayName,
                style: .default
            ) { [weak self] _ in
                self?.applyUserAgentProfile(profile)
            })
        }
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func applyUserAgentProfile(_ profile: WebUserAgentProfile) {
        guard profile != preferences.userAgentProfile else { return }
        let chatGPTApplied = chatGPTViewController.applyUserAgentProfile(profile)
        let geminiApplied = geminiViewController.applyUserAgentProfile(profile)
        guard chatGPTApplied, geminiApplied else {
            let previousProfile = preferences.userAgentProfile
            _ = chatGPTViewController.applyUserAgentProfile(previousProfile)
            _ = geminiViewController.applyUserAgentProfile(previousProfile)
            showSimpleAlert(title: "切换失败", message: "用户代理未更改，请稍后重试。")
            return
        }
        preferences.userAgentProfile = profile
        NSLog("[GeminiGecko][UA] persisted profile=%@", profile.displayName)
        // Let both GeckoView:UpdateSettings events finish before either
        // session reloads. This also matches the proven manual-refresh path.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chatGPTViewController.reloadAfterUserAgentChange()
            self.geminiViewController.reloadAfterUserAgentChange()
        }
    }

    private func showWebTextSizeMenu() {
        let current = preferences.webTextSize
        let menu = UIAlertController(
            title: "网页文字大小",
            message: "只缩放网页文字，不改变工具栏和 App 界面大小。已打开的页面会重新加载。",
            preferredStyle: .alert
        )
        for size in WebTextSize.allCases {
            let prefix = size == current ? "✓ " : ""
            menu.addAction(UIAlertAction(title: prefix + size.displayName, style: .default) {
                [weak self] _ in
                guard let self, size != current else { return }
                let configuration = self.makeContentConfiguration(textSize: size)
                self.applyContentConfiguration(
                    configuration,
                    failureTitle: "修改文字大小失败",
                    reloadPages: true
                ) {
                    self.preferences.webTextSize = size
                }
            })
        }
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func showMediaSettingsMenu() {
        let suspend = preferences.suspendMediaWhenInactive
        let menu = UIAlertController(
            title: "媒体播放",
            message: "自动播放策略对所有网页生效；后台暂停也用于 GPT/Gemini 切换后的非活动页面。",
            preferredStyle: .alert
        )
        menu.addAction(UIAlertAction(
            title: "自动播放：\(preferences.webAutoplayPolicy.displayName)",
            style: .default
        ) { [weak self] _ in
            self?.showAutoplayPolicyMenu()
        })
        menu.addAction(UIAlertAction(
            title: "非活动/后台暂停媒体 = \(suspend ? "开" : "关")",
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            let newValue = !suspend
            let configuration = self.makeContentConfiguration(
                suspendMediaWhenInactive: newValue
            )
            self.applyContentConfiguration(
                configuration,
                failureTitle: "修改后台媒体设置失败",
                reloadPages: false
            ) {
                self.preferences.suspendMediaWhenInactive = newValue
            }
        })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func showAutoplayPolicyMenu() {
        let current = preferences.webAutoplayPolicy
        let menu = UIAlertController(
            title: "自动播放",
            message: "“阻止有声”允许静音媒体自动播放；“阻止所有”兼容性最严格。",
            preferredStyle: .alert
        )
        for policy in WebAutoplayPolicy.allCases {
            let prefix = policy == current ? "✓ " : ""
            menu.addAction(UIAlertAction(title: prefix + policy.displayName, style: .default) {
                [weak self] _ in
                guard let self, policy != current else { return }
                let configuration = self.makeContentConfiguration(autoplayPolicy: policy)
                self.applyContentConfiguration(
                    configuration,
                    failureTitle: "修改自动播放失败",
                    reloadPages: true
                ) {
                    self.preferences.webAutoplayPolicy = policy
                }
            })
        }
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func showPrivacyProtectionMenu() {
        let current = preferences.webPrivacyProtectionLevel
        let menu = UIAlertController(
            title: "隐私保护",
            message: "标准会启用跟踪保护并分区第三方 Cookie；兼容允许第三方 Cookie；严格会阻止第三方 Cookie，部分登录或嵌入内容可能失效。该设置不改变 GPT/Gemini 是否共用登录 Cookie。",
            preferredStyle: .alert
        )
        for level in WebPrivacyProtectionLevel.allCases {
            let prefix = level == current ? "✓ " : ""
            menu.addAction(UIAlertAction(title: prefix + level.displayName, style: .default) {
                [weak self] _ in
                guard let self, level != current else { return }
                let configuration = self.makeContentConfiguration(privacyLevel: level)
                self.applyContentConfiguration(
                    configuration,
                    failureTitle: "修改隐私保护失败",
                    reloadPages: true
                ) {
                    self.preferences.webPrivacyProtectionLevel = level
                }
            })
        }
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func makeContentConfiguration(
        textSize: WebTextSize? = nil,
        autoplayPolicy: WebAutoplayPolicy? = nil,
        suspendMediaWhenInactive: Bool? = nil,
        privacyLevel: WebPrivacyProtectionLevel? = nil
    ) -> WebContentConfiguration {
        let resolvedTextSize = textSize ?? preferences.webTextSize
        let resolvedAutoplay = autoplayPolicy ?? preferences.webAutoplayPolicy
        let resolvedSuspend = suspendMediaWhenInactive ?? preferences.suspendMediaWhenInactive
        let resolvedPrivacy = privacyLevel ?? preferences.webPrivacyProtectionLevel
        return WebContentConfiguration(
            textZoom: resolvedTextSize.zoom,
            autoplayDefault: resolvedAutoplay.rawValue,
            suspendMediaWhenInactive: resolvedSuspend,
            cookieBehavior: resolvedPrivacy.cookieBehavior,
            usesTrackingProtection: resolvedPrivacy.usesTrackingProtection,
            usesStrictTrackingList: resolvedPrivacy.usesStrictTrackingList
        )
    }

    private func applyContentConfiguration(
        _ configuration: WebContentConfiguration,
        failureTitle: String,
        reloadPages: Bool,
        persist: @escaping () -> Void
    ) {
        let previous = preferences.webContentConfiguration
        chatGPTViewController.applyContentConfiguration(configuration) { [weak self] chatGPTSuccess in
            guard let self else { return }
            guard chatGPTSuccess else {
                self.rollbackContentConfiguration(previous)
                self.showSimpleAlert(title: failureTitle, message: "Gecko 设置未更改，请稍后重试。")
                return
            }
            self.geminiViewController.applyContentConfiguration(configuration) {
                [weak self] geminiSuccess in
                guard let self else { return }
                guard geminiSuccess else {
                    self.rollbackContentConfiguration(previous)
                    self.showSimpleAlert(title: failureTitle, message: "Gecko 设置未更改，请稍后重试。")
                    return
                }
                persist()
                if reloadPages {
                    self.chatGPTViewController.reloadIgnoringCache()
                    self.geminiViewController.reloadIgnoringCache()
                }
                NSLog("[GeminiGecko][Settings] content configuration persisted")
            }
        }
    }

    private func rollbackContentConfiguration(_ configuration: WebContentConfiguration) {
        chatGPTViewController.applyContentConfiguration(configuration) { _ in }
        geminiViewController.applyContentConfiguration(configuration) { _ in }
    }

    private func showResetWebsitePermissionsConfirmation(for controller: WebContentController) {
        let serviceName = controller.service == .chatGPT ? "ChatGPT" : "Gemini"
        let alert = UIAlertController(
            title: "重置\(serviceName)网站权限？",
            message: "会清除该服务当前登录 context 的麦克风、摄像头、位置、通知和自动播放等网站权限决定。Cookie、登录状态和站点数据不会删除。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重置", style: .destructive) {
            [weak self, weak controller] _ in
            controller?.clearWebsitePermissions { success in
                guard let self, let controller else { return }
                if success {
                    controller.reloadIgnoringCache()
                    self.showSimpleAlert(
                        title: "网站权限已重置",
                        message: "\(serviceName)下次使用相关功能时会重新请求权限。"
                    )
                } else {
                    self.showStorageResult(title: "重置网站权限", success: false)
                }
            }
        })
        present(alert, animated: true)
    }

    private func applySharedCookieSetting(_ newValue: Bool,
                                          controller: WebContentController) {
        preferences.shareGeckoLoginCookies = newValue
        preferences.didSeedIsolatedCookieContexts = !newValue
        NSLog("[GeminiGecko][Storage] shared-login-cookie setting updated value=%d next-launch=1 migrated=1",
              newValue ? 1 : 0)
        let alert = UIAlertController(
            title: "已保存",
            message: newValue
                ? "两个独立 context 的当前登录 Cookie 已合并回共享 context。完全退出并重新打开 App 后生效。"
                : "共享登录 Cookie 已按服务迁移到两个独立 context。完全退出并重新打开 App 后生效；Google 身份 Cookie 不会带入 GPT。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.showSettingsMenu(for: controller)
        })
        present(alert, animated: true)
    }

    private func showBackupExportPasswordPrompt(for controller: WebContentController) {
        let prompt = UIAlertController(
            title: "导出加密备份",
            message: "备份包含登录 Cookie、站点存储/IndexedDB、权限和 App 设置，因此必须使用密码加密。cache2/startupCache 等可重建缓存不会导出。",
            preferredStyle: .alert
        )
        prompt.addTextField { field in
            field.placeholder = "备份密码（至少 8 个字符）"
            field.isSecureTextEntry = true
            field.textContentType = .newPassword
        }
        prompt.addTextField { field in
            field.placeholder = "再次输入密码"
            field.isSecureTextEntry = true
            field.textContentType = .newPassword
        }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        prompt.addAction(UIAlertAction(title: "生成备份", style: .default) { [weak self, weak prompt] _ in
            guard let self else { return }
            let password = prompt?.textFields?.first?.text ?? ""
            let confirmation = prompt?.textFields?.dropFirst().first?.text ?? ""
            guard password == confirmation, password.utf8.count >= 8 else {
                self.showSimpleAlert(title: "密码无效", message: "两次密码必须一致，且至少 8 个字符。")
                return
            }
            self.performBackupExport(password: password, controller: controller)
        })
        present(prompt, animated: true)
    }

    private func performBackupExport(password: String, controller: WebContentController) {
        let progress = UIAlertController(
            title: "正在生成备份",
            message: "正在从 Gecko 导出逻辑 Cookie 快照，并复制、加密账户和站点数据…",
            preferredStyle: .alert
        )
        present(progress, animated: true)
        controller.exportCookieSnapshot { [weak self, weak progress] cookieSnapshot in
            guard let self else { return }
            guard let cookieSnapshot, !cookieSnapshot.isEmpty else {
                progress?.dismiss(animated: true) {
                    self.showSimpleAlert(title: "备份失败", message: "Gecko 登录 Cookie 快照导出失败。")
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let url = try AppDataBackupManager.shared.createEncryptedBackup(
                        password: password,
                        cookieSnapshot: cookieSnapshot
                    )
                    DispatchQueue.main.async {
                        guard let self else {
                            AppDataBackupManager.shared.removeTemporaryBackup(at: url)
                            return
                        }
                        progress?.dismiss(animated: true) {
                            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                            activity.completionWithItemsHandler = { _, _, _, _ in
                                AppDataBackupManager.shared.removeTemporaryBackup(at: url)
                            }
                            activity.popoverPresentationController?.sourceView = self.view
                            activity.popoverPresentationController?.sourceRect = CGRect(
                                x: self.view.bounds.midX,
                                y: self.view.bounds.midY,
                                width: 1,
                                height: 1
                            )
                            self.present(activity, animated: true)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        progress?.dismiss(animated: true) {
                            self.showSimpleAlert(title: "备份失败", message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    private func showBackupImportPicker() {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.data"], in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let prompt = UIAlertController(
            title: "导入加密备份",
            message: "输入创建此备份时使用的密码。恢复会先写入安全 staging，下一次启动 Gecko 前再替换数据。",
            preferredStyle: .alert
        )
        prompt.addTextField { field in
            field.placeholder = "备份密码"
            field.isSecureTextEntry = true
            field.textContentType = .password
        }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        prompt.addAction(UIAlertAction(title: "导入", style: .default) { [weak self, weak prompt] _ in
            guard let self else { return }
            let password = prompt?.textFields?.first?.text ?? ""
            guard password.utf8.count >= 8 else {
                self.showSimpleAlert(title: "密码无效", message: "请输入至少 8 个字符的备份密码。")
                return
            }
            self.performBackupImport(url: url, password: password)
        })
        present(prompt, animated: true)
    }

    private func performBackupImport(url: URL, password: String) {
        let progress = UIAlertController(
            title: "正在导入备份",
            message: "正在验证、解密并准备恢复数据…",
            preferredStyle: .alert
        )
        present(progress, animated: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AppDataBackupManager.shared.stageRestore(from: url, password: password)
                DispatchQueue.main.async {
                    guard let self else { return }
                    progress.dismiss(animated: true) {
                        self.showSimpleAlert(
                            title: "备份已准备好",
                            message: "请完全退出并重新打开 App。下一次启动会在 Gecko 加载 profile 之前恢复账号、站点数据和 App 设置；恢复完成后备份 staging 会自动删除。"
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    progress.dismiss(animated: true) {
                        self.showSimpleAlert(title: "导入失败", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func showCacheSettingsMenu(for controller: WebContentController) {
        let smartSizeEnabled = preferences.geckoDiskCacheSmartSizeEnabled
        let capacityKB = preferences.geckoDiskCacheCapacityKB
        let menu = UIAlertController(
            title: "设置 & 清理缓存",
            message: smartSizeEnabled
                ? "Smart Size 已开启：Gecko 会自动决定磁盘缓存容量，browser.cache.disk.capacity 暂不作为硬上限。修改会实时写入 Gecko，并在下次启动继续使用。"
                : "Smart Size 已关闭：browser.cache.disk.capacity 是磁盘缓存硬上限（KiB）。修改会实时写入 Gecko，并在下次启动继续使用。",
            preferredStyle: .alert
        )
        menu.addAction(UIAlertAction(title: "清理缓存", style: .default) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.showClearCacheConfirmation(for: controller)
        })
        menu.addAction(UIAlertAction(
            title: "browser.cache.disk.smart_size.enabled = \(smartSizeEnabled ? "true" : "false")",
            style: .default
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            let newValue = !smartSizeEnabled
            controller.setDiskCacheSmartSizeEnabled(newValue) { [weak self, weak controller] success in
                guard let self else { return }
                if success {
                    self.preferences.geckoDiskCacheSmartSizeEnabled = newValue
                    NSLog("[GeminiGecko][Storage] smart-size setting updated value=%d",
                          newValue ? 1 : 0)
                    if let controller {
                        DispatchQueue.main.async {
                            self.showCacheSettingsMenu(for: controller)
                        }
                    }
                } else {
                    self.showStorageResult(title: "修改 Smart Size", success: false)
                }
            }
        })
        menu.addAction(UIAlertAction(
            title: "browser.cache.disk.capacity = \(capacityKB) KiB",
            style: .default
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.showDiskCacheCapacityEditor(for: controller)
        })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func showClearCacheConfirmation(for controller: WebContentController) {
        let confirm = UIAlertController(
            title: "清除缓存和离线网站数据？",
            message: "会清除网页网络/图片缓存，以及 IndexedDB、Cache API 等离线网站数据。不会主动清除 Cookie，但网页可能需要重新建立本地数据。",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "取消", style: .cancel))
        confirm.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            let progress = UIAlertController(
                title: "正在清理缓存",
                message: "正在等待 Gecko 删除磁盘缓存和离线网站数据…",
                preferredStyle: .alert
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.present(progress, animated: true) {
                    controller.clearCache { [weak self, weak progress] success in
                        guard let self else { return }
                        DispatchQueue.main.async {
                            progress?.dismiss(animated: true) {
                                if success {
                                    NSLog("[GeminiGecko][Storage] cache clear completed; page retained")
                                    let alert = UIAlertController(
                                        title: "已完成",
                                        message: "磁盘缓存和离线网站数据已清除。cache2 目录会保留供 Gecko 复用，但其中旧缓存文件已经删除。iOS“储存空间”的统计可能不会立即刷新。",
                                        preferredStyle: .alert
                                    )
                                    alert.addAction(UIAlertAction(title: "好", style: .default))
                                    self.present(alert, animated: true)
                                } else {
                                    self.showStorageResult(title: "清除缓存", success: false)
                                }
                            }
                        }
                    }
                }
            }
        })
        present(confirm, animated: true)
    }

    private func showDiskCacheCapacityEditor(for controller: WebContentController) {
        let currentValue = preferences.geckoDiskCacheCapacityKB
        let editor = UIAlertController(
            title: "browser.cache.disk.capacity",
            message: "单位为 KiB。32768 = 32 MiB。Smart Size 开启时此值会保留，但不会作为硬上限。降低容量不会立即删除已有 cache2；需要马上释放空间时请再点“清理缓存”。",
            preferredStyle: .alert
        )
        editor.addTextField { textField in
            textField.keyboardType = .numberPad
            textField.text = String(currentValue)
            textField.placeholder = "例如 32768"
            textField.clearButtonMode = .whileEditing
        }
        editor.addAction(UIAlertAction(title: "取消", style: .cancel))
        editor.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak controller, weak editor] _ in
            guard let self, let controller,
                  let rawValue = editor?.textFields?.first?.text,
                  let capacityKB = Int(rawValue),
                  capacityKB >= 0,
                  capacityKB <= Int(Int32.max) else {
                self?.showStorageResult(title: "容量值无效", success: false)
                return
            }
            controller.setDiskCacheCapacityKB(capacityKB) { [weak self, weak controller] success in
                guard let self else { return }
                if success {
                    self.preferences.geckoDiskCacheCapacityKB = capacityKB
                    NSLog("[GeminiGecko][Storage] disk-cache capacity updated capacityKB=%d",
                          capacityKB)
                    if let controller {
                        DispatchQueue.main.async {
                            self.showCacheSettingsMenu(for: controller)
                        }
                    }
                } else {
                    self.showStorageResult(title: "修改缓存容量", success: false)
                }
            }
        })
        present(editor, animated: true)
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
