//
//  Font+Theme.swift
//  CarQuiz
//
//  Typography extensions using system fonts (SF Pro variants)
//

import SwiftUI

extension Font {

    // MARK: - Display Fonts (SF Pro Display - for titles and headlines)

    /// Extra large title - 36pt bold
    static var displayXXL: Font {
        .system(size: Theme.Typography.sizeXXL, weight: .bold, design: .default)
    }

    /// Large title - 28pt bold
    static var displayXL: Font {
        .system(size: Theme.Typography.sizeXL, weight: .bold, design: .default)
    }

    /// Title - 20pt bold
    static var displayLG: Font {
        .system(size: Theme.Typography.sizeLG, weight: .bold, design: .default)
    }

    /// Subtitle - 17pt semibold
    static var displayMD: Font {
        .system(size: Theme.Typography.sizeMD, weight: .semibold, design: .default)
    }

    // MARK: - Rounded Fonts (SF Pro Rounded - for buttons and badges)

    /// Large rounded text - 20pt bold
    static var roundedLG: Font {
        .system(size: Theme.Typography.sizeLG, weight: .bold, design: .rounded)
    }

    /// Medium rounded text - 17pt semibold
    static var roundedMD: Font {
        .system(size: Theme.Typography.sizeMD, weight: .semibold, design: .rounded)
    }

    /// Small rounded text - 15pt semibold
    static var roundedSM: Font {
        .system(size: Theme.Typography.sizeSM, weight: .semibold, design: .rounded)
    }

    // MARK: - Text Fonts (SF Pro Text - for body text and labels)

    /// Body text - 17pt regular
    static var textMD: Font {
        .system(size: Theme.Typography.sizeMD, weight: .regular, design: .default)
    }

    /// Small body text - 15pt regular
    static var textSM: Font {
        .system(size: Theme.Typography.sizeSM, weight: .regular, design: .default)
    }

    /// Caption text - 13pt regular
    static var textXS: Font {
        .system(size: Theme.Typography.sizeXS, weight: .regular, design: .default)
    }

    /// Extra small text - 11pt regular
    static var textXXS: Font {
        .system(size: Theme.Typography.sizeXXS, weight: .regular, design: .default)
    }

    // MARK: - Label Fonts (with weight variations)

    /// Label - 15pt semibold
    static var labelMD: Font {
        .system(size: Theme.Typography.sizeSM, weight: .semibold, design: .default)
    }

    /// Small label - 13pt semibold
    static var labelSM: Font {
        .system(size: Theme.Typography.sizeXS, weight: .semibold, design: .default)
    }

    /// Medium weight body - 15pt medium
    static var textMDMedium: Font {
        .system(size: Theme.Typography.sizeSM, weight: .medium, design: .default)
    }

    /// Medium weight small - 13pt medium
    static var textSMMedium: Font {
        .system(size: Theme.Typography.sizeXS, weight: .medium, design: .default)
    }
}
