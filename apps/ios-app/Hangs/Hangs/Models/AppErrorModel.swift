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

/// Maps any thrown error to a title + description + retry action.
/// Copy is English source text localized via the String Catalog (#56 task 56.3b);
/// the Slovak originals are preserved in `docs/issues/issue-56-ios-localization.md`.
struct AppErrorModel: Equatable, Sendable {
    let title: String
    let description: String
    let retryAction: AppErrorRetryAction

    /// Question history hit the 500-question cap. Retrying restarts the same
    /// guard and fails identically, so the CTA is Go Home — the recovery path
    /// is Settings → "Reset question history" (#54 task 54.17).
    static let historyAtCapacity = AppErrorModel(
        title: String(localized: "Question history is full", comment: "Error title: saved-question history reached its cap"),
        description: String(localized: "Clear your question history in Settings (Reset question history) and start a new game.", comment: "Error body: how to recover from a full question history"),
        retryAction: .goHome
    )

    /// Map a thrown error and its quiz context to the Error screen display model.
    static func from(_ error: Error, context: ErrorContext = .general) -> AppErrorModel {
        // Cancellation: not a network failure — a retry CTA is misleading,
        // offer a soft dismiss instead (54.15; surfaced by the 54.5 path).
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return AppErrorModel(
                title: String(localized: "Action cancelled", comment: "Error title: the in-flight operation was cancelled"),
                description: String(localized: "Your submission was interrupted. Try answering again.", comment: "Error body: a cancelled submission"),
                retryAction: .dismiss
            )
        }

        // URLError: connectivity / timeout
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return AppErrorModel(
                    title: String(localized: "No internet connection", comment: "Error title: device is offline"),
                    description: String(localized: "Check your Wi-Fi or mobile data and try again.", comment: "Error body: offline recovery"),
                    retryAction: .retryOperation
                )
            case .timedOut:
                return AppErrorModel(
                    title: String(localized: "Request timed out", comment: "Error title: the request exceeded its timeout"),
                    description: String(localized: "The server took too long to respond. Try again.", comment: "Error body: request timeout"),
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
                    title: String(localized: "Daily limit reached", comment: "Error title: user hit the free daily question quota"),
                    description: String(localized: "You've answered the maximum number of questions today. Come back tomorrow.", comment: "Error body: daily quota reached"),
                    retryAction: .goHome
                )
            case .sessionNotFound:
                return AppErrorModel(
                    title: String(localized: "Session expired", comment: "Error title: the quiz session is no longer active"),
                    description: String(localized: "This quiz session is no longer active. Start a new game.", comment: "Error body: expired session"),
                    retryAction: .goHome
                )
            case let .serverError(statusCode, _) where statusCode >= 500:
                return AppErrorModel(
                    title: String(localized: "Server error", comment: "Error title: backend returned a 5xx"),
                    description: String(localized: "Something went wrong on our end. Try again.", comment: "Error body: server-side failure"),
                    retryAction: .retryOperation
                )
            case let .serverError(statusCode, _) where statusCode == 429:
                return AppErrorModel(
                    title: String(localized: "Too many requests", comment: "Error title: rate limited (HTTP 429)"),
                    description: String(localized: "Slow down a little and try again in a moment.", comment: "Error body: rate limited"),
                    retryAction: .retryOperation
                )
            case .decodingError, .invalidResponse:
                return AppErrorModel(
                    title: String(localized: "Unexpected response", comment: "Error title: response could not be decoded"),
                    description: String(localized: "We received unexpected data. Try again.", comment: "Error body: malformed response"),
                    retryAction: .retryOperation
                )
            case .invalidURL:
                return AppErrorModel(
                    title: String(localized: "Configuration error", comment: "Error title: app could not build a valid request URL"),
                    description: String(localized: "Something is wrong with the app's settings.", comment: "Error body: misconfiguration"),
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
                title: String(localized: "Couldn't start the quiz", comment: "Error title: quiz failed to start (no specific error)"),
                description: String(localized: "Check your connection and try again.", comment: "Error body: generic start failure"),
                retryAction: .retryOperation
            )
        case .submission:
            return AppErrorModel(
                title: String(localized: "Couldn't submit your answer", comment: "Error title: answer submission failed (no specific error)"),
                description: String(localized: "Try submitting your answer again.", comment: "Error body: generic submission failure"),
                retryAction: .retryOperation
            )
        case .recording:
            return AppErrorModel(
                title: String(localized: "Recording failed", comment: "Error title: audio recording failed (no specific error)"),
                description: String(localized: "Try answering again.", comment: "Error body: generic recording failure"),
                retryAction: .retryOperation
            )
        case .general:
            return AppErrorModel(
                title: String(localized: "Something went wrong", comment: "Error title: generic catch-all failure"),
                description: String(localized: "Try again.", comment: "Error body: generic catch-all failure"),
                retryAction: .retryOperation
            )
        }
    }
}
