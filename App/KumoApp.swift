import SwiftUI
import WebKit

/// Values decided once at launch.
enum AppEnvironment {
    /// The real User-Agent of this device's web view. Extensions receive this
    /// from `getDefaultUserAgent()`, so requests made by the app look the same
    /// as the web view used for site verification (cookies are tied to it).
    static var userAgent = "Mozilla/5.0 (iPad; CPU OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    static func readUserAgent() {
        // Must run on the main thread.
        if let ua = WKWebView(frame: .zero).value(forKey: "userAgent") as? String, !ua.isEmpty {
            userAgent = ua
        }
    }
}

/// Which tab is showing. Shared so one screen can send the user to another.
final class AppState: ObservableObject {
    @Published var tab = 0
}

@main
struct KumoApp: App {
    @StateObject private var store = SourceStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var app = AppState()

    init() {
        AppEnvironment.readUserAgent()
        Theme.apply()
        Log.info("Kumo started. User-Agent: \(AppEnvironment.userAgent)")
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $app.tab) {
                NavigationView { LibraryScreen() }
                    .navigationViewStyle(.stack)
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(0)
                NavigationView { DiscoverScreen() }
                    .navigationViewStyle(.stack)
                    .tabItem { Label("Browse", systemImage: "safari") }
                    .tag(1)
                NavigationView { SettingsScreen() }
                    .navigationViewStyle(.stack)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(2)
            }
            .environmentObject(store)
            .environmentObject(library)
            .environmentObject(app)
            .accentColor(Theme.accent)
            .preferredColorScheme(.dark)
        }
    }
}
