//
//  SourceWebView.swift
//  Hangs
//
//  WebView modal for displaying question source articles
//

import SwiftUI
import WebKit

/// Modal view for displaying the source article of a question.
///
/// Shows ONLY the source page: every navigation away from it is blocked (see
/// `SourceNavigationPolicy`). Apple's age rating treats an in-app browser with
/// free navigation as "unrestricted web access" (pushes the app to 18+), so
/// "Open in Browser" hands the URL to the system instead.
struct SourceWebView: View {
    let url: String
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationView {
            if let validUrl = URL(string: url) {
                WebViewRepresentable(url: validUrl)
                    .navigationTitle("Source")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") {
                                isPresented = false
                            }
                            .accessibilityIdentifier("source.done")
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            ShareLink(item: validUrl) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("source.share")
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button {
                                openURL(validUrl)
                            } label: {
                                Label("Open in Browser", systemImage: "safari")
                            }
                            .accessibilityIdentifier("source.openInBrowser")
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Invalid URL",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The source URL could not be loaded.")
                )
            }
        }
    }
}

/// How a WebKit navigation was triggered (mirror of the `WKNavigationType`
/// cases the policy distinguishes, so the decision stays a pure function).
enum SourceNavigationKind: Equatable {
    case linkActivated
    case formSubmitted
    case backForward
    case reload
    /// Initial load, server redirects, script or meta-refresh navigation.
    case other
}

/// Allow/deny decision for every navigation inside the source viewer.
///
/// Why this exists: the viewer must stay a single-page reader. If a link tap,
/// form post or `window.open` could reach another page, the in-app browser
/// becomes "unrestricted web access" for Apple's age rating. A regression here
/// silently re-opens the web and changes the App Store rating.
enum SourceNavigationPolicy {
    /// - Parameters:
    ///   - requestURL: Destination of the navigation.
    ///   - currentURL: URL currently shown (nil before the first commit).
    ///   - kind: What triggered the navigation.
    ///   - isMainFrame: false for iframe loads (embedded content of the page).
    ///   - opensNewWindow: true for `target=_blank` / `window.open` (no target frame).
    ///   - initialLoadFinished: true once the first page load finished or failed;
    ///     before that, `.other` main-frame navigations are the initial load and
    ///     its server redirects.
    static func allows(
        requestURL: URL,
        currentURL: URL?,
        kind: SourceNavigationKind,
        isMainFrame: Bool,
        opensNewWindow: Bool,
        initialLoadFinished: Bool
    ) -> Bool {
        if opensNewWindow { return false }
        // Same-page anchor jumps are always fine in the main frame.
        if isMainFrame, isSamePageAnchor(requestURL, currentURL: currentURL) { return true }
        // Main frame is web pages only (no mailto:, tel:, app schemes); iframes
        // may use about:/blob:/data: for their own embedded content.
        if isMainFrame {
            guard let scheme = requestURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return false
            }
        }
        switch kind {
        case .linkActivated, .formSubmitted, .backForward:
            return false
        case .reload:
            return true
        case .other:
            // Embedded frames are page content; main-frame `.other` is only the
            // initial load + redirects, never a later script-driven jump.
            return !isMainFrame || !initialLoadFinished
        }
    }

    /// True when `requestURL` differs from `currentURL` only by its fragment.
    static func isSamePageAnchor(_ requestURL: URL, currentURL: URL?) -> Bool {
        guard let currentURL, requestURL.fragment != nil else { return false }
        return stripFragment(requestURL) == stripFragment(currentURL)
    }

    private static func stripFragment(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }
}

/// UIViewRepresentable wrapper for WKWebView
struct WebViewRepresentable: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Source page only: no swipe history, no navigation (see policy above).
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var initialLoadFinished = false

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let allowed = SourceNavigationPolicy.allows(
                requestURL: requestURL,
                currentURL: webView.url,
                kind: Self.kind(for: navigationAction.navigationType),
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                opensNewWindow: navigationAction.targetFrame == nil,
                initialLoadFinished: initialLoadFinished
            )
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            initialLoadFinished = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            initialLoadFinished = true
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            initialLoadFinished = true
        }

        /// `window.open` / `target=_blank`: never open a second page.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        private static func kind(for type: WKNavigationType) -> SourceNavigationKind {
            switch type {
            case .linkActivated: return .linkActivated
            case .formSubmitted, .formResubmitted: return .formSubmitted
            case .backForward: return .backForward
            case .reload: return .reload
            case .other: return .other
            // Fail closed: an unknown trigger must not open the web.
            @unknown default: return .linkActivated
            }
        }
    }
}

#Preview {
    SourceWebView(
        url: "https://en.wikipedia.org/wiki/Paris",
        isPresented: .constant(true)
    )
}
