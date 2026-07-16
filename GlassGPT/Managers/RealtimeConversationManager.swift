import AVFAudio
import Foundation

@MainActor
final class RealtimeConversationManager: NSObject, ObservableObject {
    @Published private(set) var stateLabel = "Disconnected"
    @Published private(set) var audioRouteLabel = "Not checked"
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentTranscript = ""
    /// The exact JPEG attached to the current user turn, if that turn included
    /// visual context. This is kept only for the compact on-screen transcript.
    @Published private(set) var currentTurnVisionFrameData: Data?
    @Published private(set) var responseText = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isResponding = false
    /// Remains true through playback of the final queued PCM buffer, which can
    /// outlive Realtime's `response.done` event by several seconds.
    @Published private(set) var isAssistantSpeaking = false
    /// A deliberately visual-only energy signal. It is randomized during the
    /// known audio-buffer duration so the Wave remains lively even when audio
    /// callbacks are delivered early or coalesced by iOS.
    @Published private(set) var assistantAnimationLevel: CGFloat = 0
    /// Smoothed RMS level of model PCM that is about to be played on glasses.
    @Published private(set) var assistantAudioLevel: CGFloat = 0

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let session = AVAudioSession.sharedInstance()
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    private weak var cameraStreamManager: CameraStreamManager?
    private weak var wearablesManager: WearablesManager?
    private weak var locationManager: LocationManager?
    private weak var nativeActionsManager: NativeActionsManager?
    private var isStopping = false
    /// Remains true after a deliberate shutdown until the next start attempt so
    /// a cancelled receive() cannot overwrite the real stop reason.
    private var isLocallyClosing = false
    private var activeOutputItemID: String?
    private var hasQueuedAssistantAudio = false
    private var queuedAssistantBufferCount = 0
    private var responseAudioIsComplete = false
    private var assistantAnimationEnd = Date.distantPast
    private var assistantAnimationTask: Task<Void, Never>?
    private var assistantAnimationStopTask: Task<Void, Never>?
    private var discardingInterruptedAudio = false
    /// A monotonically increasing token prevents playback callbacks from an
    /// interrupted response being counted toward a later response.
    private var assistantAudioGeneration = 0
    private var confirmedPlayedAssistantFrames: Int64 = 0
    /// Realtime only allows one response at a time. A completed follow-up
    /// transcript waits here until an interrupted response is fully cancelled.
    private var responseRequestInFlight = false
    private var pendingTranscript: String?
    private var audioLevelDecayTask: Task<Void, Never>?

    private let realtimeFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    var canRetry: Bool { !isConnected && !isStopping }

    func start(
        cameraStreamManager: CameraStreamManager,
        wearablesManager: WearablesManager,
        locationManager: LocationManager,
        nativeActionsManager: NativeActionsManager
    ) async {
        guard !isConnected else { return }

        self.cameraStreamManager = cameraStreamManager
        self.wearablesManager = wearablesManager
        self.locationManager = locationManager
        self.nativeActionsManager = nativeActionsManager
        nativeActionsManager.setCameraStreamManager(cameraStreamManager)
        isStopping = false
        isLocallyClosing = false
        errorMessage = nil
        responseRequestInFlight = false
        pendingTranscript = nil
        currentTurnVisionFrameData = nil
        stateLabel = "Preparing audio"

        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String,
              !apiKey.isEmpty,
              !apiKey.contains("YOUR_") else {
            fail("OpenAI prototype key is not configured. Add OPENAI_API_KEY to your local Config.xcconfig.")
            return
        }

        do {
            try await requestMicrophonePermission()
            try configureGlassesAudioRoute()
            try startAudioEngine()
            try await connect(apiKey: apiKey)
            try await sendSessionConfiguration()

            isConnected = true
            stateLabel = "Listening"
            log("Realtime session connected using glasses microphone and speakers", category: .realtime)
        } catch {
            await stop()
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        isLocallyClosing = true
        isConnected = false
        isResponding = false
        stateLabel = "Disconnected"

        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioLevelDecayTask?.cancel()
        audioLevelDecayTask = nil
        assistantAudioLevel = 0
        hasQueuedAssistantAudio = false
        queuedAssistantBufferCount = 0
        responseAudioIsComplete = false
        isAssistantSpeaking = false
        assistantAnimationLevel = 0
        assistantAnimationTask?.cancel()
        assistantAnimationTask = nil
        assistantAnimationStopTask?.cancel()
        assistantAnimationStopTask = nil
        discardingInterruptedAudio = false
        activeOutputItemID = nil
        confirmedPlayedAssistantFrames = 0
        responseRequestInFlight = false
        pendingTranscript = nil
        audioEngine.stop()
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isStopping = false
    }

    private func requestMicrophonePermission() async throws {
        if session.recordPermission == .granted { return }

        let granted = await withCheckedContinuation { continuation in
            session.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else { throw RealtimeError.microphonePermissionDenied }
    }

    private func configureGlassesAudioRoute() throws {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)

        guard let glassesInput = session.availableInputs?.first(where: isMetaGlassesHFP) else {
            throw RealtimeError.glassesAudioUnavailable
        }
        try session.setPreferredInput(glassesInput)

        guard session.currentRoute.inputs.contains(where: isMetaGlassesHFP),
              session.currentRoute.outputs.contains(where: isMetaGlassesHFP) else {
            throw RealtimeError.glassesAudioUnavailable
        }

        audioRouteLabel = routeDescription()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleRouteChange() }
        }
    }

    private func isMetaGlassesHFP(_ port: AVAudioSessionPortDescription) -> Bool {
        guard port.portType == .bluetoothHFP else { return false }
        let name = port.portName.lowercased()
        return name.contains("ray-ban") || name.contains("ray ban") || name.contains("meta")
    }

    private func handleRouteChange() {
        audioRouteLabel = routeDescription()
        guard isConnected else { return }
        guard session.currentRoute.inputs.contains(where: isMetaGlassesHFP),
              session.currentRoute.outputs.contains(where: isMetaGlassesHFP) else {
            log("Glasses audio route was lost", category: .audio)
            Task {
                await stop()
                fail(RealtimeError.glassesAudioUnavailable.localizedDescription)
            }
            return
        }
        log("Glasses audio route changed: \(audioRouteLabel)", category: .audio)
    }

    private func routeDescription() -> String {
        let input = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        let output = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        return "In: \(input.isEmpty ? "—" : input) · Out: \(output.isEmpty ? "—" : output)"
    }

    private func startAudioEngine() throws {
        if !audioEngine.attachedNodes.contains(playerNode) {
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: realtimeFormat)
        }

        let input = audioEngine.inputNode
        // Bluetooth HFP microphones commonly run at 16 kHz. A tap must use the
        // input node's *current hardware* format; using the engine's default
        // 48 kHz graph format causes AVAudioEngine error -10868.
        let hardwareInputFormat = input.inputFormat(forBus: 0)
        guard hardwareInputFormat.sampleRate > 0, hardwareInputFormat.channelCount > 0 else {
            throw RealtimeError.glassesAudioUnavailable
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_048, format: hardwareInputFormat) { [weak self] buffer, _ in
            guard let pcmData = Self.resampleToRealtimePCM(buffer) else { return }
            Task { @MainActor in self?.sendAudio(pcmData) }
        }

        log(
            "Audio input tap uses hardware format \(Int(hardwareInputFormat.sampleRate)) Hz / \(hardwareInputFormat.channelCount) channel(s)",
            category: .audio
        )

        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()
    }

    private static func resampleToRealtimePCM(_ input: AVAudioPCMBuffer) -> Data? {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else { return nil }
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let bytes = output.int16ChannelData else { return nil }
        return Data(bytes: bytes[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    private func connect(apiKey: String) async throws {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini") else {
            throw RealtimeError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        webSocket = socket

        // URLSession returns from resume() before the WebSocket HTTP upgrade has
        // completed. Do not send session configuration or microphone audio until
        // OpenAI has confirmed the session; otherwise iOS reports "Socket is not
        // connected" and drops the first write.
        let initialMessage = try await socket.receive()
        guard case let .string(initialText) = initialMessage,
              let initialData = initialText.data(using: .utf8),
              let initialEvent = try JSONSerialization.jsonObject(with: initialData) as? [String: Any],
              let initialType = initialEvent["type"] as? String else {
            throw RealtimeError.invalidHandshake
        }

        if initialType == "error" {
            let message = ((initialEvent["error"] as? [String: Any])?["message"] as? String)
                ?? "OpenAI rejected the Realtime connection."
            throw RealtimeError.connectionRejected(message)
        }
        guard initialType == "session.created" else {
            throw RealtimeError.invalidHandshake
        }

        log("OpenAI confirmed Realtime session", category: .realtime)
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    private func sendSessionConfiguration() async throws {
        try await sendEvent([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": "gpt-realtime-2.1-mini",
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": [
                            "model": "gpt-realtime-whisper",
                            "language": "en"
                        ],
                        "turn_detection": [
                            // Semantic VAD waits for the meaning of an
                            // utterance to complete, rather than responding to
                            // a short natural pause mid-sentence.
                            "type": "semantic_vad",
                            "eagerness": "low",
                            "create_response": false,
                            "interrupt_response": true
                        ]
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": "marin"
                    ]
                ],
                "instructions": "You are GlassGPT, a concise hands-free assistant. Answer naturally in spoken English. A current still image from the glasses is supplied with every completed user turn; use it when it is relevant, but do not claim visual details that are not present."
                    + " When the user asks you to take an action, call the matching tool immediately — do not ask for confirmation first. Infer reasonable defaults from the request when details are missing. Briefly acknowledge what you are doing, then wait for the tool result. Never claim an action succeeded until its tool result says it did.",
                "tools": nativeActionsManager?.realtimeTools ?? [],
                "tool_choice": "auto"
            ]
        ])
    }

    func refreshNativeTools() async {
        guard isConnected else { return }
        do {
            try await sendEvent([
                "type": "session.update",
                "session": ["tools": nativeActionsManager?.realtimeTools ?? [], "tool_choice": "auto"]
            ])
        } catch {
            log("Could not refresh native action tools: \(error.localizedDescription)", category: .realtime)
        }
    }

    private func sendAudio(_ data: Data) {
        guard isConnected, !data.isEmpty else { return }
        Task {
            try? await sendEvent([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString()
            ])
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let webSocket {
            do {
                let message = try await webSocket.receive()
                guard case let .string(text) = message,
                      let data = text.data(using: .utf8),
                      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                await handle(event: event)
            } catch {
                guard !Task.isCancelled, !isStopping, !isLocallyClosing else { return }
                log("Realtime socket closed: \(error.localizedDescription)", category: .realtime)
                await stop()
                fail("Realtime connection ended: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handle(event: [String: Any]) async {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started":
            await interruptAssistantPlayback()
        case "input_audio_buffer.speech_stopped":
            // With server VAD, Realtime closes and commits the detected audio
            // turn itself. Sending input_audio_buffer.commit here attempts to
            // commit the *next*, empty buffer and causes the 100 ms error.
            log("Server VAD ended the audio turn", category: .audio)
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = event["transcript"] as? String else { return }
            currentTranscript = transcript
            // A new utterance should never display the previous turn's image
            // while we decide whether this one has a fresh vision frame.
            currentTurnVisionFrameData = nil
            pendingTranscript = transcript
            await startPendingResponseIfPossible()
        case "response.output_item.added":
            if let item = event["item"] as? [String: Any],
               let itemID = item["id"] as? String {
                activeOutputItemID = itemID
            }
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any],
               item["type"] as? String == "function_call" {
                await handleFunctionCall(item)
            }
        case "response.audio.delta", "response.output_audio.delta":
            if let encoded = event["delta"] as? String, let audio = Data(base64Encoded: encoded) {
                if !discardingInterruptedAudio {
                    scheduleAudio(audio)
                }
            }
        case "response.output_text.delta", "response.text.delta", "response.output_audio_transcript.delta":
            if let delta = event["delta"] as? String { responseText += delta }
        case "response.created":
            isResponding = true
            responseAudioIsComplete = false
            responseText = ""
            discardingInterruptedAudio = false
            activeOutputItemID = nil
            hasQueuedAssistantAudio = false
            assistantAudioGeneration &+= 1
            confirmedPlayedAssistantFrames = 0
        case "response.done":
            isResponding = false
            responseAudioIsComplete = true
            finishAssistantSpeechIfPlaybackCompleted()
            responseRequestInFlight = false
            await startPendingResponseIfPossible()
        case "response.cancelled":
            isResponding = false
            responseAudioIsComplete = true
            finishAssistantSpeechIfPlaybackCompleted()
            responseRequestInFlight = false
            await startPendingResponseIfPossible()
        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "Unknown Realtime API error"
            fail(message)
        default:
            break
        }
    }

    private func handleFunctionCall(_ item: [String: Any]) async {
        guard let name = item["name"] as? String,
              let callID = item["call_id"] as? String else { return }
        let argumentsText = item["arguments"] as? String ?? "{}"
        let argumentsData = argumentsText.data(using: .utf8) ?? Data()
        let arguments = (try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]) ?? [:]
        let output = await nativeActionsManager?.perform(name: name, arguments: arguments)
            ?? ["ok": false, "message": "Native actions are unavailable."]

        do {
            try await sendEvent([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8) ?? "{}"
                ]
            ])
            try await sendEvent(["type": "response.create"])
        } catch {
            fail("Could not complete a native action: \(error.localizedDescription)")
        }
    }

    private func createResponse(for transcript: String) async {
        // Use the most recent frame from the deliberately low-bandwidth live
        // preview. This adds no per-turn camera start or capture latency.
        var content: [[String: Any]] = []

        if let locationContext = locationManager?.realtimeContext() {
            content.append([
                "type": "input_text",
                "text": locationContext
            ])
            log("Attached opted-in location context for this turn", category: .location)
        }

        if TurnImagePolicy.shouldCaptureImage(for: transcript),
           let imageData = cameraStreamManager?.latestLiveFrameData() {
            // Retain the already-compressed payload rather than extracting a
            // second frame. The UI therefore previews precisely what Realtime
            // receives for this turn.
            currentTurnVisionFrameData = imageData
            content.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"
            ])
            log("Attached the latest 1 fps live-stream frame for this turn", category: .vision)
        } else {
            log("No fresh live-stream frame was available; responding with audio context only", category: .vision)
        }

        if !content.isEmpty {
            do {
                try await sendEvent([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": content
                    ]
                ])
            } catch {
                log("Could not attach turn context: \(error.localizedDescription)", category: .realtime)
            }
        }

        do {
            try await sendEvent(["type": "response.create"])
        } catch {
            responseRequestInFlight = false
            fail("Could not request a response: \(error.localizedDescription)")
        }
    }

    private func startPendingResponseIfPossible() async {
        guard !responseRequestInFlight,
              let transcript = pendingTranscript else { return }

        pendingTranscript = nil
        // Set this before sending so two near-simultaneous transcription events
        // cannot produce two response.create events.
        responseRequestInFlight = true
        await createResponse(for: transcript)
    }

    private func scheduleAudio(_ data: Data) {
        guard !data.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: realtimeFormat, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let destination = buffer.int16ChannelData else { return }
        buffer.frameLength = buffer.frameCapacity
        destination[0].withMemoryRebound(to: UInt8.self, capacity: data.count) { bytes in
            data.copyBytes(to: bytes, count: data.count)
        }
        let frameCount = Int64(buffer.frameLength)
        let generation = assistantAudioGeneration
        queuedAssistantBufferCount += 1
        extendAssistantAnimation(for: Double(buffer.frameLength) / realtimeFormat.sampleRate)
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.assistantAudioGeneration == generation else { return }
                self.confirmedPlayedAssistantFrames += frameCount
                self.queuedAssistantBufferCount = max(0, self.queuedAssistantBufferCount - 1)
                self.finishAssistantSpeechIfPlaybackCompleted()
            }
        }
        hasQueuedAssistantAudio = true
        updateAssistantAudioLevel(from: data)
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func finishAssistantSpeechIfPlaybackCompleted() {
        // `dataPlayedBack` can be delivered before all device-side output has
        // audibly drained. The PCM duration window is the visual authority.
        guard responseAudioIsComplete,
              queuedAssistantBufferCount == 0,
              Date() >= assistantAnimationEnd else { return }
        stopAssistantAnimation()
    }

    private func extendAssistantAnimation(for duration: TimeInterval) {
        assistantAnimationEnd = max(Date(), assistantAnimationEnd).addingTimeInterval(duration)
        isAssistantSpeaking = true

        if assistantAnimationTask == nil {
            assistantAnimationTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isAssistantSpeaking else { return }
                    // The visual is intentionally expressive rather than a
                    // literal oscilloscope of the encoded PCM amplitude.
                    self.assistantAnimationLevel = CGFloat.random(in: 0.34...0.92)
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 110_000_000...220_000_000))
                }
            }
        }

        assistantAnimationStopTask?.cancel()
        let interval = max(0, assistantAnimationEnd.timeIntervalSinceNow)
        assistantAnimationStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self, Date() >= self.assistantAnimationEnd else { return }
            self.stopAssistantAnimation()
        }
    }

    private func stopAssistantAnimation() {
        hasQueuedAssistantAudio = false
        isAssistantSpeaking = false
        assistantAnimationLevel = 0
        assistantAnimationTask?.cancel()
        assistantAnimationTask = nil
        assistantAnimationStopTask?.cancel()
        assistantAnimationStopTask = nil
    }

    private func updateAssistantAudioLevel(from pcmData: Data) {
        let rms = pcmData.withUnsafeBytes { rawBuffer -> Double in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let meanSquare = samples.reduce(0.0) { partial, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return partial + (normalized * normalized)
            } / Double(samples.count)
            return sqrt(meanSquare)
        }

        // Speech is naturally quiet in PCM terms; a gentle curve gives the
        // visual enough motion without reacting to low-level noise.
        let target = min(1, pow(rms * 6, 0.62))
        assistantAudioLevel = max(target, assistantAudioLevel * 0.70)

        audioLevelDecayTask?.cancel()
        audioLevelDecayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled, let self else { return }
                self.assistantAudioLevel *= 0.72
                if self.assistantAudioLevel < 0.012 {
                    self.assistantAudioLevel = 0
                    return
                }
            }
        }
    }

    /// Server VAD automatically cancels the active response when it sees a new
    /// user speech turn. WebSocket clients still own their playback queue, so
    /// clear it locally and truncate the unplayed assistant audio.
    private func interruptAssistantPlayback() async {
        guard isResponding || hasQueuedAssistantAudio else { return }

        let playedFrames = confirmedPlayedAssistantFrames
        let interruptedItemID = activeOutputItemID

        discardingInterruptedAudio = true
        assistantAudioGeneration &+= 1
        playerNode.stop() // Also clears AVAudioPlayerNode's scheduled buffers.
        audioLevelDecayTask?.cancel()
        assistantAudioLevel = 0
        hasQueuedAssistantAudio = false
        queuedAssistantBufferCount = 0
        responseAudioIsComplete = true
        stopAssistantAnimation()
        isResponding = false
        confirmedPlayedAssistantFrames = 0

        if let itemID = interruptedItemID, playedFrames > 0 {
            // Use only frames that AVAudioPlayerNode has confirmed as played.
            // This is intentionally conservative: it cannot exceed the audio
            // content OpenAI sent, unlike an elapsed wall-clock estimate.
            let audioEndMilliseconds = Int(
                (Double(playedFrames) / realtimeFormat.sampleRate) * 1_000
            )
            try? await sendEvent([
                "type": "conversation.item.truncate",
                "item_id": itemID,
                "content_index": 0,
                "audio_end_ms": audioEndMilliseconds
            ])
        }

        log("User interrupted assistant; stopped queued response audio", category: .audio)
    }

    private func sendEvent(_ event: [String: Any]) async throws {
        guard let webSocket else { throw RealtimeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else { throw RealtimeError.encodingFailed }
        try await webSocket.send(.string(text))
    }

    private func fail(_ message: String) {
        errorMessage = message
        stateLabel = "Unavailable"
        isConnected = false
        log(message, category: .realtime)
    }

    private func log(_ message: String, category: LogCategory) {
        wearablesManager?.appendLog(message, category: category)
    }
}

enum TurnImagePolicy {
    /// One current preview frame is attached to each completed turn.
    static func shouldCaptureImage(for transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum RealtimeError: LocalizedError {
    case microphonePermissionDenied
    case glassesAudioUnavailable
    case invalidEndpoint
    case notConnected
    case encodingFailed
    case invalidHandshake
    case connectionRejected(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required to talk through the Meta glasses."
        case .glassesAudioUnavailable:
            return "Meta glasses microphone and speakers are not the active Bluetooth audio route. Reconnect them in iOS, then retry the assistant."
        case .invalidEndpoint:
            return "The Realtime API endpoint is invalid."
        case .notConnected:
            return "The Realtime assistant is not connected."
        case .encodingFailed:
            return "Could not encode a Realtime API event."
        case .invalidHandshake:
            return "OpenAI did not confirm the Realtime session. Check the model access and API key."
        case .connectionRejected(let message):
            return "OpenAI rejected the Realtime connection: \(message)"
        }
    }
}
