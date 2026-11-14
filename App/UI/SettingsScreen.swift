import SwiftUI

/// Sources, reader options, troubleshooting and the privacy statement.
struct SettingsScreen: View {
    @EnvironmentObject private var store: SourceStore
    @AppStorage("reader.twoPages") private var twoPages = true
    @State private var cacheCleared = false
    @State private var cacheMB: Int?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section(header: Text("Sources"),
                    footer: Text("MangaDex is built in. Other sources come from repositories you add yourself.")) {
                NavigationLink(destination: SourcesScreen()) {
                    HStack {
                        Label("Sources and repositories", systemImage: "square.stack.3d.up")
                        Spacer()
                        Text("\(store.installed.count) installed").foregroundColor(Theme.muted)
                    }
                }
            }
            .listRowBackground(Theme.surface)

            Section(header: Text("Reader"),
                    footer: Text("In landscape, two pages are shown side by side like an open book. The ⇄ button in the reader shifts the pairing by one page for the manga you are reading.")) {
                Toggle("Two pages in landscape", isOn: $twoPages)
            }
            .listRowBackground(Theme.surface)

            Section(header: Text("Troubleshooting"),
                    footer: Text("If something fails, open the log and send a screenshot of it. Downloaded covers and pages are kept up to 500 MB; the oldest are removed first.")) {
                NavigationLink(destination: LogScreen()) {
                    Label("Log", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    ImagePipeline.shared.clearDisk()
                    cacheCleared = true
                } label: {
                    Label(cacheCleared ? "Image cache cleared"
                          : cacheMB.map { "Clear image cache (\($0) MB)" } ?? "Clear image cache", systemImage: "trash")
                }
                .disabled(cacheCleared)
            }
            .listRowBackground(Theme.surface)

            Section(header: Text("Privacy"),
                    footer: Text("Version \(version)")) {
                Text("No analytics, no telemetry, no accounts. Nothing leaves this iPad except the requests your sources make to their own sites when you browse or read. A source can see what you search and open on its site. Cookies from site verification are kept in a private file inside the app, one per source.")
                    .font(.callout)
                    .foregroundColor(Theme.muted)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .task {
            // Measured off the main thread: it walks every cached file.
            cacheMB = await Task.detached { ImagePipeline.shared.diskUsage() / 1_048_576 }.value
        }
    }
}
