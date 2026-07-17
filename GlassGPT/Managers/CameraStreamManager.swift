import Foundation
import MWDATCamera
import MWDATCore
import UIKit

@MainActor
final class CameraStreamManager: ObservableObject {
    @Published private(set) var currentFrame: UIImage?
    @Published private(set) var streamStateLabel = "Stopped"
    @Published private(set) var isStreaming = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryAction: StreamRecoveryAction?

    private var latestFrame: CapturedStreamFrame?

    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var frameListenerToken: (any AnyListenerToken)?
    private var streamStateListenerToken: (any AnyListenerToken)?
    private var streamErrorListenerToken: (any AnyListenerToken)?
    private var sessionStateListenerToken: (any AnyListenerToken)?
    private var sessionErrorListenerToken: (any AnyListenerToken)?
    private var userRequestedStop = false
    private var lastSessionError: DeviceSessionError?
    private var streamAttemptIndex = 1

    var canStartStream: Bool {
        !isStreaming && !isStarting
    }

    func startStream(with wearablesManager: WearablesManager) async {
        guard canStartStream else {
            if isStarting {
                errorMessage = "Stream is already starting…"
            }
            return
        }

        await wearablesManager.bootstrapIfNeeded()

        guard wearablesManager.isRegistered else {
            errorMessage = "Register GlassGPT with Meta AI in Settings first."
            return
        }

        guard let wearables = wearablesManager.datWearables else {
            errorMessage = "Wearables SDK is not ready yet."
            return
        }

        userRequestedStop = false
        errorMessage = nil
        recoveryAction = nil
        lastSessionError = nil

        await cleanupSession()
        isStarting = true
        streamStateLabel = "Preparing"

        defer {
            isStarting = false
        }

        do {
            try await Task.sleep(nanoseconds: 500_000_000)

            var lastError: Error?

            for attempt in 1...2 {
                try throwIfUserRequestedStop()

                streamAttemptIndex = attempt
                do {
                    try await runStreamAttempt(
                        wearables: wearables,
                        wearablesManager: wearablesManager
                    )
                    return
                } catch {
                    if case .userRequestedStop = error as? StreamSetupError {
                        await finalizeStop()
                        streamStateLabel = "Stopped"
                        log("Stream stopped by user", to: wearablesManager)
                        return
                    }

                    lastError = error
                    log("Stream attempt \(attempt) failed: \(localizedStreamError(from: error))", to: wearablesManager)

                    guard attempt == 1, shouldRetryStream(after: error) else { break }

                    streamStateLabel = "Retrying"
                    log("Cleaning up and retrying stream once with lighter config…", to: wearablesManager)
                    await cleanupSession()
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }

            if let lastError {
                await finalizeStop()
                applyFailure(from: lastError)
                streamStateLabel = "Stopped"
                log("Stream failed: \(errorMessage ?? lastError.localizedDescription)", to: wearablesManager)
            }
        } catch {
            if case .userRequestedStop = error as? StreamSetupError {
                await finalizeStop()
                streamStateLabel = "Stopped"
                log("Stream stopped by user", to: wearablesManager)
                return
            }

            await finalizeStop()
            applyFailure(from: error)
            streamStateLabel = "Stopped"
            log("Stream failed: \(errorMessage ?? error.localizedDescription)", to: wearablesManager)
        }
    }

    private func runStreamAttempt(
        wearables: WearablesInterface,
        wearablesManager: WearablesManager
    ) async throws {
        streamStateLabel = "Waiting for glasses"
        wearablesManager.refreshDeviceSnapshot()
        log("Looking for glasses in DAT…", to: wearablesManager)

        let deviceId = try? await wearablesManager.waitForReadyDevice(timeoutSeconds: 12)
        try throwIfUserRequestedStop()
        if let deviceId {
            wearablesManager.logDeviceHealth(for: deviceId)
            log("Glasses selected id=\(deviceId)", to: wearablesManager)
        } else {
            log("No DAT device selected yet — using AutoDeviceSelector", to: wearablesManager)
        }

        streamStateLabel = "Checking camera permission"
        log("Checking camera permission…", category: .permission, to: wearablesManager)
        let permission = try await wearablesManager.requestCameraPermission()
        try throwIfUserRequestedStop()
        log("Camera permission result=\(String(describing: permission))", category: .permission, to: wearablesManager)
        guard permission == .granted else {
            recoveryAction = .grantCameraPermission
            errorMessage = "Camera permission was not granted in Meta AI."
            streamStateLabel = "Stopped"
            throw StreamSetupError.permissionDenied
        }

        // Official DAT sample uses AutoDeviceSelector; specific selection can race the stream channel.
        let deviceSelector = wearablesManager.makeDeviceSelector(for: nil)
        streamStateLabel = "Opening session"
        log("Creating device session selector=auto (device hint=\(deviceId ?? "none"))", category: .session, to: wearablesManager)

        let session = try wearables.createSession(deviceSelector: deviceSelector)
        self.deviceSession = session
        attachSessionListeners(to: session, wearablesManager: wearablesManager)

        log("Session created deviceId=\(session.deviceId) state=\(session.state.description)", category: .session, to: wearablesManager)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        log("Calling session.start()", category: .session, to: wearablesManager)
        try session.start()
        log("session.start() returned state=\(session.state.description)", category: .session, to: wearablesManager)
        try await waitForSessionStart(session, wearablesManager: wearablesManager)
        try throwIfUserRequestedStop()
        log("Session reached started — settling before addStream", category: .session, to: wearablesManager)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try throwIfUserRequestedStop()

        // Prefer the highest-quality continuous feed the glasses expose
        // (720×1280). Keep one frame per second so Bluetooth still has headroom
        // for HFP audio.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 1)

        log(
            "Adding stream capability codec=raw resolution=\(String(describing: config.resolution)) frameRate=\(config.frameRate)",
            category: .stream,
            to: wearablesManager
        )

        guard let stream = try session.addStream(config: config) else {
            log("addStream returned nil — session may not be started", category: .stream, to: wearablesManager)
            throw StreamSetupError.streamUnavailable
        }

        self.stream = stream
        attachStreamListeners(to: stream, wearablesManager: wearablesManager)

        streamStateLabel = "Starting video"
        await stream.start()
        try await waitForStreaming(stream, wearablesManager: wearablesManager)
        try throwIfUserRequestedStop()
        isStreaming = true
        streamStateLabel = "Streaming (1 fps)"
        log("High-quality live stream ready at one frame per second", category: .stream, to: wearablesManager)
    }

    /// Returns a recent preview frame immediately; no camera operation is
    /// initiated at response time.
    func latestLiveFrameData() -> Data? {
        latestFrameData(maximumAge: 2.5)
    }

    private func shouldRetryStream(after error: Error) -> Bool {
        if case .userRequestedStop = error as? StreamSetupError {
            return false
        }

        if let streamError = error as? StreamError {
            switch streamError {
            case .internalError, .videoStreamingError, .timeout, .deviceNotConnected:
                return true
            default:
                return false
            }
        }

        if case .streamError(let streamError) = error as? StreamSetupError {
            return shouldRetryStream(after: streamError)
        }

        if case .streamError = error as? StreamSetupError {
            return true
        }

        if case .streamStopped = error as? StreamSetupError {
            return true
        }

        if case .sessionStopped = error as? StreamSetupError {
            // Meta AI can briefly retain the previous DAT camera channel after
            // an app install or foreground transition. A fully torn-down retry
            // is inexpensive and normally succeeds once that channel releases.
            return true
        }

        if case let .sessionError(.unexpectedError(description)) = error as? StreamSetupError,
           description.localizedCaseInsensitiveContains("session ended by device") {
            return true
        }

        return false
    }

    func stopStream() async {
        guard isStreaming || isStarting || deviceSession != nil || stream != nil else {
            return
        }

        userRequestedStop = true
        isStopping = true
        streamStateLabel = "Stopping"
        currentFrame = nil
        isStreaming = false
        await finalizeStop()
    }

    private func finalizeStop() async {
        isStarting = false
        isStreaming = false
        streamStateLabel = "Stopping"
        currentFrame = nil
        latestFrame = nil
        await cleanupSession()
        streamStateLabel = "Stopped"
        isStopping = false
    }

    private func throwIfUserRequestedStop() throws {
        if userRequestedStop {
            throw StreamSetupError.userRequestedStop
        }
    }

    private func cleanupSession() async {
        await cancelListeners()

        if let stream {
            await stopStreamCapability(stream)
        }

        stream = nil
        deviceSession?.stop()
        deviceSession = nil
    }

    private func stopStreamCapability(_ stream: MWDATCamera.Stream) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await stream.stop()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            _ = await group.next()
            group.cancelAll()
        }
    }

    private func tearDownStream() async {
        await finalizeStop()
    }

    private func waitForSessionStart(
        _ session: DeviceSession,
        wearablesManager: WearablesManager
    ) async throws {
        if session.state == .started {
            log("Session already started", category: .session, to: wearablesManager)
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: 45 * 1_000_000_000)
                throw StreamSetupError.sessionStartTimeout
            }

            group.addTask { @MainActor in
                while true {
                    if self.userRequestedStop {
                        throw StreamSetupError.userRequestedStop
                    }

                    let state = session.state
                    self.log("Session poll state=\(state.description)", category: .session, to: wearablesManager)

                    if state == .started {
                        return
                    }

                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            group.addTask { @MainActor in
                for await error in session.errorStream() {
                    self.lastSessionError = error
                    self.log("Device session error: \(error.localizedDescription) case=\(String(describing: error))", category: .session, to: wearablesManager)
                    throw StreamSetupError.sessionError(error)
                }
            }

            group.addTask { @MainActor in
                var hasEnteredStartFlow = session.state == .starting

                for await state in session.stateStream() {
                    self.log("Device session state: \(state.description)", category: .session, to: wearablesManager)

                    switch state {
                    case .starting:
                        hasEnteredStartFlow = true
                    case .started:
                        return
                    case .paused:
                        continue
                    case .stopped:
                        if hasEnteredStartFlow {
                            if let lastSessionError = self.lastSessionError {
                                throw StreamSetupError.sessionError(lastSessionError)
                            }
                            throw StreamSetupError.sessionStopped
                        }
                    default:
                        continue
                    }
                }

                throw StreamSetupError.sessionStartTimeout
            }

            try await group.next()
            group.cancelAll()
        }
    }

    private func waitForStreaming(
        _ stream: MWDATCamera.Stream,
        wearablesManager: WearablesManager
    ) async throws {
        if stream.state == .streaming {
            log("Stream already streaming", category: .stream, to: wearablesManager)
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                throw StreamSetupError.streamStartTimeout
            }

            group.addTask { @MainActor in
                while true {
                    if self.userRequestedStop {
                        throw StreamSetupError.userRequestedStop
                    }

                    let state = stream.state
                    self.log("Stream poll state=\(String(describing: state))", category: .stream, to: wearablesManager)

                    if state == .streaming {
                        return
                    }

                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            group.addTask { @MainActor in
                for await error in stream.errorPublisher.listenAsStream() {
                    self.log("Stream error while starting: \(String(describing: error))", category: .stream, to: wearablesManager)
                    throw StreamSetupError.streamError(error)
                }
            }

            group.addTask { @MainActor in
                var hasEnteredStartFlow = false

                for await state in stream.statePublisher.listenAsStream() {
                    self.log("Stream state: \(String(describing: state))", category: .stream, to: wearablesManager)

                    switch state {
                    case .waitingForDevice, .starting:
                        hasEnteredStartFlow = true
                    case .streaming:
                        return
                    case .paused:
                        continue
                    case .stopped:
                        if hasEnteredStartFlow {
                            throw StreamSetupError.streamStopped
                        }
                    default:
                        continue
                    }
                }

                throw StreamSetupError.streamStartTimeout
            }

            try await group.next()
            group.cancelAll()
        }
    }

    private func attachSessionListeners(to session: DeviceSession, wearablesManager: WearablesManager) {
        sessionStateListenerToken = session.statePublisher.listen { [weak self] (state: DeviceSessionState) in
            Task { @MainActor in
                wearablesManager.appendLog("Session state: \(state.description)", category: .session)

                guard let self, self.isStreaming || self.isStarting else { return }

                if state == .stopped, !self.userRequestedStop {
                    self.errorMessage = self.lastSessionError.map(self.localizedSessionError)
                        ?? "Glasses session ended. Keep Meta AI open and avoid using the camera there."
                    Task { await self.finalizeStop() }
                }
            }
        }

        sessionErrorListenerToken = session.errorPublisher.listen { [weak self] (error: DeviceSessionError) in
            Task { @MainActor in
                self?.lastSessionError = error
                wearablesManager.appendLog("Session error: \(error.localizedDescription) case=\(String(describing: error))", category: .session)
                self?.errorMessage = self?.localizedSessionError(error)
                self?.recoveryAction = error == .datAppOnTheGlassesUpdateRequired ? .updateGlassesDATApp : nil
            }
        }
    }

    private func attachStreamListeners(to stream: MWDATCamera.Stream, wearablesManager: WearablesManager) {
        frameListenerToken = stream.videoFramePublisher.listen { [weak self] (frame: VideoFrame) in
            guard let image = frame.makeUIImage() else { return }

            Task { @MainActor in
                guard let self, self.isStreaming || self.isStarting else { return }
                self.currentFrame = image
                self.latestFrame = CapturedStreamFrame(image: image, capturedAt: Date())
            }
        }

        streamStateListenerToken = stream.statePublisher.listen { [weak self] (state: StreamState) in
            Task { @MainActor in
                guard let self else { return }

                let wasStreaming = self.isStreaming
                self.streamStateLabel = state == .streaming ? "Streaming (1 fps)" : String(describing: state).capitalized
                self.isStreaming = state == .streaming

                if state == .stopped, wasStreaming, !self.userRequestedStop {
                    self.errorMessage = "Camera stream stopped. Close Meta AI camera features and retry."
                    Task { await self.finalizeStop() }
                }
            }
        }

        streamErrorListenerToken = stream.errorPublisher.listen { [weak self] (error: StreamError) in
            Task { @MainActor in
                wearablesManager.appendLog("Stream error: \(String(describing: error))", category: .stream)
                self?.errorMessage = self?.localizedStreamError(error)
                self?.recoveryAction = self?.recoveryAction(for: error)
            }
        }
    }

    private func cancelListeners() async {
        await frameListenerToken?.cancel()
        await streamStateListenerToken?.cancel()
        await streamErrorListenerToken?.cancel()
        await sessionStateListenerToken?.cancel()
        await sessionErrorListenerToken?.cancel()

        frameListenerToken = nil
        streamStateListenerToken = nil
        streamErrorListenerToken = nil
        sessionStateListenerToken = nil
        sessionErrorListenerToken = nil
    }

    private func applyFailure(from error: Error) {
        errorMessage = localizedStreamError(from: error)
        recoveryAction = recoveryAction(for: error)
    }

    private func recoveryAction(for error: Error) -> StreamRecoveryAction? {
        if let readinessError = error as? DeviceReadinessError {
            switch readinessError {
            case .deviceUpdateRequired:
                return .updateGlassesDATApp
            default:
                return nil
            }
        }

        if let permissionError = error as? PermissionError {
            switch permissionError {
            case .connectionError, .noDevice, .noDeviceWithConnection:
                return nil
            default:
                return .grantCameraPermission
            }
        }

        if let sessionError = error as? DeviceSessionError, sessionError == .datAppOnTheGlassesUpdateRequired {
            return .updateGlassesDATApp
        }

        if let streamError = error as? StreamError {
            switch streamError {
            case .internalError, .videoStreamingError, .timeout, .deviceNotConnected:
                return .powerCycleGlasses
            case .thermalCritical, .thermalEmergency:
                return .powerCycleGlasses
            case .batteryCritical, .peakPowerShutdown:
                return .powerCycleGlasses
            case .permissionDenied:
                return .grantCameraPermission
            case .hingesClosed:
                return nil
            default:
                return .powerCycleGlasses
            }
        }

        if let setupError = error as? StreamSetupError {
            switch setupError {
            case .sessionError(let sessionError) where sessionError == .datAppOnTheGlassesUpdateRequired:
                return .updateGlassesDATApp
            case .streamError(let streamError):
                return recoveryAction(for: streamError)
            case .permissionDenied:
                return .grantCameraPermission
            default:
                return nil
            }
        }

        return nil
    }

    private func localizedStreamError(from error: Error) -> String {
        if let setupError = error as? StreamSetupError {
            return setupError.errorDescription ?? setupError.localizedDescription
        }

        if let readinessError = error as? DeviceReadinessError {
            return readinessError.errorDescription ?? readinessError.localizedDescription
        }

        if let permissionError = error as? PermissionError {
            return localizedPermissionError(permissionError)
        }

        if let sessionError = error as? DeviceSessionError {
            return localizedSessionError(sessionError)
        }

        if let streamError = error as? StreamError {
            return localizedStreamError(streamError)
        }

        return error.localizedDescription
    }

    private func localizedStreamError(_ error: StreamError) -> String {
        switch error {
        case .internalError, .videoStreamingError:
            return "Bluetooth video channel failed (videoStreamingError). Force-quit Meta AI completely, keep glasses on with hinges open, then retry. If it keeps failing: restart iPhone, then re-pair glasses in Meta AI."
        case .deviceNotFound(_):
            return "Glasses not found. Wear them with hinges open and open Meta AI."
        case .deviceNotConnected(_):
            return "Glasses disconnected during stream start. Wait for the connected chime in Meta AI, then retry."
        case .timeout:
            return "Stream start timed out. Keep Meta AI open in the background and retry."
        case .permissionDenied:
            return "Camera permission denied. Approve camera access for GlassGPT in Meta AI."
        case .hingesClosed:
            return "Glasses hinges are closed. Open them and retry."
        case .thermalCritical:
            return "Glasses are too hot to stream. Let them cool down, then retry."
        case .thermalEmergency:
            return "Glasses overheated and stopped streaming. Let them cool down before retrying."
        case .peakPowerShutdown:
            return "Glasses hit a power limit. Charge them or wait a minute, then retry."
        case .batteryCritical:
            return "Glasses battery is too low to stream. Charge them and retry."
        }
    }

    private func localizedPermissionError(_ error: PermissionError) -> String {
        switch error {
        case .noDevice:
            return "No glasses found for camera permission. Wear them with hinges open and open Meta AI."
        case .noDeviceWithConnection:
            return "Glasses are not connected. Open Meta AI, wait for the connected chime, then retry."
        case .connectionError:
            return "Bluetooth dropped while requesting camera permission. Keep Meta AI open, wait for glasses to reconnect, then retry."
        case .metaAINotInstalled:
            return "Meta AI is not installed. Install it from the App Store to grant camera permission."
        case .requestInProgress:
            return "A camera permission request is already open in Meta AI. Complete it, then retry."
        case .requestTimeout:
            return "Camera permission timed out in Meta AI. Open Meta AI and approve access for GlassGPT."
        case .internalError:
            return "Camera permission failed unexpectedly. Retry after glasses reconnect in Meta AI."
        }
    }

    private func localizedSessionError(_ error: DeviceSessionError) -> String {
        switch error {
        case .noEligibleDevice:
            return "No eligible glasses found. Wear them with hinges open and open Meta AI."
        case .datAppOnTheGlassesUpdateRequired:
            return "The DAT app on your glasses needs an update. Open Meta AI → App connections → Developer mode apps."
        case .unexpectedError(let description):
            if description.localizedCaseInsensitiveContains("session ended by device") {
                return "The glasses ended the camera session. GlassGPT will retry once. If it still fails, close every Meta AI camera feature, open Meta AI until the glasses show connected, then update the GlassGPT DAT app in Settings."
            }
            if description.localizedCaseInsensitiveContains("device unavailable") {
                return "Glasses became unavailable. Close Meta AI camera features, power-cycle the glasses (close case 30s), then retry."
            }
            return description
        case .thermalCritical:
            return "Glasses are too hot to start a session. Let them cool down, then retry."
        case .thermalEmergency:
            return "Glasses overheated. Let them cool down before retrying."
        case .batteryCritical:
            return "Glasses battery is critically low. Charge them and retry."
        case .peakPowerShutdown:
            return "Glasses hit a power limit. Wait a minute, then retry."
        case .sessionAlreadyExists:
            return "A previous glasses session is still active. Stop the stream, power-cycle the glasses, then retry."
        case .dwaUnavailable:
            return "The DAT app on the glasses is not reachable. Open Meta AI, confirm the glasses app updated, then power-cycle the glasses."
        default:
            return error.localizedDescription
        }
    }

    private func log(_ message: String, category: LogCategory = .stream, to wearablesManager: WearablesManager) {
        wearablesManager.appendLog(message, category: category)
    }
}

struct CapturedStreamFrame {
    let image: UIImage
    let capturedAt: Date

    /// Lossless PNG at the stream's native resolution — no resize, no JPEG.
    func pngData() -> Data? {
        image.pngData()
    }
}

extension CameraStreamManager {
    /// The manager is MainActor-isolated, so this snapshot cannot race video-frame updates.
    func latestFrameData(maximumAge: TimeInterval = 3) -> Data? {
        guard let latestFrame, Date().timeIntervalSince(latestFrame.capturedAt) <= maximumAge else {
            return nil
        }

        return latestFrame.pngData()
    }
}

private enum StreamSetupError: LocalizedError {
    case streamUnavailable
    case sessionStopped
    case sessionStartTimeout
    case sessionError(DeviceSessionError)
    case streamError(StreamError)
    case streamStopped
    case streamStartTimeout
    case permissionDenied
    case userRequestedStop

    var errorDescription: String? {
        switch self {
        case .userRequestedStop:
            return nil
        case .streamUnavailable:
            return "Could not start a camera stream. Keep glasses on, Meta AI open, and try again."
        case .sessionStopped:
            return "The glasses ended the camera session before streaming started. GlassGPT retried once. Close every Meta AI camera feature, wait for its connected chime, then retry."
        case .sessionStartTimeout:
            return "Timed out connecting to glasses. Wear them with hinges open, open Meta AI, wait for the connected chime, then retry. If this keeps happening, power-cycle the glasses (close case for 30 seconds)."
        case .sessionError(let error):
            if case let .unexpectedError(description) = error,
               description.localizedCaseInsensitiveContains("session ended by device") {
                return "The glasses ended the camera session twice. Close every Meta AI camera feature, open Meta AI and wait for the connected chime, then update the GlassGPT DAT app in Settings before retrying."
            }
            switch error {
            case .unexpectedError(let description) where description.localizedCaseInsensitiveContains("device unavailable"):
                return "Glasses became unavailable during connect. Close Meta AI camera features, power-cycle the glasses, then retry."
            case .datAppOnTheGlassesUpdateRequired:
                return "The DAT app on your glasses needs an update. Open Meta AI → App connections → Developer mode apps."
            default:
                return error.localizedDescription
            }
        case .streamError(let error):
            switch error {
            case .internalError, .videoStreamingError:
                return "Bluetooth video channel failed (videoStreamingError). Force-quit Meta AI completely, keep glasses on with hinges open, then retry. If it keeps failing: restart iPhone, then re-pair glasses in Meta AI."
            default:
                return error.localizedDescription
            }
        case .streamStopped:
            return "The camera stream stopped. Close camera features in Meta AI and try again."
        case .streamStartTimeout:
            return "Timed out waiting for video. Make sure glasses are worn with hinges open."
        case .permissionDenied:
            return "Camera permission was not granted in Meta AI."
        }
    }
}

private extension Announcer {
    func listenAsStream() -> AsyncStream<T> {
        AsyncStream { continuation in
            let token = listen { value in
                continuation.yield(value)
            }

            continuation.onTermination = { _ in
                Task {
                    await token.cancel()
                }
            }
        }
    }
}
