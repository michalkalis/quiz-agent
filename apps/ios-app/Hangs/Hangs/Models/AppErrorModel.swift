//
//  AppErrorModel.swift
//  Hangs
//
//  Display model for the Error screen (Fwafe frame).
//  Pure value type — no ViewModel dependency, fully testable.
//  52.14 binds ErrorView to this struct.
//

import Foundation

/// The CTA the Error screen offers after a failure.
enum AppErrorRetryAction: Equatable, Sendable {
    /// Re-run the operation that just failed (network retries).
    case retryOperation
    /// Return to Home — for terminal failures where retry is not meaningful.
    case goHome
    /// Soft dismiss — for non-blocking / configuration errors.
    case dismiss
}

/// Maps any thrown error to a localised (English source; `sk` translation pending #56) title + description + retry action.
struct AppErrorModel: Equatable, Sendable {
    let title: String
    let description: String
    let retryAction: AppErrorRetryAction

    /// Question history hit the 500-question cap. Retrying restarts the same
    /// guard and fails identically, so the CTA is Go Home — the recovery path
    /// is Settings → "Reset question history" (#54 task 54.17).
    static let historyAtCapacity = AppErrorModel(
        title: String(localized: "Question history is full", comment: "Error title: question history cap reached"),
        description: String(localized: "Clear your question history in Settings (Reset question history) and start a new game.", comment: "Error description: question history cap reached"),
        retryAction: .goHome
    )

    /// Map a thrown error and its quiz context to the Error screen display model.
    static func from(_ error: Error, context: ErrorContext = .general) -> AppErrorModel {
        // Cancellation: not a network failure — a retry CTA is misleading,
        // offer a soft dismiss instead (54.15; surfaced by the 54.5 path).
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return AppErrorModel(
                title: String(localized: "Submission interrupted", comment: "Error title: answer submission was cancelled"),
                description: String(localized: "The submission was interrupted. Try answering again.", comment: "Error description: submission cancelled"),
                retryAction: .dismiss
            )
        }

        // URLError: connectivity / timeout
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return AppErrorModel(
                    title: String(localized: "No internet connection", comment: "Error title: device is offline"),
                    description: String(localized: "Check your Wi-Fi or mobile data and try again.", comment: "Error description: no internet connection"),
                    retryAction: .retryOperation
                )
            case .timedOut:
                return AppErrorModel(
                    title: String(localized: "Request timed out", comment: "Error title: network request timed out"),
                    description: String(localized: "The server took too long to respond. Try again.", comment: "Error description: request timed out"),
                    retryAction: .retryOperation
                )
            default:
                break
            }
        }

        // NetworkError: domain-specific failures
        if let networkError = error as? NetworkError {
            switch networkError {
            case .dailyLimitReached:
                return AppErrorModel(
                    title: String(localized: "Daily limit reached", comment: "Error title: user hit daily question quota"),
                    description: String(localized: "You've answered the maximum number of questions for today. Come back tomorrow.", comment: "Error description: daily limit reached"),
                    retryAction: .goHome
                )
            case .sessionNotFound:
                return AppErrorModel(
                    title: String(localized: "Session expired", comment: "Error title: quiz session is no longer active"),
                    description: String(localized: "This quiz session is no longer active. Start a new game.", comment: "Error description: session expired"),
                    retryAction: .goHome
                )
            case let .serverError(statusCode, _) where statusCode >= 500:
                return AppErrorModel(
                    title: String(localized: "Server error", comment: "Error title: backend returned 5xx"),
                    description: String(localized: "Something went wrong on our end. Try again.", comment: "Error description: server error"),
                    retryAction: .retryOperation
                )
            case let .serverError(statusCode, _) where statusCode == 429:
                return AppErrorModel(
                    title: String(localized: "Too many requests", comment: "Error title: rate limited (429)"),
                    description: String(localized: "Slow down a bit and try again shortly.", comment: "Error description: rate limited"),
                    retryAction: .retryOperation
                )
            case .decodingError, .invalidResponse:
                return AppErrorModel(
                    title: String(localized: "Unexpected response", comment: "Error title: response parsing failed"),
                    description: String(localized: "We received unexpected data. Try again.", comment: "Error description: unexpected response"),
                    retryAction: .retryOperation
                )
            case .invalidURL:
                return AppErrorModel(
                    title: String(localized: "Configuration error", comment: "Error title: app configuration problem"),
                    description: String(localized: "Something went wrong with the app settings.", comment: "Error description: configuration error"),
                    retryAction: .dismiss
                )
            default:
                break
            }
        }

        // Context-driven fallback when the error type does not map to a specific case
        return from(context: context)
    }

    /// Context-only fallback for call sites that have no underlying `Error`
    /// (e.g. `setError(message:context:)` without an error argument).
    static func from(context: ErrorContext) -> AppErrorModel {
        switch context {
        case .initialization:
            return AppErrorModel(
                title: String(localized: "Couldn't start quiz", comment: "Error title: quiz failed to initialise"),
                description: String(localized: "Check your connection and try again.", comment: "Error description: initialisation failure"),
                retryAction: .retryOperation
            )
        case .submission:
            return AppErrorModel(
                title: String(localized: "Couldn't submit answer", comment: "Error title: answer submission failed"),
                description: String(localized: "Try submitting your answer again.", comment: "Error description: submission failure"),
                retryAction: .retryOperation
            )
        case .recording:
            return AppErrorModel(
                title: String(localized: "Recording failed", comment: "Error title: microphone recording failed"),
                description: String(localized: "Try answering again.", comment: "Error description: recording failure"),
                retryAction: .retryOperation
            )
        case .general:
            return AppErrorModel(
                title: String(localized: "Something went wrong", comment: "Error title: generic fallback"),
                description: String(localized: "Try again.", comment: "Error description: generic fallback"),
                retryAction: .retryOperation
            )
        }
    }
}
