import SwiftUI
import UIKit

struct EventLogView: View {
    let entries: [LogEntry]
    let onCopy: () -> Void
    let onClear: () -> Void

    @State private var didCopy = false

    private var fullText: String {
        if entries.isEmpty {
            return "No events yet"
        }

        return entries.map(\.formatted).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Copy all") {
                    UIPasteboard.general.string = fullText
                    onCopy()
                    didCopy = true

                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        didCopy = false
                    }
                }
                .disabled(entries.isEmpty)

                Button("Clear", role: .destructive) {
                    onClear()
                }
                .disabled(entries.isEmpty)

                Spacer()

                if didCopy {
                    Text("Copied")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("\(entries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if entries.isEmpty {
                Text("No events yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 120)
            } else {
                ScrollView {
                    Text(fullText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 320)
            }
        }
    }
}

#Preview {
    EventLogView(
        entries: [
            LogEntry(timestamp: "12:00:01", category: .sdk, message: "Meta Wearables SDK ready"),
            LogEntry(timestamp: "12:00:02", category: .device, message: "Device snapshot: list=1"),
        ],
        onCopy: {},
        onClear: {}
    )
}
