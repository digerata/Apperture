import Foundation

struct RemoteWindowSummary: Codable, Equatable, Identifiable {
    var id: UInt32
    var title: String
    var subtitle: String
    var isSelected: Bool
    var isSimulator: Bool
}

struct RemoteWindowListMessage: Codable, Equatable {
    var windows: [RemoteWindowSummary]
}
