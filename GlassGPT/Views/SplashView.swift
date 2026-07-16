import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image("SplashArtwork")
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 38, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
                    .frame(width: 172, height: 172)

                VStack(spacing: 8) {
                    Text("GlassGPT")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Zuck 🤝 Sam 🤝 Tim Apple")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

}

#Preview {
    SplashView()
}
