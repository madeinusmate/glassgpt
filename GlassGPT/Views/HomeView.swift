import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var wearablesManager: WearablesManager
    @EnvironmentObject private var cameraStreamManager: CameraStreamManager
    @EnvironmentObject private var realtimeConversationManager: RealtimeConversationManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var nativeActionsManager: NativeActionsManager
    @State private var isShowingSettings = false
    @AppStorage("showChatMessages") private var showChatMessages = true

    private var isSessionActive: Bool {
        cameraStreamManager.isStreaming && realtimeConversationManager.isConnected
    }

    private var isTransitioning: Bool {
        cameraStreamManager.isStarting || cameraStreamManager.isStopping
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                Spacer()

                sessionIndicator

                if let sessionFailure {
                    sessionFailureView(sessionFailure)
                        .padding(.top, 20)
                }

                Spacer()

                if isSessionActive, showChatMessages, hasConversationContent {
                    conversationBubbles
                        .padding(.bottom, 16)
                }

                if isSessionActive {
                    sessionControl
                        .padding(.bottom, 12)
                }
            }
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            Text("GlassGPT")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .glassEffect(in: .buttonBorder)
                

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Settings")
            .contentShape(Circle())
        }
    }

    private var sessionIndicator: some View {
        Group {
            if isSessionActive {
                SiriSessionAnimation(
                    isResponding: realtimeConversationManager.isAssistantSpeaking,
                    audioLevel: realtimeConversationManager.assistantAnimationLevel
                )
                .accessibilityLabel("Chat session active, assistant audio level \(Int(realtimeConversationManager.assistantAudioLevel * 100)) percent")
            } else {
                openMyEyesButton
            }
        }
        .frame(width: isSessionActive ? 300 : 216, height: isSessionActive ? 150 : 216)
    }

    private var openMyEyesButton: some View {
        Button {
            Task { await toggleSession() }
        } label: {
            if isTransitioning {
                ProgressView()
                    .tint(.primary)
            } else {
                Image(systemName: "eye.fill")
                    .font(.title2.weight(.semibold))
            }
            Text(isTransitioning ? "Opening…" : "Open my eyes")
                .font(.headline)
        
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Start Session")
        .disabled(isTransitioning || !wearablesManager.isRegistered)
        .contentShape(Circle())
    
//        Button {
//            Task { await toggleSession() }
//        } label: {
//            VStack(spacing: 10) {
//                if isTransitioning {
//                    ProgressView()
//                        .tint(.primary)
//                } else {
//                    Image(systemName: "eye.fill")
//                        .font(.title2.weight(.semibold))
//                }
//                Text(isTransitioning ? "Opening…" : "Open my eyes")
//                    .font(.headline)
//            }
//            .frame(width: 216, height: 216)
//            .contentShape(Circle())
//        }
//        .buttonStyle(.glass)
//        .buttonBorderShape(.circle)
//        .disabled(isTransitioning || !wearablesManager.isRegistered)
//        .accessibilityLabel("Open my eyes and start a chat session")
    }

    private var sessionControl: some View {
        Button {
            Task { await toggleSession() }
        } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.bold))
                .frame(width: 58, height: 58)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(isTransitioning || !wearablesManager.isRegistered)
        .accessibilityLabel("End chat session")
    }

    private func toggleSession() async {
        if cameraStreamManager.isStreaming || cameraStreamManager.isStarting {
            await realtimeConversationManager.stop()
            await cameraStreamManager.stopStream()
            return
        }

        await cameraStreamManager.startStream(with: wearablesManager)
        if cameraStreamManager.isStreaming {
            await realtimeConversationManager.start(
                cameraStreamManager: cameraStreamManager,
                wearablesManager: wearablesManager,
                locationManager: locationManager,
                nativeActionsManager: nativeActionsManager
            )
            if !realtimeConversationManager.isConnected {
                await cameraStreamManager.stopStream()
            }
        }
    }

    private var sessionFailure: String? {
        realtimeConversationManager.errorMessage ?? cameraStreamManager.errorMessage
    }

    private func sessionFailureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Session could not start", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var hasConversationContent: Bool {
        !realtimeConversationManager.currentTranscript.isEmpty || !realtimeConversationManager.responseText.isEmpty
    }

    private var conversationBubbles: some View {
        VStack(spacing: 8) {
            if !realtimeConversationManager.currentTranscript.isEmpty {
                ConversationBubble(
                    title: "You",
                    text: realtimeConversationManager.currentTranscript,
                    imageData: realtimeConversationManager.currentTurnVisionFrameData,
                    alignment: .trailing
                )
            }

            if !realtimeConversationManager.responseText.isEmpty || realtimeConversationManager.isResponding {
                ConversationBubble(
                    title: "GlassGPT",
                    text: realtimeConversationManager.responseText.isEmpty ? "Thinking…" : realtimeConversationManager.responseText,
                    imageData: nil,
                    alignment: .leading
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ConversationBubble: View {
    let title: String
    let text: String
    let imageData: Data?
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .lineLimit(2)
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityLabel("Vision frame sent with this request")
            }
        }
        .frame(maxWidth: 300, alignment: alignment == .leading ? .leading : .trailing)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct SiriSessionAnimation: View {
    let isResponding: Bool
    let audioLevel: CGFloat

    var body: some View {
        // The wave remains intentionally almost flat while GlassGPT listens;
        // it comes alive only when assistant audio is actually being spoken.
        SiriMetalView(
            mode: .wave,
            activity: isResponding && audioLevel > 0.012 ? max(0.15, audioLevel) : 0
        )
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: audioLevel)
    }
}

#Preview {
    HomeView()
        .environmentObject(WearablesManager())
        .environmentObject(CameraStreamManager())
        .environmentObject(RealtimeConversationManager())
        .environmentObject(LocationManager())
        .environmentObject(NativeActionsManager())
}
