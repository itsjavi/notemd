import CryptoKit
import Foundation
import LocalAuthentication
import NoteMDCore
import Security

/// Keeps the age identity of secret notes on this Mac (decision-6), wrapped by a Secure Enclave key whose use needs
/// user presence: unwrapping it asks for Touch ID, an Apple Watch or the login password. CryptoKit's Secure Enclave
/// keys need no Keychain entitlement, so this works in ad-hoc signed builds. Only the public recipient is stored in
/// the clear, so notes can be encrypted without unlocking.
nonisolated enum SecretKeyStore {
    private struct Stored: Codable {
        /// Who notes are encrypted to (`age1…`).
        var recipient: String
        /// The Secure Enclave key's `dataRepresentation`: an opaque blob only this Mac's Secure Enclave can use.
        var enclaveKey: Data?
        /// Test builds only: a software key instead of the Secure Enclave, so hooks never prompt.
        var testKey: Data?
        var ephemeralPublicKey: Data
        /// The identity's raw key, sealed with ChaCha20-Poly1305 under the key agreed with the wrapping key.
        var sealedIdentity: Data
    }

    enum Failure: LocalizedError {
        case notSetUp
        case damaged

        var errorDescription: String? {
            switch self {
            case .notSetUp: "Secret notes aren't set up on this Mac."
            case .damaged: "The secret notes key on this Mac can't be read. Import your recovery key in Settings to set it up again."
            }
        }
    }

    private static let wrapInfo = Data("NoteMD secret notes identity v1".utf8)

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.itsjavi.notemd", isDirectory: true)
            .appendingPathComponent("secret-notes-key.json")
    }

    private static func load() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static var isSetUp: Bool { load() != nil }

    /// Who secret notes are encrypted to, readable without unlocking.
    static var recipient: AgeRecipient? { load().flatMap { try? AgeRecipient(string: $0.recipient) } }

    /// Wraps `identity` with a new Secure Enclave key and stores it, replacing any earlier setup.
    static func save(_ identity: AgeIdentity, testOnly: Bool = false) throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let wrappingPublicKey: P256.KeyAgreement.PublicKey
        var stored = Stored(recipient: identity.recipient.string, ephemeralPublicKey: ephemeral.publicKey.x963Representation, sealedIdentity: Data())
        if testOnly {
            let key = P256.KeyAgreement.PrivateKey()
            stored.testKey = key.rawRepresentation
            wrappingPublicKey = key.publicKey
        } else {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error) else {
                throw error.map { $0.takeRetainedValue() as Error } ?? Failure.damaged
            }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            stored.enclaveKey = key.dataRepresentation
            wrappingPublicKey = key.publicKey
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: wrappingPublicKey)
        stored.sealedIdentity = try ChaChaPoly.seal(identity.rawRepresentation, using: wrappingKey(shared, stored)).combined
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
    }

    /// Unwraps the identity. With the Secure Enclave this blocks while the system asks for Touch ID or the password:
    /// call it off the main thread. Throws `LAError.userCancel` (and similar) when the user cancels.
    /// `allowingTestKey`: test builds only, for keys stored with `testOnly`.
    static func unwrap(reason: String, allowingTestKey: Bool = false) throws -> AgeIdentity {
        guard let stored = load() else { throw Failure.notSetUp }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: stored.ephemeralPublicKey)
        let shared: SharedSecret
        if let enclaveKey = stored.enclaveKey {
            let context = LAContext()
            context.localizedReason = reason
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclaveKey, authenticationContext: context)
            shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        } else if let testKey = stored.testKey, allowingTestKey {
            shared = try P256.KeyAgreement.PrivateKey(rawRepresentation: testKey).sharedSecretFromKeyAgreement(with: ephemeral)
        } else {
            throw Failure.damaged
        }
        guard let raw = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: stored.sealedIdentity), using: wrappingKey(shared, stored)),
              let identity = try? AgeIdentity(rawRepresentation: raw)
        else { throw Failure.damaged }
        return identity
    }

    /// Forgets the key on this Mac. Secret notes then open only after importing the recovery key.
    static func remove() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }

    private static func wrappingKey(_ shared: SharedSecret, _ stored: Stored) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: stored.ephemeralPublicKey, sharedInfo: wrapInfo, outputByteCount: 32)
    }
}
