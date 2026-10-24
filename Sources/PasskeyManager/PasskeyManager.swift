//
//  PasskeyManager.swift
//
//  A comprehensive, Swift 6 strict-concurrency-safe helper around
//  AuthenticationServices' platform passkey (WebAuthn) APIs.
//
//  Covers:
//    - Registration (creating a new passkey)
//    - Sign-in with an explicit button tap
//    - Sign-in with AutoFill / Conditional UI (iOS / visionOS)
//    - Cancellation of an in-flight AutoFill request
//    - Base64URL helpers for talking to a WebAuthn-compliant server
//
//  Requirements: iOS 16 / macOS 13 / visionOS 1 or later. The relying party
//  identifier must match a domain with an associated
//  apple-app-site-association file (`webcredentials` service) configured
//  for your app.
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
//  // Send reg.credentialIDBase64URL, reg.rawAttestationObjectBase64URL,
//  // reg.rawClientDataJSONBase64URL to your server to finish registration.
//
//  // Sign-in
//  let assertion = try await PasskeyManager.shared.signIn(
//      relyingPartyIdentifier: "example.com",
//      challenge: challengeDataFromServer,
//      anchor: anchor
//  )
//
//  // AutoFill (iOS/visionOS: call once, early, e.g. in viewDidAppear / .task
//  // on the screen that owns the username field marked .textContentType(.username))
//  #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS)
//  let assertion = try await PasskeyManager.shared.beginAutoFillAssistedSignIn(
//      relyingPartyIdentifier: "example.com",
//      challenge: challengeDataFromServer,
//      anchor: anchor
//  )
//  #endif
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
/// is `@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)`, so any call site that can
/// already reference `PasskeyManager` has, by definition,
/// already satisfied that availability requirement — making such a check
/// always `true` and therefore useless. This type carries no such
/// annotation, so it can be called from code with a lower deployment target
/// to decide *whether* to branch into passkey-gated code at all.
///
/// When consumed through Swift Package Manager, the package already requires
/// iOS 16 / macOS 13 / visionOS 1, so `isSupported` is always `true`; it only
/// matters when this file is dropped into a project with a lower deployment
/// target. These checks only report API availability, not saved credentials,
/// credential provider setup, or Associated Domains configuration.
public enum PasskeyCapability {
    public static var isSupported: Bool {
        if #available(iOS 16.0, macOS 13.0, visionOS 1.0, *) {
            return true
        }
        return false
    }

    /// Whether AutoFill-assisted sign-in (Conditional UI) is supported on this platform and OS version.
    public static var isAutoFillSupported: Bool {
        #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS)
        if #available(iOS 16.0, visionOS 1.0, *) {
            return true
        }
        return false
        #else
        return false
        #endif
    }
}

// MARK: - Base64URL

/// WebAuthn challenges, user IDs, and credential IDs are exchanged with
/// servers as Base64URL (RFC 4648 §5), not standard Base64.
public enum Base64URL: Sendable {

    /// Decodes a Base64URL string. Trailing `=` padding is optional, since
    /// WebAuthn omits it. Returns `nil` for anything else — including the
    /// standard-Base64 `+` and `/` characters, which mean the server used the
    /// wrong alphabet.
    public static func decode(_ string: String) -> Data? {
        guard !string.contains(where: { $0 == "+" || $0 == "/" }) else {
            return nil
        }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingNeeded = base64.count % 4
        if paddingNeeded == 1 {
            // A single remainder character cannot form a valid Base64 payload.
            return nil
        } else if paddingNeeded > 1 {
            base64.append(String(repeating: "=", count: 4 - paddingNeeded))
        }
        return Data(base64Encoded: base64)
    }

    /// Encodes `data` as unpadded Base64URL, as WebAuthn expects.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Errors

/// Errors thrown by `PasskeyManager`.
///
/// Once input has been decoded, cancelling the calling `Task` cancels a
/// pending authorization and throws `CancellationError` rather than any of
/// these. A failure the system reports while the Task is being cancelled is
/// also reported as `CancellationError`. A successful authorization that
/// wins the race is still returned, so checks on its result
/// (``missingAttestationObject``, ``unexpectedCredentialType``) can still
/// throw.
public enum PasskeyError: LocalizedError, Sendable {
    /// The system reported the request as cancelled. This covers:
    /// - the user dismissing the passkey sheet or backgrounding the app;
    /// - `signIn(…, preferImmediatelyAvailableCredentials: true)` finding no
    ///   passkey on this device, in which case no sheet was shown — fall back
    ///   to your password form;
    /// - an AutoFill request being superseded by another request or by
    ///   `cancelAutoFillAssistedSignIn()`.
    case cancelled
    /// The system didn't handle the request (`ASAuthorizationError.Code.notHandled`),
    /// e.g. no credential provider could satisfy it. Fall back to another
    /// sign-in method.
    case noCredentialsAvailable
    /// The authorization returned a credential type we didn't ask for.
    case unexpectedCredentialType
    /// A registration response arrived without an attestation object.
    case missingAttestationObject
    /// Registration matched one of `excludedCredentialIDs`: this
    /// authenticator already holds a passkey for the account.
    case credentialAlreadyRegistered
    /// The server-supplied challenge string could not be Base64URL-decoded.
    case invalidChallenge
    /// The server-supplied user identifier could not be Base64URL-decoded.
    case invalidUserID
    /// A server-supplied credential ID string could not be Base64URL-decoded.
    case invalidCredentialID
    /// Any other error, preserved so callers can inspect it — typically an
    /// `ASAuthorizationError` whose `code` is e.g. `.failed`,
    /// `.invalidResponse` or `.notInteractive`.
    case underlying(any Error)

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
        case .credentialAlreadyRegistered:
            return "A passkey for this account already exists on this device."
        case .invalidChallenge:
            return "The server challenge could not be decoded."
        case .invalidUserID:
            return "The user identifier could not be decoded."
        case .invalidCredentialID:
            return "A credential identifier could not be decoded."
        case .underlying(let error):
            return error.localizedDescription
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
    public var rawAttestationObjectBase64URL: String { Base64URL.encode(rawAttestationObject) }
    public var rawClientDataJSONBase64URL: String { Base64URL.encode(rawClientDataJSON) }

    /// UTF-8 string representation of `rawClientDataJSON`.
    public var clientDataJSONString: String? { String(data: rawClientDataJSON, encoding: .utf8) }

    public init(
        credentialID: Data,
        rawAttestationObject: Data,
        rawClientDataJSON: Data
    ) {
        self.credentialID = credentialID
        self.rawAttestationObject = rawAttestationObject
        self.rawClientDataJSON = rawClientDataJSON
    }
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
    public var rawAuthenticatorDataBase64URL: String { Base64URL.encode(rawAuthenticatorData) }
    public var signatureBase64URL: String { Base64URL.encode(signature) }
    public var userIDBase64URL: String? { userID.map { Base64URL.encode($0) } }
    public var rawClientDataJSONBase64URL: String { Base64URL.encode(rawClientDataJSON) }

    /// UTF-8 string representation of `rawClientDataJSON`.
    public var clientDataJSONString: String? { String(data: rawClientDataJSON, encoding: .utf8) }

    public init(
        credentialID: Data,
        rawAuthenticatorData: Data,
        signature: Data,
        userID: Data?,
        rawClientDataJSON: Data
    ) {
        self.credentialID = credentialID
        self.rawAuthenticatorData = rawAuthenticatorData
        self.signature = signature
        self.userID = userID
        self.rawClientDataJSON = rawClientDataJSON
    }
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
@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
@MainActor
final class PasskeyAuthorizationCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private let anchor: ASPresentationAnchor
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    /// The controller whose request is in flight, kept so Task cancellation
    /// can cancel it. Cleared once the request finishes.
    private var controller: ASAuthorizationController?
    private var isUsed = false

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    /// Wires this instance up as `controller`'s delegate, calls `start`
    /// (which should invoke one of `performRequests(options:)`), and
    /// suspends until the request finishes.
    ///
    /// If the enclosing `Task` is cancelled (e.g. a SwiftUI `.task {}` view
    /// disappearing), its cancellation handler hops to the main actor to
    /// resume with `CancellationError` and cancel the request.
    /// `CheckedContinuation` doesn't resume on
    /// cancellation by itself, so without this a cancelled caller would stay
    /// suspended until the system responded. If the Task is already
    /// cancelled, `start` is never called.
    ///
    /// A failure that arrives while the Task is cancelled is always reported
    /// as `CancellationError`, even if the delegate callback beat the
    /// cancellation handler's main-actor hop. A success in that window is
    /// still returned, since the user did complete the ceremony.
    ///
    /// Each coordinator is single-use: it is created fresh per request and
    /// discarded afterwards, so reusing an instance would indicate a misuse
    /// of this type rather than a supported scenario.
    func perform(on controller: ASAuthorizationController, start: () -> Void) async throws -> ASAuthorization {
        precondition(!isUsed, "PasskeyAuthorizationCoordinator is single-use; create a new instance per request.")
        isUsed = true

        controller.delegate = self
        controller.presentationContextProvider = self

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    if Task.isCancelled {
                        finish(.failure(CancellationError()))
                    } else {
                        self.controller = controller
                        start()
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    self.cancel()
                }
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Resumes the caller with `CancellationError` and cancels the in-flight
    /// request. The delegate callback the system makes in response is
    /// ignored, since the continuation has already been consumed.
    private func cancel() {
        let inFlight = controller
        finish(.failure(CancellationError()))
        inFlight?.cancel()
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        switch result {
        case .success(let authorization):
            pending?.resume(returning: authorization)
        case .failure(let error):
            pending?.resume(throwing: error)
        }
    }

    /// Translates an error delivered by `ASAuthorizationController` into a
    /// `PasskeyError`, keeping the original error for anything without a
    /// dedicated case.
    nonisolated static func mapError(_ error: Error) -> PasskeyError {
        guard let authError = error as? ASAuthorizationError else {
            return .underlying(error)
        }
        switch authError.code {
        case .canceled:
            return .cancelled
        case .notHandled:
            return .noCredentialsAvailable
        default:
            if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *),
               authError.code == .matchedExcludedCredential {
                return .credentialAlreadyRegistered
            }
            return .underlying(authError)
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
        let mapped = Self.mapError(error)
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

/// Performs platform passkey requests on the main actor.
///
/// Cancelling the calling Task cancels a pending authorization and throws
/// `CancellationError`. If a successful authorization wins the cancellation
/// race, that result is still returned. A failure the system reports while
/// the Task is being cancelled is reported as `CancellationError`.
@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
@MainActor
public final class PasskeyManager {

    public static let shared = PasskeyManager()

    #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS)
    /// Kept so an in-flight AutoFill request can be cancelled, e.g. when the
    /// user starts typing a password instead.
    private var autoFillController: ASAuthorizationController?
    #endif

    private init() {}

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
    ///   - excludedCredentialIDs: Credential IDs already registered for this
    ///     account (WebAuthn `excludeCredentials`). If the authenticator holds
    ///     one of them, registration fails with
    ///     ``PasskeyError/credentialAlreadyRegistered`` instead of creating a
    ///     duplicate passkey. Honored on iOS / Mac Catalyst 18 and macOS 15
    ///     and later; ignored on visionOS and earlier OS versions.
    ///   - anchor: The window to present the passkey sheet from.
    ///
    /// On iOS and visionOS, this cancels any in-flight AutoFill request first.
    public func register(
        relyingPartyIdentifier: String,
        userName: String,
        userID: Data,
        challenge: Data,
        userVerification: ASAuthorizationPublicKeyCredentialUserVerificationPreference = .preferred,
        attestation: ASAuthorizationPublicKeyCredentialAttestationKind = .none,
        excludedCredentialIDs: [Data] = [],
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
        #if !os(visionOS)
        if #available(iOS 18.0, macOS 15.0, *), !excludedCredentialIDs.isEmpty {
            request.excludedCredentials = excludedCredentialIDs.map(
                ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:)
            )
        }
        #endif

        cancelAutoFillBeforeModalRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let coordinator = PasskeyAuthorizationCoordinator(anchor: anchor)

        let authorization = try await coordinator.perform(on: controller) {
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
    /// On iOS and visionOS, this cancels any in-flight AutoFill request first.
    ///
    /// - Parameters:
    ///   - allowedCredentialIDs: When non-empty, only these credentials
    ///     (WebAuthn `allowCredentials`) may be used to sign in — e.g. after
    ///     the user has typed a username. Leave empty to let the user pick
    ///     any passkey for the relying party.
    ///   - preferImmediatelyAvailableCredentials: When `true`, the system
    ///     shows a sheet only if a matching passkey is immediately available
    ///     on this device (no QR code / nearby-device option). Any supplied
    ///     `allowedCredentialIDs` must also match. If there is
    ///     none, it shows no UI and throws ``PasskeyError/cancelled``
    ///     immediately. Use this when your sign-in screen first appears, and
    ///     fall back to your password form on `.cancelled`.
    public func signIn(
        relyingPartyIdentifier: String,
        challenge: Data,
        allowedCredentialIDs: [Data] = [],
        anchor: ASPresentationAnchor,
        preferImmediatelyAvailableCredentials: Bool = false
    ) async throws -> PasskeyAssertionResult {
        try Task.checkCancellation()
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowedCredentialIDs.map(
            ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:)
        )

        cancelAutoFillBeforeModalRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let coordinator = PasskeyAuthorizationCoordinator(anchor: anchor)

        let authorization = try await coordinator.perform(on: controller) {
            if preferImmediatelyAvailableCredentials {
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }

        return try Self.assertionResult(from: authorization)
    }

    // MARK: Sign in with AutoFill (Conditional UI)

    #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS)
    /// Begins a passive, AutoFill-assisted passkey request. Call this once,
    /// early in the lifetime of your sign-in screen (e.g. from `.task {}` or
    /// `viewDidAppear`), *before* the user interacts with anything. iOS/visionOS
    /// surfaces matching passkeys directly in the QuickType bar above the
    /// keyboard when the user taps a text field with
    /// `.textContentType(.username)`.
    ///
    /// This call suspends until the user picks a passkey (or cancels), so
    /// run it in its own `Task` rather than awaiting it inline in a view's
    /// body — it is not meant to block your UI.
    ///
    /// Throws ``PasskeyError/cancelled`` if the request is superseded by
    /// another AutoFill request, a `signIn` / `register` call, or
    /// `cancelAutoFillAssistedSignIn()`. It isn't restarted automatically, so
    /// call this again if the user returns to the sign-in field. Cancelling
    /// the enclosing `Task` throws `CancellationError` unless a successful
    /// authorization wins the cancellation race.
    public func beginAutoFillAssistedSignIn(
        relyingPartyIdentifier: String,
        challenge: Data,
        anchor: ASPresentationAnchor
    ) async throws -> PasskeyAssertionResult {
        try Task.checkCancellation()
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let controller = ASAuthorizationController(authorizationRequests: [request])

        // Cancel any existing in-flight AutoFill before starting a new one
        autoFillController?.cancel()
        autoFillController = controller

        let coordinator = PasskeyAuthorizationCoordinator(anchor: anchor)

        defer {
            if autoFillController === controller {
                autoFillController = nil
            }
        }

        let authorization = try await coordinator.perform(on: controller) {
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
    #endif

    // MARK: Helpers

    /// Apple's guidance is to cancel a running AutoFill request before
    /// starting a modal one, so the two never compete for the same sheet.
    private func cancelAutoFillBeforeModalRequest() {
        #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS)
        cancelAutoFillAssistedSignIn()
        #endif
    }

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
    /// Convenience for grabbing a foreground window as a presentation anchor.
    /// Handles multi-scene environments (iPadOS Stage Manager / multitasking / visionOS)
    /// by preferring foreground-active scenes, then foreground-inactive ones (e.g. during
    /// launch). Windows of backgrounded scenes are never returned, since the passkey
    /// sheet can't be shown from them.
    ///
    /// Unavailable in app extensions, which can't reach `UIApplication.shared`;
    /// pass the extension's own window as the anchor instead.
    @available(iOSApplicationExtension, unavailable)
    @available(macCatalystApplicationExtension, unavailable)
    @available(visionOSApplicationExtension, unavailable)
    public static func keyWindowAnchor() -> ASPresentationAnchor? {
        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        for state in [UIScene.ActivationState.foregroundActive, .foregroundInactive] {
            let windows = connectedScenes
                .filter { $0.activationState == state }
                .flatMap(\.windows)
            if let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }) {
                return window
            }
        }
        return nil
    }
    #elseif canImport(AppKit)
    /// Convenience for grabbing the key or main window as a presentation anchor on macOS.
    public static func keyWindowAnchor() -> ASPresentationAnchor? {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible && !$0.isMiniaturized })
    }
    #endif
}

// MARK: - Base64URL string convenience overloads

/// Most WebAuthn servers hand back challenges and user IDs as Base64URL
/// strings in a JSON payload. These overloads decode them for you and throw
/// `.invalidChallenge` / `.invalidUserID` / `.invalidCredentialID` on
/// malformed input, rather than requiring every call site to force-unwrap
/// `Base64URL.decode(_:)` itself.
@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
public extension PasskeyManager {

    /// Creates a new passkey, decoding the server's Base64URL-encoded
    /// challenge, user ID and excluded credential ID strings automatically.
    ///
    /// Throws ``PasskeyError/invalidChallenge``, ``PasskeyError/invalidUserID``
    /// or ``PasskeyError/invalidCredentialID`` if the corresponding input
    /// cannot be decoded. All other parameters and behavior are identical to
    /// the `Data`-based ``register(relyingPartyIdentifier:userName:userID:challenge:userVerification:attestation:excludedCredentialIDs:anchor:)``.
    func register(
        relyingPartyIdentifier: String,
        userName: String,
        userIDBase64URL: String,
        challengeBase64URL: String,
        userVerification: ASAuthorizationPublicKeyCredentialUserVerificationPreference = .preferred,
        attestation: ASAuthorizationPublicKeyCredentialAttestationKind = .none,
        excludedCredentialIDsBase64URL: [String] = [],
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
            excludedCredentialIDs: Self.decodeCredentialIDs(excludedCredentialIDsBase64URL),
            anchor: anchor
        )
    }

    /// Prompts the user to authenticate with an existing passkey, decoding
    /// the server's Base64URL-encoded challenge and allowed credential ID
    /// strings automatically.
    ///
    /// Throws ``PasskeyError/invalidChallenge`` or
    /// ``PasskeyError/invalidCredentialID`` if the corresponding input cannot
    /// be decoded. All other parameters and behavior are identical to the
    /// `Data`-based ``signIn(relyingPartyIdentifier:challenge:allowedCredentialIDs:anchor:preferImmediatelyAvailableCredentials:)``.
    func signIn(
        relyingPartyIdentifier: String,
        challengeBase64URL: String,
        allowedCredentialIDsBase64URL: [String] = [],
        anchor: ASPresentationAnchor,
        preferImmediatelyAvailableCredentials: Bool = false
    ) async throws -> PasskeyAssertionResult {
        guard let challenge = Base64URL.decode(challengeBase64URL) else {
            throw PasskeyError.invalidChallenge
        }
        return try await signIn(
            relyingPartyIdentifier: relyingPartyIdentifier,
            challenge: challenge,
            allowedCredentialIDs: Self.decodeCredentialIDs(allowedCredentialIDsBase64URL),
            anchor: anchor,
            preferImmediatelyAvailableCredentials: preferImmediatelyAvailableCredentials
        )
    }

    #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS)
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
    #endif

    private static func decodeCredentialIDs(_ strings: [String]) throws -> [Data] {
        try strings.map { string in
            guard let data = Base64URL.decode(string) else {
                throw PasskeyError.invalidCredentialID
            }
            return data
        }
    }
}
