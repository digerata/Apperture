import Foundation

struct RemoteWindowSummary: Codable, Equatable, Identifiable {
    var id: UInt32
    var title: String
    var subtitle: String
    var isSelected: Bool
    var isSimulator: Bool
    var appName: String?
    var appBundleIdentifier: String?
    var appIconPNGData: Data?

    var displayAppName: String {
        appName ?? title
    }

    var appGroupID: String {
        appBundleIdentifier ?? displayAppName.lowercased()
    }
}

struct RemoteWindowListMessage: Codable, Equatable {
    var windows: [RemoteWindowSummary]
}
