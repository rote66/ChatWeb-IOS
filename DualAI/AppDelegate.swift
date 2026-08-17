import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var coordinator: AppCoordinator?
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let coordinator = AppCoordinator(window: window)
        self.window = window
        self.coordinator = coordinator
        coordinator.start()
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        coordinator?.applicationWillEnterForeground()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        coordinator?.applicationDidEnterBackground()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        coordinator?.applicationDidReceiveMemoryWarning()
    }
}
