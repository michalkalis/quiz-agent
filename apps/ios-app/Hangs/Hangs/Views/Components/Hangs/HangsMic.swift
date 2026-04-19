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
    var action: (() -> Void)? = nil

    private var outerSize: CGFloat { mode == .tap ? 260 : 240 }
    private var middleSize: CGFloat { mode == .tap ? 200 : 180 }
    private var coreSize: CGFloat { mode == .tap ? 148 : 130 }

    @State private var pulse = false
    @State private var waveTick = false

    var body: some View {
        Button(action: { action?() }) {
            ZStack {
                Circle()
                    .fill(Theme.Hangs.Colors.pinkHalo1)
                    .frame(width: outerSize, height: outerSize)
                    .scaleEffect(pulse ? 1.04 : 1.0)
                Circle()
                    .fill(Theme.Hangs.Colors.pinkHalo2)
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
            Image(systemName: "mic.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundColor(.white)
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
