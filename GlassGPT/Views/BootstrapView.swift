import SwiftUI

struct BootstrapView: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text("GlassGPT")
                    .font(.title2.weight(.semibold))

                Text("Connecting to Meta Wearables…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    BootstrapView()
}
