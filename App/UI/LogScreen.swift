import SwiftUI
import UIKit

/// Everything the app logged, newest first. Made for screenshots.
struct LogScreen: View {
    @ObservedObject private var log = Log.shared
    @State private var cleared = false

    var body: some View {
        List {
            if !cleared, let tail = log.previousCrashTail {
                Section(header: Text("Last run did not close cleanly. Its final log lines:")) {
                    Text(tail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section(header: Text("This run")) {
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.time)  \(entry.level)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(color(entry.level))
                        Text(entry.text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Clear") { log.clear(); cleared = true }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Copy all") { UIPasteboard.general.string = log.allText }
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        default: return .secondary
        }
    }
}
