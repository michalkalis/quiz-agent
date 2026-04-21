//
//  DebugLogView.swift
//  Hangs
//
//  In-app log viewer for DEBUG builds. Reads from OSLogStore so it inspects the same
//  `os.Logger` events we already emit — no parallel logging layer.
//
//  Entry points: Settings → Developer → View Logs, or shake gesture (TODO if needed).
//

#if DEBUG
import Sentry
import SwiftUI

struct DebugLogView: View {
    @State private var entries: [LogEntry] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil
    @State private var minLevel: LogEntry.Level = .debug
    @State private var sinceMinutes: Int = 30
    @State private var sentryStatus: String? = nil
    @Environment(\.dismiss) private var dismiss

    private static let windowOptions: [(minutes: Int, label: String)] = [
        (5, "5m"), (15, "15m"), (30, "30m"), (60, "1h"), (180, "3h")
    ]

    private static let levelOptions: [LogEntry.Level] = [.debug, .info, .warning, .error]

    private var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    private var filtered: [LogEntry] {
        entries.filter { entry in
            if entry.level.sortOrder < minLevel.sortOrder { return false }
            if let cat = selectedCategory, entry.category != cat { return false }
            if !searchText.isEmpty, !entry.message.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filtersBar
            Divider()
            content
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task { await load() }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }

                    ShareLink(item: exportText(), preview: SharePreview("hangs-logs.txt"))

                    if SentrySDK.isEnabled {
                        Button {
                            sendToSentry()
                        } label: { Label("Send to Sentry", systemImage: "paperplane") }
                    } else {
                        Text("Sentry disabled (simulator)").font(.caption)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
        .overlay(alignment: .bottom) {
            if let sentryStatus {
                Text(sentryStatus)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Subviews

    private var filtersBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search messages", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.windowOptions, id: \.minutes) { opt in
                        chip("Last \(opt.label)", isOn: sinceMinutes == opt.minutes) {
                            sinceMinutes = opt.minutes
                            Task { await load() }
                        }
                    }
                    Divider().frame(height: 14)
                    ForEach(Self.levelOptions, id: \.rawValue) { lvl in
                        chip(lvl.rawValue, isOn: minLevel == lvl) { minLevel = lvl }
                    }
                    Divider().frame(height: 14)
                    chip("all categories", isOn: selectedCategory == nil) { selectedCategory = nil }
                    ForEach(categories, id: \.self) { cat in
                        chip(cat, isOn: selectedCategory == cat) { selectedCategory = cat }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isOn ? Color.accentColor : Color(.systemGray6), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView(
                "No matching logs",
                systemImage: "doc.text.magnifyingglass",
                description: Text(entries.isEmpty ? "No entries in the selected window." : "Try widening the filters.")
            )
        } else {
            List(filtered) { entry in
                DebugLogRow(entry: entry)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        entries = await LogStore.shared.fetch(sinceMinutes: sinceMinutes)
    }

    private func exportText() -> String {
        let header = "Hangs debug log export — \(Date())\nSubsystem: com.missinghue.hangs\nEntries: \(filtered.count)\n\n"
        return header + filtered.map { $0.formatted() }.joined(separator: "\n")
    }

    private func sendToSentry() {
        guard SentrySDK.isEnabled else {
            flash("Sentry disabled — use Share instead")
            return
        }
        let payload = exportText()
        let eventId = SentrySDK.capture(message: "debug_log_export")
        let attachment = Attachment(
            data: Data(payload.utf8),
            filename: "hangs-logs.txt",
            contentType: "text/plain"
        )
        SentrySDK.configureScope { scope in
            scope.addAttachment(attachment)
        }
        flash("Sent to Sentry (event: \(eventId.sentryIdString.prefix(8)))")
    }

    private func flash(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) { sentryStatus = message }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { sentryStatus = nil }
            }
        }
    }
}

// MARK: - Row

private struct DebugLogRow: View {
    let entry: LogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.level.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(levelColor, in: RoundedRectangle(cornerRadius: 4))
                Text(entry.category)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeString).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(entry.message)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .swipeActions(edge: .trailing) {
            Button {
                UIPasteboard.general.string = entry.formatted()
            } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .gray
        case .info: return .blue
        case .notice: return .teal
        case .warning: return .orange
        case .error, .fault: return .red
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: entry.date)
    }
}

#Preview {
    NavigationStack { DebugLogView() }
}
#endif
