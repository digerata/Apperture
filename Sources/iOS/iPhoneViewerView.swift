import AVFoundation
import Combine
import UIKit

private final class PaddedLabel: UILabel {
    var contentInsets = UIEdgeInsets.zero {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }
}

private final class DeveloperActivityBannerView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(activity: DeveloperActivityState) {
        guard let event = activity.latestEvent else {
            isHidden = true
            return
        }

        iconView.image = UIImage(systemName: symbolName(for: event))
        iconView.tintColor = symbolColor(for: event)
        titleLabel.text = activity.title
        if let issueSummary = activity.issueSummary {
            detailLabel.text = "\(activity.detail) - \(issueSummary)"
        } else {
            detailLabel.text = activity.detail
        }
        isHidden = false
    }

    private func configureSubviews() {
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.46)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        detailLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    private func symbolName(for event: DeveloperActivityEvent) -> String {
        if event.isFailure {
            return "xmark.circle.fill"
        }

        switch event.kind {
        case "buildStarted":
            return "hammer.fill"
        case "testStarted":
            return "checkmark.seal"
        case "appLaunched":
            return "play.circle.fill"
        case "simulatorBooted":
            return "iphone.gen3"
        default:
            return "terminal.fill"
        }
    }

    private func symbolColor(for event: DeveloperActivityEvent) -> UIColor {
        if event.isFailure {
            return .systemRed
        }

        return event.isActive ? .systemBlue : .systemGreen
    }
}

private struct ViewerResumeTarget: Codable, Equatable {
    var hostID: String
    var windowID: UInt32
    var appGroupID: String
    var savedAt: Date

    var isValid: Bool {
        Date().timeIntervalSince(savedAt) <= Self.resumeWindow
    }

    func store() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func load() -> ViewerResumeTarget? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let target = try? JSONDecoder().decode(ViewerResumeTarget.self, from: data) else {
            return nil
        }

        guard target.isValid else {
            clear()
            return nil
        }

        return target
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static let defaultsKey = "AppertureViewer.resumeTarget"
    private static let resumeWindow: TimeInterval = 10 * 60
}

final class iPhoneViewerViewController: UIViewController {
    private let streamClient = RemoteFrameStreamClient()
    private var cancellables = Set<AnyCancellable>()
    private var nextSequenceNumber: UInt64 = 0

    private let fallbackWallpaperView = FallbackWallpaperView()
    private let wallpaperImageView = UIImageView()
    private let mirrorCanvasView = MirrorCanvasView()
    private let hostConnectionView = HostConnectionOverlayView()
    private let appLauncherView = AppLauncherOverlayView()
    private let loadingInterstitialView = LoadingInterstitialView()
    private let toolbarView = ViewerToolbarView()
    private let keyboardInputView = KeyboardInputView()
    private let fpsOverlayLabel = PaddedLabel()
    private let developerActivityBannerView = DeveloperActivityBannerView()
    private var developerActivityDismissWorkItem: DispatchWorkItem?
    private var currentDefaultLayoutMode: MirrorLayoutMode?
    private var mirrorLeadingConstraint: NSLayoutConstraint?
    private var mirrorTrailingConstraint: NSLayoutConstraint?
    private var mirrorTopConstraint: NSLayoutConstraint?
    private var mirrorBottomConstraint: NSLayoutConstraint?
    private var developerActivityTopConstraint: NSLayoutConstraint?
    private var developerActivityLeadingConstraint: NSLayoutConstraint?
    private var developerActivityTrailingConstraint: NSLayoutConstraint?
    private var frameTimestamps: [CFTimeInterval] = []
    private var displayedFPS: Double?
    private var latestStreamDiagnostics: RemoteStreamDiagnosticsMessage?
    private var selectedWindowIsSimulator = false
    private var hasSelectedWindowMetadata = false
    private var currentFrameHasAlphaMask = false
    private var hasRequestedStreamForCurrentConnection = false
    private var isAppLauncherPresented = false
    private var isWaitingForSelectedStream = false
    private var isDismissingLauncherForSelectedStream = false
    private var hasPendingSelectedStreamFrame = false
    private var isAwaitingWindowList = false
    private var isPresentingAppLauncher = false
    private var appLauncherPresentationGeneration = 0
    private var currentSelectedWindowID: UInt32?
    private var currentSelectedWindow: RemoteWindowSummary?
    private var pendingResumeTarget: ViewerResumeTarget?
    private var resumeDeadlineWorkItem: DispatchWorkItem?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var recentAppIDs = UserDefaults.standard.stringArray(forKey: "RecentMirroredAppIDs") ?? []
    private var isVideoDebugEnabled = UserDefaults.standard.bool(forKey: "VideoDebugOverlayEnabled") {
        didSet {
            UserDefaults.standard.set(isVideoDebugEnabled, forKey: "VideoDebugOverlayEnabled")
            toolbarView.isVideoDebugEnabled = isVideoDebugEnabled
            updateFrameRateOverlay()
        }
    }

    private var isKeyboardPresented = false {
        didSet {
            toolbarView.isKeyboardPresented = isKeyboardPresented

            if isKeyboardPresented {
                keyboardInputView.becomeFirstResponder()
            } else {
                keyboardInputView.resignFirstResponder()
            }
        }
    }

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        [.portrait, .landscapeLeft, .landscapeRight]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1)
        configureSubviews()
        configureCallbacks()
        bindStreamClient()
        configureLifecycleObservers()
        streamClient.start()
        beginResumeIfAvailable()
    }

    deinit {
        resumeDeadlineWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateChromeLayoutForCurrentSize()
        updateDefaultLayoutModeForCurrentSize()
    }

    private func configureSubviews() {
        fallbackWallpaperView.translatesAutoresizingMaskIntoConstraints = false

        wallpaperImageView.translatesAutoresizingMaskIntoConstraints = false
        wallpaperImageView.contentMode = .scaleAspectFill
        wallpaperImageView.clipsToBounds = true
        wallpaperImageView.isHidden = true

        mirrorCanvasView.translatesAutoresizingMaskIntoConstraints = false
        mirrorCanvasView.layoutMode = .fitHeight

        hostConnectionView.translatesAutoresizingMaskIntoConstraints = false
        hostConnectionView.isHidden = true

        appLauncherView.translatesAutoresizingMaskIntoConstraints = false
        appLauncherView.isHidden = true

        loadingInterstitialView.translatesAutoresizingMaskIntoConstraints = false
        loadingInterstitialView.isHidden = true

        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.isVideoDebugEnabled = isVideoDebugEnabled

        keyboardInputView.translatesAutoresizingMaskIntoConstraints = false
        keyboardInputView.alpha = 0.01
        keyboardInputView.isAccessibilityElement = false

        fpsOverlayLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsOverlayLabel.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        fpsOverlayLabel.textColor = .white
        fpsOverlayLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        fpsOverlayLabel.textAlignment = .left
        fpsOverlayLabel.numberOfLines = 0
        fpsOverlayLabel.contentInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        fpsOverlayLabel.layer.cornerRadius = 7
        fpsOverlayLabel.layer.cornerCurve = .continuous
        fpsOverlayLabel.clipsToBounds = true
        fpsOverlayLabel.text = "FPS --"
        fpsOverlayLabel.isHidden = true

        developerActivityBannerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(fallbackWallpaperView)
        view.addSubview(wallpaperImageView)
        view.addSubview(mirrorCanvasView)
        view.addSubview(hostConnectionView)
        view.addSubview(appLauncherView)
        view.addSubview(loadingInterstitialView)
        view.addSubview(toolbarView)
        view.addSubview(developerActivityBannerView)
        view.addSubview(fpsOverlayLabel)
        view.addSubview(keyboardInputView)

        let mirrorLeadingConstraint = mirrorCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let mirrorTrailingConstraint = mirrorCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let mirrorTopConstraint = mirrorCanvasView.topAnchor.constraint(equalTo: view.topAnchor, constant: 76)
        let mirrorBottomConstraint = mirrorCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        let developerActivityTopConstraint = developerActivityBannerView.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor,
            constant: 72
        )
        let developerActivityLeadingConstraint = developerActivityBannerView.leadingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.leadingAnchor,
            constant: 16
        )
        let developerActivityTrailingConstraint = developerActivityBannerView.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor,
            constant: -16
        )
        self.mirrorLeadingConstraint = mirrorLeadingConstraint
        self.mirrorTrailingConstraint = mirrorTrailingConstraint
        self.mirrorTopConstraint = mirrorTopConstraint
        self.mirrorBottomConstraint = mirrorBottomConstraint
        self.developerActivityTopConstraint = developerActivityTopConstraint
        self.developerActivityLeadingConstraint = developerActivityLeadingConstraint
        self.developerActivityTrailingConstraint = developerActivityTrailingConstraint

        NSLayoutConstraint.activate([
            fallbackWallpaperView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fallbackWallpaperView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fallbackWallpaperView.topAnchor.constraint(equalTo: view.topAnchor),
            fallbackWallpaperView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            wallpaperImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wallpaperImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wallpaperImageView.topAnchor.constraint(equalTo: view.topAnchor),
            wallpaperImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            mirrorLeadingConstraint,
            mirrorTrailingConstraint,
            mirrorTopConstraint,
            mirrorBottomConstraint,

            hostConnectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostConnectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostConnectionView.topAnchor.constraint(equalTo: view.topAnchor),
            hostConnectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            appLauncherView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            appLauncherView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            appLauncherView.topAnchor.constraint(equalTo: view.topAnchor),
            appLauncherView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingInterstitialView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingInterstitialView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingInterstitialView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingInterstitialView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            developerActivityTopConstraint,
            developerActivityLeadingConstraint,
            developerActivityTrailingConstraint,
            developerActivityBannerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            fpsOverlayLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            fpsOverlayLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            fpsOverlayLabel.widthAnchor.constraint(equalToConstant: 176),
            fpsOverlayLabel.heightAnchor.constraint(equalToConstant: 120),

            keyboardInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardInputView.widthAnchor.constraint(equalToConstant: 1),
            keyboardInputView.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func configureCallbacks() {
        mirrorCanvasView.onPointerEvent = { [weak self] kind, point in
            self?.sendPointerEvent(kind: kind, point: point)
        }
        mirrorCanvasView.onScrollEvent = { [weak self] point, delta, phase in
            self?.sendScrollEvent(point: point, delta: delta, phase: phase)
        }

        toolbarView.onLayoutModeChanged = { [weak self] layoutMode in
            self?.setLayoutMode(layoutMode)
        }

        toolbarView.onAppLauncherTapped = { [weak self] in
            self?.presentAppLauncherFromToolbar()
        }

        hostConnectionView.onHostSelected = { [weak self] host in
            self?.streamClient.connect(toHostID: host.id)
        }

        hostConnectionView.onManualConnectRequested = { [weak self] host, _, _ in
            guard let self else { return }
            if let errorMessage = streamClient.connectManually(to: host) {
                presentManualConnectError(errorMessage)
            }
        }

        hostConnectionView.onDiagnosticsTapped = { [weak self] in
            self?.presentConnectionDiagnostics()
        }

        appLauncherView.onRefreshTapped = { [weak self] in
            self?.requestWindowList()
        }

        appLauncherView.onWindowSelected = { [weak self] window in
            self?.selectWindow(window)
        }

        toolbarView.onKeyboardTapped = { [weak self] in
            guard let self else { return }
            isKeyboardPresented.toggle()
        }

        toolbarView.onDisconnectTapped = { [weak self] in
            self?.disconnectFromHost()
        }

        toolbarView.onDiagnosticsTapped = { [weak self] in
            self?.presentConnectionDiagnostics()
        }

        toolbarView.onVideoDebugToggled = { [weak self] in
            guard let self else { return }
            isVideoDebugEnabled.toggle()
        }

        keyboardInputView.onTextInput = { [weak self] text in
            self?.sendTextInput(text)
        }

        keyboardInputView.onKeyPress = { [weak self] key in
            self?.sendKeyPress(key)
        }
    }

    private func configureLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    private func bindStreamClient() {
        streamClient.$latestFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.mirrorCanvasView.image = image
                self?.recordDisplayedFrame(image)
                if image != nil {
                    self?.handleSelectedStreamFrameReady()
                }
            }
            .store(in: &cancellables)

        streamClient.$videoFrameSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.mirrorCanvasView.videoSourceSize = size
            }
            .store(in: &cancellables)

        streamClient.videoSampleBuffers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sampleBuffer in
                guard let self else { return }
                if mirrorCanvasView.enqueueVideoSampleBuffer(sampleBuffer) {
                    recordDisplayedFrame()
                    handleSelectedStreamFrameReady()
                } else {
                    streamClient.requestKeyFrameIfNeeded()
                }
            }
            .store(in: &cancellables)

        streamClient.$latestFrameMask
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mask in
                guard let self else { return }
                mirrorCanvasView.maskImage = mask
                currentFrameHasAlphaMask = mask != nil
                updateInputMode()
            }
            .store(in: &cancellables)

        streamClient.$wallpaper
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.wallpaperImageView.image = image
                self?.wallpaperImageView.isHidden = image == nil
            }
            .store(in: &cancellables)

        streamClient.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                toolbarView.streamState = state
                if case .connected = state {
                    requestWindowList()
                } else if case .live = state {
                    hasRequestedStreamForCurrentConnection = true
                } else {
                    hasRequestedStreamForCurrentConnection = false
                }
                attemptPendingResume()
                updateFlowOverlays()
            }
            .store(in: &cancellables)

        streamClient.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                guard let self else { return }
                isAwaitingWindowList = false
                toolbarView.windows = windows
                if let selectedWindow = windows.first(where: \.isSelected) {
                    currentSelectedWindowID = selectedWindow.id
                    currentSelectedWindow = selectedWindow
                    selectedWindowIsSimulator = selectedWindow.isSimulator
                    hasSelectedWindowMetadata = true
                } else {
                    currentSelectedWindowID = nil
                    currentSelectedWindow = nil
                    selectedWindowIsSimulator = false
                    hasSelectedWindowMetadata = false
                }
                attemptPendingResume()
                refreshAppLauncher()
                updateInputMode()
                updateFlowOverlays()
            }
            .store(in: &cancellables)

        streamClient.$hosts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hosts in
                guard let self else { return }
                hostConnectionView.hosts = hosts
                attemptPendingResume()
                updateFlowOverlays()
            }
            .store(in: &cancellables)

        streamClient.$streamDiagnostics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] diagnostics in
                self?.latestStreamDiagnostics = diagnostics
                self?.updateFrameRateOverlay()
            }
            .store(in: &cancellables)

        streamClient.$developerActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in
                self?.showDeveloperActivity(activity)
            }
            .store(in: &cancellables)
    }

    private func showDeveloperActivity(_ activity: DeveloperActivityState) {
        developerActivityDismissWorkItem?.cancel()
        developerActivityBannerView.layer.removeAllAnimations()
        developerActivityBannerView.alpha = 1
        developerActivityBannerView.configure(activity: activity)

        guard activity.latestEvent != nil else { return }

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.18) {
                self?.developerActivityBannerView.alpha = 0
            } completion: { _ in
                self?.developerActivityBannerView.isHidden = true
                self?.developerActivityBannerView.alpha = 1
            }
        }

        developerActivityDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismissWorkItem)
    }

    @objc private func applicationDidEnterBackground() {
        persistResumeTarget()
        beginSessionBackgroundTaskIfNeeded()
    }

    @objc private func applicationWillEnterForeground() {
        endSessionBackgroundTask()
        beginResumeIfAvailable()
    }

    private func beginSessionBackgroundTaskIfNeeded() {
        guard backgroundTaskIdentifier == .invalid else { return }
        guard streamClient.currentHostID != nil else { return }

        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Apperture Session Grace"
        ) { [weak self] in
            guard let self else { return }
            persistResumeTarget()
            endSessionBackgroundTask()
        }
    }

    private func endSessionBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else { return }
        let identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func beginResumeIfAvailable() {
        guard let target = ViewerResumeTarget.load(), target.isValid else { return }
        pendingResumeTarget = target
        scheduleResumeDeadline()

        switch streamClient.state {
        case .idle, .failed:
            streamClient.restart()
        case .searching, .connecting, .connected, .live:
            break
        }

        attemptPendingResume()
        updateFlowOverlays()
    }

    private func persistResumeTarget() {
        guard let hostID = streamClient.currentHostID,
              let window = currentSelectedWindow else {
            return
        }

        ViewerResumeTarget(
            hostID: hostID,
            windowID: window.id,
            appGroupID: window.appGroupID,
            savedAt: Date()
        )
        .store()
    }

    private func scheduleResumeDeadline() {
        resumeDeadlineWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, pendingResumeTarget != nil else { return }
            pendingResumeTarget = nil
            isWaitingForSelectedStream = false
            isDismissingLauncherForSelectedStream = false
            hasPendingSelectedStreamFrame = false
            mirrorCanvasView.defersAutomaticContentArrival = false
            updateFlowOverlays()
        }
        resumeDeadlineWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    private func attemptPendingResume() {
        guard let target = pendingResumeTarget else { return }
        guard target.isValid else {
            pendingResumeTarget = nil
            updateFlowOverlays()
            return
        }

        if streamClient.currentHostID != target.hostID,
           streamClient.hosts.contains(where: { $0.id == target.hostID }) {
            streamClient.connect(toHostID: target.hostID)
            return
        }

        switch streamClient.state {
        case .idle, .failed:
            streamClient.restart()
        case .searching, .connecting:
            break
        case .connected:
            requestWindowList()
        case .live:
            pendingResumeTarget = nil
            resumeDeadlineWorkItem?.cancel()
            loadingInterstitialView.setVisible(false, animated: view.window != nil)
        }

        guard streamClient.currentHostID == target.hostID else { return }
        guard let window = streamClient.windows.first(where: { $0.id == target.windowID })
            ?? streamClient.windows.first(where: { $0.appGroupID == target.appGroupID }) else {
            return
        }

        selectWindowForResume(window)
    }

    private func selectWindowForResume(_ window: RemoteWindowSummary) {
        pendingResumeTarget = nil
        resumeDeadlineWorkItem?.cancel()

        if window.id == currentSelectedWindowID {
            currentSelectedWindow = window
            loadingInterstitialView.setVisible(false, animated: view.window != nil)
            updateFlowOverlays()
            return
        }

        isAppLauncherPresented = false
        isWaitingForSelectedStream = true
        isDismissingLauncherForSelectedStream = false
        hasPendingSelectedStreamFrame = false
        currentSelectedWindowID = window.id
        currentSelectedWindow = window
        selectedWindowIsSimulator = window.isSimulator
        hasSelectedWindowMetadata = true
        currentFrameHasAlphaMask = false
        updateInputMode()
        mirrorCanvasView.prepareForAppSwitch()
        mirrorCanvasView.defersAutomaticContentArrival = true
        streamClient.prepareForStreamSelection()
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(selectWindowID: window.id, sequenceNumber: nextSequenceNumber))
        updateFlowOverlays()
    }

    private func sendPointerEvent(kind: RemoteControlMessage.Kind, point: CGPoint) {
        nextSequenceNumber += 1
        streamClient.send(
            RemoteControlMessage(
                kind: kind,
                normalizedX: Double(point.x),
                normalizedY: Double(point.y),
                sequenceNumber: nextSequenceNumber
            )
        )
    }

    private func sendScrollEvent(point: CGPoint, delta: CGPoint, phase: RemoteControlMessage.ScrollPhase) {
        nextSequenceNumber += 1
        streamClient.send(
            RemoteControlMessage(
                scrollAt: point,
                delta: delta,
                phase: phase,
                sequenceNumber: nextSequenceNumber
            )
        )
    }

    private func updateInputMode() {
        mirrorCanvasView.usesTouchDragForSingleFingerPan = hasSelectedWindowMetadata
            ? selectedWindowIsSimulator
            : currentFrameHasAlphaMask
    }

    private func sendTextInput(_ text: String) {
        guard !text.isEmpty else { return }
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(text: text, sequenceNumber: nextSequenceNumber))
    }

    private func sendKeyPress(_ key: RemoteControlMessage.Key) {
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(key: key, sequenceNumber: nextSequenceNumber))
    }

    private func requestWindowList() {
        isAwaitingWindowList = true
        refreshAppLauncher()
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(requestWindowListWithSequenceNumber: nextSequenceNumber))
    }

    private func requestStartStream() {
        hasRequestedStreamForCurrentConnection = true
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(startStreamWithSequenceNumber: nextSequenceNumber))
    }

    private func requestStartStreamIfNeeded() {
        guard !hasRequestedStreamForCurrentConnection else { return }
        requestStartStream()
    }

    private func refreshAppLauncher() {
        appLauncherView.configure(
            groups: RemoteApplicationWindowGroup.make(from: streamClient.windows),
            recentGroupIDs: Set(recentAppIDs),
            isLoading: isAwaitingWindowList
        )
    }

    private func updateFlowOverlays() {
        if pendingResumeTarget != nil {
            hostConnectionView.setVisible(false, animated: view.window != nil)
            appLauncherView.setVisible(false, animated: view.window != nil)
            loadingInterstitialView.setVisible(true, animated: view.window != nil)
            mirrorCanvasView.alpha = 0
            mirrorCanvasView.isUserInteractionEnabled = false
            return
        }

        if isWaitingForSelectedStream {
            switch streamClient.state {
            case .idle, .searching, .connecting, .failed:
                isWaitingForSelectedStream = false
                isDismissingLauncherForSelectedStream = false
                hasPendingSelectedStreamFrame = false
                mirrorCanvasView.defersAutomaticContentArrival = false
            case .connected, .live:
                break
            }
        }

        if isWaitingForSelectedStream {
            hostConnectionView.setVisible(false, animated: view.window != nil)
            if !isDismissingLauncherForSelectedStream {
                appLauncherView.setVisible(false, animated: view.window != nil)
            }
            loadingInterstitialView.setVisible(
                !isDismissingLauncherForSelectedStream,
                animated: view.window != nil
            )
            mirrorCanvasView.alpha = 0
            mirrorCanvasView.isUserInteractionEnabled = false
            return
        }

        if isPresentingAppLauncher {
            hostConnectionView.setVisible(false, animated: view.window != nil)
            appLauncherView.setVisible(false, animated: view.window != nil)
            loadingInterstitialView.setVisible(false, animated: view.window != nil)
            mirrorCanvasView.alpha = 1
            mirrorCanvasView.isUserInteractionEnabled = false
            return
        }

        let shouldShowHosts: Bool
        var shouldShowApps: Bool

        switch streamClient.state {
        case .idle, .searching, .connecting, .failed:
            shouldShowHosts = true
            shouldShowApps = false
        case .connected:
            shouldShowHosts = false
            shouldShowApps = true
        case .live:
            shouldShowHosts = false
            shouldShowApps = false
        }

        if isAppLauncherPresented {
            switch streamClient.state {
            case .connected, .live:
                shouldShowApps = true
            case .idle, .searching, .connecting, .failed:
                isAppLauncherPresented = false
            }
        }

        hostConnectionView.setVisible(shouldShowHosts, animated: view.window != nil)
        appLauncherView.setVisible(shouldShowApps, animated: view.window != nil)
        loadingInterstitialView.setVisible(false, animated: view.window != nil)
        mirrorCanvasView.alpha = shouldShowApps ? 0 : 1
        mirrorCanvasView.isUserInteractionEnabled = !shouldShowApps
    }

    private func presentAppLauncherFromToolbar() {
        guard !isWaitingForSelectedStream else { return }
        guard !isPresentingAppLauncher else { return }

        if isAppLauncherPresented {
            dismissAppLauncherToCurrentApp(animated: true)
            return
        }

        switch streamClient.state {
        case .connected:
            appLauncherPresentationGeneration += 1
            isAppLauncherPresented = true
            requestWindowList()
            updateFlowOverlays()
        case .live:
            appLauncherPresentationGeneration += 1
            let generation = appLauncherPresentationGeneration
            isPresentingAppLauncher = true
            requestWindowList()
            mirrorCanvasView.isUserInteractionEnabled = false
            mirrorCanvasView.departForAppLauncher { [weak self] in
                guard let self else { return }
                guard generation == self.appLauncherPresentationGeneration else { return }
                self.isPresentingAppLauncher = false
                self.isAppLauncherPresented = true
                self.updateFlowOverlays()
            }
        case .idle, .failed:
            streamClient.restart()
            updateFlowOverlays()
        case .searching, .connecting:
            updateFlowOverlays()
        }
    }

    private func dismissAppLauncherToCurrentApp(animated: Bool) {
        appLauncherPresentationGeneration += 1
        isPresentingAppLauncher = false
        isAppLauncherPresented = false
        isWaitingForSelectedStream = false
        isDismissingLauncherForSelectedStream = false
        hasPendingSelectedStreamFrame = false
        mirrorCanvasView.defersAutomaticContentArrival = false
        loadingInterstitialView.setVisible(false, animated: view.window != nil)
        appLauncherView.setVisible(false, animated: animated && view.window != nil)
        mirrorCanvasView.alpha = 1
        mirrorCanvasView.isUserInteractionEnabled = true
        updateFlowOverlays()
    }

    private func rememberAppSelection(_ window: RemoteWindowSummary) {
        let groupID = window.appGroupID
        recentAppIDs.removeAll { $0 == groupID }
        recentAppIDs.insert(groupID, at: 0)
        if recentAppIDs.count > 8 {
            recentAppIDs.removeLast(recentAppIDs.count - 8)
        }
        UserDefaults.standard.set(recentAppIDs, forKey: "RecentMirroredAppIDs")
        refreshAppLauncher()
    }

    private func selectWindow(_ window: RemoteWindowSummary) {
        if window.id == currentSelectedWindowID {
            currentSelectedWindow = window
            rememberAppSelection(window)
            dismissAppLauncherToCurrentApp(animated: true)
            return
        }

        appLauncherPresentationGeneration += 1
        isPresentingAppLauncher = false
        isAppLauncherPresented = false
        isWaitingForSelectedStream = true
        isDismissingLauncherForSelectedStream = true
        hasPendingSelectedStreamFrame = false
        rememberAppSelection(window)
        currentSelectedWindowID = window.id
        currentSelectedWindow = window
        resetFrameRateOverlay()
        currentFrameHasAlphaMask = false
        selectedWindowIsSimulator = window.isSimulator
        hasSelectedWindowMetadata = true
        updateInputMode()
        mirrorCanvasView.prepareForAppSwitch()
        mirrorCanvasView.defersAutomaticContentArrival = true
        streamClient.prepareForStreamSelection()
        nextSequenceNumber += 1
        streamClient.send(RemoteControlMessage(selectWindowID: window.id, sequenceNumber: nextSequenceNumber))
        appLauncherView.setVisible(false, animated: view.window != nil) { [weak self] in
            guard let self else { return }
            self.isDismissingLauncherForSelectedStream = false
            if self.hasPendingSelectedStreamFrame {
                self.completeSelectedStreamTransition()
            } else {
                self.updateFlowOverlays()
            }
        }
    }

    private func handleSelectedStreamFrameReady() {
        guard isWaitingForSelectedStream else { return }
        hasPendingSelectedStreamFrame = true
        guard !isDismissingLauncherForSelectedStream else { return }
        completeSelectedStreamTransition()
    }

    private func completeSelectedStreamTransition() {
        guard isWaitingForSelectedStream else { return }

        isWaitingForSelectedStream = false
        isDismissingLauncherForSelectedStream = false
        hasPendingSelectedStreamFrame = false
        mirrorCanvasView.alpha = 1
        mirrorCanvasView.revealDeferredContentArrivalForAppSwitch()
        mirrorCanvasView.isUserInteractionEnabled = true
        loadingInterstitialView.setVisible(false, animated: view.window != nil)
        updateFlowOverlays()
    }

    private func recordDisplayedFrame(_ image: UIImage?) {
        guard image != nil else {
            resetFrameRateOverlay()
            return
        }

        recordDisplayedFrame()
    }

    private func recordDisplayedFrame() {
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now - $0 > 2.0 }

        guard let firstTimestamp = frameTimestamps.first,
              let lastTimestamp = frameTimestamps.last,
              lastTimestamp > firstTimestamp,
              frameTimestamps.count > 1 else {
            updateFrameRateOverlay()
            return
        }

        displayedFPS = Double(frameTimestamps.count - 1) / (lastTimestamp - firstTimestamp)
        updateFrameRateOverlay()
    }

    private func resetFrameRateOverlay() {
        frameTimestamps.removeAll()
        displayedFPS = nil
        latestStreamDiagnostics = nil
        fpsOverlayLabel.text = "FPS --"
        fpsOverlayLabel.isHidden = true
    }

    private func updateFrameRateOverlay() {
        guard isVideoDebugEnabled else {
            fpsOverlayLabel.isHidden = true
            return
        }

        guard displayedFPS != nil || latestStreamDiagnostics != nil else {
            fpsOverlayLabel.text = "FPS --"
            fpsOverlayLabel.isHidden = false
            return
        }

        let displayFPS = displayedFPS.map { String(format: "%.1f", $0) } ?? "--"
        guard let diagnostics = latestStreamDiagnostics else {
            fpsOverlayLabel.text = "Render \(displayFPS) fps"
            fpsOverlayLabel.isHidden = false
            return
        }

        fpsOverlayLabel.text = String(
            format: "Render %@ fps\nCap %.1f Enc %.1f Send %.1f Target %.0f\n%d x %d  %.1f/%.1f Mbps Q %.2f\nDrop %d  RKF %d  KF %d\nPrep %.1f CG %.1f Crop %.1f Mat %.1f\nPB %.1f Enc %.1f Q %.1f Dir %.0f%%",
            displayFPS,
            diagnostics.captureFPS,
            diagnostics.encodedFPS,
            diagnostics.sentFPS,
            diagnostics.targetFPS,
            diagnostics.encodedWidth,
            diagnostics.encodedHeight,
            diagnostics.bitrateMbps,
            diagnostics.configuredBitrateMbps,
            diagnostics.videoQuality,
            diagnostics.droppedFrames,
            diagnostics.backpressureKeyFrames,
            diagnostics.keyFrameInterval,
            diagnostics.capturePrepMS,
            diagnostics.cgImageMS,
            diagnostics.cropMS,
            diagnostics.materializeMS,
            diagnostics.pixelBufferMS,
            diagnostics.encodeMS,
            diagnostics.encoderQueueMS,
            diagnostics.directFramePercent
        )
        fpsOverlayLabel.isHidden = false
    }

    private func updateDefaultLayoutModeForCurrentSize() {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        let defaultLayoutMode: MirrorLayoutMode = view.bounds.width > view.bounds.height
            ? .fitWidth
            : .fitHeight

        guard currentDefaultLayoutMode != defaultLayoutMode else { return }
        currentDefaultLayoutMode = defaultLayoutMode
        setLayoutMode(defaultLayoutMode)
    }

    private func updateChromeLayoutForCurrentSize() {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        let isLandscape = view.bounds.width > view.bounds.height
        toolbarView.usesLandscapeLayout = isLandscape
        mirrorLeadingConstraint?.constant = isLandscape ? max(16, view.safeAreaInsets.left + 16) : 0
        mirrorTrailingConstraint?.constant = isLandscape ? -max(16, view.safeAreaInsets.right + 16) : 0
        mirrorTopConstraint?.constant = isLandscape ? 0 : 76
        mirrorBottomConstraint?.constant = isLandscape ? 0 : -8
        developerActivityTopConstraint?.constant = isLandscape ? 12 : 72
        developerActivityLeadingConstraint?.constant = isLandscape ? max(84, view.safeAreaInsets.left + 84) : 16
        developerActivityTrailingConstraint?.constant = isLandscape ? -max(20, view.safeAreaInsets.right + 20) : -16
    }

    private func setLayoutMode(_ layoutMode: MirrorLayoutMode) {
        mirrorCanvasView.layoutMode = layoutMode
        toolbarView.setLayoutMode(layoutMode)
    }

    private func disconnectFromHost() {
        pendingResumeTarget = nil
        resumeDeadlineWorkItem?.cancel()
        endSessionBackgroundTask()
        ViewerResumeTarget.clear()
        isPresentingAppLauncher = false
        isAppLauncherPresented = false
        isWaitingForSelectedStream = false
        isDismissingLauncherForSelectedStream = false
        hasPendingSelectedStreamFrame = false
        mirrorCanvasView.defersAutomaticContentArrival = false
        streamClient.stop()
        updateFlowOverlays()
    }

    private func toggleStreamConnection() {
        switch streamClient.state {
        case .idle, .failed:
            streamClient.restart()
        case .searching, .connecting, .connected, .live:
            streamClient.stop()
        }
    }

    private func presentManualConnectError(_ message: String) {
        let alert = UIAlertController(title: "Cannot Connect", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentConnectionDiagnostics() {
        let report = streamClient.diagnosticsReport
        let alert = UIAlertController(
            title: "Connection Diagnostics",
            message: report,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = report
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

private final class HostConnectionOverlayView: UIView, UITextFieldDelegate {
    var hosts: [RemoteHostSummary] = [] {
        didSet { reloadHosts() }
    }

    var onHostSelected: (RemoteHostSummary) -> Void = { _ in }
    var onManualConnectRequested: (String, String?, String?) -> Void = { _, _, _ in }
    var onDiagnosticsTapped: () -> Void = {}

    private let dimmingView = UIView()
    private let panelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let hostsStackView = UIStackView()
    private let emptyStateLabel = UILabel()
    private let addHostButton = UIButton(type: .system)
    private let diagnosticsButton = UIButton(type: .system)
    private let manualOverlayView = UIView()
    private let manualPanelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let manualTitleLabel = UILabel()
    private let manualDetailLabel = UILabel()
    private let hostField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let cancelManualButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        reloadHosts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVisible(_ visible: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        guard visible != !isHidden || alpha != (visible ? 1 : 0) else {
            completion?()
            return
        }

        if visible {
            isHidden = false
        } else {
            hideManualConnect(animated: false)
            endEditing(true)
        }

        let updates = {
            self.alpha = visible ? 1 : 0
        }

        let animationCompletion: (Bool) -> Void = { _ in
            self.isHidden = !visible
            completion?()
        }

        if animated {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: updates,
                completion: animationCompletion
            )
        } else {
            updates()
            animationCompletion(true)
        }
    }

    private func configureSubviews() {
        alpha = 0
        isHidden = true

        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.20)

        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.clipsToBounds = true
        panelView.layer.cornerRadius = 28
        panelView.layer.cornerCurve = .continuous

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.text = "Choose Mac"

        detailLabel.font = .systemFont(ofSize: 15, weight: .medium)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        detailLabel.numberOfLines = 2
        detailLabel.text = "Pick a saved or nearby host, or connect to a new Mac by hostname."

        hostsStackView.axis = .vertical
        hostsStackView.spacing = 0

        emptyStateLabel.text = "No saved hosts yet."
        emptyStateLabel.textColor = UIColor.white.withAlphaComponent(0.64)
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)

        addHostButton.configuration = filledButtonConfiguration(title: "Connect to New Host", systemName: "plus")
        addHostButton.addAction(UIAction { [weak self] _ in
            self?.showManualConnect()
        }, for: .touchUpInside)

        diagnosticsButton.configuration = plainButtonConfiguration(title: "Diagnostics", systemName: "stethoscope")
        diagnosticsButton.addAction(UIAction { [weak self] _ in
            self?.onDiagnosticsTapped()
        }, for: .touchUpInside)

        configureTextField(hostField, placeholder: "Hostname or Tailscale IP")
        hostField.keyboardType = .URL
        hostField.returnKeyType = .go
        hostField.delegate = self
        hostField.inputAccessoryView = keyboardAccessoryView()

        connectButton.configuration = filledButtonConfiguration(title: "Connect", systemName: "network")
        connectButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            submitManualConnect()
        }, for: .touchUpInside)

        cancelManualButton.configuration = plainButtonConfiguration(title: "Cancel", systemName: "xmark")
        cancelManualButton.addAction(UIAction { [weak self] _ in
            self?.hideManualConnect(animated: true)
        }, for: .touchUpInside)

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .vertical
        headerStack.spacing = 6

        let buttonStack = UIStackView(arrangedSubviews: [addHostButton, diagnosticsButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually

        let contentStack = UIStackView(arrangedSubviews: [headerStack, hostsStackView, emptyStateLabel, buttonStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 18

        addSubview(dimmingView)
        addSubview(panelView)
        addSubview(manualOverlayView)
        panelView.contentView.addSubview(contentStack)
        configureManualOverlay()

        NSLayoutConstraint.activate([
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            panelView.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            panelView.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(lessThanOrEqualToConstant: 430),

            contentStack.leadingAnchor.constraint(equalTo: panelView.contentView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: panelView.contentView.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: panelView.contentView.topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(equalTo: panelView.contentView.bottomAnchor, constant: -20),

            addHostButton.heightAnchor.constraint(equalToConstant: 48),
            diagnosticsButton.heightAnchor.constraint(equalToConstant: 48),

            manualOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            manualOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            manualOverlayView.topAnchor.constraint(equalTo: topAnchor),
            manualOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureManualOverlay() {
        manualOverlayView.translatesAutoresizingMaskIntoConstraints = false
        manualOverlayView.alpha = 0
        manualOverlayView.isHidden = true
        manualOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.22)

        manualPanelView.translatesAutoresizingMaskIntoConstraints = false
        manualPanelView.clipsToBounds = true
        manualPanelView.layer.cornerRadius = 24
        manualPanelView.layer.cornerCurve = .continuous

        manualTitleLabel.text = "Connect to New Host"
        manualTitleLabel.textColor = .white
        manualTitleLabel.font = .systemFont(ofSize: 23, weight: .bold)

        manualDetailLabel.text = "Enter a hostname, MagicDNS name, or Tailscale IP. Successful direct hosts are saved here."
        manualDetailLabel.textColor = UIColor.white.withAlphaComponent(0.68)
        manualDetailLabel.font = .systemFont(ofSize: 14, weight: .medium)
        manualDetailLabel.numberOfLines = 0

        let buttonStack = UIStackView(arrangedSubviews: [cancelManualButton, connectButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually

        let stackView = UIStackView(arrangedSubviews: [manualTitleLabel, manualDetailLabel, hostField, buttonStack])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 12

        manualOverlayView.addSubview(manualPanelView)
        manualPanelView.contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            manualPanelView.leadingAnchor.constraint(greaterThanOrEqualTo: manualOverlayView.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            manualPanelView.trailingAnchor.constraint(lessThanOrEqualTo: manualOverlayView.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            manualPanelView.centerXAnchor.constraint(equalTo: manualOverlayView.centerXAnchor),
            manualPanelView.centerYAnchor.constraint(equalTo: manualOverlayView.centerYAnchor),
            manualPanelView.widthAnchor.constraint(lessThanOrEqualToConstant: 390),

            stackView.leadingAnchor.constraint(equalTo: manualPanelView.contentView.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(equalTo: manualPanelView.contentView.trailingAnchor, constant: -18),
            stackView.topAnchor.constraint(equalTo: manualPanelView.contentView.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(equalTo: manualPanelView.contentView.bottomAnchor, constant: -18),

            hostField.heightAnchor.constraint(equalToConstant: 48),
            cancelManualButton.heightAnchor.constraint(equalToConstant: 48),
            connectButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func configureTextField(_ textField: UITextField, placeholder: String) {
        textField.borderStyle = .none
        textField.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        textField.textColor = .white
        textField.tintColor = .white
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.clearButtonMode = .whileEditing
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.48)]
        )
        textField.layer.cornerRadius = 14
        textField.layer.cornerCurve = .continuous
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        textField.leftViewMode = .always
    }

    private func keyboardAccessoryView() -> UIView {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.barStyle = .black
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(dismissKeyboard)
            )
        ]
        return toolbar
    }

    private func submitManualConnect() {
        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            hostField.becomeFirstResponder()
            return
        }

        endEditing(true)
        hideManualConnect(animated: true)
        onManualConnectRequested(host, nil, nil)
    }

    @objc private func dismissKeyboard() {
        endEditing(true)
    }

    private func showManualConnect() {
        hostField.text = ""
        manualOverlayView.isHidden = false
        manualPanelView.transform = CGAffineTransform(translationX: 0, y: 18)
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.manualOverlayView.alpha = 1
            self.manualPanelView.transform = .identity
        } completion: { _ in
            self.hostField.becomeFirstResponder()
        }
    }

    private func hideManualConnect(animated: Bool) {
        endEditing(true)
        let updates = {
            self.manualOverlayView.alpha = 0
            self.manualPanelView.transform = CGAffineTransform(translationX: 0, y: 18)
        }
        let completion: (Bool) -> Void = { _ in
            self.manualOverlayView.isHidden = true
            self.manualPanelView.transform = .identity
        }

        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseIn],
                animations: updates,
                completion: completion
            )
        } else {
            updates()
            completion(true)
        }
    }

    private func reloadHosts() {
        hostsStackView.arrangedSubviews.forEach { view in
            hostsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let sortedHosts = hosts.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        emptyStateLabel.isHidden = !sortedHosts.isEmpty

        sortedHosts.enumerated().forEach { index, host in
            let button = UIButton(type: .system)
            button.configuration = hostButtonConfiguration(for: host)
            button.contentHorizontalAlignment = .fill
            button.addAction(UIAction { [weak self] _ in
                self?.onHostSelected(host)
            }, for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 66).isActive = true
            hostsStackView.addArrangedSubview(button)

            if index < sortedHosts.count - 1 {
                let separator = UIView()
                separator.backgroundColor = UIColor.white.withAlphaComponent(0.10)
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                hostsStackView.addArrangedSubview(separator)
            }
        }
    }

    private func hostButtonConfiguration(for host: RemoteHostSummary) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = host.isActive
            ? UIColor.systemBlue.withAlphaComponent(0.30)
            : UIColor.white.withAlphaComponent(0.08)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .medium
        configuration.image = UIImage(systemName: host.symbolName)
        configuration.imagePadding = 14
        configuration.title = host.name
        configuration.subtitle = host.detail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 18, weight: .semibold)
            return outgoing
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 12, weight: .medium)
            outgoing.foregroundColor = UIColor.white.withAlphaComponent(0.64)
            return outgoing
        }
        return configuration
    }

    private func filledButtonConfiguration(title: String, systemName: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: systemName)
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = .systemBlue
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        return configuration
    }

    private func plainButtonConfiguration(title: String, systemName: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: systemName)
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.10)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        return configuration
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitManualConnect()
        return true
    }
}

private final class LoadingInterstitialView: UIView {
    private let dimmingView = UIView()
    private let panelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != !isHidden || alpha != (visible ? 1 : 0) else { return }

        if visible {
            isHidden = false
            spinner.startAnimating()
        }

        let updates = {
            self.alpha = visible ? 1 : 0
            self.panelView.transform = visible ? .identity : CGAffineTransform(scaleX: 0.94, y: 0.94)
        }

        let completion: (Bool) -> Void = { _ in
            self.isHidden = !visible
            if !visible {
                self.spinner.stopAnimating()
            }
        }

        if animated {
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: updates,
                completion: completion
            )
        } else {
            updates()
            completion(true)
        }
    }

    private func configureSubviews() {
        alpha = 0
        isHidden = true

        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.10)

        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.clipsToBounds = true
        panelView.layer.cornerRadius = 24
        panelView.layer.cornerCurve = .continuous
        panelView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Loading..."
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center

        let stackView = UIStackView(arrangedSubviews: [spinner, titleLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 14

        addSubview(dimmingView)
        addSubview(panelView)
        panelView.contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(equalToConstant: 180),
            panelView.heightAnchor.constraint(equalToConstant: 132),

            stackView.centerXAnchor.constraint(equalTo: panelView.contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: panelView.contentView.centerYAnchor)
        ])
    }
}

private final class AppLauncherOverlayView: UIView {
    var onWindowSelected: (RemoteWindowSummary) -> Void = { _ in }
    var onRefreshTapped: () -> Void = {}

    private let dimmingView = UIView()
    private let panelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let emptyStateLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let refreshButton = UIButton(type: .system)
    private let collectionView: UICollectionView
    private let windowPanelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let windowIconView = UIImageView()
    private let windowTitleLabel = UILabel()
    private let windowTableView = UITableView(frame: .zero, style: .plain)
    private let backButton = UIButton(type: .system)
    private var groups: [RemoteApplicationWindowGroup] = []
    private var recentGroupIDs = Set<String>()
    private var selectedGroup: RemoteApplicationWindowGroup?
    private var visibilityGeneration = 0

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 24
        layout.sectionInset = UIEdgeInsets(top: 18, left: 18, bottom: 24, right: 18)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(groups: [RemoteApplicationWindowGroup], recentGroupIDs: Set<String>, isLoading: Bool) {
        self.recentGroupIDs = recentGroupIDs
        self.groups = groups.sorted { lhs, rhs in
            let lhsPriority = sortPriority(for: lhs)
            let rhsPriority = sortPriority(for: rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        collectionView.reloadData()
        loadingIndicator.isHidden = !isLoading || !self.groups.isEmpty
        if isLoading, self.groups.isEmpty {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
        emptyStateLabel.isHidden = isLoading || !self.groups.isEmpty
    }

    func setVisible(_ visible: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        visibilityGeneration += 1
        let generation = visibilityGeneration

        guard visible != !isHidden || alpha != (visible ? 1 : 0) else {
            completion?()
            return
        }

        if visible {
            isHidden = false
        } else {
            hideWindowChooser(animated: false)
        }

        let updates = {
            self.alpha = visible ? 1 : 0
        }

        let animationCompletion: (Bool) -> Void = { _ in
            guard generation == self.visibilityGeneration else { return }
            self.isHidden = !visible
            completion?()
        }

        if animated {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: updates,
                completion: animationCompletion
            )
        } else {
            updates()
            animationCompletion(true)
        }
    }

    private func configureSubviews() {
        alpha = 0
        isHidden = true

        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.12)

        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.clipsToBounds = true
        panelView.layer.cornerRadius = 28
        panelView.layer.cornerCurve = .continuous

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Choose App"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 27, weight: .bold)
        titleLabel.textAlignment = .center

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Simulator and recent apps stay near the top."
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.66)
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textAlignment = .center

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.configuration = {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "arrow.clockwise")
            configuration.baseForegroundColor = .white
            return configuration
        }()
        refreshButton.addAction(UIAction { [weak self] _ in
            self?.onRefreshTapped()
        }, for: .touchUpInside)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.register(AppLauncherCell.self, forCellWithReuseIdentifier: AppLauncherCell.reuseIdentifier)

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.text = "No streamable apps found.\nOpen an app on your Mac, then refresh."
        emptyStateLabel.textColor = UIColor.white.withAlphaComponent(0.66)
        emptyStateLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.isHidden = true

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true

        addSubview(dimmingView)
        addSubview(panelView)
        addSubview(windowPanelView)
        panelView.contentView.addSubview(titleLabel)
        panelView.contentView.addSubview(subtitleLabel)
        panelView.contentView.addSubview(refreshButton)
        panelView.contentView.addSubview(collectionView)
        panelView.contentView.addSubview(emptyStateLabel)
        panelView.contentView.addSubview(loadingIndicator)

        configureWindowPanel()

        NSLayoutConstraint.activate([
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            panelView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            panelView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            panelView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 96),
            panelView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),

            titleLabel.topAnchor.constraint(equalTo: panelView.contentView.topAnchor, constant: 22),
            titleLabel.centerXAnchor.constraint(equalTo: panelView.contentView.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            subtitleLabel.leadingAnchor.constraint(equalTo: panelView.contentView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: panelView.contentView.trailingAnchor, constant: -20),

            refreshButton.trailingAnchor.constraint(equalTo: panelView.contentView.trailingAnchor, constant: -14),
            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 44),
            refreshButton.heightAnchor.constraint(equalToConstant: 44),

            collectionView.leadingAnchor.constraint(equalTo: panelView.contentView.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: panelView.contentView.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            collectionView.bottomAnchor.constraint(equalTo: panelView.contentView.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: panelView.contentView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: panelView.contentView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(equalTo: panelView.contentView.leadingAnchor, constant: 28),
            emptyStateLabel.trailingAnchor.constraint(equalTo: panelView.contentView.trailingAnchor, constant: -28),

            loadingIndicator.centerXAnchor.constraint(equalTo: panelView.contentView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: panelView.contentView.centerYAnchor)
        ])
    }

    private func configureWindowPanel() {
        windowPanelView.translatesAutoresizingMaskIntoConstraints = false
        windowPanelView.alpha = 0
        windowPanelView.isHidden = true
        windowPanelView.clipsToBounds = true
        windowPanelView.layer.cornerRadius = 28
        windowPanelView.layer.cornerCurve = .continuous

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.configuration = {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "chevron.left")
            configuration.baseForegroundColor = .white
            return configuration
        }()
        backButton.addAction(UIAction { [weak self] _ in
            self?.hideWindowChooser(animated: true)
        }, for: .touchUpInside)

        windowIconView.translatesAutoresizingMaskIntoConstraints = false
        windowIconView.contentMode = .scaleAspectFit
        windowIconView.layer.cornerRadius = 10
        windowIconView.layer.cornerCurve = .continuous
        windowIconView.clipsToBounds = true

        windowTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        windowTitleLabel.text = "Choose Window"
        windowTitleLabel.textColor = .white
        windowTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        windowTableView.translatesAutoresizingMaskIntoConstraints = false
        windowTableView.backgroundColor = .clear
        windowTableView.separatorColor = UIColor.white.withAlphaComponent(0.16)
        windowTableView.dataSource = self
        windowTableView.delegate = self
        windowTableView.register(UITableViewCell.self, forCellReuseIdentifier: "WindowCell")

        windowPanelView.contentView.addSubview(backButton)
        windowPanelView.contentView.addSubview(windowIconView)
        windowPanelView.contentView.addSubview(windowTitleLabel)
        windowPanelView.contentView.addSubview(windowTableView)

        NSLayoutConstraint.activate([
            windowPanelView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            windowPanelView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            windowPanelView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            windowPanelView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.55),

            backButton.leadingAnchor.constraint(equalTo: windowPanelView.contentView.leadingAnchor, constant: 12),
            backButton.topAnchor.constraint(equalTo: windowPanelView.contentView.topAnchor, constant: 12),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),

            windowIconView.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            windowIconView.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            windowIconView.widthAnchor.constraint(equalToConstant: 32),
            windowIconView.heightAnchor.constraint(equalToConstant: 32),

            windowTitleLabel.leadingAnchor.constraint(equalTo: windowIconView.trailingAnchor, constant: 10),
            windowTitleLabel.trailingAnchor.constraint(equalTo: windowPanelView.contentView.trailingAnchor, constant: -18),
            windowTitleLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            windowTableView.leadingAnchor.constraint(equalTo: windowPanelView.contentView.leadingAnchor),
            windowTableView.trailingAnchor.constraint(equalTo: windowPanelView.contentView.trailingAnchor),
            windowTableView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 10),
            windowTableView.bottomAnchor.constraint(equalTo: windowPanelView.contentView.bottomAnchor, constant: -10),
            windowTableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 132)
        ])
    }

    private func showWindowChooser(for group: RemoteApplicationWindowGroup) {
        selectedGroup = group
        windowIconView.image = group.iconImage ?? group.fallbackImage
        windowTitleLabel.text = group.name
        windowTableView.reloadData()
        windowPanelView.isHidden = false
        windowPanelView.transform = CGAffineTransform(translationX: 0, y: 18)
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.windowPanelView.alpha = 1
            self.windowPanelView.transform = .identity
        }
    }

    private func hideWindowChooser(animated: Bool) {
        selectedGroup = nil
        let updates = {
            self.windowPanelView.alpha = 0
            self.windowPanelView.transform = CGAffineTransform(translationX: 0, y: 18)
        }
        let completion: (Bool) -> Void = { _ in
            self.windowPanelView.isHidden = true
            self.windowPanelView.transform = .identity
        }

        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseIn],
                animations: updates,
                completion: completion
            )
        } else {
            updates()
            completion(true)
        }
    }

    private func sortPriority(for group: RemoteApplicationWindowGroup) -> Int {
        if group.containsSimulator { return 0 }
        if recentGroupIDs.contains(group.id) { return 1 }
        return 2
    }
}

extension AppLauncherOverlayView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        groups.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: AppLauncherCell.reuseIdentifier,
            for: indexPath
        ) as? AppLauncherCell else {
            return UICollectionViewCell()
        }

        let group = groups[indexPath.item]
        cell.configure(
            group: group,
            isRecent: recentGroupIDs.contains(group.id)
        )
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let group = groups[indexPath.item]
        guard group.windows.count > 1 else {
            if let window = group.windows.first {
                onWindowSelected(window)
            }
            return
        }

        showWindowChooser(for: group)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let availableWidth = collectionView.bounds.width - 36
        let targetColumns: CGFloat = collectionView.bounds.width > 600 ? 6 : 4
        let spacing: CGFloat = 12 * (targetColumns - 1)
        let width = floor((availableWidth - spacing) / targetColumns)
        return CGSize(width: max(72, width), height: 118)
    }
}

extension AppLauncherOverlayView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        selectedGroup?.windows.count ?? 0
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        58
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "WindowCell", for: indexPath)
        guard let window = selectedGroup?.windows[indexPath.row] else { return cell }

        var content = UIListContentConfiguration.subtitleCell()
        content.text = window.title
        content.secondaryText = window.subtitle
        content.image = selectedGroup?.iconImage ?? selectedGroup?.fallbackImage
        content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        content.textProperties.color = .white
        content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
        content.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.58)
        content.secondaryTextProperties.font = .systemFont(ofSize: 12, weight: .medium)
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.selectedBackgroundView = {
            let view = UIView()
            view.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            return view
        }()
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let window = selectedGroup?.windows[indexPath.row] else { return }
        onWindowSelected(window)
    }
}

private final class AppLauncherCell: UICollectionViewCell {
    static let reuseIdentifier = "AppLauncherCell"

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let badgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(group: RemoteApplicationWindowGroup, isRecent: Bool) {
        iconView.image = group.iconImage ?? group.fallbackImage
        iconView.tintColor = .white
        nameLabel.text = group.name
        if group.containsSimulator {
            badgeLabel.text = "SIM"
            badgeLabel.isHidden = false
        } else if isRecent {
            badgeLabel.text = "RECENT"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    private func configureSubviews() {
        contentView.backgroundColor = .clear

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 14
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.82

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.84)
        badgeLabel.font = .systemFont(ofSize: 8, weight: .bold)
        badgeLabel.textAlignment = .center
        badgeLabel.layer.cornerRadius = 6
        badgeLabel.layer.cornerCurve = .continuous
        badgeLabel.clipsToBounds = true

        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 58),
            iconView.heightAnchor.constraint(equalToConstant: 58),

            badgeLabel.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            badgeLabel.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -5),
            badgeLabel.heightAnchor.constraint(equalToConstant: 14),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),

            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 9)
        ])
    }
}

private final class ViewerToolbarView: UIView {
    var streamState: RemoteFrameStreamState = .idle {
        didSet {
            updateStatusColor()
            updateConnectionButton()
            updateSettingsMenu()
        }
    }

    var isKeyboardPresented = false {
        didSet { updateKeyboardButton() }
    }

    var onAppLauncherTapped: () -> Void = {}
    var onKeyboardTapped: () -> Void = {}
    var onDisconnectTapped: () -> Void = {}
    var onDiagnosticsTapped: () -> Void = {}
    var onVideoDebugToggled: () -> Void = {}
    var onLayoutModeChanged: (MirrorLayoutMode) -> Void = { _ in }
    var windows: [RemoteWindowSummary] = []

    private var layoutMode: MirrorLayoutMode = .fitHeight
    var isVideoDebugEnabled = false {
        didSet {
            guard isVideoDebugEnabled != oldValue else { return }
            updateSettingsMenu()
        }
    }
    private let exitButton = ViewerToolbarView.makeButton(systemName: "rectangle.portrait.and.arrow.right")
    private let keyboardButton = ViewerToolbarView.makeButton(systemName: "keyboard")
    private let settingsButton = ViewerToolbarView.makeButton(systemName: "gearshape")
    private let statusDotView = UIView()
    private let rightStackView = UIStackView()
    var usesLandscapeLayout = false {
        didSet {
            guard usesLandscapeLayout != oldValue else { return }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        configureActions()
        updateStatusColor()
        updateConnectionButton()
        updateKeyboardButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        isUserInteractionEnabled = true

        exitButton.translatesAutoresizingMaskIntoConstraints = false
        rightStackView.translatesAutoresizingMaskIntoConstraints = false
        rightStackView.alignment = .center
        rightStackView.distribution = .fill
        rightStackView.spacing = 8

        rightStackView.addArrangedSubview(keyboardButton)
        rightStackView.addArrangedSubview(settingsButton)

        addSubview(exitButton)
        addSubview(rightStackView)

        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        statusDotView.layer.cornerRadius = 4
        statusDotView.layer.borderWidth = 1
        statusDotView.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        settingsButton.addSubview(statusDotView)

        NSLayoutConstraint.activate([
            statusDotView.leadingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: 8),
            statusDotView.topAnchor.constraint(equalTo: settingsButton.topAnchor, constant: 8),
            statusDotView.widthAnchor.constraint(equalToConstant: 8),
            statusDotView.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    private func configureActions() {
        exitButton.addAction(UIAction { [weak self] _ in
            self?.onAppLauncherTapped()
        }, for: .touchUpInside)

        keyboardButton.addAction(UIAction { [weak self] _ in
            self?.onKeyboardTapped()
        }, for: .touchUpInside)

        settingsButton.showsMenuAsPrimaryAction = true
        updateSettingsMenu()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if usesLandscapeLayout {
            let leftInset = max(20, safeAreaInsets.left + 20)
            let railCenterY = bounds.height / 2

            exitButton.transform = CGAffineTransform(rotationAngle: .pi / 2)
            keyboardButton.transform = CGAffineTransform(rotationAngle: .pi / 2)
            settingsButton.transform = CGAffineTransform(rotationAngle: .pi / 2)

            exitButton.frame = CGRect(x: leftInset, y: railCenterY - 22, width: 44, height: 44)
            rightStackView.axis = .vertical
            rightStackView.frame = CGRect(x: leftInset, y: railCenterY + 52, width: 44, height: 96)
        } else {
            exitButton.transform = .identity
            keyboardButton.transform = .identity
            settingsButton.transform = .identity

            exitButton.frame = CGRect(x: 20, y: 20, width: 44, height: 44)
            rightStackView.axis = .horizontal
            rightStackView.frame = CGRect(x: bounds.width - 116, y: 20, width: 96, height: 44)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        [exitButton, keyboardButton, settingsButton].contains { button in
            button.point(inside: convert(point, to: button), with: event)
        }
    }

    private func updateSettingsMenu() {
        var menus: [UIMenuElement] = []

        if streamState.hasVisibleApp {
            menus.append(
                UIMenu(
                    title: "View",
                    options: .displayInline,
                    children: layoutMenuActions()
                )
            )
            menus.append(
                UIMenu(
                    title: "Debug",
                    options: .displayInline,
                    children: debugMenuActions()
                )
            )
        }

        menus.append(
            UIMenu(
                title: "Connection",
                options: .displayInline,
                children: settingsConnectionActions()
            )
        )

        settingsButton.menu = UIMenu(children: menus)
    }

    private func layoutMenuActions() -> [UIMenuElement] {
        MirrorLayoutMode.allCases.map { mode in
            UIAction(
                title: mode.title,
                image: UIImage(systemName: mode.symbolName),
                state: mode == layoutMode ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                setLayoutMode(mode)
                onLayoutModeChanged(mode)
            }
        }
    }

    private func debugMenuActions() -> [UIMenuElement] {
        [
            UIAction(
                title: "Video Debug",
                image: UIImage(systemName: "chart.line.uptrend.xyaxis"),
                state: isVideoDebugEnabled ? .on : .off
            ) { [weak self] _ in
                self?.onVideoDebugToggled()
            }
        ]
    }

    private func settingsConnectionActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []

        if streamState.canDisconnect {
            actions.append(
                UIAction(
                    title: "Disconnect",
                    image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.onDisconnectTapped()
                }
            )
        }

        actions.append(
            UIAction(
                title: "Diagnostics",
                image: UIImage(systemName: "stethoscope")
            ) { [weak self] _ in
                self?.onDiagnosticsTapped()
            }
        )

        return actions
    }

    func setLayoutMode(_ mode: MirrorLayoutMode) {
        guard layoutMode != mode else { return }
        layoutMode = mode
        updateSettingsMenu()
    }

    private func updateStatusColor() {
        statusDotView.backgroundColor = streamState.indicatorColor
    }

    private func updateConnectionButton() {
        let systemName: String

        switch streamState {
        case .idle, .failed:
            systemName = "arrow.clockwise"
        case .searching, .connecting:
            systemName = "antenna.radiowaves.left.and.right"
        case .connected, .live:
            systemName = "square.grid.2x2"
        }

        exitButton.setImage(UIImage(systemName: systemName), for: .normal)
    }

    private func updateKeyboardButton() {
        keyboardButton.backgroundColor = isKeyboardPresented
            ? UIColor.systemBlue.withAlphaComponent(0.48)
            : UIColor.black.withAlphaComponent(0.18)
    }

    private static func makeButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.contentVerticalAlignment = .center
        button.contentHorizontalAlignment = .center
        button.imageView?.contentMode = .scaleAspectFit
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .medium),
            forImageIn: .normal
        )

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])

        return button
    }
}

private struct RemoteApplicationWindowGroup {
    var id: String
    var name: String
    var iconPNGData: Data?
    var windows: [RemoteWindowSummary]

    var containsSimulator: Bool {
        windows.contains(where: \.isSimulator)
    }

    var iconImage: UIImage? {
        guard let iconPNGData else { return nil }
        return UIImage(data: iconPNGData)
    }

    var fallbackImage: UIImage? {
        UIImage(systemName: containsSimulator ? "iphone.gen3" : "app.fill")
    }

    static func make(from windows: [RemoteWindowSummary]) -> [RemoteApplicationWindowGroup] {
        Dictionary(grouping: windows) { $0.appGroupID }
            .values
            .map { windows in
                let sortedWindows = windows.sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                let firstWindow = sortedWindows[0]
                return RemoteApplicationWindowGroup(
                    id: firstWindow.appGroupID,
                    name: firstWindow.displayAppName,
                    iconPNGData: sortedWindows.first(where: { $0.appIconPNGData != nil })?.appIconPNGData,
                    windows: sortedWindows
                )
            }
            .sorted { lhs, rhs in
                if lhs.containsSimulator != rhs.containsSimulator {
                    return lhs.containsSimulator
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

private enum MirrorContentTransitionStyle: Equatable {
    case normal
    case switching(direction: CGFloat)
}

private final class MirrorCanvasView: UIView {
    var image: UIImage? {
        didSet {
            let hadContent = oldValue != nil || videoSourceSize != nil
            let isDeparting = hadContent && image == nil && videoSourceSize == nil

            if image != nil {
                isSynchronizingRenderMode = true
                videoSourceSize = nil
                isSynchronizingRenderMode = false
                videoRenderView.flush()
            }

            if !isDeparting {
                imageView.image = image
            }

            finishContentUpdate(hadContent: hadContent, isDeparting: isDeparting)
        }
    }

    var videoSourceSize: CGSize? {
        didSet {
            let hadContent = image != nil || oldValue != nil
            let isDeparting = hadContent && image == nil && videoSourceSize == nil

            if videoSourceSize != nil {
                if oldValue != videoSourceSize {
                    videoRenderView.flush()
                }
                imageView.image = nil
            } else if !isDeparting {
                videoRenderView.flush()
            }

            if isSynchronizingRenderMode {
                updateContentVisibility()
                updateScrollableContent(resetOffsetIfNeeded: false)
            } else {
                finishContentUpdate(hadContent: hadContent, isDeparting: isDeparting)
            }
        }
    }

    var maskImage: UIImage? {
        didSet {
            updateImageMask()
        }
    }

    var layoutMode: MirrorLayoutMode = .fitHeight {
        didSet {
            updateScrollableContent(resetOffsetIfNeeded: true)
        }
    }
    var usesTouchDragForSingleFingerPan = false {
        didSet {
            pointerSurfaceView.usesTouchDragForSingleFingerPan = usesTouchDragForSingleFingerPan
        }
    }
    var defersAutomaticContentArrival = false

    func prepareForAppSwitch() {
        nextSwitchDirection *= -1
        pendingTransitionStyle = .switching(direction: nextSwitchDirection)
    }

    func departForAppSwitch(completion: @escaping () -> Void) {
        prepareForAppSwitch()
        departureCompletion = completion
        clearsContentAfterDeparture = true

        if image != nil {
            image = nil
        } else if videoSourceSize != nil {
            videoSourceSize = nil
        } else {
            runDepartureCompletion()
        }
    }

    func departForAppLauncher(completion: @escaping () -> Void) {
        prepareForAppSwitch()
        departureCompletion = completion
        clearsContentAfterDeparture = false

        guard hasContent else {
            runDepartureCompletion()
            return
        }

        animateContentDeparture()
    }

    func revealDeferredContentArrivalForAppSwitch() {
        guard hasContent else {
            defersAutomaticContentArrival = false
            return
        }

        defersAutomaticContentArrival = false
        animateContentArrival()
    }

    var onPointerEvent: (RemoteControlMessage.Kind, CGPoint) -> Void = { _, _ in }
    var onScrollEvent: (CGPoint, CGPoint, RemoteControlMessage.ScrollPhase) -> Void = { _, _, _ in }

    private let scrollView = TwoFingerScrollView()
    private let contentView = UIView()
    private let renderPivotView = UIView()
    private let renderSurfaceView = UIView()
    private let shadowView = UIView()
    private let videoRenderView = VideoRenderView()
    private let imageView = UIImageView()
    private let imageMaskLayer = CALayer()
    private let pointerSurfaceView = PointerSurfaceView()
    private var lastShadowBounds = CGRect.zero
    private var lastContentSize = CGSize.zero
    private var isSynchronizingRenderMode = false
    private var isAnimatingDeparture = false
    private var departureCompletion: (() -> Void)?
    private var clearsContentAfterDeparture = true
    private var pendingTransitionStyle: MirrorContentTransitionStyle = .normal
    private var nextSwitchDirection: CGFloat = 1
    private var transitionGeneration = 0
    private let viewportPadding: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = true
        scrollView.decelerationRate = .normal
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        scrollView.clipsToBounds = true

        contentView.backgroundColor = .clear
        contentView.isUserInteractionEnabled = true

        renderPivotView.backgroundColor = .clear
        renderPivotView.isUserInteractionEnabled = false
        renderPivotView.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        renderPivotView.layer.allowsGroupOpacity = true
        renderPivotView.layer.isDoubleSided = false
        renderPivotView.layer.rasterizationScale = UIScreen.main.scale

        renderSurfaceView.backgroundColor = .clear
        renderSurfaceView.isUserInteractionEnabled = false
        renderSurfaceView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        renderSurfaceView.layer.allowsGroupOpacity = true
        renderSurfaceView.layer.isDoubleSided = false

        shadowView.isUserInteractionEnabled = false
        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.28
        shadowView.layer.shadowRadius = 18
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 10)
        shadowView.layer.shouldRasterize = true
        shadowView.layer.rasterizationScale = UIScreen.main.scale

        videoRenderView.clipsToBounds = true
        videoRenderView.layer.cornerRadius = 8
        videoRenderView.layer.cornerCurve = .continuous
        videoRenderView.isUserInteractionEnabled = false
        videoRenderView.isHidden = true

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.layer.cornerCurve = .continuous
        imageView.isUserInteractionEnabled = false

        pointerSurfaceView.onPointerEvent = { [weak self] kind, point in
            self?.onPointerEvent(kind, point)
        }
        pointerSurfaceView.onScrollEvent = { [weak self] point, delta, phase in
            self?.onScrollEvent(point, delta, phase)
        }

        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(renderPivotView)
        renderPivotView.addSubview(renderSurfaceView)
        renderSurfaceView.addSubview(shadowView)
        renderSurfaceView.addSubview(videoRenderView)
        renderSurfaceView.addSubview(imageView)
        contentView.addSubview(pointerSurfaceView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrollableContent(resetOffsetIfNeeded: false)
    }

    @discardableResult
    func enqueueVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        imageView.image = nil
        let didEnqueue = videoRenderView.enqueue(sampleBuffer)
        updateContentVisibility()
        return didEnqueue
    }

    private func finishContentUpdate(hadContent: Bool, isDeparting: Bool) {
        let hasUpdatedContent = hasContent

        if isDeparting {
            animateContentDeparture()
            return
        }

        updateContentVisibility()
        updateScrollableContent(resetOffsetIfNeeded: false)

        if !hadContent && hasUpdatedContent && !defersAutomaticContentArrival {
            animateContentArrival()
        }
    }

    private func updateScrollableContent(resetOffsetIfNeeded: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let previousContentSize = scrollView.contentSize
        let previousOffset = scrollView.contentOffset
        let size = renderedSize
        let contentSize = CGSize(
            width: scrollsHorizontally ? max(bounds.width, size.width + viewportPadding * 2) : bounds.width,
            height: scrollsVertically ? max(bounds.height, size.height + viewportPadding * 2) : bounds.height
        )
        let frame = CGRect(
            x: scrollsHorizontally ? viewportPadding : (contentSize.width - size.width) / 2,
            y: scrollsVertically ? viewportPadding : (contentSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        scrollView.frame = bounds
        scrollView.contentSize = contentSize
        scrollView.alwaysBounceHorizontal = scrollsHorizontally
        scrollView.alwaysBounceVertical = scrollsVertically
        scrollView.isDirectionalLockEnabled = true
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        renderPivotView.bounds = CGRect(origin: .zero, size: frame.size)
        renderPivotView.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        renderPivotView.layer.position = CGPoint(x: frame.midX, y: frame.maxY)
        renderSurfaceView.bounds = renderPivotView.bounds
        renderSurfaceView.layer.position = CGPoint(
            x: renderPivotView.bounds.midX,
            y: renderPivotView.bounds.midY
        )
        shadowView.frame = renderSurfaceView.bounds
        videoRenderView.frame = renderSurfaceView.bounds
        imageView.frame = renderSurfaceView.bounds
        updateImageMask()
        pointerSurfaceView.frame = contentView.bounds
        pointerSurfaceView.imageFrame = hasContent ? frame : nil

        if shadowView.bounds != lastShadowBounds {
            lastShadowBounds = shadowView.bounds
            shadowView.layer.shadowPath = UIBezierPath(
                roundedRect: shadowView.bounds,
                cornerRadius: renderCornerRadius
            ).cgPath
        }

        CATransaction.commit()

        let shouldResetOffset = resetOffsetIfNeeded || previousContentSize == .zero
        if shouldResetOffset {
            scrollView.setContentOffset(.zero, animated: false)
        } else if previousContentSize != contentSize {
            scrollView.setContentOffset(
                clampedContentOffset(previousOffset, contentSize: contentSize),
                animated: false
            )
        }
    }

    private func updateImageMask() {
        guard !isAnimatingDeparture else { return }

        imageView.layer.mask = nil
        videoRenderView.layer.mask = nil

        guard let maskImage, let targetLayer = activeRenderLayer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageMaskLayer.frame = targetLayer.bounds
        imageMaskLayer.contents = maskImage.cgImage
        imageMaskLayer.contentsGravity = .resize
        targetLayer.mask = imageMaskLayer
        CATransaction.commit()
    }

    private func updateContentVisibility() {
        let isDisplayingVideo = videoSourceSize != nil
        renderPivotView.isHidden = !hasContent
        renderSurfaceView.isHidden = !hasContent
        videoRenderView.isHidden = !isDisplayingVideo
        imageView.isHidden = isDisplayingVideo || imageView.image == nil
    }

    private func animateContentArrival() {
        transitionGeneration += 1
        let generation = transitionGeneration
        let style = pendingTransitionStyle
        let reducedMotion = UIAccessibility.isReduceMotionEnabled

        renderPivotView.isHidden = false
        renderSurfaceView.isHidden = false
        applyLayerState(
            to: renderPivotView,
            alpha: 0,
            transform: reducedMotion ? CATransform3DIdentity : bottomHingeTransform(for: style)
        )
        applyAffineState(
            to: renderSurfaceView,
            alpha: 1,
            transform: reducedMotion ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        )
        pointerSurfaceView.isUserInteractionEnabled = false

        UIView.animate(
            withDuration: reducedMotion ? 0.18 : arrivalDuration(for: style),
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                self.renderPivotView.alpha = 1
                self.renderPivotView.layer.transform = CATransform3DIdentity
                self.renderSurfaceView.transform = .identity
            },
            completion: { _ in
                guard generation == self.transitionGeneration else { return }
                self.renderPivotView.alpha = 1
                self.renderPivotView.layer.transform = CATransform3DIdentity
                self.renderSurfaceView.alpha = 1
                self.renderSurfaceView.transform = .identity
                self.pointerSurfaceView.isUserInteractionEnabled = true
                self.pendingTransitionStyle = .normal
                self.updateContentVisibility()
            }
        )
    }

    private func animateContentDeparture() {
        transitionGeneration += 1
        let generation = transitionGeneration
        let style = pendingTransitionStyle
        let reducedMotion = UIAccessibility.isReduceMotionEnabled

        isAnimatingDeparture = true
        applyLayerState(
            to: renderPivotView,
            alpha: renderPivotView.alpha,
            transform: CATransform3DIdentity
        )
        applyAffineState(to: renderSurfaceView, alpha: 1, transform: .identity)
        setRenderRasterizationEnabled(true)
        pointerSurfaceView.isUserInteractionEnabled = false

        guard !renderPivotView.isHidden else {
            guard generation == transitionGeneration else { return }
            isAnimatingDeparture = false
            if clearsContentAfterDeparture {
                clearDepartedContent()
            }
            clearsContentAfterDeparture = true
            setRenderRasterizationEnabled(false)
            pointerSurfaceView.isUserInteractionEnabled = true
            updateContentVisibility()
            updateScrollableContent(resetOffsetIfNeeded: false)
            runDepartureCompletion()
            return
        }

        UIView.animate(
            withDuration: reducedMotion ? 0.16 : departureDuration(for: style),
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                self.renderPivotView.alpha = 0
                self.renderPivotView.layer.transform = reducedMotion ? CATransform3DIdentity : self.bottomHingeTransform(for: style)
                self.renderSurfaceView.transform = reducedMotion ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
            },
            completion: { _ in
                guard generation == self.transitionGeneration else {
                    let shouldCompletePreservedDeparture = !self.clearsContentAfterDeparture
                    self.isAnimatingDeparture = false
                    self.clearsContentAfterDeparture = true
                    self.renderPivotView.alpha = 1
                    self.renderPivotView.layer.transform = CATransform3DIdentity
                    self.renderSurfaceView.alpha = 1
                    self.renderSurfaceView.transform = .identity
                    self.setRenderRasterizationEnabled(false)
                    self.updateImageMask()
                    if shouldCompletePreservedDeparture {
                        self.pointerSurfaceView.isUserInteractionEnabled = true
                        self.updateContentVisibility()
                        self.updateScrollableContent(resetOffsetIfNeeded: false)
                        self.runDepartureCompletion()
                    }
                    return
                }
                self.isAnimatingDeparture = false
                if self.clearsContentAfterDeparture {
                    self.clearDepartedContent()
                }
                self.clearsContentAfterDeparture = true
                self.renderPivotView.alpha = 1
                self.renderPivotView.layer.transform = CATransform3DIdentity
                self.renderSurfaceView.alpha = 1
                self.renderSurfaceView.transform = .identity
                self.setRenderRasterizationEnabled(false)
                self.pointerSurfaceView.isUserInteractionEnabled = true
                self.updateContentVisibility()
                self.updateScrollableContent(resetOffsetIfNeeded: false)
                self.runDepartureCompletion()
            }
        )
    }

    private func runDepartureCompletion() {
        let completion = departureCompletion
        departureCompletion = nil
        completion?()
    }

    private func clearDepartedContent() {
        imageView.image = nil
        videoRenderView.flush()
        updateImageMask()
    }

    private func setRenderRasterizationEnabled(_ isEnabled: Bool) {
        renderPivotView.layer.shouldRasterize = isEnabled
    }

    private func applyLayerState(to view: UIView, alpha: CGFloat, transform: CATransform3D) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.alpha = alpha
        view.transform = .identity
        view.layer.transform = transform
        CATransaction.commit()
    }

    private func applyAffineState(to view: UIView, alpha: CGFloat, transform: CGAffineTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.alpha = alpha
        view.layer.transform = CATransform3DIdentity
        view.transform = transform
        CATransaction.commit()
    }

    private func bottomHingeTransform(for style: MirrorContentTransitionStyle) -> CATransform3D {
        let angle: CGFloat

        switch style {
        case .normal, .switching:
            angle = 25 * .pi / 180
        }

        var transform = CATransform3DIdentity
        transform.m34 = -1 / 700
        return CATransform3DRotate(transform, angle, 1, 0, 0)
    }

    private func arrivalDuration(for style: MirrorContentTransitionStyle) -> TimeInterval {
        switch style {
        case .normal, .switching:
            return 0.25
        }
    }

    private func departureDuration(for style: MirrorContentTransitionStyle) -> TimeInterval {
        switch style {
        case .normal, .switching:
            return 0.25
        }
    }

    private func clampedContentOffset(_ offset: CGPoint, contentSize: CGSize) -> CGPoint {
        CGPoint(
            x: scrollsHorizontally ? min(max(offset.x, 0), max(contentSize.width - bounds.width, 0)) : 0,
            y: scrollsVertically ? min(max(offset.y, 0), max(contentSize.height - bounds.height, 0)) : 0
        )
    }

    private var sourceSize: CGSize {
        if let videoSourceSize, videoSourceSize.width > 0, videoSourceSize.height > 0 {
            return videoSourceSize
        }

        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: 960, height: 640)
        }

        return image.size
    }

    private var renderedSize: CGSize {
        ViewerGeometry.renderedSize(
            sourceSize: sourceSize,
            availableSize: bounds.size,
            layoutMode: layoutMode
        )
    }

    private var imageFrame: CGRect {
        let size = renderedSize
        let contentSize = CGSize(
            width: scrollsHorizontally ? max(bounds.width, size.width + viewportPadding * 2) : bounds.width,
            height: scrollsVertically ? max(bounds.height, size.height + viewportPadding * 2) : bounds.height
        )
        return CGRect(
            x: scrollsHorizontally ? viewportPadding : (contentSize.width - size.width) / 2,
            y: scrollsVertically ? viewportPadding : (contentSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private var hasContent: Bool {
        image != nil || videoSourceSize != nil
    }

    private var activeRenderLayer: CALayer? {
        if videoSourceSize != nil {
            return videoRenderView.layer
        }

        if image != nil {
            return imageView.layer
        }

        return nil
    }

    private var renderCornerRadius: CGFloat {
        videoRenderView.layer.cornerRadius
    }

    private var scrollsHorizontally: Bool {
        switch layoutMode {
        case .fitHeight:
            return renderedSize.width > bounds.width
        case .fitWidth:
            return false
        case .readableZoom:
            return renderedSize.width > bounds.width
        }
    }

    private var scrollsVertically: Bool {
        switch layoutMode {
        case .fitHeight:
            return false
        case .fitWidth:
            return renderedSize.height > bounds.height
        case .readableZoom:
            return renderedSize.height > bounds.height
        }
    }
}

extension MirrorCanvasView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let currentOffset = scrollView.contentOffset
        let axisLockedOffset = CGPoint(
            x: scrollsHorizontally ? currentOffset.x : 0,
            y: scrollsVertically ? currentOffset.y : 0
        )

        if axisLockedOffset != currentOffset {
            scrollView.contentOffset = axisLockedOffset
        }

        pointerSurfaceView.cancelPointerIfNeeded()
    }
}

private final class TwoFingerScrollView: UIScrollView, UIGestureRecognizerDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

private final class VideoRenderView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        displayLayer.backgroundColor = UIColor.clear.cgColor
        displayLayer.videoGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }

        guard displayLayer.isReadyForMoreMediaData else { return false }
        displayLayer.enqueue(sampleBuffer)
        return true
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}

private final class PointerSurfaceView: UIView {
    var imageFrame: CGRect?
    var usesTouchDragForSingleFingerPan = false
    var onPointerEvent: (RemoteControlMessage.Kind, CGPoint) -> Void = { _, _ in }
    var onScrollEvent: (CGPoint, CGPoint, RemoteControlMessage.ScrollPhase) -> Void = { _, _, _ in }

    private enum PointerIntent {
        case idle
        case pendingTap
        case scrolling
        case dragging
    }

    private let dragStartThreshold: CGFloat = 7
    private let holdDownDelay: TimeInterval = 0.32
    private var pointerIntent: PointerIntent = .idle
    private var initialTouchLocation: CGPoint?
    private var initialPointerPoint: CGPoint?
    private var lastTouchLocation: CGPoint?
    private var lastTouchTimestamp: TimeInterval?
    private var lastScrollVelocity = CGPoint.zero
    private var lastScrollPoint: CGPoint?
    private var scrollSamples: [ScrollSample] = []
    private var hasSentScrollBegin = false
    private var lastPointerPoint: CGPoint?
    private var holdDownWorkItem: DispatchWorkItem?
    private var momentumGeneration = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopScrollMomentum()
        let activeTouches = activeTouches(from: event, fallback: touches)
        guard activeTouches.count == 1,
              let touch = touches.first,
              let point = normalizedPoint(for: touch.location(in: self), allowsClamping: false) else {
            cancelPointerIfNeeded()
            return
        }

        let location = touch.location(in: self)
        initialTouchLocation = location
        lastTouchLocation = location
        lastTouchTimestamp = touch.timestamp
        initialPointerPoint = point
        lastPointerPoint = point
        lastScrollPoint = point
        lastScrollVelocity = .zero
        scrollSamples = [ScrollSample(time: touch.timestamp, location: location)]
        hasSentScrollBegin = false

        if usesTouchDragForSingleFingerPan {
            pointerIntent = .dragging
            onPointerEvent(.pointerDown, point)
            return
        }

        pointerIntent = .pendingTap
        scheduleHoldDown(at: point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouches(from: event, fallback: touches).count == 1 else {
            cancelPointerIfNeeded()
            return
        }

        guard let touch = touches.first,
              let point = normalizedPoint(for: touch.location(in: self), allowsClamping: true) else {
            return
        }

        switch pointerIntent {
        case .idle:
            return
        case .pendingTap:
            guard hasExceededDragThreshold(touch.location(in: self)) else { return }
            holdDownWorkItem?.cancel()
            holdDownWorkItem = nil
            if usesTouchDragForSingleFingerPan {
                let startPoint = initialPointerPoint ?? point
                onPointerEvent(.pointerDown, startPoint)
                pointerIntent = .dragging
                fallthrough
            } else {
                pointerIntent = .scrolling
                sendScroll(from: touch.location(in: self), timestamp: touch.timestamp, at: point)
            }
        case .scrolling:
            sendScroll(from: touch.location(in: self), timestamp: touch.timestamp, at: point)
        case .dragging:
            guard shouldSendMove(to: point) else { return }
            lastPointerPoint = point
            onPointerEvent(.pointerMove, point)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdDownWorkItem?.cancel()
        holdDownWorkItem = nil

        let point: CGPoint?
        if let touch = touches.first {
            point = normalizedPoint(for: touch.location(in: self), allowsClamping: true)
        } else {
            point = lastPointerPoint
        }

        switch pointerIntent {
        case .idle:
            break
        case .pendingTap:
            if let point {
                onPointerEvent(.pointerDown, point)
                onPointerEvent(.pointerUp, point)
            }
        case .scrolling:
            if let point {
                startScrollMomentum(at: point)
                return
            }
        case .dragging:
            if let point {
                onPointerEvent(.pointerUp, point)
            }
        }

        resetPointerState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelPointerIfNeeded()
    }

    func cancelPointerIfNeeded() {
        holdDownWorkItem?.cancel()
        holdDownWorkItem = nil
        stopScrollMomentum()

        if case .dragging = pointerIntent, let lastPointerPoint {
            onPointerEvent(.pointerUp, lastPointerPoint)
        }

        if case .scrolling = pointerIntent, hasSentScrollBegin, let lastScrollPoint {
            onScrollEvent(lastScrollPoint, .zero, .cancelled)
        }

        resetPointerState()
    }

    private func activeTouches(from event: UIEvent?, fallback: Set<UITouch>) -> [UITouch] {
        Array(event?.allTouches ?? fallback)
    }

    private func scheduleHoldDown(at point: CGPoint) {
        holdDownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, case .pendingTap = self.pointerIntent else { return }
            self.onPointerEvent(.pointerDown, point)
            self.pointerIntent = .dragging
        }
        holdDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDownDelay, execute: workItem)
    }

    private func hasExceededDragThreshold(_ location: CGPoint) -> Bool {
        guard let initialTouchLocation else { return false }
        let dx = location.x - initialTouchLocation.x
        let dy = location.y - initialTouchLocation.y
        return hypot(dx, dy) >= dragStartThreshold
    }

    private func resetPointerState() {
        pointerIntent = .idle
        initialTouchLocation = nil
        initialPointerPoint = nil
        lastTouchLocation = nil
        lastTouchTimestamp = nil
        lastScrollVelocity = .zero
        lastScrollPoint = nil
        scrollSamples.removeAll()
        hasSentScrollBegin = false
        lastPointerPoint = nil
    }

    private func sendScroll(from location: CGPoint, timestamp: TimeInterval, at point: CGPoint) {
        guard let lastTouchLocation, let lastTouchTimestamp else {
            self.lastTouchLocation = location
            self.lastTouchTimestamp = timestamp
            return
        }

        let movement = CGPoint(
            x: location.x - lastTouchLocation.x,
            y: location.y - lastTouchLocation.y
        )
        self.lastTouchLocation = location
        self.lastTouchTimestamp = timestamp
        lastScrollPoint = point
        recordScrollSample(time: timestamp, location: location)

        guard abs(movement.x) > 0.2 || abs(movement.y) > 0.2 else { return }
        let interval = max(timestamp - lastTouchTimestamp, 1.0 / 120.0)
        let instantVelocity = CGPoint(x: movement.x / interval, y: movement.y / interval)
        lastScrollVelocity = CGPoint(
            x: lastScrollVelocity.x * 0.35 + instantVelocity.x * 0.65,
            y: lastScrollVelocity.y * 0.35 + instantVelocity.y * 0.65
        )
        let phase: RemoteControlMessage.ScrollPhase = hasSentScrollBegin ? .changed : .began
        hasSentScrollBegin = true
        sendScrollDelta(movement, at: point, phase: phase)
    }

    private func sendScrollDelta(
        _ movement: CGPoint,
        at point: CGPoint,
        phase: RemoteControlMessage.ScrollPhase
    ) {
        let scrollSensitivity: CGFloat = 7.0
        onScrollEvent(
            point,
            CGPoint(
                x: movement.x * scrollSensitivity,
                y: movement.y * scrollSensitivity
            ),
            phase
        )
    }

    private func startScrollMomentum(at point: CGPoint) {
        var velocity = releaseScrollVelocity()
        let minimumVelocity: CGFloat = 35
        if hasSentScrollBegin {
            onScrollEvent(point, .zero, .ended)
        }

        guard hypot(velocity.x, velocity.y) >= minimumVelocity else {
            resetPointerState()
            return
        }

        momentumGeneration &+= 1
        let generation = momentumGeneration
        let frameInterval: TimeInterval = 1.0 / 60.0
        let decay: CGFloat = 0.965
        let momentumBoost: CGFloat = 1.55
        velocity.x *= momentumBoost
        velocity.y *= momentumBoost
        var hasSentMomentumBegin = false

        func step(_ remainingSteps: Int) {
            guard generation == momentumGeneration else { return }
            guard remainingSteps > 0, hypot(velocity.x, velocity.y) >= 4 else {
                onScrollEvent(point, .zero, .momentumEnded)
                resetPointerState()
                return
            }

            let movement = CGPoint(
                x: velocity.x * frameInterval,
                y: velocity.y * frameInterval
            )
            sendScrollDelta(
                movement,
                at: point,
                phase: hasSentMomentumBegin ? .momentumChanged : .momentumBegan
            )
            hasSentMomentumBegin = true
            velocity.x *= decay
            velocity.y *= decay

            DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) {
                step(remainingSteps - 1)
            }
        }

        step(150)
    }

    private func stopScrollMomentum() {
        momentumGeneration &+= 1
    }

    private func recordScrollSample(time: TimeInterval, location: CGPoint) {
        scrollSamples.append(ScrollSample(time: time, location: location))
        let cutoff = time - 0.16
        scrollSamples.removeAll { $0.time < cutoff }
    }

    private func releaseScrollVelocity() -> CGPoint {
        guard let newest = scrollSamples.last else { return lastScrollVelocity }

        let minimumWindow: TimeInterval = 0.045
        let oldest = scrollSamples.first { newest.time - $0.time <= 0.14 && newest.time - $0.time >= minimumWindow }
            ?? scrollSamples.first

        guard let oldest, newest.time > oldest.time else { return lastScrollVelocity }

        let interval = CGFloat(newest.time - oldest.time)
        let velocity = CGPoint(
            x: (newest.location.x - oldest.location.x) / interval,
            y: (newest.location.y - oldest.location.y) / interval
        )

        if hypot(velocity.x, velocity.y) > hypot(lastScrollVelocity.x, lastScrollVelocity.y) * 0.65 {
            return velocity
        }

        return lastScrollVelocity
    }

    private func normalizedPoint(for location: CGPoint, allowsClamping: Bool) -> CGPoint? {
        guard let imageFrame, imageFrame.width > 0, imageFrame.height > 0 else { return nil }

        let x = (location.x - imageFrame.minX) / imageFrame.width
        let y = (location.y - imageFrame.minY) / imageFrame.height

        if allowsClamping {
            return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }

        guard x >= 0, y >= 0, x <= 1, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func shouldSendMove(to point: CGPoint) -> Bool {
        guard let lastPointerPoint else { return true }
        return abs(lastPointerPoint.x - point.x) > 0.001 || abs(lastPointerPoint.y - point.y) > 0.001
    }
}

private struct ScrollSample {
    var time: TimeInterval
    var location: CGPoint
}

private final class KeyboardInputView: UIView, UIKeyInput {
    var onTextInput: (String) -> Void = { _ in }
    var onKeyPress: (RemoteControlMessage.Key) -> Void = { _ in }

    var hasText: Bool { true }
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    func insertText(_ text: String) {
        switch text {
        case "\n":
            onKeyPress(.returnKey)
        case "\t":
            onKeyPress(.tab)
        default:
            onTextInput(text)
        }
    }

    func deleteBackward() {
        onKeyPress(.deleteBackward)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscapeKey))
        ]
    }

    @objc private func handleEscapeKey() {
        onKeyPress(.escape)
    }
}

private final class FallbackWallpaperView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = UIColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }

        UIColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1).setFill()
        context.fill(rect)

        UIColor.systemYellow.withAlphaComponent(0.16).setFill()

        let bands = [
            CGRect(x: bounds.width * 0.02, y: bounds.height * 0.70, width: bounds.width * 0.56, height: 10),
            CGRect(x: bounds.width * 0.18, y: bounds.height * 0.76, width: bounds.width * 0.62, height: 8),
            CGRect(x: bounds.width * 0.56, y: bounds.height * 0.18, width: bounds.width * 0.34, height: 7)
        ]

        for band in bands {
            UIBezierPath(roundedRect: band, cornerRadius: 4).fill()
        }
    }
}

private enum ViewerGeometry {
    static func renderedSize(sourceSize: CGSize, availableSize: CGSize, layoutMode: MirrorLayoutMode) -> CGSize {
        let maxWidth = max(availableSize.width - 32, 1)
        let maxHeight = max(availableSize.height - 32, 1)
        let fitWidthScale = maxWidth / sourceSize.width
        let fitHeightScale = maxHeight / sourceSize.height

        switch layoutMode {
        case .fitWidth:
            let scale = fitWidthScale
            return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        case .fitHeight:
            let scale = fitHeightScale
            return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        case .readableZoom:
            let scale = max(fitHeightScale, maxWidth / 720, 0.6)
            return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        }
    }

    static func frameRect(
        sourceSize: CGSize,
        availableSize: CGSize,
        layoutMode: MirrorLayoutMode,
        panOffset: CGPoint,
        startsAtLeadingEdge: Bool
    ) -> CGRect {
        let size = renderedSize(sourceSize: sourceSize, availableSize: availableSize, layoutMode: layoutMode)
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 16
        let constrainedOffset = constrainedPanOffset(
            panOffset,
            sourceSize: sourceSize,
            availableSize: availableSize,
            layoutMode: layoutMode,
            startsAtLeadingEdge: startsAtLeadingEdge
        )
        let x: CGFloat
        let y: CGFloat

        if size.width > availableSize.width {
            x = startsAtLeadingEdge
                ? horizontalInset + constrainedOffset.x
                : (availableSize.width - size.width) / 2 + constrainedOffset.x
        } else {
            x = (availableSize.width - size.width) / 2
        }

        if size.height > availableSize.height {
            y = startsAtLeadingEdge
                ? verticalInset + constrainedOffset.y
                : (availableSize.height - size.height) / 2 + constrainedOffset.y
        } else {
            y = (availableSize.height - size.height) / 2
        }

        return CGRect(
            x: x,
            y: y,
            width: size.width,
            height: size.height
        )
    }

    static func constrainedPanOffset(
        _ offset: CGPoint,
        sourceSize: CGSize,
        availableSize: CGSize,
        layoutMode: MirrorLayoutMode,
        startsAtLeadingEdge: Bool
    ) -> CGPoint {
        let renderedSize = renderedSize(sourceSize: sourceSize, availableSize: availableSize, layoutMode: layoutMode)
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 16
        let xOffset: CGFloat
        let yOffset: CGFloat

        if renderedSize.width > availableSize.width {
            let minOffset = startsAtLeadingEdge
                ? availableSize.width - renderedSize.width - (horizontalInset * 2)
                : (availableSize.width - renderedSize.width) / 2
            let maxOffset = startsAtLeadingEdge
                ? 0
                : (renderedSize.width - availableSize.width) / 2
            xOffset = min(max(offset.x, minOffset), maxOffset)
        } else {
            xOffset = 0
        }

        if renderedSize.height > availableSize.height {
            let minOffset = startsAtLeadingEdge
                ? availableSize.height - renderedSize.height - (verticalInset * 2)
                : (availableSize.height - renderedSize.height) / 2
            let maxOffset = startsAtLeadingEdge
                ? 0
                : (renderedSize.height - availableSize.height) / 2
            yOffset = min(max(offset.y, minOffset), maxOffset)
        } else {
            yOffset = 0
        }

        return CGPoint(x: xOffset, y: yOffset)
    }

    static func normalizedPoint(
        for location: CGPoint,
        sourceSize: CGSize,
        availableSize: CGSize,
        layoutMode: MirrorLayoutMode,
        panOffset: CGPoint,
        startsAtLeadingEdge: Bool,
        allowsClamping: Bool
    ) -> CGPoint? {
        let rect = frameRect(
            sourceSize: sourceSize,
            availableSize: availableSize,
            layoutMode: layoutMode,
            panOffset: panOffset,
            startsAtLeadingEdge: startsAtLeadingEdge
        )
        guard rect.width > 0, rect.height > 0 else { return nil }

        let x = (location.x - rect.minX) / rect.width
        let y = (location.y - rect.minY) / rect.height

        if allowsClamping {
            return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }

        guard x >= 0, y >= 0, x <= 1, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }
}
