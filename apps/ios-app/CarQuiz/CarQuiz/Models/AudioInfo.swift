//
//  AudioInfo.swift
//  CarQuiz
//
//  Audio URL metadata model matching backend API
//

import Foundation

/// Contains audio URLs returned from backend
struct AudioInfo: Codable, Sendable {
    let feedbackUrl: String?
    let questionUrl: String?
    let format: String

    enum CodingKeys: String, CodingKey {
        case feedbackUrl = "feedback_url"
        case questionUrl = "question_url"
        case format
    }
}

extension AudioInfo {
    /// Check if feedback audio is available
    var hasFeedbackAudio: Bool {
        feedbackUrl != nil
    }

    /// Check if question audio is available
    var hasQuestionAudio: Bool {
        questionUrl != nil
    }

    /// Get full feedback URL (prepend base URL if relative)
    func fullFeedbackUrl(baseURL: String) -> URL? {
        guard let urlString = feedbackUrl else { return nil }

        if urlString.hasPrefix("http") {
            return URL(string: urlString)
        } else {
            return URL(string: baseURL + urlString)
        }
    }

    /// Get full question URL (prepend base URL if relative)
    func fullQuestionUrl(baseURL: String) -> URL? {
        guard let urlString = questionUrl else { return nil }

        if urlString.hasPrefix("http") {
            return URL(string: urlString)
        } else {
            return URL(string: baseURL + urlString)
        }
    }
}
