import XCTest
import Foundation
import AuthenticationServices
@testable import PasskeyManager

final class PasskeyManagerTests: XCTestCase {

    // MARK: - Base64URL Tests

    func testBase64URLRoundtrip() {
        let testStrings = [
            "",
            "f",
            "fo",
            "foo",
            "foob",
            "fooba",
            "foobar",
            "Hello, WebAuthn! 🚀",
            "{\"challenge\":\"dGVzdA\",\"origin\":\"https://example.com\"}"
        ]

        for string in testStrings {
            let originalData = Data(string.utf8)
            let encoded = Base64URL.encode(originalData)

            // Must not contain standard base64 characters +, /, or =
            XCTAssertFalse(encoded.contains("+"))
            XCTAssertFalse(encoded.contains("/"))
            XCTAssertFalse(encoded.contains("="))

            let decodedData = Base64URL.decode(encoded)
            XCTAssertEqual(decodedData, originalData)
        }
    }

    func testBase64URLSafeCharacters() {
        // 0xfb, 0xff, 0xbf in standard Base64 is "+/+/".
        // In Base64URL without padding it should be "-_-_".
        let bytes: [UInt8] = [0xfb, 0xff, 0xbf]
        let data = Data(bytes)
        let encoded = Base64URL.encode(data)
        XCTAssertEqual(encoded, "-_-_")

        let decoded = Base64URL.decode(encoded)
        XCTAssertEqual(decoded, data)
    }

    func testBase64URLPaddingLengths() {
        // Length mod 4 == 3 -> needs 1 '=' padding character
        let data2Bytes = Data([0x61, 0x62]) // "ab" -> standard base64 "YWI=" -> base64url "YWI"
        XCTAssertEqual(Base64URL.encode(data2Bytes), "YWI")
        XCTAssertEqual(Base64URL.decode("YWI"), data2Bytes)

        // Length mod 4 == 2 -> needs 2 '=' padding characters
        let data1Byte = Data([0x61]) // "a" -> standard base64 "YQ==" -> base64url "YQ"
        XCTAssertEqual(Base64URL.encode(data1Byte), "YQ")
        XCTAssertEqual(Base64URL.decode("YQ"), data1Byte)

        // Invalid length mod 4 == 1
        XCTAssertNil(Base64URL.decode("A"))
    }

    func testBase64URLAcceptsOptionalPadding() {
        XCTAssertEqual(Base64URL.decode("YQ=="), Data([0x61]))
        XCTAssertEqual(Base64URL.decode("YQ="), Data([0x61]))
        XCTAssertEqual(Base64URL.decode("YWI="), Data([0x61, 0x62]))
    }

    func testBase64URLRejectsStandardAlphabetAndInvalidCharacters() {
        // Standard Base64 for [0xfb, 0xff, 0xbf]; Base64URL would be "-_-_".
        XCTAssertNil(Base64URL.decode("+/+/"))
        XCTAssertNil(Base64URL.decode("YW I"))
        XCTAssertNil(Base64URL.decode("YQ!"))
        XCTAssertNil(Base64URL.decode("Y=Q"))
    }

    // MARK: - Result Models Tests

    func testRegistrationResultProperties() {
        let credID = Data([0x01, 0x02, 0x03, 0x04])
        let attestation = Data([0xAA, 0xBB, 0xCC])
        let clientJSONString = "{\"type\":\"webauthn.create\",\"challenge\":\"dGVzdA\"}"
        let clientDataJSON = Data(clientJSONString.utf8)

        let result = PasskeyRegistrationResult(
            credentialID: credID,
            rawAttestationObject: attestation,
            rawClientDataJSON: clientDataJSON
        )

        XCTAssertEqual(result.credentialIDBase64URL, Base64URL.encode(credID))
        XCTAssertEqual(result.rawAttestationObjectBase64URL, Base64URL.encode(attestation))
        XCTAssertEqual(result.rawClientDataJSONBase64URL, Base64URL.encode(clientDataJSON))
        XCTAssertEqual(result.clientDataJSONString, clientJSONString)
    }

    func testAssertionResultProperties() {
        let credID = Data([0x10, 0x20, 0x30])
        let authData = Data([0x40, 0x50, 0x60, 0x70])
        let sig = Data([0x80, 0x90, 0xA0])
        let userID = Data([0xB0, 0xC0])
        let clientJSONString = "{\"type\":\"webauthn.get\",\"challenge\":\"dGVzdA\"}"
        let clientDataJSON = Data(clientJSONString.utf8)

        let resultWithUser = PasskeyAssertionResult(
            credentialID: credID,
            rawAuthenticatorData: authData,
            signature: sig,
            userID: userID,
            rawClientDataJSON: clientDataJSON
        )

        XCTAssertEqual(resultWithUser.credentialIDBase64URL, Base64URL.encode(credID))
        XCTAssertEqual(resultWithUser.rawAuthenticatorDataBase64URL, Base64URL.encode(authData))
        XCTAssertEqual(resultWithUser.signatureBase64URL, Base64URL.encode(sig))
        XCTAssertEqual(resultWithUser.userIDBase64URL, Base64URL.encode(userID))
        XCTAssertEqual(resultWithUser.rawClientDataJSONBase64URL, Base64URL.encode(clientDataJSON))
        XCTAssertEqual(resultWithUser.clientDataJSONString, clientJSONString)

        let resultWithoutUser = PasskeyAssertionResult(
            credentialID: credID,
            rawAuthenticatorData: authData,
            signature: sig,
            userID: nil,
            rawClientDataJSON: clientDataJSON
        )
        XCTAssertNil(resultWithoutUser.userIDBase64URL)
    }

    // MARK: - Errors Tests

    func testErrorDescriptions() {
        XCTAssertEqual(PasskeyError.cancelled.errorDescription, "The passkey request was cancelled.")
        XCTAssertEqual(PasskeyError.noCredentialsAvailable.errorDescription, "No passkeys were found for this request.")
        XCTAssertEqual(PasskeyError.unexpectedCredentialType.errorDescription, "The authorization returned an unexpected credential type.")
        XCTAssertEqual(PasskeyError.missingAttestationObject.errorDescription, "The registration response was missing its attestation object.")
        XCTAssertEqual(PasskeyError.credentialAlreadyRegistered.errorDescription, "A passkey for this account already exists on this device.")
        XCTAssertEqual(PasskeyError.invalidChallenge.errorDescription, "The server challenge could not be decoded.")
        XCTAssertEqual(PasskeyError.invalidUserID.errorDescription, "The user identifier could not be decoded.")
        XCTAssertEqual(PasskeyError.invalidCredentialID.errorDescription, "A credential identifier could not be decoded.")

        let underlying = URLError(.timedOut)
        XCTAssertEqual(PasskeyError.underlying(underlying).errorDescription, underlying.localizedDescription)
    }

    // MARK: - Error Mapping Tests

    private func mapped(_ code: ASAuthorizationError.Code) -> PasskeyError {
        PasskeyAuthorizationCoordinator.mapError(ASAuthorizationError(code))
    }

    func testCanceledMapsToCancelled() {
        guard case .cancelled = mapped(.canceled) else {
            return XCTFail("Expected .cancelled")
        }
    }

    func testNotHandledMapsToNoCredentialsAvailable() {
        guard case .noCredentialsAvailable = mapped(.notHandled) else {
            return XCTFail("Expected .noCredentialsAvailable")
        }
    }

    func testOtherAuthorizationErrorsKeepTheirCode() {
        for code: ASAuthorizationError.Code in [.failed, .invalidResponse, .notInteractive, .unknown] {
            guard case .underlying(let error as ASAuthorizationError) = mapped(code) else {
                XCTFail("Expected .underlying(ASAuthorizationError) for \(code)")
                continue
            }
            XCTAssertEqual(error.code, code)
        }
    }

    func testMatchedExcludedCredentialMapsToCredentialAlreadyRegistered() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else {
            throw XCTSkip("matchedExcludedCredential requires iOS 18 / macOS 15 / visionOS 2")
        }
        guard case .credentialAlreadyRegistered = mapped(.matchedExcludedCredential) else {
            return XCTFail("Expected .credentialAlreadyRegistered")
        }
    }

    func testNonAuthorizationErrorsArePreserved() {
        let error = URLError(.notConnectedToInternet)
        guard case .underlying(let underlying as URLError) = PasskeyAuthorizationCoordinator.mapError(error) else {
            return XCTFail("Expected .underlying(URLError)")
        }
        XCTAssertEqual(underlying.code, .notConnectedToInternet)
    }

    // MARK: - Coordinator Tests

    @MainActor
    private func makeController() -> ASAuthorizationController {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "example.com")
        let request = provider.createCredentialAssertionRequest(challenge: Data(count: 32))
        return ASAuthorizationController(authorizationRequests: [request])
    }

    @MainActor
    func testCoordinatorResumesOnceWithMappedError() async {
        let controller = makeController()
        let coordinator = PasskeyAuthorizationCoordinator(anchor: ASPresentationAnchor())

        do {
            _ = try await coordinator.perform(on: controller) {
                coordinator.authorizationController(
                    controller: controller,
                    didCompleteWithError: ASAuthorizationError(.canceled)
                )
                // A second callback must be ignored rather than resuming the continuation twice.
                coordinator.authorizationController(
                    controller: controller,
                    didCompleteWithError: ASAuthorizationError(.failed)
                )
            }
            XCTFail("Expected an error")
        } catch PasskeyError.cancelled {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCoordinatorThrowsCancellationErrorWhenCancelledMidRequest() async {
        let controller = makeController()
        let coordinator = PasskeyAuthorizationCoordinator(anchor: ASPresentationAnchor())
        var started = false

        let task = Task { @MainActor in
            // `start` never triggers a delegate callback, so only cancellation can end this.
            try await coordinator.perform(on: controller) { started = true }
        }
        while !started {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCoordinatorThrowsCancellationErrorWhenCallbackBeatsCancellationHop() async {
        let controller = makeController()
        let coordinator = PasskeyAuthorizationCoordinator(anchor: ASPresentationAnchor())
        var started = false

        let task = Task { @MainActor in
            try await coordinator.perform(on: controller) { started = true }
        }
        while !started {
            await Task.yield()
        }
        // Cancel, then deliver a callback before the cancellation handler's
        // main-actor hop gets a chance to run.
        task.cancel()
        coordinator.authorizationController(
            controller: controller,
            didCompleteWithError: ASAuthorizationError(.canceled)
        )

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCoordinatorDoesNotStartWhenAlreadyCancelled() async {
        let controller = makeController()
        let coordinator = PasskeyAuthorizationCoordinator(anchor: ASPresentationAnchor())
        var started = false

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.perform(on: controller) { started = true }
        }

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertFalse(started)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Capability Tests

    func testCapabilityChecks() {
        XCTAssertTrue(PasskeyCapability.isSupported)
        #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS)
        XCTAssertTrue(PasskeyCapability.isAutoFillSupported)
        #else
        XCTAssertFalse(PasskeyCapability.isAutoFillSupported)
        #endif
    }
}
