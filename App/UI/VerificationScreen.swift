import SwiftUI
import WebKit

/// Site verification, the same way Paperback does it: the source's website
/// opens in a web view, you pass its "are you human" check by hand, tap Done,
/// and the app takes over the cookies the site set so its own requests are
/// accepted too.
///
/// Two details make this work:
///  - The web view uses the same User-Agent as the app's requests. Sites tie
///    the "passed" cookie to the User-Agent.
///  - ALL cookies for the site are taken over, not just Cloudflare's
///    `cf_clearance`: some sites use their own (comix.to uses `waf_pass`).
struct VerificationScreen: View {
    let runtime: SourceRuntime
    /// Called after the cookies were taken over, to retry what failed.
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var page = VerificationPage()
    @State private var target: URL?
    @State private var noPage = false
    @State private var finishing = false

    var body: some View {
        NavigationView {
            Group {
                if let target = target {
                    WebViewContainer(webView: page.webView)
                        .onAppear { page.open(target) }
                } else if noPage {
                    ErrorBox(message: "This source did not say which page to open for verification.")
                } else {
                    ProgressView("Opening the website…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(target?.host ?? "Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { page.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload page")
                        .disabled(target == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }.disabled(target == nil || finishing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Pass the site's check (for example “Verify you are human”), wait for the normal page to appear, then tap Done.")
                    .font(.footnote)
                    .foregroundColor(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface)
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled()
        .task {
            if let request = await runtime.verificationRequest() {
                page.userAgent = request.userAgent
                target = request.url
            } else {
                noPage = true
            }
        }
    }

    private func finish() {
        guard let host = target?.host else { return }
        finishing = true
        // Cookies of the site and its subdomains: "www.comix.to" -> "comix.to".
        let labels = host.split(separator: ".")
        let base = labels.suffix(2).joined(separator: ".")
        page.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let wanted = cookies.filter { cookie in
                var domain = cookie.domain
                if domain.hasPrefix(".") { domain.removeFirst() }
                return domain == base || domain.hasSuffix("." + base)
            }
            runtime.importCookies(wanted)
            dismiss()
            // Give the cookie hand-over a moment before retrying.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onDone() }
        }
    }
}

/// Owns the web view so it survives SwiftUI redraws.
final class VerificationPage: ObservableObject {
    let webView: WKWebView
    var userAgent: String?
    private var opened = false

    init() {
        let configuration = WKWebViewConfiguration()
        // Persistent store: a check passed once stays passed in this web view.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
    }

    func open(_ url: URL) {
        guard !opened else { return }
        opened = true
        // Normally the source uses the web view's own User-Agent and nothing
        // needs changing. If the source sends a different one, the web view
        // adopts it, so both sides always present the same identity.
        if let agent = userAgent, !agent.isEmpty, agent != AppEnvironment.userAgent {
            webView.customUserAgent = agent
        }
        webView.load(URLRequest(url: url))
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
