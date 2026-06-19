//
//  DeviceAttestService.swift
//  Hangs
//
//  Apple App Attest client (issue #60 Part B, task 60.13).
//
//  The crypto half of App Attest: it proves to the backend that a bootstrap
//  request comes from *our* genuine app on a *real* iPhone (Secure Enclave), not
//  a script minting unlimited anonymous identities. AuthService drives the flow
//  (fetch a server challenge → ask for a credential → POST it to anon-bootstrap);
//  this type only generates the Secure-Enclave key and signs over the challenge.
//
//  App Attest cannot run on the simulator (`DCAppAttestService.isSupported` is
//  false there), so the whole DeviceCheck path is compiled out under
//  `#if targetEnvironment(simulator)` — the bypass is physically absent from the
//  production binary, not a runtime branch. On the simulator `isSupported`
//  returns false and AuthService falls back to a plain (unattested) bootstrap,
//  which the backend accepts only while `APP_ATTEST_REQUIRED` is off.
//

import Foundation
import os

#if !targetEnvironment(simulator)
import CryptoKit
import DeviceCheck
#endif

// MARK: - Model

/// One App Attest credential, ready to attach to an `anon-bootstrap` request.
nonisolated struct AttestCredential: Sendable {
    enum Mode: Sendable { case attestation, assertion }
    let mode: Mode
    /// base64 App Attest keyId (SHA256 of the device public key).
    let keyID: String
    /// The JSON body to POST to `/auth/anon-bootstrap` for this credential.
    let bootstrapBody: [String: String]
}

// MARK: - DeviceAttestor protocol

/// The crypto half of App Attest, abstracted so AuthService can be unit-tested
/// with a mock — the real `DCAppAttestService` only runs on a physical device.
// `nonisolated` requirements so the `actor AuthService` can drive this under the
// project's `-default-isolation=MainActor` build flag (mirrors `TokenStore`).
protocol DeviceAttestor: Sendable {
    /// False on the simulator and on unsupported devices. When false, AuthService
    /// skips App Attest and mints a plain identity (backend allows that only with
    /// `APP_ATTEST_REQUIRED` off).
    nonisolated var isSupported: Bool { get }

    /// The keyId of a previously attested **and** backend-bound key, if any. Its
    /// presence is what makes AuthService re-bootstrap with an assertion rather
    /// than mint a brand-new identity.
    nonisolated func storedKeyID() -> String?

    /// Build a credential signed over `challenge`. `.attestation` generates a
    /// fresh Secure-Enclave key (first launch); `.assertion` signs with the
    /// stored key (re-bootstrap). Returns nil on any DeviceCheck failure.
    nonisolated func credential(for mode: AttestCredential.Mode, challenge: String) async -> AttestCredential?

    /// Persist `keyID` once the backend has bound it to an identity. Called only
    /// after a *successful* attestation bootstrap, so a stored keyId always has a
    /// matching backend key — never an orphan that would 401 forever on assertion.
    nonisolated func confirmKey(_ keyID: String)

    /// Forget the stored keyId (e.g. the backend rejected its assertion) so the
    /// next bootstrap re-attests a fresh key.
    nonisolated func forgetKey()
}

// MARK: - AppAttestor (real, device-only)

/// `DCAppAttestService`-backed attestor. Stateless in Swift — the keyId lives in
/// the Keychain — so it is trivially `Sendable`.
nonisolated final class AppAttestor: DeviceAttestor {
    private let keyStore = AttestKeyStore()

    var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        DCAppAttestService.shared.isSupported
        #endif
    }

    func storedKeyID() -> String? { keyStore.load() }
    func confirmKey(_ keyID: String) { keyStore.save(keyID) }
    func forgetKey() { keyStore.clear() }

    func credential(for mode: AttestCredential.Mode, challenge: String) async -> AttestCredential? {
        #if targetEnvironment(simulator)
        return nil
        #else
        let service = DCAppAttestService.shared
        guard service.isSupported, let challengeData = challenge.data(using: .utf8) else {
            return nil
        }
        // Both sides hash the raw challenge bytes: the backend verifies the nonce
        // over SHA256(authData ‖ SHA256(challenge)), so clientDataHash must be
        // SHA256(challenge) — matching app_attest.py exactly.
        let clientDataHash = Data(SHA256.hash(data: challengeData))

        do {
            switch mode {
            case .attestation:
                let keyID = try await service.generateKey()
                let attestation = try await attestWithRetry(service, keyID: keyID, hash: clientDataHash)
                return AttestCredential(
                    mode: .attestation,
                    keyID: keyID,
                    bootstrapBody: [
                        "key_id": keyID,
                        "attestation": attestation.base64EncodedString(),
                        "challenge": challenge,
                    ]
                )
            case .assertion:
                guard let keyID = keyStore.load() else { return nil }
                let assertion = try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
                return AttestCredential(
                    mode: .assertion,
                    keyID: keyID,
                    bootstrapBody: [
                        "key_id": keyID,
                        "assertion": assertion.base64EncodedString(),
                        "challenge": challenge,
                    ]
                )
            }
        } catch {
            Logger.network.warning("🔐 App Attest \(String(describing: mode), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    /// `attestKey` round-trips to Apple's servers and can fail transiently
    /// (`DCError.serverUnavailable`). Retry once before giving up so a single
    /// hiccup doesn't force a plain bootstrap.
    private func attestWithRetry(
        _ service: DCAppAttestService, keyID: String, hash: Data
    ) async throws -> Data {
        do {
            return try await service.attestKey(keyID, clientDataHash: hash)
        } catch {
            Logger.network.warning("🔐 attestKey failed, retrying once: \(error.localizedDescription, privacy: .public)")
            try await Task.sleep(nanoseconds: 500_000_000)
            return try await service.attestKey(keyID, clientDataHash: hash)
        }
    }
    #endif
}

// MARK: - AttestKeyStore

/// Persists the App Attest keyId (a public value — SHA256 of the device public
/// key — not a secret) in the Keychain so it survives relaunches. This-device,
/// after-first-unlock, matching the token store. The keyId is written only once
/// the backend confirms the identity binding (see `AppAttestor.confirmKey`).
private nonisolated struct AttestKeyStore {
    private let service = "\(Bundle.main.bundleIdentifier ?? "com.missinghue.hangs").appattest"
    private let account = "attest_key_id"

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Logger.network.warning("🔐 Attest keyId load failed: OSStatus \(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ keyID: String) {
        let data = Data(keyID.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Logger.network.warning("🔐 Attest keyId add failed: OSStatus \(addStatus, privacy: .public)")
            }
        } else if updateStatus != errSecSuccess {
            Logger.network.warning("🔐 Attest keyId update failed: OSStatus \(updateStatus, privacy: .public)")
        }
    }

    func clear() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.network.warning("🔐 Attest keyId delete failed: OSStatus \(status, privacy: .public)")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
