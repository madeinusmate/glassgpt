import EventKit
import Foundation
import MapKit
import Contacts
import CoreLocation
import MusicKit
import Photos
import UIKit
import UserNotifications

/// Owns the narrow set of device actions that GlassGPT may perform for a user.
/// Realtime only asks for these actions; this object remains the authority that
/// checks the user's Settings choices, iOS permissions, and validates inputs.
@MainActor
final class NativeActionsManager: NSObject, ObservableObject {
    @Published private(set) var remindersStatus = "Not allowed"
    @Published private(set) var calendarStatus = "Not allowed"
    @Published private(set) var isMapsEnabled: Bool
    @Published private(set) var notificationsStatus = "Not allowed"
    @Published private(set) var contactsStatus = "Not allowed"
    @Published private(set) var locationAutomationStatus = "Not allowed"
    @Published private(set) var musicStatus = "Not allowed"
    @Published private(set) var photosStatus = "Not allowed"

    private let eventStore = EKEventStore()
    private let mapsEnabledKey = "nativeActions.mapsEnabled"
    private let contactsStore = CNContactStore()
    private let locationManager = CLLocationManager()
    private weak var cameraStreamManager: CameraStreamManager?

    override init() {
        isMapsEnabled = UserDefaults.standard.object(forKey: mapsEnabledKey) as? Bool ?? true
        super.init()
        locationManager.delegate = self
        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        remindersStatus = statusLabel(for: EKEventStore.authorizationStatus(for: .reminder))
        calendarStatus = statusLabel(for: EKEventStore.authorizationStatus(for: .event))
        contactsStatus = contactsStatusLabel(CNContactStore.authorizationStatus(for: .contacts))
        locationAutomationStatus = locationStatusLabel(locationManager.authorizationStatus)
        photosStatus = photosStatusLabel(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        Task { await refreshNotificationsStatus() }
        musicStatus = musicStatusLabel(MusicAuthorization.currentStatus)
    }

    func setCameraStreamManager(_ cameraStreamManager: CameraStreamManager) {
        self.cameraStreamManager = cameraStreamManager
    }

    func requestRemindersAccess() async {
        do {
            _ = try await eventStore.requestFullAccessToReminders()
        } catch {
            // The status label below gives the user the actionable state.
        }
        refreshPermissionStatus()
    }

    func requestCalendarAccess() async {
        do {
            _ = try await eventStore.requestWriteOnlyAccessToEvents()
        } catch {
            // The status label below gives the user the actionable state.
        }
        refreshPermissionStatus()
    }

    func requestNotificationsAccess() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotificationsStatus()
    }

    func requestContactsAccess() async {
        _ = try? await contactsStore.requestAccess(for: .contacts)
        refreshPermissionStatus()
    }

    func requestLocationAutomationAccess() {
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func requestMusicAccess() async {
        _ = await MusicAuthorization.request()
        refreshPermissionStatus()
    }

    func requestPhotosAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        refreshPermissionStatus()
    }

    func setMapsEnabled(_ enabled: Bool) {
        isMapsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: mapsEnabledKey)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var realtimeTools: [[String: Any]] {
        var tools: [[String: Any]] = []

        if canWriteReminders {
            tools.append(Self.reminderTool)
        }
        if canWriteCalendar {
            tools.append(Self.calendarTool)
        }
        if isMapsEnabled {
            tools.append(Self.directionsTool)
        }
        if notificationsAllowed {
            tools += [Self.timerTool, Self.notificationTool]
        }
        if contactsAllowed {
            tools += [Self.searchContactsTool, Self.callContactTool]
        }
        if locationAutomationAllowed, notificationsAllowed {
            tools.append(Self.locationReminderTool)
        }
        if musicAllowed {
            tools.append(Self.playMusicTool)
        }
        if photosAllowed, cameraStreamManager != nil {
            tools.append(Self.savePhotoTool)
        }
        return tools
    }

    func perform(name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "create_reminder":
                return try createReminder(arguments)
            case "create_calendar_event":
                return try createCalendarEvent(arguments)
            case "open_directions":
                return try await openDirections(arguments)
            case "schedule_timer":
                return try await scheduleTimer(arguments)
            case "schedule_notification":
                return try await scheduleNotification(arguments)
            case "search_contacts":
                return try searchContacts(arguments)
            case "call_contact":
                return try callContact(arguments)
            case "create_location_reminder":
                return try await createLocationReminder(arguments)
            case "play_music":
                return try await playMusic(arguments)
            case "save_current_photo":
                return try await saveCurrentPhoto()
            default:
                return ["ok": false, "message": "That device action is not available."]
            }
        } catch {
            return ["ok": false, "message": error.localizedDescription]
        }
    }

    private var canWriteReminders: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    private var canWriteCalendar: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess || status == .writeOnly
    }

    private var notificationsAllowed: Bool { notificationsStatus == "Allowed" }
    private var contactsAllowed: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized || status == .limited
    }
    private var locationAutomationAllowed: Bool { locationManager.authorizationStatus == .authorizedAlways }
    private var musicAllowed: Bool { MusicAuthorization.currentStatus == .authorized }
    private var photosAllowed: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private func createReminder(_ arguments: [String: Any]) throws -> [String: Any] {
        guard canWriteReminders else { throw NativeActionError.remindersNotAllowed }
        guard let title = nonEmptyString(arguments["title"]) else { throw NativeActionError.missingTitle }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw NativeActionError.noReminderList
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = arguments["notes"] as? String
        if let dueAt = parseDate(arguments["due_at"] as? String) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueAt
            )
        }
        try eventStore.save(reminder, commit: true)
        return ["ok": true, "message": "Reminder created: \(title)"]
    }

    private func createCalendarEvent(_ arguments: [String: Any]) throws -> [String: Any] {
        guard canWriteCalendar else { throw NativeActionError.calendarNotAllowed }
        guard let title = nonEmptyString(arguments["title"]),
              let start = parseDate(arguments["start_at"] as? String) else {
            throw NativeActionError.invalidEvent
        }
        let end = parseDate(arguments["end_at"] as? String) ?? start.addingTimeInterval(60 * 60)
        guard end > start, let calendar = eventStore.defaultCalendarForNewEvents else {
            throw NativeActionError.invalidEvent
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = arguments["notes"] as? String
        event.location = arguments["location"] as? String
        try eventStore.save(event, span: .thisEvent, commit: true)
        return ["ok": true, "message": "Calendar event created: \(title)"]
    }

    private func openDirections(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard isMapsEnabled else { throw NativeActionError.mapsDisabled }
        guard let destination = nonEmptyString(arguments["destination"]) else {
            throw NativeActionError.missingDestination
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destination
        let response = try await MKLocalSearch(request: request).start()
        guard let mapItem = response.mapItems.first else { throw NativeActionError.destinationNotFound }

        let mode = arguments["travel_mode"] as? String
        let directionsMode: String = switch mode {
        case "walking": MKLaunchOptionsDirectionsModeWalking
        case "transit": MKLaunchOptionsDirectionsModeTransit
        default: MKLaunchOptionsDirectionsModeDriving
        }
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: directionsMode])
        return ["ok": true, "message": "Opened Apple Maps directions to \(mapItem.name ?? destination)."]
    }

    private func scheduleTimer(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard notificationsAllowed else { throw NativeActionError.notificationsNotAllowed }
        guard let title = nonEmptyString(arguments["title"]),
              let seconds = arguments["duration_seconds"] as? Double,
              seconds >= 1, seconds <= 604_800 else { throw NativeActionError.invalidTimer }
        try await addNotification(
            identifier: "timer.\(UUID().uuidString)", title: title,
            body: "Your timer is complete.", trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        )
        return ["ok": true, "message": "Timer set for \(Int(seconds)) seconds: \(title)."]
    }

    private func scheduleNotification(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard notificationsAllowed else { throw NativeActionError.notificationsNotAllowed }
        guard let title = nonEmptyString(arguments["title"]),
              let date = parseDate(arguments["due_at"] as? String), date > Date() else {
            throw NativeActionError.invalidNotification
        }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try await addNotification(
            identifier: "reminder.\(UUID().uuidString)", title: title,
            body: arguments["body"] as? String ?? "", trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        return ["ok": true, "message": "Notification scheduled for \(ISO8601DateFormatter().string(from: date))."]
    }

    private func searchContacts(_ arguments: [String: Any]) throws -> [String: Any] {
        guard contactsAllowed else { throw NativeActionError.contactsNotAllowed }
        guard let query = nonEmptyString(arguments["query"]) else { throw NativeActionError.missingContactQuery }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try contactsStore.unifiedContacts(matching: predicate, keysToFetch: keys).prefix(5)
        let results = contacts.compactMap { contact -> [String: String]? in
            guard !contact.phoneNumbers.isEmpty else { return nil }
            return [
                "identifier": contact.identifier,
                "name": CNContactFormatter.string(from: contact, style: .fullName) ?? "Contact",
                "phone_count": "\(contact.phoneNumbers.count)"
            ]
        }
        return ["ok": true, "contacts": results]
    }

    private func callContact(_ arguments: [String: Any]) throws -> [String: Any] {
        guard contactsAllowed else { throw NativeActionError.contactsNotAllowed }
        guard let identifier = nonEmptyString(arguments["contact_identifier"]) else { throw NativeActionError.missingContactQuery }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor]
        let contact = try contactsStore.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        guard let phone = contact.phoneNumbers.first?.value.stringValue,
              let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })") else {
            throw NativeActionError.noPhoneNumber
        }
        UIApplication.shared.open(url)
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "contact"
        return ["ok": true, "message": "Opened the call screen for \(name)."]
    }

    private func createLocationReminder(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard locationAutomationAllowed else { throw NativeActionError.locationAutomationNotAllowed }
        guard notificationsAllowed else { throw NativeActionError.notificationsNotAllowed }
        guard let destination = nonEmptyString(arguments["destination"]),
              let title = nonEmptyString(arguments["title"]) else { throw NativeActionError.missingDestination }
        let radius = min(max(arguments["radius_meters"] as? CLLocationDistance ?? 200, 100), 1_000)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destination
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw NativeActionError.destinationNotFound }
        let region = CLCircularRegion(center: item.placemark.coordinate, radius: radius, identifier: "geofence.\(UUID().uuidString)")
        region.notifyOnEntry = true
        region.notifyOnExit = false
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { throw NativeActionError.locationAutomationNotAllowed }
        locationManager.startMonitoring(for: region)
        let record = GeofenceReminder(title: title, body: arguments["body"] as? String ?? "", identifier: region.identifier)
        saveGeofence(record)
        return ["ok": true, "message": "I'll notify you when you arrive near \(item.name ?? destination)."]
    }

    private func playMusic(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard musicAllowed else { throw NativeActionError.musicNotAllowed }
        guard let query = nonEmptyString(arguments["query"]) else { throw NativeActionError.missingMusicQuery }
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 1
        let response = try await request.response()
        guard let song = response.songs.first else { throw NativeActionError.musicNotFound }
        ApplicationMusicPlayer.shared.queue = [song]
        try await ApplicationMusicPlayer.shared.play()
        return ["ok": true, "message": "Playing \(song.title) by \(song.artistName)."]
    }

    private func saveCurrentPhoto() async throws -> [String: Any] {
        guard photosAllowed else { throw NativeActionError.photosNotAllowed }
        guard let data = cameraStreamManager?.latestLiveFrameData(), let image = UIImage(data: data) else {
            throw NativeActionError.noPhotoAvailable
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
        return ["ok": true, "message": "Saved the current glasses view to Photos."]
    }

    private func addNotification(identifier: String, title: String, body: String, trigger: UNNotificationTrigger?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private func refreshNotificationsStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsStatus = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional ? "Allowed" : "Not allowed"
    }

    private func saveGeofence(_ record: GeofenceReminder) {
        var records = (UserDefaults.standard.data(forKey: "nativeActions.geofences")).flatMap { try? JSONDecoder().decode([GeofenceReminder].self, from: $0) } ?? []
        records.append(record)
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: "nativeActions.geofences")
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func statusLabel(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess, .writeOnly: "Allowed"
        case .denied, .restricted: "Not allowed"
        case .notDetermined: "Not requested"
        @unknown default: "Unavailable"
        }
    }

    private static let reminderTool: [String: Any] = [
        "type": "function",
        "name": "create_reminder",
        "description": "Create a reminder in Apple Reminders. Call immediately when the user asks to be reminded; infer title and due time from the request.",
        "parameters": [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "due_at": ["type": "string", "description": "ISO-8601 date-time in the user's time zone."],
                "notes": ["type": "string"]
            ],
            "required": ["title"],
            "additionalProperties": false
        ]
    ]

    private static let calendarTool: [String: Any] = [
        "type": "function",
        "name": "create_calendar_event",
        "description": "Create an event in Apple Calendar. Call immediately when the user asks to schedule something; infer title, date, and time from the request.",
        "parameters": [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "start_at": ["type": "string", "description": "ISO-8601 date-time in the user's time zone."],
                "end_at": ["type": "string", "description": "ISO-8601 date-time in the user's time zone."],
                "location": ["type": "string"],
                "notes": ["type": "string"]
            ],
            "required": ["title", "start_at"],
            "additionalProperties": false
        ]
    ]

    private static let directionsTool: [String: Any] = [
        "type": "function",
        "name": "open_directions",
        "description": "Open turn-by-turn directions in Apple Maps. Call immediately when the user asks for directions.",
        "parameters": [
            "type": "object",
            "properties": [
                "destination": ["type": "string"],
                "travel_mode": ["type": "string", "enum": ["driving", "walking", "transit"]]
            ],
            "required": ["destination"],
            "additionalProperties": false
        ]
    ]

    private static let timerTool: [String: Any] = tool(name: "schedule_timer", description: "Set a GlassGPT timer that sends a local notification. Call immediately when the user asks for a timer.", properties: ["title": ["type": "string"], "duration_seconds": ["type": "number"]], required: ["title", "duration_seconds"])
    private static let notificationTool: [String: Any] = tool(name: "schedule_notification", description: "Schedule a local notification. Call immediately when the user asks to be notified.", properties: ["title": ["type": "string"], "body": ["type": "string"], "due_at": ["type": "string", "description": "ISO-8601 date-time in the user's time zone."]], required: ["title", "due_at"])
    private static let searchContactsTool: [String: Any] = tool(name: "search_contacts", description: "Find the user's contacts by name before calling. Call immediately when the user asks to find or call someone.", properties: ["query": ["type": "string"]], required: ["query"])
    private static let callContactTool: [String: Any] = tool(name: "call_contact", description: "Open the iPhone call screen for a contact returned by search_contacts. Call immediately once you have a matching contact_identifier.", properties: ["contact_identifier": ["type": "string"]], required: ["contact_identifier"])
    private static let locationReminderTool: [String: Any] = tool(name: "create_location_reminder", description: "Create an arrival-based local notification around a place. Call immediately when the user asks for an arrival reminder.", properties: ["title": ["type": "string"], "destination": ["type": "string"], "body": ["type": "string"], "radius_meters": ["type": "number"]], required: ["title", "destination"])
    private static let playMusicTool: [String: Any] = tool(name: "play_music", description: "Search Apple Music and begin playback. Call immediately when the user asks to play something.", properties: ["query": ["type": "string"]], required: ["query"])
    private static let savePhotoTool: [String: Any] = tool(name: "save_current_photo", description: "Save the current glasses camera view to the user's Photos library. Call immediately when the user asks to save or capture a photo.", properties: [:], required: [])

    private static func tool(name: String, description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    private func contactsStatusLabel(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .limited: "Allowed"
        case .notDetermined: "Not requested"
        case .denied, .restricted: "Not allowed"
        @unknown default: "Unavailable"
        }
    }

    private func locationStatusLabel(_ status: CLAuthorizationStatus) -> String {
        status == .authorizedAlways ? "Allowed" : status == .notDetermined ? "Not requested" : "Not allowed"
    }

    private func musicStatusLabel(_ status: MusicAuthorization.Status) -> String {
        status == .authorized ? "Allowed" : status == .notDetermined ? "Not requested" : "Not allowed"
    }

    private func photosStatusLabel(_ status: PHAuthorizationStatus) -> String {
        status == .authorized || status == .limited ? "Allowed" : status == .notDetermined ? "Not requested" : "Not allowed"
    }
}

extension NativeActionsManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshPermissionStatus()
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let records = (UserDefaults.standard.data(forKey: "nativeActions.geofences")).flatMap { try? JSONDecoder().decode([GeofenceReminder].self, from: $0) } ?? []
        guard let record = records.first(where: { $0.identifier == region.identifier }) else { return }
        Task {
            try? await addNotification(identifier: "arrival.\(region.identifier)", title: record.title, body: record.body, trigger: nil)
        }
        manager.stopMonitoring(for: region)
        let remaining = records.filter { $0.identifier != region.identifier }
        UserDefaults.standard.set(try? JSONEncoder().encode(remaining), forKey: "nativeActions.geofences")
    }
}

private struct GeofenceReminder: Codable {
    let title: String
    let body: String
    let identifier: String
}

private enum NativeActionError: LocalizedError {
    case remindersNotAllowed, calendarNotAllowed, mapsDisabled, missingTitle, noReminderList, invalidEvent, missingDestination, destinationNotFound, notificationsNotAllowed, invalidTimer, invalidNotification, contactsNotAllowed, missingContactQuery, noPhoneNumber, locationAutomationNotAllowed, musicNotAllowed, missingMusicQuery, musicNotFound, photosNotAllowed, noPhotoAvailable

    var errorDescription: String? {
        switch self {
        case .remindersNotAllowed: "Reminders access is not enabled in Settings."
        case .calendarNotAllowed: "Calendar access is not enabled in Settings."
        case .mapsDisabled: "Apple Maps directions are disabled in Settings."
        case .missingTitle: "A title is required."
        case .noReminderList: "No default Reminders list is available."
        case .invalidEvent: "A calendar event needs a valid start time and an end time after its start."
        case .missingDestination: "A destination is required."
        case .destinationNotFound: "Apple Maps could not find that destination."
        case .notificationsNotAllowed: "Notifications are not enabled in Settings."
        case .invalidTimer: "A timer must be between one second and seven days."
        case .invalidNotification: "A notification needs a future date and a title."
        case .contactsNotAllowed: "Contacts access is not enabled in Settings."
        case .missingContactQuery: "A contact name is required."
        case .noPhoneNumber: "That contact does not have a callable phone number."
        case .locationAutomationNotAllowed: "Always Allow location access is needed for arrival reminders."
        case .musicNotAllowed: "Apple Music access is not enabled in Settings."
        case .missingMusicQuery: "A song, artist, or album is required."
        case .musicNotFound: "Apple Music could not find that selection."
        case .photosNotAllowed: "Photos access is not enabled in Settings."
        case .noPhotoAvailable: "There is no current glasses photo to save."
        }
    }
}
