//
//  HangsSourceLink.swift
//  Hangs
//
//  The "source ›" affordance. It lived as a private member of `ResultMetaRow`
//  until #179 finding 8 asked for the same link on every expanded row of the
//  set recap — one component now, so the two screens cannot drift apart.
//

import SwiftUI

/// Tappable source link — the 10pt mono "source" label plus a chevron, in the
/// faintest grey. The label deliberately drops the domain (the result screen's
/// meta row has no width budget for it); the domain survives as the
/// accessibility label, where there is none to spend.
///
/// The owner decides what a tap does: the result screen opens its in-app
/// `SourceWebView` sheet, the recap row opens the URL.
struct HangsSourceLink: View {
    /// Host of the source URL ("nasa.gov") — what VoiceOver reads out.
    let domain: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("source")
                    .font(.hangsMono(10, weight: .medium))
                    .tracking(1.2)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(Theme.Hangs.Colors.mutedFaint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Source: \(domain)", comment: "Accessibility label for the source link, naming the site"))
    }

    /// "https://www.nasa.gov/uranus" → "nasa.gov". nil when there is no usable
    /// host — that is what gates the link's presence on both screens.
    static func domain(from urlString: String?) -> String? {
        guard let urlString, let host = URL(string: urlString)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
