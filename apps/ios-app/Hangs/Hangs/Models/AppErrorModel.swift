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
        title: "Question history is full",
        description: "Clear your question history in Settings (Reset question history) and start a new game.",
        retryAction: .goHome
    )

    /// Map a thrown error and its quiz context to the Error screen display model.
    static func from(_ error: Error, context: ErrorContext = .general) -> AppErrorModel {
        // Cancellation: not a network failure — a retry CTA is misleading,
        // offer a soft dismiss instead (54.15; surfaced by the 54.5 path).
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return AppErrorModel(
                title: "Submission interrupted",
                description: "The submission was interrupted. Try answering again.",
                retryAction: .dismiss
            )
        }

        // URLError: connectivity / timeout
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return AppErrorModel(
                    title: "No internet connection",
                    description: "Check your Wi-Fi or mobile data and try again.",
                    retryAction: .retryOperation
                )
            case .timedOut:
                return AppErrorModel(
                    title: "Request timed out",
                    description: "The server took too long to respond. Try again.",
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
                    title: "Daily limit reached",
                    description: "You've answered the maximum number of questions for today. Come back tomorrow.",
                    retryAction: .goHome
                )
            case .sessionNotFound:
                return AppErrorModel(
                    title: "Session expired",
                    description: "This quiz session is no longer active. Start a new game.",
                    retryAction: .goHome
                )
            case let .serverError(statusCode, _) where statusCode >= 500:
                return AppErrorModel(
                    title: "Server error",
                    description: "Something went wrong on our end. Try again.",
                    retryAction: .retryOperation
                )
            case let .serverError(statusCode, _) where statusCode == 429:
                return AppErrorModel(
                    title: "Too many requests",
                    description: "Slow down a bit and try again shortly.",
                    retryAction: .retryOperation
                )
            case .decodingError, .invalidResponse:
                return AppErrorModel(
                    title: "Unexpected response",
                    description: "We received unexpected data. Try again.",
                    retryAction: .retryOperation
                )
            case .invalidURL:
                return AppErrorModel(
                    title: "Configuration error",
                    description: "Something went wrong with the app settings.",
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
                title: "Couldn't start quiz",
                description: "Check your connection and try again.",
                retryAction: .retryOperation
            )
        case .submission:
            return AppErrorModel(
                title: "Couldn't submit answer",
                description: "Try submitting your answer again.",
                retryAction: .retryOperation
            )
        case .recording:
            return AppErrorModel(
                title: "Recording failed",
                description: "Try answering again.",
                retryAction: .retryOperation
            )
        case .general:
            return AppErrorModel(
                title: "Something went wrong",
                description: "Try again.",
                retryAction: .retryOperation
            )
        }
    }
}
