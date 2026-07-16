import ActivityKit

struct GlassGPTActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var isResponding: Bool
    }

    var sessionName: String
}
