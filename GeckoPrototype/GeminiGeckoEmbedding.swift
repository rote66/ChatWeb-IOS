import UIKit

final class GeminiGeckoEmbedding: GeckoEmbedding {
    private let bridge = GeminiGeckoBridge()
    private let placeholderView = UIView()

    var onProgressChange: ((Double) -> Void)? {
        didSet {
            bridge.progressHandler = onProgressChange
        }
    }

    var nativeView: UIView {
        bridge.nativeView ?? placeholderView
    }

    var currentURL: URL? { bridge.currentURL }
    var canGoBack: Bool { bridge.canGoBack }
    var canGoForward: Bool { bridge.canGoForward }

    var jitState: GeckoJITRuntimeState {
        switch bridge.jitState.rawValue {
        case 1:
            return .enabled
        case 2:
            return .degradedNoJIT(reason: Int32(clamping: bridge.jitReason))
        case 3:
            return .failed(reason: Int32(clamping: bridge.jitReason))
        default:
            return .unresolved
        }
    }

    func start(profileDirectory: URL, jitPolicy: GeckoJITPolicy) throws {
        let objcPolicy = GeminiGeckoJITPolicy(
            rawValue: jitPolicy == .required ? 1 : 0
        )!
        try bridge.start(profileDirectory: profileDirectory, jitPolicy: objcPolicy)
        // Required means this state is a production acceptance gate, not that
        // diagnostic startup must abort. The Gecko-side fallback deliberately
        // keeps the browser usable without JIT so we can report/measure the
        // failure and let the user relaunch through TrollStore's JIT path.
    }

    func load(_ url: URL) throws {
        try bridge.load(url: url)
    }

    func reload() { bridge.reload() }
    func stopLoading() { bridge.stopLoading() }
    func goBack() { bridge.goBack() }
    func goForward() { bridge.goForward() }
    func setActive(_ active: Bool) { bridge.setActive(active) }
    func setFocused(_ focused: Bool) { bridge.setFocused(focused) }
    func enterBackground() { bridge.enterBackground() }
    func enterForeground() { bridge.enterForeground() }
    func close() { bridge.close() }
}
