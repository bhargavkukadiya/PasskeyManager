# PasskeyManager

A Swift 6, strict-concurrency-safe wrapper around AuthenticationServices' platform
passkey (WebAuthn) APIs — registration, sign-in, and AutoFill/Conditional UI —
exposed as `async`/`await`.

## Requirements

- iOS 16+, macOS 13+, visionOS 1+ (enforced via `@available`)
  - *Note:* AutoFill / Conditional UI is supported on iOS and visionOS. On macOS and Mac Catalyst, button-triggered passkey sign-in is used.
- Xcode 16+, Swift 6 language mode
- A domain you control, with HTTPS and the ability to host a
  `.well-known/apple-app-site-association` file
- A WebAuthn-capable server (this package handles the client side)

## Installation

### Swift Package Manager (SPM)

Add the dependency to your `Package.swift`:

**Option 1: Tagged release (recommended once published)**
```swift
dependencies: [
    .package(url: "https://github.com/bhargavkukadiya/PasskeyManager.git", from: "1.0.0")
]
```

**Option 2: Main branch directly**
```swift
dependencies: [
    .package(url: "https://github.com/bhargavkukadiya/PasskeyManager.git", branch: "main")
]
```

Or in Xcode: **File** → **Add Package Dependencies...** and enter the repository URL.

Alternatively, you can drag and drop `Sources/PasskeyManager/PasskeyManager.swift` directly into your Xcode project.

## 1. One-time app setup

Passkeys are scoped to a **relying party identifier** (your bare domain, e.g.
`example.com`) and require Apple to trust that your app is allowed to use it.

**a. Add the Associated Domains capability**

In your target's *Signing & Capabilities*, add **Associated Domains** and an entry:

```
webcredentials:example.com
```

**b. Host an `apple-app-site-association` file**

At `https://example.com/.well-known/apple-app-site-association` (no file
extension, served as `application/json`, no redirects):

```json
{
  "webcredentials": {
    "apps": ["TEAMID.com.yourcompany.yourapp"]
  }
}
```

Replace `TEAMID` with your Apple Developer Team ID. Apple fetches and caches
this file, so changes can take a little while to propagate — test on a real
device, not just the simulator, when debugging this step.

**c. (Optional) Support your website too**

If users can also sign in on the web, add `"webauthn"` alongside
`"webcredentials"` so passkeys are shared between your site and app via
iCloud Keychain.

## 2. What's in `PasskeyManager`

| Symbol | Purpose |
|---|---|
| `PasskeyManager.shared.register(...)` | Create a new passkey |
| `PasskeyManager.shared.signIn(...)` | Sign in with an explicit button tap |
| `PasskeyManager.shared.beginAutoFillAssistedSignIn(...)` | Passive sign-in via QuickType bar (iOS / visionOS) |
| `PasskeyManager.shared.cancelAutoFillAssistedSignIn()` | Stop an in-flight AutoFill request |
| `PasskeyManager.keyWindowAnchor()` | Grab the active key window as a presentation anchor |
| `PasskeyCapability.isSupported` | OS-version capability check — callable without satisfying `PasskeyManager`'s `@available` gate |
| `PasskeyCapability.isAutoFillSupported` | Checks if AutoFill passkey flow is supported on current OS & platform |
| `Base64URL.encode` / `.decode` | Convert between `Data` and RFC 4648 §5 Base64URL |
| `register`/`signIn`/`beginAutoFillAssistedSignIn` (Base64URL overloads) | Direct `String` overloads that decode server Base64URL values for you |
| `PasskeyRegistrationResult`, `PasskeyAssertionResult` | Payloads with both `Data` and `Base64URL` accessors for easy JSON serialization |
| `PasskeyError` | Typed, `LocalizedError`-conforming failure reasons |

## 3. The server contract

Passkeys follow the standard WebAuthn ceremony. Your server is responsible for
generating challenges and validating signatures — this class only handles the
on-device half.

**Registration**

1. Server → app: a fresh `challenge` (send as Base64URL, decode with
   `Base64URL.decode(_:)`) and a `userID` (an opaque account identifier, *not*
   the username/email).
2. App → server: `credentialIDBase64URL`, `rawAttestationObjectBase64URL`,
   `rawClientDataJSONBase64URL` from `PasskeyRegistrationResult`.
3. Server verifies the attestation and stores the public key extracted from it,
   keyed by `credentialID`.

**Sign-in**

1. Server → app: a fresh `challenge`.
2. App → server: `credentialIDBase64URL`, `rawAuthenticatorDataBase64URL`, `signatureBase64URL`,
   `rawClientDataJSONBase64URL` from `PasskeyAssertionResult`.
3. Server looks up the stored public key for that `credentialID` and verifies
   the signature over `authenticatorData || SHA-256(clientDataJSON)`.

## 4. Usage

**Registration**

Use the Base64URL-string overload directly with what your server sends:

```swift
guard let anchor = PasskeyManager.keyWindowAnchor() else { return }

let result = try await PasskeyManager.shared.register(
    relyingPartyIdentifier: "example.com",
    userName: username,
    userIDBase64URL: serverResponse.userID,
    challengeBase64URL: serverResponse.challenge,
    anchor: anchor
)

try await api.finishRegistration(
    credentialID: result.credentialIDBase64URL,
    attestationObject: result.rawAttestationObjectBase64URL,
    clientDataJSON: result.rawClientDataJSONBase64URL
)
```

(A `Data`-based overload is also available if you've already decoded the
challenge/user ID yourself.)

**Sign-in (button tap)**

```swift
guard let anchor = PasskeyManager.keyWindowAnchor() else { return }

let result = try await PasskeyManager.shared.signIn(
    relyingPartyIdentifier: "example.com",
    challenge: challenge,
    anchor: anchor
)

try await api.finishSignIn(
    credentialID: result.credentialIDBase64URL,
    authenticatorData: result.rawAuthenticatorDataBase64URL,
    signature: result.signatureBase64URL,
    clientDataJSON: result.rawClientDataJSONBase64URL
)
```

**Sign-in (AutoFill / Conditional UI - iOS / visionOS)**

Mark your username field so the system knows it can offer passkeys there:

```swift
TextField("Username", text: $username)
    .textContentType(.username)
```

Then kick off AutoFill early, in its own `Task`:

```swift
.task {
    guard let anchor = PasskeyManager.keyWindowAnchor() else { return }
    do {
        let result = try await PasskeyManager.shared.beginAutoFillAssistedSignIn(
            relyingPartyIdentifier: "example.com",
            challenge: challenge,
            anchor: anchor
        )
        // proceed with `result`
    } catch is CancellationError {
        // view disappeared or request was cancelled — ignore
    } catch {
        // real failure — surface it
    }
}
```

Call `PasskeyManager.shared.cancelAutoFillAssistedSignIn()` if the user starts
typing a password instead, or when the screen disappears.

## 5. Error handling

| `PasskeyError` case | Typical cause |
|---|---|
| `.cancelled` | User dismissed the sheet, or backgrounded the app |
| `.noCredentialsAvailable` | No matching passkey exists for this RP on this account (common, expected during AutoFill) |
| `.unexpectedCredentialType` | Mixed up a registration request with an assertion result, or vice versa |
| `.missingAttestationObject` | Should not happen in practice; guards against a malformed response |
| `.invalidChallenge` / `.invalidUserID` | Base64URL decoding failed on a string-based `register`/`signIn` call — check your server's encoding |
| `.underlying(_)` | Any other `ASAuthorizationError`, including `.failed` (e.g. a misconfigured associated domain) — check `errorDescription` for detail |

`.cancelled` and `.noCredentialsAvailable` are expected, routine outcomes —
don't show an alert for them, especially from AutoFill.

## 6. Testing notes

- The simulator supports passkeys, but you must be signed into iCloud with
  two-factor auth enabled and Passwords & Keychain syncing on (Settings →
  your name → iCloud).
- Test on a real device before shipping — the associated domain file fetch
  and iCloud Keychain sync behave more reliably there.
- To reset test credentials on a device: Settings → Passwords, find the
  entry, and delete it.
