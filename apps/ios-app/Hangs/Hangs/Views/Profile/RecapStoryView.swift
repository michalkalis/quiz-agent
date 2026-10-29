//
//  RecapStoryView.swift
//  Hangs
//
//  #213.5: the recap played as a story, like on Instagram — slides move on by
//  themselves, a tap on the right goes forward and on the left goes back. The
//  last slide (player type) offers Share: a 1080×1920 image of that slide.
//

import SwiftUI

struct RecapStoryView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    let recap: PlayerRecap
    var onShareOpened: () -> Void = {}
    /// How many slides the player reached, of how many.
    let onClose: (_ slidesSeen: Int, _ slidesTotal: Int) -> Void

    private let slides: [RecapSlide]
    @State private var index: Int
    @State private var furthest: Int
    @State private var shareImage: Image?

    init(
        recap: PlayerRecap,
        startAt: Int = 0,
        onShareOpened: @escaping () -> Void = {},
        onClose: @escaping (_ slidesSeen: Int, _ slidesTotal: Int) -> Void
    ) {
        self.recap = recap
        self.onShareOpened = onShareOpened
        self.onClose = onClose
        let slides = RecapSlide.story(for: recap)
        self.slides = slides
        let start = min(max(startAt, 0), slides.count - 1)
        _index = State(initialValue: start)
        _furthest = State(initialValue: start)
    }

    private var isLast: Bool {
        index == slides.count - 1
    }

    private var style: Theme.Hangs.Category.Style {
        RecapSlideView.style(at: index, in: slides)
    }

    var body: some View {
        ZStack {
            RecapSlideView(slide: slides[index], recap: recap, style: style)
                .accessibilityIdentifier("recap.slide.\(index)")
            tapZones
            VStack(spacing: Theme.Hangs.Spacing.sm) {
                progress
                HStack {
                    Spacer()
                    closeButton
                }
                Spacer()
                if isLast {
                    shareButton
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
        }
        .foregroundStyle(style.text)
        // `.contain` keeps the slide's and the buttons' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.story")
        .statusBarHidden()
        .task(id: index) { await autoAdvance() }
        .task(id: isLast) {
            if isLast, shareImage == nil { shareImage = renderShareImage() }
        }
    }

    // MARK: - Navigation

    private var tapZones: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                zone("Previous", id: "recap.previous", width: geometry.size.width * Metrics.backZone, action: back)
                zone("Next", id: "recap.next", width: geometry.size.width * (1 - Metrics.backZone), action: forward)
            }
        }
    }

    private func zone(_ label: LocalizedStringKey, id: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    private func forward() {
        guard !isLast else { return }
        index += 1
        furthest = max(furthest, index)
    }

    private func back() {
        index = max(index - 1, 0)
    }

    /// Slides move on by themselves, except the last one and under VoiceOver.
    private func autoAdvance() async {
        guard !isLast, !voiceOverEnabled else { return }
        try? await Task.sleep(for: Metrics.slideDuration)
        guard !Task.isCancelled else { return }
        forward()
    }

    // MARK: - Chrome

    private var progress: some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            ForEach(slides.indices, id: \.self) { slide in
                Capsule()
                    .fill(style.text.opacity(slide <= index ? 1 : Metrics.pendingOpacity))
                    .frame(height: Metrics.barHeight)
            }
        }
        .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button {
            onClose(furthest + 1, slides.count)
        } label: {
            Image(systemName: "xmark")
                .font(.hangsLabel)
                .frame(width: Metrics.closeSize, height: Metrics.closeSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
        .accessibilityIdentifier("recap.close")
    }

    @ViewBuilder
    private var shareButton: some View {
        if let shareImage {
            ShareLink(item: shareImage, preview: SharePreview(Text(RecapCopy.playerTypeName(recap.playerType)), image: shareImage)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.hangsButton)
                    .frame(maxWidth: .infinity, minHeight: Metrics.shareHeight)
                    .foregroundStyle(Theme.Hangs.Recap.intro.text)
                    .background(Capsule().fill(Theme.Hangs.Recap.intro.fill))
            }
            .simultaneousGesture(TapGesture().onEnded(onShareOpened))
            .accessibilityIdentifier("recap.share")
        }
    }

    /// The last slide at story size, 1080×1920 pixels.
    private func renderShareImage() -> Image? {
        let slide = RecapSlideView(slide: slides[slides.count - 1], recap: recap, style: Theme.Hangs.Recap.finale)
            .frame(width: Metrics.shareSize.width, height: Metrics.shareSize.height)
            .environment(\.locale, locale)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: slide)
        renderer.scale = Metrics.shareScale
        return renderer.uiImage.map { Image(uiImage: $0) }
    }

    private enum Metrics {
        static let slideDuration: Duration = .seconds(6)
        /// The left third goes back, as on Instagram.
        static let backZone: CGFloat = 1.0 / 3.0
        static let barHeight: CGFloat = 3
        static let pendingOpacity = 0.35
        static let closeSize: CGFloat = 44
        static let shareHeight: CGFloat = 52
        static let shareSize = CGSize(width: 360, height: 640)
        static let shareScale: CGFloat = 3
    }
}

#if DEBUG
    #Preview {
        RecapStoryView(recap: .mockOctober) { _, _ in }
    }
#endif
