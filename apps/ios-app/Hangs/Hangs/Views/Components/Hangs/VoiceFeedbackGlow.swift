//
//  VoiceFeedbackGlow.swift
//  Hangs
//
//  Issue #122 Track A — Variant C "Ambient glow" (approved 2026-07-28,
//  docs/design/ui-variants-2026-07-28-decisions.md). The app-wide voice-command
//  feedback treatment (rule V1): a text-free bottom wash + light sweep on a
//  match, one slow amber breath on a no-match. Consumed by QuestionView here
//  and by the #125 ListenBar / #127 Result footer per rule V1.
//  Peripheral-vision-first: no strings, and no layout movement — both views
//  reserve their space in every phase and animate only opacity/position.
//

import SwiftUI

/// Bottom-anchored radial wash over the lower third of a screen. Attach behind
/// the screen's content (e.g. as a bottom-aligned layer above the background
/// fill); purely ambient — hit-testing disabled, hidden from accessibility.
struct AmbientGlowWash: View {
    let phase: VoiceFeedbackPhase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Group {
            if phase != .idle {
                Rectangle()
                    .fill(EllipticalGradient(stops: stops, center: UnitPoint(x: 0.5, y: 1.0)))
                    .opacity(reduceMotion ? 0.85 : (pulsing ? 1.0 : 0.62))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(
                            .easeInOut(duration: halfCycle).repeatForever(autoreverses: true)
                        ) { pulsing = true }
                    }
                    .id(phase) // restart the pulse when the phase flips
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // Teal wash on a match, amber on a miss (never red — nothing failed).
    private var stops: [Gradient.Stop] {
        let tint = phase == .unmatched ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.accentTeal
        let (peak, mid): (Double, Double) = phase == .unmatched ? (0.30, 0.10) : (0.42, 0.16)
        return [
            .init(color: tint.opacity(peak), location: 0),
            .init(color: tint.opacity(mid), location: 0.42),
            .init(color: tint.opacity(0), location: 0.74),
        ]
    }

    // Full pulse cycles: matched 1.6 s, unmatched 2.6 s (the "slow breath").
    private var halfCycle: Double { phase == .unmatched ? 1.3 : 0.8 }
}

/// The 4 pt full-width light strip docked above the listening bar. Reserves its
/// height in EVERY phase — a strip that appears would shift the bar mid-drive;
/// only its opacity and the sweep move. Match: a light sweeps left→right (the
/// direction is the "working on it"). Miss: a full-width amber breath.
struct GlowSweepLine: View {
    let phase: VoiceFeedbackPhase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false
    @State private var breathing = false

    private var teal: Color { Theme.Hangs.Colors.accentTeal }
    private var amber: Color { Theme.Hangs.Colors.warning }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(phase == .unmatched ? amber.opacity(0.16) : teal.opacity(0.14))

                if phase == .matched {
                    if reduceMotion {
                        Rectangle().fill(teal.opacity(0.35))
                    } else {
                        LinearGradient(
                            colors: [teal.opacity(0), teal, teal.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.34)
                        .offset(x: sweeping ? proxy.size.width : -proxy.size.width * 0.34)
                        .onAppear {
                            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                                sweeping = true
                            }
                        }
                    }
                } else if phase == .unmatched {
                    Rectangle()
                        .fill(amber.opacity(0.55))
                        .opacity(reduceMotion ? 1.0 : (breathing ? 1.0 : 0.35))
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                breathing = true
                            }
                        }
                }
            }
            .clipped()
        }
        .frame(height: 4)
        .opacity(phase == .idle ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: phase)
        .id(phase) // restart sweep/breath cleanly on phase change
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
    #Preview("Glow states") {
        VStack(spacing: 24) {
            ForEach([VoiceFeedbackPhase.idle, .matched, .unmatched], id: \.self) { phase in
                VStack(spacing: 8) {
                    GlowSweepLine(phase: phase)
                    Text(verbatim: phase.rawValue).font(.hangsMonoMini)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            AmbientGlowWash(phase: .matched).frame(height: 330)
        }
        .background(Theme.Hangs.Colors.bg)
    }
#endif
