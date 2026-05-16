import UIKit
import PostHog

@main
final class AppertureiOSApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configurePostHog()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = iPhoneViewerViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    private func configurePostHog() {
        guard let token = ProcessInfo.processInfo.environment["POSTHOG_PROJECT_TOKEN"],
              let host = ProcessInfo.processInfo.environment["POSTHOG_HOST"] else {
            fatalError("Set POSTHOG_PROJECT_TOKEN and POSTHOG_HOST in the Xcode scheme's Run environment variables.")
        }
        let config = PostHogConfig(apiKey: token, host: host)
        config.captureApplicationLifecycleEvents = true
        PostHogSDK.shared.setup(config)
    }
}
