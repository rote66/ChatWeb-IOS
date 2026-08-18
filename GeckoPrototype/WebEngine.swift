import UIKit

protocol WebEngine: AnyObject {
    var view: UIView { get }
    var currentURL: URL? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    func load(_ url: URL)
    func reload()
    func reloadIgnoringCache()
    func stopLoading()
    func goBack()
    func goForward()
    func setActive(_ active: Bool)
    func setFocused(_ focused: Bool)
    func applicationDidEnterBackground()
    func applicationWillEnterForeground()
    func close()
}

enum WebEngineError: Error, Equatable {
    case notInitialized
    case runtimeUnavailable(String)
    case sessionUnavailable(String)
    case invalidURL
    case closed
}
