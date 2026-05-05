import UIKit

@main
final class AppertureiOSApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = iPhoneViewerViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
