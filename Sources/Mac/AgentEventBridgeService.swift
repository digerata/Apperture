import Foundation
import Dispatch

final class AgentEventBridgeService {
    static var defaultEventDirectoryURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return applicationSupportURL
            .appendingPathComponent("Apperture", isDirectory: true)
            .appendingPathComponent("AgentEvents", isDirectory: true)
    }

    private let fileManager: FileManager
    private let eventDirectoryURL: URL
    private let queue = DispatchQueue(label: "com.mikewille.Apperture.agent-events")
    private var timer: DispatchSourceTimer?
    private var processedFileNames: Set<String> = []

    init(
        eventDirectoryURL: URL = AgentEventBridgeService.defaultEventDirectoryURL,
        fileManager: FileManager = .default
    ) {
        self.eventDirectoryURL = eventDirectoryURL
        self.fileManager = fileManager
    }

    deinit {
        stop()
    }

    var eventDirectoryPath: String {
        eventDirectoryURL.path
    }

    func start(onEvent: @escaping (DeveloperActivityEvent) -> Void) {
        stop()
        ensureEventDirectoryExists()
        processedFileNames.removeAll()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let events = Self.loadEvents(
                from: self.eventDirectoryURL,
                fileManager: self.fileManager,
                processedFileNames: &self.processedFileNames
            )

            for event in events {
                onEvent(event)
            }
        }

        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func ensureEventDirectoryExists() {
        try? fileManager.createDirectory(
            at: eventDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private static func loadEvents(
        from eventDirectoryURL: URL,
        fileManager: FileManager,
        processedFileNames: inout Set<String>
    ) -> [DeveloperActivityEvent] {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: eventDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let eventFileURLs = fileURLs
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("json") == .orderedSame }
            .filter { !processedFileNames.contains($0.lastPathComponent) }
            .sorted { lhs, rhs in
                modificationDate(for: lhs) < modificationDate(for: rhs)
            }

        let decoder = JSONDecoder()
        var events: [DeveloperActivityEvent] = []

        for fileURL in eventFileURLs {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            if let event = try? decoder.decode(DeveloperActivityEvent.self, from: data) {
                events.append(event)
                processedFileNames.insert(fileURL.lastPathComponent)
                continue
            }

            if let decodedEvents = try? decoder.decode([DeveloperActivityEvent].self, from: data) {
                events.append(contentsOf: decodedEvents)
                processedFileNames.insert(fileURL.lastPathComponent)
            }
        }

        return events
    }

    private static func modificationDate(for fileURL: URL) -> Date {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
            .distantPast
    }
}
