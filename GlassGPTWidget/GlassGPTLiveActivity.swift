import ActivityKit
import SwiftUI
import WidgetKit

struct GlassGPTLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlassGPTActivityAttributes.self) { context in
            HStack(spacing: 12) {
                liveActivityArtwork
                VStack(alignment: .leading, spacing: 2) {
                    Text("GlassGPT").font(.headline)
                    Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .activityBackgroundTint(.black.opacity(0.88))
            .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    dynamicIslandArtwork
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("GlassGPT").font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                dynamicIslandArtwork
            } compactTrailing: {
                Image(systemName: context.state.isResponding ? "waveform" : "ear.fill")
                    .foregroundStyle(.green)
            } minimal: {
                dynamicIslandArtwork
            }
            .widgetURL(URL(string: "glassgpt://"))
            .keylineTint(.green)
        }
    }

    @ViewBuilder
    private func statusIcon(isResponding: Bool) -> some View {
        Image(systemName: isResponding ? "waveform" : "ear.fill")
            .symbolEffect(.variableColor.iterative, isActive: isResponding)
    }

    private var liveActivityArtwork: some View {
        Image("LiveActivityArtwork")
            .resizable()
            .scaledToFill()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dynamicIslandArtwork: some View {
        Image("DynamicIslandArtwork")
            .resizable()
            .scaledToFill()
            .frame(width: 22, height: 22)
            .clipShape(Circle())
    }
}

@main
struct GlassGPTWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlassGPTLiveActivity()
    }
}
