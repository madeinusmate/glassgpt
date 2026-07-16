import MWDATCore
import SwiftUI

@main
struct GlassGPTApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var wearablesManager = WearablesManager()

    var body: some Scene {
        WindowGroup {
            ContentRoot()
                .environmentObject(wearablesManager)
        }
    }
}

private struct ContentRoot: View {
    @EnvironmentObject private var wearablesManager: WearablesManager
    @State private var isShowingSplash = true

    var body: some View {
        ZStack {
            Group {
                if wearablesManager.isBootstrapped {
                    MainTabView()
                } else {
                    BootstrapView()
                }
            }

            if isShowingSplash {
                SplashView()
                    .transition(.opacity)
            }
        }
        .task {
            await wearablesManager.bootstrapIfNeeded()
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_350_000_000)
            withAnimation(.easeOut(duration: 0.32)) {
                isShowingSplash = false
            }
        }
        .onOpenURL { url in
            Task {
                await wearablesManager.handleURL(url)
            }
        }
    }
}
