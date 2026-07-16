import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager: ObservableObject {
    private var activity: Activity<GlassGPTActivityAttributes>?

    func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }

        let state = GlassGPTActivityAttributes.ContentState(status: "Listening", isResponding: false)
        do {
            activity = try Activity.request(
                attributes: GlassGPTActivityAttributes(sessionName: "GlassGPT"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // A Live Activity is optional presentation; failure must not affect voice chat.
            activity = nil
        }
    }

    func update(isResponding: Bool) async {
        guard let activity else { return }
        let state = GlassGPTActivityAttributes.ContentState(
            status: isResponding ? "GlassGPT is replying" : "Listening",
            isResponding: isResponding
        )
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func stop() async {
        guard let activity else { return }
        let finalState = GlassGPTActivityAttributes.ContentState(status: "Session ended", isResponding: false)
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
        self.activity = nil
    }
}
