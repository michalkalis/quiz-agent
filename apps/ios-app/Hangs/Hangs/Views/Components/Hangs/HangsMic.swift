//
//  HangsMic.swift
//  Hangs
//
//  Mic button with two concentric pink halo rings + center waveform/icon.
//  Used on Question-Waiting (mic icon) and Question-Recording (animated waveform).
//

import SwiftUI

enum HangsMicMode {
    case tap        // idle, showing a mic icon
    case listening  // recording, showing an animated waveform
}

struct HangsMicBlock: View {
    let mode: HangsMicMode
    /// Compact variant: smaller mic + extra-translucent halos for floating layouts
    /// where question text scrolls underneath the mic.
    var compact: Bool = false
    var action: (() -> Void)? = nil

    private var outerSize: CGFloat {
        if compact { return mode == .tap ? 200 : 188 }
        return mode == .tap ? 260 : 240
    }
    private var middleSize: CGFloat {
        if compact { return mode == .tap ? 152 : 140 }
        return mode == .tap ? 200 : 180
    }
    private var coreSize: CGFloat {
        if compact { return mode == .tap ? 104 : 96 }
        return mode == .tap ? 148 : 130
    }
    private var iconSize: CGFloat { compact ? 32 : 48 }
    private var labelSize: CGFloat { compact ? 13 : 16 }
    private var haloOuter: Color {
        compact ? Theme.Hangs.Colors.pinkHalo1.opacity(0.55) : Theme.Hangs.Colors.pinkHalo1
    }
    private var haloMiddle: Color {
        compact ? Theme.Hangs.Colors.pinkHalo2.opacity(0.55) : Theme.Hangs.Colors.pinkHalo2
    }

    @State private var pulse = false
    @State private var waveTick = false

    var body: some View {
        Button(action: { action?() }) {
            ZStack {
                Circle()
                    .fill(haloOuter)
                    .frame(width: outerSize, height: outerSize)
                    .scaleEffect(pulse ? 1.04 : 1.0)
                Circle()
                    .fill(haloMiddle)
                    .frame(width: middleSize, height: middleSize)
                    .scaleEffect(pulse ? 1.02 : 1.0)
                Circle()
                    .fill(Theme.Hangs.Colors.pink)
                    .frame(width: coreSize, height: coreSize)
                    .hangsShadow(mode == .listening ? Theme.Hangs.Shadow.micStrong : Theme.Hangs.Shadow.mic)
                    .overlay(center)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .tap ? "Tap to speak" : "Stop recording")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
            if mode == .listening {
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                    waveTick.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private var center: some View {
        switch mode {
        case .tap:
            VStack(spacing: compact ? 2 : 4) {
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(.white)
                Text("speak")
                    .font(.hangsBody(labelSize, weight: .bold))
                    .foregroundColor(.white)
            }
        case .listening:
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 4, height: heights[i] * (waveTick ? 1.15 : 0.85))
                        .animation(
                            .easeInOut(duration: 0.4 + Double(i) * 0.05)
                                .repeatForever(autoreverses: true),
                            value: waveTick
                        )
                }
            }
            .frame(width: 60)
        }
    }

    private let heights: [CGFloat] = [22, 44, 62, 36, 50, 28, 18]
}

#if DEBUG
#Preview {
    VStack(spacing: 40) {
        HangsMicBlock(mode: .tap)
        HangsMicBlock(mode: .listening)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
}
#endif
