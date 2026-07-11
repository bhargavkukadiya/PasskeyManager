//
//  PasskeyManager.swift
//
//  A comprehensive, Swift 6 strict-concurrency-safe helper around
//  AuthenticationServices' platform passkey (WebAuthn) APIs.
//
//  Covers:
//    - Registration (creating a new passkey)
//    - Sign-in with an explicit button tap
//    - Sign-in with AutoFill / Conditional UI (tied to a username text field)
//    - Cancellation of an in-flight AutoFill request
//    - Base64URL helpers for talking to a WebAuthn-compliant server
//
//  Requirements: iOS 16 / macOS 13 or later. Passkeys rely on an iCloud
//  Keychain-backed platform authenticator, so the relying party identifier
//  must match a domain with an associated apple-app-site-association file
//  (`webcredentials` service) configured for your app.
//
//  ── Quick usage ──────────────────────────────────────────────────────
//
//  guard let anchor = PasskeyManager.keyWindowAnchor() else { return }
//
//  // Registration (Base64URL-string overload — decodes for you)
//  let reg = try await PasskeyManager.shared.register(
//      relyingPartyIdentifier: "example.com",
//      userName: "bhargav",
//      userIDBase64URL: serverResponse.userID,
//      challengeBase64URL: serverResponse.challenge,
//      anchor: anchor
//  )
//  // Send reg.credentialIDBase64URL, reg.rawAttestationObject,
//  // reg.rawClientDataJSON to your server to finish registration.
//
//  // Sign-in
//  let assertion = try await PasskeyManager.shared.signIn(
//      relyingPartyIdentifier: "example.com",
//      challenge: challengeDataFromServer,
//      anchor: anchor
//  )
//
//  // AutoFill (call once, early, e.g. in viewDidAppear / .task on the
//  // screen that owns the username field marked .textContentType(.username))
//  let assertion = try await PasskeyManager.shared.beginAutoFillAssistedSignIn(
//      relyingPartyIdentifier: "example.com",
//      challenge: challengeDataFromServer,
//      anchor: anchor
//  )
//  ─────────────────────────────────────────────────────────────────────

import AuthenticationServices
import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Capability check

/// Whether platform passkeys are supported on this OS version.
///
/// This lives outside `PasskeyManager` deliberately: `PasskeyManager` itself
/// is `@available(iOS 16.0, macOS 13.0, *)`, so any call site that can
/// already reference `PasskeyManager.isSupported` has, by definition,
/// already satisfied that availability requirement — making such a check
/// always `true` and therefore useless. This type carries no such
/// annotation, so it can be called from code with a lower deployment target
/// to decide *whether* to branch into passkey-gated code at all.
public enum PasskeyCapability {
    public static var isSupported: Bool {
        if #available(iOS 16.0, macOS 13.0, *) {
            return true
        }
        return false
    }
}

// MARK: - Base64URL

/// WebAuthn challenges, user IDs, and credential IDs are exchanged with
/// servers as Base64URL (RFC 4648 §5), not standard Base64.
public enum Base64URL {

    public static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingNeeded = base64.count % 4
        if paddingNeeded > 0 {
            base64.append(String(repeating: "=", count: 4 - paddingNeeded))
        }
        return Data(base64Encoded: base64)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Errors

public enum PasskeyError: LocalizedError, Sendable {
    /// The user dismissed the passkey sheet or backgrounded the app mid-request.
    case cancelled
    /// No matching passkeys exist for this request (e.g. AutoFill with an empty account).
    case noCredentialsAvailable
    /// The authorization returned a credential type we didn't ask for.
    case unexpectedCredentialType
    /// A registration response arrived without an attestation object.
    case missingAttestationObject
    /// The server-supplied challenge string could not be Base64URL-decoded.
    case invalidChallenge
    /// The server-supplied user identifier could not be encoded to `Data`.
    case invalidUserID
    /// Any other underlying error surfaced by AuthenticationServices.
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The passkey request was cancelled."
        case .noCredentialsAvailable:
            return "No passkeys were found for this request."
        case .unexpectedCredentialType:
            return "The authorization returned an unexpected credential type."
        case .missingAttestationObject:
            return "The registration response was missing its attestation object."
        case .invalidChallenge:
            return "The server challenge could not be decoded."
        case .invalidUserID:
            return "The user identifier could not be encoded."
        case .underlying(let message):
            return message
        }
    }
}

// MARK: - Results

/// Everything a server needs to finish a WebAuthn `navigator.credentials.create()`-style
/// registration ceremony.
public struct PasskeyRegistrationResult: Sendable {
    public let credentialID: Data
    public let rawAttestationObject: Data
    public let rawClientDataJSON: Data

    public var credentialIDBase64URL: String { Base64URL.encode(credentialID) }
}

/// Everything a server needs to finish a WebAuthn `navigator.credentials.get()`-style
/// assertion (sign-in) ceremony.
public struct PasskeyAssertionResult: Sendable {
    public let credentialID: Data
    public let rawAuthenticatorData: Data
    public let signature: Data
    /// Echoes back the user handle the credential was registered with, if the
    /// authenticator provided one.
    public let userID: Data?
    public let rawClientDataJSON: Data

    public var credentialIDBase64URL: String { Base64URL.encode(credentialID) }
}

// MARK: - Delegate bridge

/// Bridges the callback-based `ASAuthorizationControllerDelegate` API to
/// `async`/`await`. A fresh instance is created per request so overlapping
/// or repeated calls never share mutable state.
///
/// The protocol requirements are legacy Objective-C APIs that predate Swift
/// concurrency and are not annotated `@MainActor`. Rather than suppress
/// isolation checking at the conformance site, the requirements below are
/// kept `nonisolated` and hop back onto the main actor with
/// `MainActor.assumeIsolated`, which is safe here because
/// `ASAuthorizationController` always delivers its callbacks on the main
/// thread.
@MainActor
private final class PasskeyAuthorizationCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private let anchor: ASPresentationAnchor
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    /// Wires this instance up as `controller`'s delegate, calls `start`
    /// (which should invoke one of `performRequests(options:)`), and
    /// suspends until a delegate callback fires exactly once.
    ///
    /// Each coordinator is single-use: it is created fresh per request and
    /// discarded afterwards, so overlapping calls on the same instance would
    /// indicate a misuse of this type rather than a supported scenario.
    func perform(on controller: ASAuthorizationController, start: () -> Void) async throws -> ASAuthorization {
        precondition(continuation == nil, "PasskeyAuthorizationCoordinator is single-use; create a new instance per request.")

        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let pending = continuation
        continuation = nil
        switch result {
        case .success(let authorization):
            pending?.resume(returning: authorization)
        case .failure(let error):
            pending?.resume(throwing: error)
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        MainActor.assumeIsolated {
            finish(.success(authorization))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let mapped: Error
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                mapped = PasskeyError.cancelled
            case .notHandled:
                // No matching credential for this request — the routine,
                // expected outcome during AutoFill with no saved passkeys.
                mapped = PasskeyError.noCredentialsAvailable
            case .failed:
                // Broader failure category (e.g. a misconfigured associated
                // domain, or the authenticator rejecting the request) —
                // preserve the detail instead of masking it as "no credentials".
                mapped = PasskeyError.underlying(authError.localizedDescription)
            default:
                mapped = PasskeyError.underlying(authError.localizedDescription)
            }
        } else {
            mapped = error
        }
        MainActor.assumeIsolated {
            finish(.failure(mapped))
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchor
        }
    }
}

// MARK: - PasskeyManager

@available(iOS 16.0, macOS 13.0, *)
@MainActor
public final class PasskeyManager {

    public static let shared = PasskeyManager()

    /// Kept so an in-flight AutoFill request can be cancelled, e.g. when the
    /// user starts typing a password instead.
    private var autoFillController: ASAuthorizationController?

    private init() {}

    // MARK: Cancellation-aware execution

    /// Runs `controller` via `coordinator`, and cancels `controller` if the
    /// enclosing `Task` is cancelled (e.g. a SwiftUI `.task {}` view
    /// disappearing) so the underlying request — and its continuation —
    /// never leak.
    ///
    /// `CheckedContinuation` does not automatically resume on `Task`
    /// cancellation, so without this, a cancelled caller would leave the
    /// passkey sheet's continuation permanently suspended.
    private func performCancellable(
        _ controller: ASAuthorizationController,
        coordinator: PasskeyAuthorizationCoordinator,
        start: @escaping () -> Void
    ) async throws -> ASAuthorization {
        // `ASAuthorizationController` isn't marked `Sendable`, but it's only
        // ever touched here (immediately, on the main actor) and inside
        // `onCancel` below (also hopped onto the main actor before use), so
        // capturing it across the `@Sendable` `onCancel` closure is safe.
        nonisolated(unsafe) let controller = controller

        return try await withTaskCancellationHandler {
            try await coordinator.perform(on: controller, start: start)
        } onCancel: {
            Task { @MainActor in
                controller.cancel()
            }
        }
    }

    // MARK: Registration

    /// Creates a new passkey for `relyingPartyIdentifier` and presents the
    /// system UI for biometric/passcode confirmation.
    ///
    /// - Parameters:
    ///   - relyingPartyIdentifier: Your WebAuthn RP ID, typically your bare domain (e.g. "example.com").
    ///   - userName: Displayed to the user in the system UI and stored with the credential.
    ///   - userID: An opaque, stable identifier for the account (never the username or email itself).
    ///   - challenge: A fresh, single-use challenge issued by your server.
    ///   - userVerification: Whether biometric/passcode verification is requested, required, or skipped.
    ///   - attestation: Attestation statement preference to request from the authenticator.
    ///   - anchor: The window to present the passkey sheet from.
    public func register(
        relyingPartyIdentifier: String,
        userName: String,
        userID: Data,
        challenge: Data,
        userVerification: ASAuthorizationPublicKeyCredentialUserVerificationPreference = .preferred,
        attestation: ASAuthorizationPublicKeyCredentialAttestationKind = .none,
        anchor: ASPresentationAnchor
    ) async throws -> PasskeyRegistrationResult {
        try Task.checkCancellation()
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: userName,
            userID: userID
        )
        request.userVerificationPreference = userVerification
        request.attestationPreference = attestation

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let coordinator = PasskeyAuthorizationCoordinator(anchor: anchor)

        let authorization = try await performCancellable(controller, coordinator: coordinator) {
            controller.performRequests()
        }

        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw PasskeyError.unexpectedCredentialType
        }
        guard let attestationObject = credential.rawAttestationObject else {
            throw PasskeyError.missingAttestationObject
        }

        return PasskeyRegistrationResult(
            credentialID: credential.credentialID,
            rawAttestationObject: attestationObject,
            rawClientDataJSON: credential.rawClientDataJSON
        )
    }

    // MARK: Sign in (explicit, e.g. a "Sign in with a passkey" button)

    /// Prompts the user to authenticate with an existing passkey.
    ///
    /// - Parameter preferImmediatelyAvailableCredentials: When `true`, the
    ///   system skips iCloud Keychain lookup delays and only offers
    ///   credentials already available on-device — useful right after a
    ///   password sign-in to offer a quick passkey upgrade prompt.
    public func signIn(
        relyingPartyIdentifier: String,
        challenge: Data,
        anchor: ASPresentationAnchor,
        preferImmediatelyAvailableCredentials: Bool = false
    ) async throws -> PasskeyAssertionResult {
        try Task.checkCancellation()
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let coordinator = PasskeyAuthorizationCoordinator(anchor: anchor)

        let authorization = try await performCancellable(controller, coordinator: coordinator) {
            if preferImmediatelyAvailableCredentials {
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }

        return try Self.assertionResult(from: authorization)
    }

    // MARK: Sign in with AutoFill (Conditional UI)

    /// Begins a passive, AutoFill-assisted passkey request. Call this once,
    /// early in the lifetime of your sign-in screen (e.g. from `.task {}` or
    /// `viewDidAppear`), *before* the user interacts with anything. iOS
    /// surfaces matching passkeys directly in the QuickType bar above the
    /// keyboard when the user taps a text field with
    /// `.textContentType(.username)`.
    ///
    /// This call suspends until the user picks a passkey (or cancels), so
    /// run it in its own `Task` rather than awaiting it inline in a view's
    /// body — it is not meant to block your UI.
    public func beginAutoFillAssistedSignIn(
        relyingPartyIdentifier: String,
        challenge: Data,
        anchor: ASPresentationAnchor
    ) async throws -> PasskeyAssertionResult {
        try Task.checkCancellation()
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        autoFillController = controller
        let coordinator = PasskeyAuthorizationCoordinator(anchor: anchor)

        defer { autoFillController = nil }

        let authorization = try await performCancellable(controller, coordinator: coordinator) {
            controller.performAutoFillAssistedRequests()
        }

        return try Self.assertionResult(from: authorization)
    }

    /// Cancels an in-flight AutoFill request, e.g. because the user switched
    /// to a password field or navigated away. Safe to call even if no
    /// AutoFill request is running.
    public func cancelAutoFillAssistedSignIn() {
        autoFillController?.cancel()
        autoFillController = nil
    }

    // MARK: Helpers

    private static func assertionResult(from authorization: ASAuthorization) throws -> PasskeyAssertionResult {
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError.unexpectedCredentialType
        }
        return PasskeyAssertionResult(
            credentialID: credential.credentialID,
            rawAuthenticatorData: credential.rawAuthenticatorData,
            signature: credential.signature,
            userID: credential.userID,
            rawClientDataJSON: credential.rawClientDataJSON
        )
    }

    #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
    /// Convenience for grabbing the current key window as a presentation anchor.
    /// Falls back to the first connected window scene's first window if no
    /// window is currently marked key (e.g. very early in app launch).
    public static func keyWindowAnchor() -> ASPresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return keyWindow
        }
        return scenes.first?.windows.first
    }
    #elseif canImport(AppKit)
    public static func keyWindowAnchor() -> ASPresentationAnchor? {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
    }
    #endif
}

// MARK: - Base64URL string convenience overloads

/// Most WebAuthn servers hand back challenges and user IDs as Base64URL
/// strings in a JSON payload. These overloads decode them for you and throw
/// `.invalidChallenge` / `.invalidUserID` on malformed input, rather than
/// requiring every call site to force-unwrap `Base64URL.decode(_:)` itself.
@available(iOS 16.0, macOS 13.0, *)
public extension PasskeyManager {

    /// Creates a new passkey, decoding the server's Base64URL-encoded
    /// challenge and user ID strings automatically.
    ///
    /// Throws ``PasskeyError/invalidChallenge`` if `challengeBase64URL` cannot
    /// be decoded, or ``PasskeyError/invalidUserID`` if `userIDBase64URL`
    /// cannot be decoded. All other parameters and behavior are identical to
    /// the `Data`-based ``register(relyingPartyIdentifier:userName:userID:challenge:userVerification:attestation:anchor:)``.
    func register(
        relyingPartyIdentifier: String,
        userName: String,
        userIDBase64URL: String,
        challengeBase64URL: String,
        userVerification: ASAuthorizationPublicKeyCredentialUserVerificationPreference = .preferred,
        attestation: ASAuthorizationPublicKeyCredentialAttestationKind = .none,
        anchor: ASPresentationAnchor
    ) async throws -> PasskeyRegistrationResult {
        guard let challenge = Base64URL.decode(challengeBase64URL) else {
            throw PasskeyError.invalidChallenge
        }
        guard let userID = Base64URL.decode(userIDBase64URL) else {
            throw PasskeyError.invalidUserID
        }
        return try await register(
            relyingPartyIdentifier: relyingPartyIdentifier,
            userName: userName,
            userID: userID,
            challenge: challenge,
            userVerification: userVerification,
            attestation: attestation,
            anchor: anchor
        )
    }

    /// Prompts the user to authenticate with an existing passkey, decoding
    /// the server's Base64URL-encoded challenge string automatically.
    ///
    /// Throws ``PasskeyError/invalidChallenge`` if `challengeBase64URL` cannot
    /// be decoded. All other parameters and behavior are identical to the
    /// `Data`-based ``signIn(relyingPartyIdentifier:challenge:anchor:preferImmediatelyAvailableCredentials:)``.
    func signIn(
        relyingPartyIdentifier: String,
        challengeBase64URL: String,
        anchor: ASPresentationAnchor,
        preferImmediatelyAvailableCredentials: Bool = false
    ) async throws -> PasskeyAssertionResult {
        guard let challenge = Base64URL.decode(challengeBase64URL) else {
            throw PasskeyError.invalidChallenge
        }
        return try await signIn(
            relyingPartyIdentifier: relyingPartyIdentifier,
            challenge: challenge,
            anchor: anchor,
            preferImmediatelyAvailableCredentials: preferImmediatelyAvailableCredentials
        )
    }

    /// Begins a passive, AutoFill-assisted passkey request, decoding the
    /// server's Base64URL-encoded challenge string automatically.
    ///
    /// Throws ``PasskeyError/invalidChallenge`` if `challengeBase64URL` cannot
    /// be decoded. All other parameters and behavior are identical to the
    /// `Data`-based ``beginAutoFillAssistedSignIn(relyingPartyIdentifier:challenge:anchor:)``.
    func beginAutoFillAssistedSignIn(
        relyingPartyIdentifier: String,
        challengeBase64URL: String,
        anchor: ASPresentationAnchor
    ) async throws -> PasskeyAssertionResult {
        guard let challenge = Base64URL.decode(challengeBase64URL) else {
            throw PasskeyError.invalidChallenge
        }
        return try await beginAutoFillAssistedSignIn(
            relyingPartyIdentifier: relyingPartyIdentifier,
            challenge: challenge,
            anchor: anchor
        )
    }
}
