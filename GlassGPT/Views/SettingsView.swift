import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var wearablesManager: WearablesManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var nativeActionsManager: NativeActionsManager
    @EnvironmentObject private var realtimeConversationManager: RealtimeConversationManager
    @State private var isAdvancedExpanded = false
    @AppStorage("showChatMessages") private var showChatMessages = true

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                locationSection
                nativeActionsSection
                advancedSection
            }
            .navigationTitle("Settings")
        }
    }

    private var nativeActionsSection: some View {
        Section("Apple apps") {
            permissionRow(
                title: "Reminders",
                status: nativeActionsManager.remindersStatus,
                buttonTitle: "Allow Reminders"
            ) {
                Task {
                    await nativeActionsManager.requestRemindersAccess()
                    await realtimeConversationManager.refreshNativeTools()
                }
            }

            permissionRow(
                title: "Calendar",
                status: nativeActionsManager.calendarStatus,
                buttonTitle: "Allow Calendar"
            ) {
                Task {
                    await nativeActionsManager.requestCalendarAccess()
                    await realtimeConversationManager.refreshNativeTools()
                }
            }

            permissionRow(title: "Notifications", status: nativeActionsManager.notificationsStatus, buttonTitle: "Allow Notifications") {
                Task {
                    await nativeActionsManager.requestNotificationsAccess()
                    await realtimeConversationManager.refreshNativeTools()
                }
            }

            permissionRow(title: "Contacts", status: nativeActionsManager.contactsStatus, buttonTitle: "Allow Contacts") {
                Task {
                    await nativeActionsManager.requestContactsAccess()
                    await realtimeConversationManager.refreshNativeTools()
                }
            }

            permissionRow(title: "Arrival reminders", status: nativeActionsManager.locationAutomationStatus, buttonTitle: "Allow Always") {
                nativeActionsManager.requestLocationAutomationAccess()
                Task { await realtimeConversationManager.refreshNativeTools() }
            }

            permissionRow(title: "Apple Music", status: nativeActionsManager.musicStatus, buttonTitle: "Allow Apple Music") {
                Task {
                    await nativeActionsManager.requestMusicAccess()
                    await realtimeConversationManager.refreshNativeTools()
                }
            }

            permissionRow(title: "Photos", status: nativeActionsManager.photosStatus, buttonTitle: "Allow Photos") {
                Task {
                    await nativeActionsManager.requestPhotosAccess()
                    await realtimeConversationManager.refreshNativeTools()
                }
            }

            Toggle(
                "Enable Apple Maps directions",
                isOn: Binding(
                    get: { nativeActionsManager.isMapsEnabled },
                    set: { enabled in
                        nativeActionsManager.setMapsEnabled(enabled)
                        Task { await realtimeConversationManager.refreshNativeTools() }
                    }
                )
            )

            Text("GlassGPT asks for confirmation before creating a reminder, calendar event, timer, notification, arrival reminder, call, route, music playback, or saving a photo. Permissions are requested only when you tap their buttons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func permissionRow(title: String, status: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status == "Not allowed" {
                Button("Open Settings") {
                    nativeActionsManager.openSystemSettings()
                }
            } else if status != "Allowed" {
                Button(buttonTitle, action: action)
            }
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Toggle("Show chat messages", isOn: $showChatMessages)

            Text("Show or hide your latest request, its vision frame, and GlassGPT’s latest answer on the main screen. Voice conversations continue either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var locationSection: some View {
        Section("Location") {
            Toggle(
                "Share location with GlassGPT",
                isOn: Binding(
                    get: { locationManager.isSharingEnabled },
                    set: { locationManager.setSharingEnabled($0) }
                )
            )

            LabeledContent("Status") {
                Text(locationManager.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("When enabled, GlassGPT attaches your current coordinates to each assistant request. Location is not shared while this setting is off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    advancedGlassesContent
                    Divider()
                    advancedAppContent
                    Divider()
                    advancedDebugContent
                }
                .padding(.top, 12)
            } label: {
                Label("Advanced settings", systemImage: "wrench.and.screwdriver")
                Text("Glasses tools, diagnostics, and developer information")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedGlassesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Glasses")
                .font(.headline)

            LabeledContent("Registration") {
                RegistrationBadge(label: wearablesManager.registrationStateLabel)
            }

            LabeledContent("Connected devices") {
                Text(wearablesManager.activeDeviceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Button("Register") {
                    Task {
                        await wearablesManager.startRegistration()
                    }
                }
                .disabled(!wearablesManager.canRegister)

                Spacer()

                Button("Unregister", role: .destructive) {
                    Task {
                        await wearablesManager.startUnregistration()
                    }
                }
                .disabled(!wearablesManager.canUnregister)
            }

            if wearablesManager.isRegistered {
                Button("Update DAT app on glasses") {
                    Task {
                        await wearablesManager.openDATGlassesAppUpdate()
                    }
                }

                Button("Open Meta AI manually") {
                    Task {
                        let opened = await MetaAIAppLauncher.openMetaAI()
                        wearablesManager.appendLog(
                            opened
                                ? "Opened Meta AI via fallback URL scheme"
                                : "Could not open Meta AI — install it from the App Store",
                            category: .navigation
                        )
                    }
                }

                Button("Check glasses firmware") {
                    Task {
                        await wearablesManager.openFirmwareUpdate()
                    }
                }

                if let note = wearablesManager.lastNavigationNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Manual DAT update steps") {
                    Text(MetaAIAppLauncher.manualDATUpdateSteps)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var advancedAppContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App")
                .font(.headline)

            LabeledContent("Bundle ID") {
                Text(Bundle.main.bundleIdentifier ?? "—")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            LabeledContent("URL scheme") {
                Text(urlScheme)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedDebugContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug log")
                .font(.headline)

            EventLogView(
                entries: wearablesManager.eventLog,
                onCopy: {
                    wearablesManager.appendLog("Debug log copied to clipboard", category: .app)
                },
                onClear: {
                    wearablesManager.clearLog()
                }
            )
        }
    }

    private var urlScheme: String {
        if let schemes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
           let first = schemes.first,
           let urlSchemes = first["CFBundleURLSchemes"] as? [String],
           let scheme = urlSchemes.first {
            return "\(scheme)://"
        }

        return "glassgpt://"
    }
}

private struct RegistrationBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch label {
        case "Registered":
            return .green
        case "Available":
            return .blue
        case "Registering":
            return .orange
        case "Unavailable":
            return .red
        default:
            return .secondary
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(WearablesManager())
        .environmentObject(LocationManager())
        .environmentObject(NativeActionsManager())
        .environmentObject(RealtimeConversationManager())
}
