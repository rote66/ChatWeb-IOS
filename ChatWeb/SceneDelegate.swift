import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    private var coordinator: AppCoordinator?
    private var memoryWarningObserver: NSObjectProtocol?
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        NSLog("[GeminiGecko] SceneDelegate willConnect")
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let coordinator = AppCoordinator(window: window)
        self.window = window
        self.coordinator = coordinator
        coordinator.start()
        NSLog("[GeminiGecko] SceneDelegate UI ready")

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator?.applicationDidReceiveMemoryWarning()
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        coordinator?.applicationWillEnterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        coordinator?.applicationDidEnterBackground()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }
}
