import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: LibraryController())
        navigation.navigationBar.prefersLargeTitles = true
        window.rootViewController = navigation
        self.window = window
        window.makeKeyAndVisible()
    }
    func sceneWillResignActive(_ scene: UIScene) {
        let navigation = window?.rootViewController as? UINavigationController
        (navigation?.topViewController as? ReaderController)?.savePosition()
    }
}
