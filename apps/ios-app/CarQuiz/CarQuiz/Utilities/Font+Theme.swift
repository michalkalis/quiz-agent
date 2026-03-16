//
//  Font+Theme.swift
//  CarQuiz
//
//  Typography extensions using Dynamic Type text styles (SF Pro variants)
//

import SwiftUI

extension Font {

    // MARK: - Display Fonts (SF Pro Display - for titles and headlines)

    /// Extra large title - largeTitle bold
    static var displayXXL: Font {
        .largeTitle.weight(.bold)
    }

    /// Large title - title bold
    static var displayXL: Font {
        .title.weight(.bold)
    }

    /// Title - title3 bold
    static var displayLG: Font {
        .title3.weight(.bold)
    }

    /// Subtitle - body semibold
    static var displayMD: Font {
        .body.weight(.semibold)
    }

    // MARK: - Rounded Fonts (SF Pro Rounded - for buttons and badges)

    /// Large rounded text - title3 bold rounded
    static var roundedLG: Font {
        .system(.title3, design: .rounded).weight(.bold)
    }

    /// Medium rounded text - body semibold rounded
    static var roundedMD: Font {
        .system(.body, design: .rounded).weight(.semibold)
    }

    /// Small rounded text - subheadline semibold rounded
    static var roundedSM: Font {
        .system(.subheadline, design: .rounded).weight(.semibold)
    }

    // MARK: - Text Fonts (SF Pro Text - for body text and labels)

    /// Large text - title3 regular
    static var textLG: Font {
        .title3
    }

    /// Body text - body regular
    static var textMD: Font {
        .body
    }

    /// Small body text - subheadline regular
    static var textSM: Font {
        .subheadline
    }

    /// Caption text - footnote regular
    static var textXS: Font {
        .footnote
    }

    /// Extra small text - caption2 regular
    static var textXXS: Font {
        .caption2
    }

    // MARK: - Label Fonts (with weight variations)

    /// Label - subheadline semibold
    static var labelMD: Font {
        .subheadline.weight(.semibold)
    }

    /// Small label - footnote semibold
    static var labelSM: Font {
        .footnote.weight(.semibold)
    }

    /// Medium weight body - subheadline medium
    static var textMDMedium: Font {
        .subheadline.weight(.medium)
    }

    /// Medium weight small - footnote medium
    static var textSMMedium: Font {
        .footnote.weight(.medium)
    }

    // MARK: - Additional Display Variants

    /// Extra large title heavy - largeTitle heavy (for score displays)
    static var displayXXLHeavy: Font {
        .largeTitle.weight(.heavy)
    }

    /// Body bold - body bold
    static var displayMDBold: Font {
        .body.weight(.bold)
    }

    /// Body medium - body medium
    static var textMDBodyMedium: Font {
        .body.weight(.medium)
    }

    /// Small bold - subheadline bold (for badges)
    static var labelMDBold: Font {
        .subheadline.weight(.bold)
    }

    /// Extra small bold - footnote bold (for percentage displays)
    static var labelSMBold: Font {
        .footnote.weight(.bold)
    }

    /// Extra small medium - caption2 medium
    static var textXXSMedium: Font {
        .caption2.weight(.medium)
    }
}
