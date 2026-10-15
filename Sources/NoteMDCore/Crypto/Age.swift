import CryptoKit
import Foundation

public enum AgeError: Error, Equatable, Sendable {
    /// Not an `AGE-SECRET-KEY-1…` string or a 32-byte X25519 private key.
    case invalidIdentity
    /// Not an `age1…` X25519 recipient, or one no key can be agreed with.
    case invalidRecipient
    case noRecipients
    /// ASCII armor that isn't strict PEM.
    case malformedArmor
    /// An age file of a version other than v1.
    case unsupportedVersion
    /// The header doesn't follow the age v1 grammar, or an X25519 stanza is invalid.
    case malformedHeader
    /// No stanza in the header was encrypted to the identity.
    case noMatchingIdentity
    case badHeaderMAC
    /// The payload ends before its final chunk.
    case truncatedPayload
    /// A payload chunk was tampered with or encrypted with another key.
    case payloadAuthenticationFailed
    /// An authentic but non-canonical payload: an empty final chunk after other chunks.
    case malformedPayload
    /// Data follows the final payload chunk.
    case trailingData
}

/// The age v1 file format (https://age-encryption.org/v1) with X25519 recipients, binary files only.
/// Decryption also accepts the ASCII-armored form.
public enum Age {
    static let versionLine = "age-encryption.org/v1"
    static let chunkSize = 64 * 1024
    private static let tagSize = 16
    private static let fileKeySize = 16
    private static let x25519Type = "X25519"
    private static let x25519Label = Data("age-encryption.org/v1/X25519".utf8)
    private static let armorBegin = "-----BEGIN AGE ENCRYPTED FILE-----"
    private static let armorEnd = "-----END AGE ENCRYPTED FILE-----"

    /// Whether `data` starts like an age v1 file, binary or armored. The rest isn't validated.
    public static func isAgeFile(_ data: Data) -> Bool {
        data.starts(with: (versionLine + "\n").utf8) || data.drop(while: isWhitespace).starts(with: armorBegin.utf8)
    }

    public static func encrypt(_ plaintext: Data, to recipients: [AgeRecipient]) throws -> Data {
        guard !recipients.isEmpty else { throw AgeError.noRecipients }
        let fileKey = randomBytes(fileKeySize)
        var header = versionLine + "\n"
        for recipient in recipients {
            header += try wrap(fileKey, to: recipient).encoded
        }
        header += "---"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(header.utf8), using: headerKey(fileKey))
        var file = Data((header + " " + base64(Data(mac)) + "\n").utf8)
        let nonce = randomBytes(16)
        file += nonce
        file += try sealPayload(plaintext, key: payloadKey(fileKey, nonce: nonce))
        return file
    }

    public static func decrypt(_ file: Data, with identity: AgeIdentity) throws -> Data {
        let bytes = try dearmor(file)
        let header = try parseHeader(bytes)
        if header.stanzas.count > 1, header.stanzas.contains(where: { $0.type == "scrypt" }) { throw AgeError.malformedHeader }
        var fileKey: Data?
        for stanza in header.stanzas where stanza.type == x25519Type {
            fileKey = try unwrap(stanza, with: identity)
            if fileKey != nil { break }
        }
        guard let fileKey else { throw AgeError.noMatchingIdentity }
        guard HMAC<SHA256>.isValidAuthenticationCode(header.mac, authenticating: header.macInput, using: headerKey(fileKey)) else {
            throw AgeError.badHeaderMAC
        }
        let payload = bytes[header.payloadStart...]
        guard payload.count >= 16 else { throw AgeError.truncatedPayload }
        return try openPayload(payload.dropFirst(16), key: payloadKey(fileKey, nonce: Data(payload.prefix(16))))
    }

    // MARK: Header

    struct Stanza {
        var type: String
        var arguments: [String]
        var body: Data

        /// The stanza lines, with the body wrapped at 64 columns and ending in a shorter, possibly empty, line.
        var encoded: String {
            var lines = "-> " + ([type] + arguments).joined(separator: " ") + "\n"
            let body = Array(base64(body).utf8)
            for start in stride(from: 0, through: body.count, by: 64) {
                lines += String(decoding: body[start..<min(start + 64, body.count)], as: UTF8.self) + "\n"
            }
            return lines
        }
    }

    struct Header {
        var stanzas: [Stanza]
        /// The header up to and including `---`, which the MAC covers.
        var macInput: ArraySlice<UInt8>
        var mac: Data
        var payloadStart: Int
    }

    static func parseHeader(_ bytes: [UInt8]) throws -> Header {
        var offset = 0
        func nextLine() throws -> ArraySlice<UInt8> {
            guard let end = bytes[offset...].firstIndex(of: 0x0A) else { throw AgeError.malformedHeader }
            defer { offset = end + 1 }
            return bytes[offset..<end]
        }

        let version = try nextLine()
        guard version.elementsEqual(versionLine.utf8) else {
            throw version.starts(with: "age-encryption.org/".utf8) ? AgeError.unsupportedVersion : AgeError.malformedHeader
        }
        var stanzas: [Stanza] = []
        while true {
            let lineStart = offset
            let line = try nextLine()
            if line.starts(with: "---".utf8) {
                guard !stanzas.isEmpty, line.starts(with: "--- ".utf8), let mac = decodeBase64(line.dropFirst(4)), mac.count == 32 else {
                    throw AgeError.malformedHeader
                }
                return Header(stanzas: stanzas, macInput: bytes[..<(lineStart + 3)], mac: mac, payloadStart: offset)
            }
            guard line.starts(with: "-> ".utf8) else { throw AgeError.malformedHeader }
            let arguments = line.dropFirst(3).split(separator: 0x20, omittingEmptySubsequences: false)
            guard arguments.allSatisfy({ !$0.isEmpty && $0.allSatisfy { (0x21...0x7E).contains($0) } }) else {
                throw AgeError.malformedHeader
            }
            var body = Data()
            while true {
                let bodyLine = try nextLine()
                guard bodyLine.count <= 64, let decoded = decodeBase64(bodyLine) else { throw AgeError.malformedHeader }
                body += decoded
                if bodyLine.count < 64 { break }
            }
            let strings = arguments.map { String(decoding: $0, as: UTF8.self) }
            stanzas.append(Stanza(type: strings[0], arguments: Array(strings.dropFirst()), body: body))
        }
    }

    private static func headerKey(_ fileKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: fileKey), info: Data("header".utf8), outputByteCount: 32)
    }

    // MARK: X25519 stanzas

    private static func wrap(_ fileKey: Data, to recipient: AgeRecipient) throws -> Stanza {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        guard let key = wrapKey(ephemeral, try recipient.publicKey, share: share, recipient: recipient.rawRepresentation) else {
            throw AgeError.invalidRecipient
        }
        let box = try ChaChaPoly.seal(fileKey, using: key, nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        return Stanza(type: x25519Type, arguments: [base64(share)], body: box.ciphertext + box.tag)
    }

    /// The file key in `stanza`, or nil when it was encrypted to another recipient.
    private static func unwrap(_ stanza: Stanza, with identity: AgeIdentity) throws -> Data? {
        guard stanza.arguments.count == 1, let share = decodeBase64(stanza.arguments[0].utf8), share.count == 32,
              stanza.body.count == fileKeySize + tagSize,
              let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: share),
              let key = wrapKey(identity.privateKey, ephemeral, share: share, recipient: identity.recipient.rawRepresentation)
        else { throw AgeError.malformedHeader }
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: Data(count: 12)), ciphertext: stanza.body.prefix(fileKeySize), tag: stanza.body.suffix(tagSize))
        return try? ChaChaPoly.open(box, using: key)
    }

    /// HKDF of the X25519 shared secret salted with the ephemeral share and the recipient, or nil when the secret is all
    /// zeros (a low-order point), which age requires aborting on.
    private static func wrapKey(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Curve25519.KeyAgreement.PublicKey, share: Data, recipient: Data
    ) -> SymmetricKey? {
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else { return nil }
        let secretBytes = secret.withUnsafeBytes { Data($0) }
        guard secretBytes.contains(where: { $0 != 0 }) else { return nil }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secretBytes), salt: share + recipient, info: x25519Label, outputByteCount: 32)
    }

    // MARK: Payload

    private static func payloadKey(_ fileKey: Data, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: fileKey), salt: nonce, info: Data("payload".utf8), outputByteCount: 32)
    }

    /// STREAM nonce: an 11-byte big-endian chunk counter, then 1 for the final chunk and 0 for the others.
    private static func chunkNonce(_ counter: UInt64, last: Bool) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { bytes[10 - i] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(i))) }
        bytes[11] = last ? 1 : 0
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// The final chunk may be full; it's empty only when the plaintext is.
    private static func sealPayload(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        var sealed = Data(capacity: plaintext.count + (plaintext.count / chunkSize + 1) * tagSize)
        var counter: UInt64 = 0
        var start = plaintext.startIndex
        repeat {
            let end = plaintext.index(start, offsetBy: chunkSize, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            let box = try ChaChaPoly.seal(plaintext[start..<end], using: key, nonce: chunkNonce(counter, last: end == plaintext.endIndex))
            sealed += box.ciphertext + box.tag
            counter += 1
            start = end
        } while start < plaintext.endIndex
        return sealed
    }

    private static func openPayload(_ sealed: ArraySlice<UInt8>, key: SymmetricKey) throws -> Data {
        func open(_ chunk: ArraySlice<UInt8>, _ counter: UInt64, last: Bool) throws -> Data? {
            let box = try ChaChaPoly.SealedBox(
                nonce: chunkNonce(counter, last: last), ciphertext: chunk.dropLast(tagSize), tag: chunk.suffix(tagSize))
            return try? ChaChaPoly.open(box, using: key)
        }

        var plaintext = Data(capacity: sealed.count)
        var counter: UInt64 = 0
        var start = sealed.startIndex
        while true {
            let remaining = sealed.endIndex - start
            guard remaining >= tagSize else { throw AgeError.truncatedPayload }
            // Only full chunks can be followed by more; anything shorter ends the payload.
            let end = start + min(remaining, chunkSize + tagSize)
            let chunk = sealed[start..<end]
            let isLast = end == sealed.endIndex
            if let opened = try open(chunk, counter, last: isLast) {
                guard !(isLast && opened.isEmpty && counter > 0) else { throw AgeError.malformedPayload }
                plaintext += opened
                if isLast { return plaintext }
            } else if chunk.count == chunkSize + tagSize, try open(chunk, counter, last: !isLast) != nil {
                // Authentic with the other flag: a cut after a non-final chunk, or data after the final one.
                throw isLast ? AgeError.truncatedPayload : AgeError.trailingData
            } else {
                throw AgeError.payloadAuthenticationFailed
            }
            counter += 1
            start = end
        }
    }

    // MARK: Encoding

    /// Canonical standard base64 without padding, as age headers use it.
    static func base64(_ data: Data) -> String {
        var encoded = data.base64EncodedString()
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return encoded
    }

    /// Decodes canonical unpadded base64, rejecting padding, line breaks and non-zero trailing bits.
    static func decodeBase64(_ encoded: some Collection<UInt8>) -> Data? {
        let text = String(decoding: encoded, as: UTF8.self)
        guard !text.contains("="),
              let data = Data(base64Encoded: text + String(repeating: "=", count: (4 - encoded.count % 4) % 4)),
              base64(data) == text
        else { return nil }
        return data
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// The binary file, decoding strict PEM armor (LF or CRLF, whitespace allowed around it) when present.
    private static func dearmor(_ data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        guard let first = bytes.firstIndex(where: { !isWhitespace($0) }), bytes[first...].starts(with: armorBegin.utf8),
              let last = bytes.lastIndex(where: { !isWhitespace($0) })
        else { return bytes }
        var lines = bytes[first...last].split(separator: 0x0A, omittingEmptySubsequences: false).map { $0.last == 0x0D ? $0.dropLast() : $0 }
        guard lines.count >= 3, lines.removeFirst().elementsEqual(armorBegin.utf8), lines.removeLast().elementsEqual(armorEnd.utf8),
              let final = lines.last, (1...64).contains(final.count), lines.dropLast().allSatisfy({ $0.count == 64 })
        else { throw AgeError.malformedArmor }
        let encoded = String(decoding: Array(lines.joined()), as: UTF8.self)
        guard let decoded = Data(base64Encoded: encoded), decoded.base64EncodedString() == encoded else { throw AgeError.malformedArmor }
        return [UInt8](decoded)
    }

    private static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}
