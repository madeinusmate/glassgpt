import Foundation
import MWDATCore

@MainActor
final class WearablesManager: ObservableObject {
    @Published private(set) var isBootstrapped = false
    @Published private(set) var registrationStateLabel = "Unknown"
    @Published private(set) var isRegistered = false
    @Published private(set) var connectedDeviceCount = 0
    @Published private(set) var connectedDeviceId: DeviceIdentifier?
    @Published private(set) var activeDeviceLabel = "Unknown"
    @Published private(set) var eventLog: [LogEntry] = []
    @Published private(set) var isRegistering = false
    @Published private(set) var lastNavigationNote: String?

    private var wearables: WearablesInterface?
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var activeDeviceTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var sharedDeviceSelector: AutoDeviceSelector?

    var datWearables: WearablesInterface? {
        wearables
    }

    var deviceSelector: AutoDeviceSelector? {
        sharedDeviceSelector
    }

    var canRegister: Bool {
        isBootstrapped && !isRegistered && !isRegistering && registrationStateLabel != "Unavailable"
    }

    var canUnregister: Bool {
        isBootstrapped && isRegistered && !isRegistering
    }

    func bootstrapIfNeeded() async {
        guard !isBootstrapped, bootstrapTask == nil else { return }

        bootstrapTask = Task { @MainActor in
            await Task.yield()

            log("Bootstrapping Meta Wearables SDK", category: .sdk)

            do {
                try Wearables.configure()
                wearables = Wearables.shared
                sharedDeviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
                startRegistrationListener()
                startDevicesListener()
                startActiveDeviceListener()
                isBootstrapped = true
                logSDKConfiguration()
                log("Meta Wearables SDK ready", category: .sdk)
            } catch {
                registrationStateLabel = "Unavailable"
                log("Bootstrap failed: \(error.localizedDescription)", category: .sdk)
            }

            bootstrapTask = nil
        }

        await bootstrapTask?.value
    }

    func makeDeviceSelector(for deviceId: DeviceIdentifier?) -> any DeviceSelector {
        if let deviceId {
            return SpecificDeviceSelector(device: deviceId)
        }

        if let sharedDeviceSelector {
            return sharedDeviceSelector
        }

        guard let wearables else {
            fatalError("Wearables SDK must be bootstrapped before creating a device selector")
        }

        let selector = AutoDeviceSelector(wearables: wearables)
        sharedDeviceSelector = selector
        return selector
    }

    func waitForReadyDevice(timeoutSeconds: UInt64 = 15) async throws -> DeviceIdentifier {
        guard let wearables, let selector = sharedDeviceSelector else {
            throw DeviceReadinessError.sdkNotReady
        }

        log("Scanning for glasses (DAT list: \(wearables.devices.count), timeout: \(timeoutSeconds)s)", category: .device)
        logDetailedDeviceList(from: wearables)

        if let readyDeviceId = try discoverBestDevice(from: wearables, selector: selector, requireConnectedLink: true) {
            logDeviceDiagnostics(for: readyDeviceId, on: wearables)
            return readyDeviceId
        }

        log("Waiting for glasses to appear in DAT…", category: .device)

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            refreshDeviceSnapshot(from: wearables, selector: selector)

            if let readyDeviceId = try discoverBestDevice(from: wearables, selector: selector, requireConnectedLink: true) {
                logDeviceDiagnostics(for: readyDeviceId, on: wearables)
                return readyDeviceId
            }

            if let readyDeviceId = try discoverBestDevice(from: wearables, selector: selector, requireConnectedLink: false) {
                log("Using glasses before DAT reports fully connected: \(readyDeviceId)", category: .device)
                logDeviceDiagnostics(for: readyDeviceId, on: wearables)
                return readyDeviceId
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw DeviceReadinessError.timeout
    }

    func refreshDeviceSnapshot(from wearables: WearablesInterface? = nil, selector: AutoDeviceSelector? = nil) {
        guard let wearables = wearables ?? self.wearables,
              let selector = selector ?? sharedDeviceSelector else { return }

        let listedDevices = wearables.devices
        connectedDeviceCount = listedDevices.count
        connectedDeviceId = listedDevices.first ?? selector.activeDevice ?? connectedDeviceId

        if listedDevices.isEmpty, selector.activeDevice == nil {
            activeDeviceLabel = "No devices in DAT list"
        } else if let activeDevice = selector.activeDevice,
                  let device = wearables.deviceForIdentifier(activeDevice) {
            activeDeviceLabel = "\(device.nameOrId()) · \(device.linkState)"
        } else if let first = listedDevices.first,
                  let device = wearables.deviceForIdentifier(first) {
            activeDeviceLabel = "\(device.nameOrId()) · \(device.linkState)"
        } else {
            activeDeviceLabel = "\(listedDevices.count) in DAT list"
        }

        log("Device snapshot: list=\(listedDevices.count) active=\(selector.activeDevice ?? "none") label=\(activeDeviceLabel)", category: .device)
        logDetailedDeviceList(from: wearables)
    }

    func logDeviceHealth(for deviceId: DeviceIdentifier) {
        guard let wearables, let device = wearables.deviceForIdentifier(deviceId) else {
            log("Device health unavailable for id=\(deviceId)", category: .device)
            return
        }

        log(
            "Device health id=\(deviceId) name=\(device.nameOrId()) link=\(device.linkState) compatibility=\(device.compatibility().displayString)",
            category: .device
        )
    }

    func appendLog(_ message: String, category: LogCategory = .app) {
        log(message, category: category)
    }

    func clearLog() {
        eventLog = []
    }

    var exportableLogText: String {
        if eventLog.isEmpty {
            return "No events yet"
        }

        return eventLog.map(\.formatted).joined(separator: "\n")
    }

    func openDATGlassesAppUpdate() async -> Bool {
        await bootstrapIfNeeded()
        lastNavigationNote = nil

        guard let wearables else {
            lastNavigationNote = "Wearables SDK is not ready yet."
            log(lastNavigationNote!)
            return false
        }

        guard isRegistered else {
            lastNavigationNote = "Register GlassGPT in Settings first, then retry the glasses app update."
            log(lastNavigationNote!)
            return false
        }

        guard MetaAIAppLauncher.canOpenMetaAI() else {
            lastNavigationNote = "Meta AI is not installed. Install it from the App Store, enable Developer Mode, then retry."
            log(lastNavigationNote!)
            return false
        }

        log("Opening Meta AI to update the DAT app on glasses")

        do {
            try await wearables.openDATGlassesAppUpdate()
            lastNavigationNote = "Meta AI opened. Look for GlassGPT under Developer mode apps and tap Update if shown."
            log("Meta AI opened via SDK for DAT glasses app update")
            return true
        } catch let error as NavigationError {
            log("SDK DAT update navigation failed: \(localizedNavigationError(error))")

            let opened = await MetaAIAppLauncher.openMetaAI()
            if opened {
                lastNavigationNote = "Opened Meta AI manually. \(MetaAIAppLauncher.manualDATUpdateSteps)"
                log("Meta AI opened via fallback URL scheme")
                return true
            }

            lastNavigationNote = localizedNavigationError(error)
            return false
        } catch {
            log("DAT glasses app update failed: \(error.localizedDescription)")

            let opened = await MetaAIAppLauncher.openMetaAI()
            if opened {
                lastNavigationNote = "Opened Meta AI manually. \(MetaAIAppLauncher.manualDATUpdateSteps)"
                return true
            }

            lastNavigationNote = error.localizedDescription
            return false
        }
    }

    func openFirmwareUpdate() async -> Bool {
        await bootstrapIfNeeded()
        lastNavigationNote = nil

        guard let wearables else {
            lastNavigationNote = "Wearables SDK is not ready yet."
            log(lastNavigationNote!)
            return false
        }

        guard isRegistered else {
            lastNavigationNote = "Register GlassGPT in Settings first."
            log(lastNavigationNote!)
            return false
        }

        guard MetaAIAppLauncher.canOpenMetaAI() else {
            lastNavigationNote = "Meta AI is not installed."
            log(lastNavigationNote!)
            return false
        }

        log("Opening Meta AI firmware update")

        do {
            try await wearables.openFirmwareUpdate()
            lastNavigationNote = "Meta AI opened to the firmware update screen."
            log("Meta AI opened for firmware update")
            return true
        } catch let error as NavigationError {
            log("SDK firmware navigation failed: \(localizedNavigationError(error))")

            let opened = await MetaAIAppLauncher.openMetaAI()
            if opened {
                lastNavigationNote = "Opened Meta AI manually. Check your glasses device settings for firmware updates."
                return true
            }

            lastNavigationNote = localizedNavigationError(error)
            return false
        } catch {
            log("Firmware update navigation failed: \(error.localizedDescription)")

            let opened = await MetaAIAppLauncher.openMetaAI()
            if opened {
                lastNavigationNote = "Opened Meta AI manually. Check your glasses device settings for firmware updates."
                return true
            }

            lastNavigationNote = error.localizedDescription
            return false
        }
    }

    func requestCameraPermission() async throws -> PermissionStatus {
        await bootstrapIfNeeded()

        guard let wearables else {
            throw DeviceReadinessError.sdkNotReady
        }

        return try await requestCameraPermission(on: wearables)
    }

    private func requestCameraPermission(on wearables: WearablesInterface) async throws -> PermissionStatus {
        var lastError: PermissionError?

        for attempt in 1...3 {
            do {
                var status = try await wearables.checkPermissionStatus(.camera)
                log("Camera permission status=\(String(describing: status))", category: .permission)

                if status == .granted {
                    return status
                }

                log("Requesting camera permission via Meta AI", category: .permission)
                status = try await wearables.requestPermission(.camera)
                log("Camera permission result=\(String(describing: status))", category: .permission)
                return status
            } catch let error as PermissionError {
                lastError = error
                log("Camera permission error case=\(error.description) attempt=\(attempt)/3", category: .permission)

                if error == .connectionError || error == .noDeviceWithConnection, attempt < 3 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                throw error
            }
        }

        if let lastError {
            throw lastError
        }

        throw PermissionError.internalError
    }

    func startRegistration() async {
        await bootstrapIfNeeded()

        guard canRegister, let wearables else {
            log("Register skipped — state: \(registrationStateLabel)")
            return
        }

        isRegistering = true
        log("Starting registration")

        do {
            try await wearables.startRegistration()
            log("Registration flow opened Meta AI — awaiting callback")
        } catch {
            isRegistering = false
            log("Registration failed: \(error.localizedDescription)")
        }
    }

    func startUnregistration() async {
        await bootstrapIfNeeded()

        guard canUnregister, let wearables else {
            log("Unregister skipped — state: \(registrationStateLabel)")
            return
        }

        isRegistering = true
        log("Starting unregistration")

        do {
            try await wearables.startUnregistration()
            log("Unregistration flow opened Meta AI — awaiting callback")
        } catch {
            isRegistering = false
            log("Unregistration failed: \(error.localizedDescription)")
        }
    }

    func handleURL(_ url: URL) async {
        await bootstrapIfNeeded()

        guard let wearables else {
            log("URL ignored — SDK not ready")
            return
        }

        log("Received URL callback: \(url.absoluteString)")

        do {
            let handled = try await wearables.handleUrl(url)
            log(handled ? "URL handled by DAT SDK" : "URL not relevant to DAT SDK")
        } catch {
            log("URL handling failed: \(error.localizedDescription)")
        }

        isRegistering = false
    }

    private func discoverBestDevice(
        from wearables: WearablesInterface,
        selector: AutoDeviceSelector,
        requireConnectedLink: Bool,
        preferredId: DeviceIdentifier? = nil
    ) throws -> DeviceIdentifier? {
        let candidates = Set(
            [preferredId].compactMap { $0 }
                + wearables.devices
                + [selector.activeDevice, connectedDeviceId].compactMap { $0 }
        )

        for deviceId in candidates {
            guard let device = wearables.deviceForIdentifier(deviceId) else {
                log("Device \(deviceId) listed but details unavailable")
                continue
            }

            let compatibility = device.compatibility()
            log("Candidate id=\(deviceId) name=\(device.nameOrId()) link=\(device.linkState) compatibility=\(compatibility.displayString) type=\(String(describing: device.deviceType()))", category: .device)

            if requireConnectedLink, device.linkState != .connected {
                continue
            }

            switch compatibility {
            case .compatible, .undefined:
                connectedDeviceId = deviceId
                connectedDeviceCount = max(connectedDeviceCount, wearables.devices.count, 1)
                activeDeviceLabel = "\(device.nameOrId()) · \(device.linkState)"
                return deviceId
            case .deviceUpdateRequired:
                throw DeviceReadinessError.deviceUpdateRequired
            case .sdkUpdateRequired:
                throw DeviceReadinessError.sdkUpdateRequired
            }
        }

        return nil
    }

    private func logDeviceDiagnostics(for deviceId: DeviceIdentifier, on wearables: WearablesInterface) {
        guard let device = wearables.deviceForIdentifier(deviceId) else {
            log("Selected device \(deviceId) but could not load details", category: .device)
            return
        }

        log(
            "Ready device id=\(deviceId) name=\(device.nameOrId()) uuid=\(device.deviceUUID) link=\(device.linkState) compatibility=\(device.compatibility().displayString) type=\(String(describing: device.deviceType()))",
            category: .device
        )
    }

    private func logDetailedDeviceList(from wearables: WearablesInterface) {
        guard let selector = sharedDeviceSelector else { return }

        if wearables.devices.isEmpty, selector.activeDevice == nil {
            log("No devices in DAT list", category: .device)
            return
        }

        for deviceId in wearables.devices {
            if let device = wearables.deviceForIdentifier(deviceId) {
                log(
                    "Listed id=\(deviceId) name=\(device.nameOrId()) link=\(device.linkState) compatibility=\(device.compatibility().displayString)",
                    category: .device
                )
            } else {
                log("Listed id=\(deviceId) details unavailable", category: .device)
            }
        }

        if let activeDevice = selector.activeDevice {
            log("Active selector device id=\(activeDevice)", category: .device)
        }
    }

    private func logSDKConfiguration() {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let metaAppId = (Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any])?["MetaAppID"] as? String ?? "unknown"
        let damEnabled = (Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any])?["DAMEnabled"] as? Bool ?? false
        log("Config bundle=\(bundleId) metaAppId=\(metaAppId) DAM=\(damEnabled)", category: .sdk)
    }

    private func startRegistrationListener() {
        guard let wearables else { return }

        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    self?.applyRegistrationState(state)
                }
            }
        }
    }

    private func startDevicesListener() {
        guard let wearables else { return }

        devicesTask?.cancel()
        devicesTask = Task { [weak self] in
            for await devices in wearables.devicesStream() {
                await MainActor.run {
                    self?.connectedDeviceCount = devices.count
                    self?.connectedDeviceId = devices.first
                    self?.activeDeviceLabel = devices.isEmpty
                        ? "No devices in DAT list"
                        : "\(devices.count) in DAT list"
                    self?.log("Devices stream update count=\(devices.count) ids=\(devices.joined(separator: ", "))", category: .device)
                }
            }
        }
    }

    private func startActiveDeviceListener() {
        guard let selector = sharedDeviceSelector else { return }

        activeDeviceTask?.cancel()
        activeDeviceTask = Task { [weak self] in
            for await deviceId in selector.activeDeviceStream() {
                await MainActor.run {
                    if let deviceId {
                        self?.connectedDeviceId = deviceId
                        self?.connectedDeviceCount = max(self?.connectedDeviceCount ?? 0, 1)
                        self?.activeDeviceLabel = "Active: \(deviceId)"
                        self?.log("Active device stream id=\(deviceId)", category: .device)
                    } else {
                        self?.activeDeviceLabel = "Waiting for glasses"
                        self?.log("Active device stream cleared", category: .device)
                    }
                }
            }
        }
    }

    private func applyRegistrationState(_ state: RegistrationState) {
        registrationStateLabel = state.description.capitalized
        isRegistered = state == .registered
        isRegistering = state == .registering
        log("Registration state=\(registrationStateLabel) raw=\(state.rawValue) registered=\(isRegistered)", category: .sdk)
    }

    private func localizedNavigationError(_ error: NavigationError) -> String {
        switch error {
        case .metaAINotInstalled:
            return "Meta AI is not installed on this iPhone."
        case .notRegistered:
            return "GlassGPT is not registered with Meta AI yet. Tap Register in Settings first."
        }
    }

    private func log(_ message: String, category: LogCategory = .app) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let entry = LogEntry(timestamp: timestamp, category: category, message: message)
        eventLog.insert(entry, at: 0)

        if eventLog.count > 150 {
            eventLog = Array(eventLog.prefix(150))
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

enum DeviceReadinessError: LocalizedError {
    case sdkNotReady
    case timeout
    case disconnected
    case deviceUpdateRequired
    case sdkUpdateRequired

    var errorDescription: String? {
        switch self {
        case .sdkNotReady:
            return "Wearables SDK is not ready yet."
        case .timeout:
            return "Glasses did not connect in time. Wear them with hinges open, open Meta AI, wait for the connected chime, then retry."
        case .disconnected:
            return "Glasses disconnected before the stream could start."
        case .deviceUpdateRequired:
            return "Your glasses need a firmware or DAT app update. Open Meta AI → App connections → Developer mode apps."
        case .sdkUpdateRequired:
            return "GlassGPT needs a newer DAT SDK for these glasses."
        }
    }
}
