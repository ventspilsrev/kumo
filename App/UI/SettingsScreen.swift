import SwiftUI

/// Sources, reader options, troubleshooting and the privacy statement.
struct SettingsScreen: View {
    @EnvironmentObject private var store: SourceStore
    @AppStorage("reader.twoPages") private var twoPages = true
    @State private var cacheCleared = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section(header: Text("Sources"),
                    footer: Text("Kumo ships with no sources. You add repositories yourself and install sources from them.")) {
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
                    footer: Text("If something fails, open the log and send a screenshot of it.")) {
                NavigationLink(destination: LogScreen()) {
                    Label("Log", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    ImagePipeline.shared.clearDisk()
                    cacheCleared = true
                } label: {
                    Label(cacheCleared ? "Image cache cleared" : "Clear image cache", systemImage: "trash")
                }
                .disabled(cacheCleared)
            }
            .listRowBackground(Theme.surface)

            Section(header: Text("Privacy"),
                    footer: Text("Version \(version)")) {
                Text("No analytics, no telemetry, no accounts. Nothing leaves this iPad except the requests your installed sources make to their own sites when you browse or read. A source can see what you search and open on its site.")
                    .font(.callout)
                    .foregroundColor(Theme.muted)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
    }
}
