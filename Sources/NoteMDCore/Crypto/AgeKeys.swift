import CryptoKit
import Foundation

/// An age X25519 identity (private key), written as `AGE-SECRET-KEY-1…`.
public struct AgeIdentity: Sendable {
    static let prefix = "AGE-SECRET-KEY-"

    let privateKey: Curve25519.KeyAgreement.PrivateKey

    /// Generates a new random identity.
    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Parses an `AGE-SECRET-KEY-1…` string, ignoring surrounding whitespace.
    public init(string: String) throws {
        guard let (hrp, data) = try? Bech32.decode(string.trimmingCharacters(in: .whitespacesAndNewlines)), hrp == Self.prefix
        else { throw AgeError.invalidIdentity }
        try self.init(rawRepresentation: data)
    }

    /// The 32-byte X25519 private key.
    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
        else { throw AgeError.invalidIdentity }
        privateKey = key
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    /// The secret `AGE-SECRET-KEY-1…` string, the user's recovery key.
    public var string: String { Bech32.encode(hrp: Self.prefix, data: rawRepresentation) }

    public var recipient: AgeRecipient { AgeRecipient(publicKey: privateKey.publicKey) }
}

extension AgeIdentity: CustomStringConvertible {
    /// Never includes the secret key, so identities can't leak into logs.
    public var description: String { "AgeIdentity(\(recipient.string))" }
}

/// An age X25519 recipient (public key), written as `age1…`.
public struct AgeRecipient: Sendable, Hashable {
    static let prefix = "age"

    let rawRepresentation: Data

    init(publicKey: Curve25519.KeyAgreement.PublicKey) {
        rawRepresentation = publicKey.rawRepresentation
    }

    /// Parses an `age1…` string, ignoring surrounding whitespace.
    public init(string: String) throws {
        guard let (hrp, data) = try? Bech32.decode(string.trimmingCharacters(in: .whitespacesAndNewlines)), hrp == Self.prefix,
              data.count == 32
        else { throw AgeError.invalidRecipient }
        rawRepresentation = data
    }

    public var string: String { Bech32.encode(hrp: Self.prefix, data: rawRepresentation) }

    var publicKey: Curve25519.KeyAgreement.PublicKey {
        get throws {
            do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation) } catch { throw AgeError.invalidRecipient }
        }
    }
}

extension AgeRecipient: CustomStringConvertible {
    public var description: String { string }
}
