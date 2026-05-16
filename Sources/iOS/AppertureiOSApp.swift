import UIKit
import PostHog

private enum PostHogConfigValue: String {
    case projectToken = "POSTHOG_PROJECT_TOKEN"
    case host = "POSTHOG_HOST"

    var infoDictionaryKey: String {
        switch self {
        case .projectToken:
            return "PostHogProjectToken"
        case .host:
            return "PostHogHost"
        }
    }

    var value: String {
        if let environmentValue = ProcessInfo.processInfo.environment[rawValue], !environmentValue.isEmpty {
            return environmentValue
        }

        if let bundledValue = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String, !bundledValue.isEmpty {
            return bundledValue
        }

        fatalError("Set \(rawValue) in the environment or \(infoDictionaryKey) in Info.plist.")
    }
}

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
        let config = PostHogConfig(
            projectToken: PostHogConfigValue.projectToken.value,
            host: PostHogConfigValue.host.value
        )
        config.captureApplicationLifecycleEvents = true
        PostHogSDK.shared.setup(config)
    }
}
