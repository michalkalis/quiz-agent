//
//  DebugErrorDetailsView.swift
//  Hangs
//
//  Expandable debug panel rendered below the user-facing error message in DEBUG builds.
//  Surfaces the full captured error description so root causes (HTTP status, decoding
//  path, underlying NSError chain) are visible without attaching Xcode.
//

#if DEBUG
import SwiftUI

struct DebugErrorDetailsView: View {
    let detail: String
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "ladybug.fill").foregroundStyle(.orange)
                Text("DEBUG").font(.caption2.weight(.heavy)).kerning(1.2)
                Text("Error details").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button(expanded ? "Hide" : "Show") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.caption.weight(.semibold))
            }

            if expanded {
                ScrollView {
                    Text(detail)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = detail
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run { withAnimation { copied = false } }
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    ShareLink(item: detail) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    DebugErrorDetailsView(detail: "NetworkError.serverError(statusCode: 500, message: \"The question database is empty.\")\n\n--- underlying ---\nNSError domain: NSURLErrorDomain code: -1001")
        .padding()
}
#endif
