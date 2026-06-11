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

/// Maps any thrown error to a localised (SK-first per D6) title + description + retry action.
struct AppErrorModel: Equatable, Sendable {
    let title: String
    let description: String
    let retryAction: AppErrorRetryAction

    /// Map a thrown error and its quiz context to the Error screen display model.
    static func from(_ error: Error, context: ErrorContext = .general) -> AppErrorModel {
        // URLError: connectivity / timeout
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return AppErrorModel(
                    title: "Nie je internetové pripojenie",
                    description: "Skontroluj Wi-Fi alebo mobilné dáta a skús to znova.",
                    retryAction: .retryOperation
                )
            case .timedOut:
                return AppErrorModel(
                    title: "Čas vypršal",
                    description: "Server odpovedal príliš pomaly. Skús to znova.",
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
                    title: "Denný limit dosiahnutý",
                    description: "Dnes si odpovedal na maximálny počet otázok. Vráť sa zajtra.",
                    retryAction: .goHome
                )
            case .sessionNotFound:
                return AppErrorModel(
                    title: "Relácia vypršala",
                    description: "Táto kvízová relácia už nie je aktívna. Začni novú hru.",
                    retryAction: .goHome
                )
            case let .serverError(statusCode, _) where statusCode >= 500:
                return AppErrorModel(
                    title: "Chyba servera",
                    description: "Niečo sa pokazilo na našej strane. Skús to znova.",
                    retryAction: .retryOperation
                )
            case let .serverError(statusCode, _) where statusCode == 429:
                return AppErrorModel(
                    title: "Príliš veľa požiadaviek",
                    description: "Spomaľ trochu a skús to znova za chvíľu.",
                    retryAction: .retryOperation
                )
            case .decodingError, .invalidResponse:
                return AppErrorModel(
                    title: "Neočakávaná odpoveď",
                    description: "Dostali sme neočakávané dáta. Skús to znova.",
                    retryAction: .retryOperation
                )
            case .invalidURL:
                return AppErrorModel(
                    title: "Chyba konfigurácie",
                    description: "Niečo sa pokazilo s nastaveniami aplikácie.",
                    retryAction: .dismiss
                )
            default:
                break
            }
        }

        // Context-driven fallback when the error type does not map to a specific case
        switch context {
        case .initialization:
            return AppErrorModel(
                title: "Kvíz sa nepodarilo spustiť",
                description: "Skontroluj pripojenie a skús to znova.",
                retryAction: .retryOperation
            )
        case .submission:
            return AppErrorModel(
                title: "Odpoveď sa nepodarilo odoslať",
                description: "Skús odoslať odpoveď znova.",
                retryAction: .retryOperation
            )
        case .recording:
            return AppErrorModel(
                title: "Nahrávanie zlyhalo",
                description: "Skús odpovedať znova.",
                retryAction: .retryOperation
            )
        case .general:
            return AppErrorModel(
                title: "Niečo sa pokazilo",
                description: "Skús to znova.",
                retryAction: .retryOperation
            )
        }
    }
}
