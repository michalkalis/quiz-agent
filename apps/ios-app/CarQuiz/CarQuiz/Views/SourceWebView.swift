//
//  SourceWebView.swift
//  Hangs
//
//  WebView modal for displaying question source articles
//

import SwiftUI
import WebKit

/// Modal view for displaying source article in a WebView
struct SourceWebView: View {
    let url: String
    @Binding var isPresented: Bool

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
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            ShareLink(item: validUrl) {
                                Image(systemName: "square.and.arrow.up")
                            }
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

/// UIViewRepresentable wrapper for WKWebView
struct WebViewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
}

#Preview {
    SourceWebView(
        url: "https://en.wikipedia.org/wiki/Paris",
        isPresented: .constant(true)
    )
}
