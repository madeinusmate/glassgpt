import SwiftUI
import UIKit

struct MainTabView: View {
    @StateObject private var cameraStreamManager = CameraStreamManager()
    @StateObject private var realtimeConversationManager = RealtimeConversationManager()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var nativeActionsManager = NativeActionsManager()
    @StateObject private var liveActivityManager = LiveActivityManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HomeView()
        .environmentObject(cameraStreamManager)
        .environmentObject(realtimeConversationManager)
        .environmentObject(locationManager)
        .environmentObject(nativeActionsManager)
        .onChange(of: cameraStreamManager.isStreaming) { _, isStreaming in
            // The Meta video stream may be suspended independently while the
            // app is backgrounded. Preserve the voice-only Realtime assistant
            // in that case; foreground stream failures still end the assistant.
            guard !isStreaming, scenePhase == .active else { return }
            Task {
                await realtimeConversationManager.stop()
            }
        }
        .onChange(of: realtimeConversationManager.isConnected) { _, isConnected in
            Task {
                if isConnected {
                    await liveActivityManager.start()
                } else {
                    await liveActivityManager.stop()
                }
            }
        }
        .onChange(of: realtimeConversationManager.isResponding) { _, isResponding in
            Task {
                await liveActivityManager.update(isResponding: isResponding)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            Task {
                await liveActivityManager.stop()
                await realtimeConversationManager.stop()
                await cameraStreamManager.stopStream()
            }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(WearablesManager())
}
