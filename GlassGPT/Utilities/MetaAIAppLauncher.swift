import UIKit

enum MetaAIAppLauncher {
    static let querySchemes = [
        "fb-viewapp",
        "fb-viewapp-deeplink",
        "meta-view",
    ]

    static let manualDATUpdateSteps = """
    1. Open Meta AI manually.
    2. Go to Settings → App connections → Developer mode apps.
    3. Tap GlassGPT and install/update the on-glasses app if shown.
    4. If there is no Update button, finish the Wearables Developer Center release channel setup in SETUP.md, then disconnect and re-pair your glasses in Meta AI.
    """

    static func canOpenMetaAI() -> Bool {
        querySchemes.contains { scheme in
            guard let url = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    @MainActor
    static func openMetaAI() async -> Bool {
        for scheme in querySchemes {
            guard let url = URL(string: "\(scheme)://") else { continue }
            guard UIApplication.shared.canOpenURL(url) else { continue }

            let opened = await UIApplication.shared.open(url)
            if opened {
                return true
            }
        }

        return false
    }
}
