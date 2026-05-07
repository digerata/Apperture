import Foundation

struct DeveloperActivityEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var version: Int
    var kind: String
    var timestamp: String?
    var projectRoot: String?
    var scheme: String?
    var destination: String?
    var resultBundlePath: String?
    var resultStreamPath: String?
    var platform: String?
    var simulatorUDID: String?
    var bundleID: String?
    var appPath: String?
    var pid: Int?
    var status: String?
    var message: String?
    var warningCount: Int?
    var errorCount: Int?

    init(
        id: String = UUID().uuidString,
        version: Int = 1,
        kind: String,
        timestamp: String? = nil,
        projectRoot: String? = nil,
        scheme: String? = nil,
        destination: String? = nil,
        resultBundlePath: String? = nil,
        resultStreamPath: String? = nil,
        platform: String? = nil,
        simulatorUDID: String? = nil,
        bundleID: String? = nil,
        appPath: String? = nil,
        pid: Int? = nil,
        status: String? = nil,
        message: String? = nil,
        warningCount: Int? = nil,
        errorCount: Int? = nil
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.timestamp = timestamp
        self.projectRoot = projectRoot
        self.scheme = scheme
        self.destination = destination
        self.resultBundlePath = resultBundlePath
        self.resultStreamPath = resultStreamPath
        self.platform = platform
        self.simulatorUDID = simulatorUDID
        self.bundleID = bundleID
        self.appPath = appPath
        self.pid = pid
        self.status = status
        self.message = message
        self.warningCount = warningCount
        self.errorCount = errorCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case kind
        case timestamp
        case projectRoot
        case scheme
        case destination
        case resultBundlePath
        case resultStreamPath
        case platform
        case simulatorUDID
        case bundleID
        case bundleId
        case appPath
        case pid
        case status
        case message
        case warningCount
        case errorCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        kind = try container.decode(String.self, forKey: .kind)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        projectRoot = try container.decodeIfPresent(String.self, forKey: .projectRoot)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        resultBundlePath = try container.decodeIfPresent(String.self, forKey: .resultBundlePath)
        resultStreamPath = try container.decodeIfPresent(String.self, forKey: .resultStreamPath)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        simulatorUDID = try container.decodeIfPresent(String.self, forKey: .simulatorUDID)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) ??
            container.decodeIfPresent(String.self, forKey: .bundleId)
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        warningCount = try container.decodeIfPresent(Int.self, forKey: .warningCount)
        errorCount = try container.decodeIfPresent(Int.self, forKey: .errorCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(projectRoot, forKey: .projectRoot)
        try container.encodeIfPresent(scheme, forKey: .scheme)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encodeIfPresent(resultBundlePath, forKey: .resultBundlePath)
        try container.encodeIfPresent(resultStreamPath, forKey: .resultStreamPath)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(simulatorUDID, forKey: .simulatorUDID)
        try container.encodeIfPresent(bundleID, forKey: .bundleID)
        try container.encodeIfPresent(appPath, forKey: .appPath)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(warningCount, forKey: .warningCount)
        try container.encodeIfPresent(errorCount, forKey: .errorCount)
    }
}

struct DeveloperActivityState: Equatable, Sendable {
    var eventDirectoryPath: String
    var recentEvents: [DeveloperActivityEvent] = []

    var latestEvent: DeveloperActivityEvent? {
        recentEvents.first
    }

    var title: String {
        guard let latestEvent else { return "Agent Activity Idle" }

        switch latestEvent.kind {
        case "buildStarted":
            return "Building \(latestEvent.scheme ?? "App")"
        case "buildFinished":
            return latestEvent.isFailure ? "Build Failed" : "Build Finished"
        case "testStarted":
            return "Testing \(latestEvent.scheme ?? "App")"
        case "testFinished":
            return latestEvent.isFailure ? "Tests Failed" : "Tests Finished"
        case "simulatorBooted":
            return "Simulator Ready"
        case "appInstalled":
            return "App Installed"
        case "appLaunched":
            return "App Running"
        case "appRunFailed":
            return "Run Failed"
        default:
            return latestEvent.displayKind
        }
    }

    var detail: String {
        guard let latestEvent else {
            return "Waiting for agent events in \(eventDirectoryPath)."
        }

        if let message = latestEvent.message, !message.isEmpty {
            return message
        }

        if let scheme = latestEvent.scheme, let destination = latestEvent.destination {
            return "\(scheme) on \(destination)"
        }

        if let scheme = latestEvent.scheme {
            return scheme
        }

        if let bundleID = latestEvent.bundleID {
            return bundleID
        }

        return latestEvent.timestamp ?? "Latest agent event received."
    }

    var issueSummary: String? {
        guard let latestEvent else { return nil }
        let warningCount = latestEvent.warningCount ?? 0
        let errorCount = latestEvent.errorCount ?? 0
        guard warningCount > 0 || errorCount > 0 else { return nil }

        var parts: [String] = []
        if errorCount > 0 {
            parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")")
        }
        if warningCount > 0 {
            parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    mutating func apply(_ event: DeveloperActivityEvent) {
        recentEvents.removeAll { $0.id == event.id }
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 12 {
            recentEvents.removeLast(recentEvents.count - 12)
        }
    }
}

extension DeveloperActivityEvent {
    var displayKind: String {
        kind
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    var isFailure: Bool {
        status == "failed" ||
            status == "failure" ||
            kind.localizedCaseInsensitiveContains("failed") ||
            (errorCount ?? 0) > 0
    }

    var isActive: Bool {
        kind == "buildStarted" || kind == "testStarted"
    }
}
