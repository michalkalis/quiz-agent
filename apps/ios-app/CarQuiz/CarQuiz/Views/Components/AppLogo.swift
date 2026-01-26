//
//  AppLogo.swift
//  CarQuiz
//
//  App logo with car icon in gradient rounded square
//

import SwiftUI

/// App logo with car icon in purple gradient rounded square
struct AppLogo: View {
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            // Gradient rounded square
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Theme.Gradients.primary())
                .frame(width: size, height: size)
                .shadow(
                    color: Color(hex: "#8B5CF6").opacity(0.3),
                    radius: 16,
                    x: 0,
                    y: 4
                )

            // Car icon
            Image(systemName: "car.fill")
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundColor(Theme.Colors.textOnAccent)
        }
    }
}

#Preview {
    VStack(spacing: 30) {
        AppLogo()
        AppLogo(size: 60)
        AppLogo(size: 100)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
