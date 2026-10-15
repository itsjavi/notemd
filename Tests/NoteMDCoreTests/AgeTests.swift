import CryptoKit
import Foundation
import Testing

@testable import NoteMDCore

@Suite struct AgeTests {
    // MARK: Bech32

    @Test func bech32ValidVectors() throws {
        let vectors = [
            "A12UEL5L", "a12uel5l",
            "an83characterlonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
            "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
            "11" + String(repeating: "q", count: 82) + "c8247j",
            "split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w", "?1ezyfcl",
        ]
        for vector in vectors {
            let (hrp, data) = try Bech32.decode(vector)
            #expect(Bech32.encode(hrp: hrp, data: data) == vector)
        }
        let (hrp, data) = try Bech32.decode("abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw")
        #expect(hrp == "abcdef")
        #expect(hex(data) == "00443214c74254b635cf84653a56d7c675be77df")
    }

    @Test func bech32InvalidVectors() {
        let vectors: [(String, Bech32.Error)] = [
            ("A1G7SGD8", .invalidChecksum), ("10a06t8", .invalidSeparator), ("1qzzfhee", .invalidSeparator),
            ("x1b4n0q5v", .invalidCharacter), ("li1dgmt3", .invalidSeparator), ("pzry9x0s0muk", .invalidSeparator),
            (" 1nwldj5", .invalidCharacter), ("\u{7F}1axkwrx", .invalidCharacter), ("de1lg7wt\u{FF}", .invalidCharacter),
            ("a12UEL5L", .mixedCase), ("a12uel5m", .invalidChecksum),
        ]
        for (vector, error) in vectors {
            #expect(throws: error, "\(vector)") { try Bech32.decode(vector) }
        }
    }

    // MARK: Keys

    @Test func rfc7748KeyPairMatchesAgeKeygen() throws {
        // RFC 7748 §6.1 Alice; the strings were checked with `age-keygen -y`.
        let identity = try AgeIdentity(rawRepresentation: bytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        #expect(identity.string == "AGE-SECRET-KEY-1WURK6ZNNRZJH60QKC9E9RVNXGH05CTU8A0QFJ243WLA628DE9S4QRFH26J")
        #expect(hex(identity.recipient.rawRepresentation) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        #expect(identity.recipient.string == "age1s5s0qzvfxzn4gayt0hwtg0hhtgxm7wsdycup4a8t5j5ca25mfe4qt4hs7q")
        #expect(try AgeIdentity(string: identity.string).rawRepresentation == identity.rawRepresentation)
    }

    @Test func cliKeyPair() throws {
        let identity = try AgeIdentity(string: AgeCLIFixtures.identity)
        #expect(identity.recipient == (try AgeRecipient(string: AgeCLIFixtures.recipient)))
        #expect(identity.string == AgeCLIFixtures.identity)
        #expect(identity.recipient.string == AgeCLIFixtures.recipient)
    }

    @Test func keyStringRoundTrips() throws {
        let identity = AgeIdentity()
        #expect(identity.string.hasPrefix("AGE-SECRET-KEY-1"))
        #expect(identity.recipient.string.hasPrefix("age1"))
        #expect(try AgeIdentity(string: identity.string).rawRepresentation == identity.rawRepresentation)
        #expect(try AgeIdentity(string: "  \(identity.string)\n").rawRepresentation == identity.rawRepresentation)
        #expect(try AgeRecipient(string: identity.recipient.string) == identity.recipient)
        #expect(try AgeIdentity(rawRepresentation: identity.rawRepresentation).recipient == identity.recipient)
        #expect(!identity.description.contains(identity.string))
        #expect(AgeIdentity().recipient != identity.recipient)
    }

    @Test func invalidKeyStrings() {
        let identity = AgeIdentity()
        let secret = identity.string
        let recipient = identity.recipient.string
        let mixedCase = secret.prefix(20).lowercased() + secret.dropFirst(20)
        for string in [secret.lowercased(), mixedCase, recipient, String(secret.dropLast()) + "Q", "", "AGE-SECRET-KEY-1"] {
            #expect(throws: AgeError.invalidIdentity, "\(string)") { try AgeIdentity(string: string) }
        }
        let wrongLength = Bech32.encode(hrp: "age", data: Data(count: 31))
        for string in [recipient.uppercased(), secret, wrongLength, String(recipient.dropLast()) + "q", "age1"] {
            #expect(throws: AgeError.invalidRecipient, "\(string)") { try AgeRecipient(string: string) }
        }
        #expect(throws: AgeError.invalidIdentity) { try AgeIdentity(rawRepresentation: Data(count: 31)) }
    }

    // MARK: Round trips

    @Test(arguments: [0, 1, 1_000, 65_536, 65_537, 200_000])
    func roundTrip(size: Int) throws {
        let identity = AgeIdentity()
        let plaintext = pattern(size)
        let file = try Age.encrypt(plaintext, to: [identity.recipient])
        #expect(Age.isAgeFile(file))
        #expect(try Age.decrypt(file, with: identity) == plaintext)
        let chunks = max(1, (size + Age.chunkSize - 1) / Age.chunkSize)
        #expect(file.count == (try Age.parseHeader([UInt8](file)).payloadStart) + 16 + size + 16 * chunks)
    }

    @Test func headerFormat() throws {
        let file = try Age.encrypt(Data("x".utf8), to: [AgeIdentity().recipient, AgeIdentity().recipient])
        let header = try Age.parseHeader([UInt8](file))
        let lines = String(decoding: file.prefix(header.payloadStart), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 7)
        #expect(lines[0] == "age-encryption.org/v1")
        for stanza in [lines[1], lines[3]] {
            #expect(stanza.hasPrefix("-> X25519 ") && stanza.count == 10 + 43)
        }
        #expect(lines[2].count == 43 && lines[4].count == 43)
        #expect(lines[5].hasPrefix("--- ") && lines[5].count == 4 + 43 && lines[6].isEmpty)
        #expect(header.stanzas.map(\.body.count) == [32, 32])
    }

    @Test func markdownNoteRoundTrip() throws {
        let note = """
            ---
            title: Diario — día 1
            tags: [privado, 日記]
            ---
            # Querido diario ✍️

            - [ ] Comprar café ☕️
            > Nota con emoji 👩🏽‍💻 y acentos: ñ, ü, é.

            """
        let identity = AgeIdentity()
        let file = try Age.encrypt(Data(note.utf8), to: [identity.recipient])
        #expect(!String(decoding: file, as: UTF8.self).contains("diario"))
        #expect(String(decoding: try Age.decrypt(file, with: identity), as: UTF8.self) == note)
    }

    @Test func multipleRecipients() throws {
        let identities = [AgeIdentity(), AgeIdentity(), AgeIdentity()]
        let plaintext = pattern(70_000)
        let file = try Age.encrypt(plaintext, to: identities.map(\.recipient))
        #expect(try Age.parseHeader([UInt8](file)).stanzas.count == 3)
        for identity in identities {
            #expect(try Age.decrypt(file, with: identity) == plaintext)
        }
        #expect(throws: AgeError.noMatchingIdentity) { try Age.decrypt(file, with: AgeIdentity()) }
    }

    @Test func encryptRequiresARecipient() {
        #expect(throws: AgeError.noRecipients) { try Age.encrypt(Data("x".utf8), to: []) }
    }

    @Test func detectsAgeFiles() throws {
        #expect(Age.isAgeFile(AgeCLIFixtures.data(AgeCLIFixtures.small)))
        #expect(Age.isAgeFile(Data("\n\(AgeCLIFixtures.armored)\n".utf8)))
        #expect(!Age.isAgeFile(Data("# Note\n".utf8)))
        #expect(!Age.isAgeFile(Data("age-encryption.org/v1".utf8)))
        #expect(!Age.isAgeFile(Data()))
    }

    // MARK: Tampering

    @Test func wrongIdentityFails() throws {
        let file = try Age.encrypt(Data("secret".utf8), to: [AgeIdentity().recipient])
        #expect(throws: AgeError.noMatchingIdentity) { try Age.decrypt(file, with: AgeIdentity()) }
    }

    @Test func tamperedHeaderFails() throws {
        let identity = AgeIdentity()
        let file = try Age.encrypt(Data("secret".utf8), to: [identity.recipient])
        let text = String(decoding: file.prefix(try Age.parseHeader([UInt8](file)).payloadStart), as: UTF8.self)
        let payload = file.dropFirst(text.utf8.count)
        let lines = text.split(separator: "\n").map(String.init)

        // A zeroed MAC, then an extra stanza the MAC doesn't cover.
        let zeroMAC = lines.dropLast().joined(separator: "\n") + "\n--- " + Age.base64(Data(count: 32)) + "\n"
        #expect(throws: AgeError.badHeaderMAC) { try Age.decrypt(Data(zeroMAC.utf8) + payload, with: identity) }
        let extraStanza = lines[0] + "\n-> grease x\n\n" + lines.dropFirst().joined(separator: "\n") + "\n"
        #expect(throws: AgeError.badHeaderMAC) { try Age.decrypt(Data(extraStanza.utf8) + payload, with: identity) }

        // Non-canonical base64 in the stanza body: padding, or non-zero trailing bits.
        for body in [lines[2] + "=", lines[2].dropLast() + "B"] {
            let header = [lines[0], lines[1], body, lines[3]].joined(separator: "\n") + "\n"
            #expect(throws: AgeError.malformedHeader) { try Age.decrypt(Data(header.utf8) + payload, with: identity) }
        }

        let malformed = [
            "age-encryption.org/v1\n--- \(Age.base64(Data(count: 32)))\n",  // no stanzas
            "age-encryption.org/v1\n" + lines[1] + "\n",  // ends inside the stanza
            text.replacingOccurrences(of: "-> X25519 ", with: "-> X25519  "),  // empty argument
            text.replacingOccurrences(of: "--- ", with: "---"),
            text.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "v1\r\n", with: "v1\n"),
        ]
        for header in malformed {
            #expect(throws: AgeError.malformedHeader, "\(header)") { try Age.decrypt(Data(header.utf8) + payload, with: identity) }
        }
        #expect(throws: AgeError.unsupportedVersion) {
            try Age.decrypt(Data(text.replacingOccurrences(of: "/v1", with: "/v2").utf8) + payload, with: identity)
        }
    }

    @Test func tamperedPayloadFails() throws {
        let identity = AgeIdentity()
        let file = try Age.encrypt(pattern(70_000), to: [identity.recipient])
        let start = try Age.parseHeader([UInt8](file)).payloadStart
        for offset in [start + 3, start + 16, start + 16 + 100, file.count - 1] {
            var tampered = file
            tampered[offset] ^= 0x01
            #expect(throws: AgeError.payloadAuthenticationFailed, "\(offset - start)") { try Age.decrypt(tampered, with: identity) }
        }
    }

    @Test func truncatedPayloadFails() throws {
        let identity = AgeIdentity()
        let file = try Age.encrypt(pattern(Age.chunkSize + 1), to: [identity.recipient])
        let start = try Age.parseHeader([UInt8](file)).payloadStart
        // Cut after the first (full, non-final) chunk, after the nonce, or inside it.
        for end in [file.count - 17, start + 16, start + 8] {
            #expect(throws: AgeError.truncatedPayload, "\(end)") { try Age.decrypt(file.prefix(end), with: identity) }
        }
        #expect(throws: AgeError.payloadAuthenticationFailed) { try Age.decrypt(file.dropLast(), with: identity) }
        #expect(throws: AgeError.malformedHeader) { try Age.decrypt(file.prefix(start - 1), with: identity) }
    }

    @Test func trailingDataFails() throws {
        let identity = AgeIdentity()
        let full = try Age.encrypt(pattern(Age.chunkSize), to: [identity.recipient])
        #expect(throws: AgeError.trailingData) { try Age.decrypt(full + pattern(20), with: identity) }
        let small = try Age.encrypt(pattern(10), to: [identity.recipient])
        #expect(throws: AgeError.payloadAuthenticationFailed) { try Age.decrypt(small + Data([0]), with: identity) }
    }

    // MARK: Files built from the spec

    @Test func specBuiltFileWithUnknownStanzaDecrypts() throws {
        let identity = AgeIdentity()
        let chunks = [pattern(Age.chunkSize), Data("tail".utf8)]
        // A body of exactly 48 bytes: one full 64-column line, then an empty final line.
        let grease = "-> grease-x arg !#$%\n" + Age.base64(Data(repeating: 7, count: 48)) + "\n\n"
        let file = try specBuiltFile(to: identity, chunks: chunks, stanzasBefore: grease)
        #expect(try Age.parseHeader([UInt8](file)).stanzas.map(\.type) == ["grease-x", "X25519"])
        #expect(try Age.decrypt(file, with: identity) == chunks[0] + chunks[1])
        #expect(try Age.decrypt(try specBuiltFile(to: identity, chunks: [Data()]), with: identity) == Data())
    }

    @Test func specBuiltPayloadRules() throws {
        let identity = AgeIdentity()
        let emptyFinal = try specBuiltFile(to: identity, chunks: [pattern(Age.chunkSize), Data()])
        #expect(throws: AgeError.malformedPayload) { try Age.decrypt(emptyFinal, with: identity) }
        let shortNonFinal = try specBuiltFile(to: identity, chunks: [pattern(10), pattern(10)])
        #expect(throws: AgeError.payloadAuthenticationFailed) { try Age.decrypt(shortNonFinal, with: identity) }
    }

    @Test func invalidStanzasAreRejected() throws {
        let identity = AgeIdentity()
        let scrypt = "-> scrypt \(Age.base64(Data(count: 16))) 10\n\(Age.base64(Data(count: 32)))\n"
        let withScrypt = try specBuiltFile(to: identity, chunks: [Data("x".utf8)], stanzasBefore: scrypt)
        #expect(throws: AgeError.malformedHeader) { try Age.decrypt(withScrypt, with: identity) }

        let zero = Age.base64(Data(count: 32))
        let stanzas = [
            "-> X25519 \(zero)\n\(zero)\n",  // all-zero shared secret
            "-> X25519\n\(zero)\n",
            "-> X25519 \(zero) extra\n\(zero)\n",
            "-> X25519 \(Age.base64(Data(count: 31)))\n\(zero)\n",
            "-> X25519 \(Age.base64(AgeIdentity().recipient.rawRepresentation))\n\(Age.base64(Data(count: 31)))\n",
        ]
        for stanza in stanzas {
            let file = Data("age-encryption.org/v1\n\(stanza)--- \(zero)\n".utf8) + Data(count: 48)
            #expect(throws: AgeError.malformedHeader, "\(stanza)") { try Age.decrypt(file, with: identity) }
        }
    }

    // MARK: age CLI interop

    @Test func decryptsCLIFiles() throws {
        let identity = try AgeIdentity(string: AgeCLIFixtures.identity)
        let small = Data(AgeCLIFixtures.smallPlaintext.utf8)
        #expect(try Age.decrypt(AgeCLIFixtures.data(AgeCLIFixtures.small), with: identity) == small)
        #expect(try Age.decrypt(AgeCLIFixtures.data(AgeCLIFixtures.empty), with: identity) == Data())
        #expect(try Age.decrypt(AgeCLIFixtures.data(AgeCLIFixtures.multiRecipient), with: identity) == small)
        #expect(try Age.decrypt(AgeCLIFixtures.data(AgeCLIFixtures.multiChunk), with: identity) == AgeCLIFixtures.multiChunkPlaintext)
        #expect(throws: AgeError.noMatchingIdentity) { try Age.decrypt(AgeCLIFixtures.data(AgeCLIFixtures.small), with: AgeIdentity()) }
    }

    @Test func decryptsArmoredCLIFile() throws {
        let identity = try AgeIdentity(string: AgeCLIFixtures.identity)
        let small = Data(AgeCLIFixtures.smallPlaintext.utf8)
        let armored = AgeCLIFixtures.armored
        for text in [armored, " \n\(armored)\n\n", armored.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"] {
            #expect(try Age.decrypt(Data(text.utf8), with: identity) == small)
        }
        var lines = armored.split(separator: "\n").map(String.init)
        let unpadded = armored.replacingOccurrences(of: "=\n", with: "\n")
        lines[1].removeLast()
        let shortLine = lines.joined(separator: "\n")
        let noEnd = armored.replacingOccurrences(of: "-----END AGE ENCRYPTED FILE-----", with: "")
        for text in [unpadded, shortLine, noEnd] {
            #expect(throws: AgeError.malformedArmor) { try Age.decrypt(Data(text.utf8), with: identity) }
        }
    }

    static let ageCLI: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.map { URL(filePath: $0).appending(path: "age") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    @Test(.enabled(if: AgeTests.ageCLI != nil, "needs the age CLI"), arguments: [0, 100, 65_536, 200_000])
    func liveCLIInterop(size: Int) throws {
        let age = try #require(Self.ageCLI)
        let directory = FileManager.default.temporaryDirectory.appending(path: "notemd-age-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = AgeIdentity()
        let keyFile = directory.appending(path: "key.txt")
        try Data("\(identity.string)\n".utf8).write(to: keyFile)
        let plaintext = pattern(size)

        // NoteMD encrypts, the CLI decrypts.
        let encrypted = directory.appending(path: "app.age")
        try Age.encrypt(plaintext, to: [identity.recipient]).write(to: encrypted)
        let decrypted = directory.appending(path: "app.out")
        try run(age, ["-d", "-i", keyFile.path, "-o", decrypted.path, encrypted.path])
        #expect(try Data(contentsOf: decrypted) == plaintext)

        // The CLI encrypts, NoteMD decrypts.
        let input = directory.appending(path: "cli.in")
        try plaintext.write(to: input)
        let cliEncrypted = directory.appending(path: "cli.age")
        try run(age, ["-r", identity.recipient.string, "-o", cliEncrypted.path, input.path])
        #expect(try Age.decrypt(Data(contentsOf: cliEncrypted), with: identity) == plaintext)
    }

    // MARK: Helpers

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "age \(arguments.joined(separator: " "))")
    }

    /// Builds an age file step by step from the spec, independently of `Age.encrypt`. Each chunk is encrypted as given,
    /// the last one marked final.
    private func specBuiltFile(to identity: AgeIdentity, chunks: [Data], stanzasBefore: String = "") throws -> Data {
        let fileKey = SymmetricKey(size: .bits128)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        let wrapKey = try ephemeral.sharedSecretFromKeyAgreement(with: identity.privateKey.publicKey).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: share + identity.recipient.rawRepresentation, sharedInfo: Data("age-encryption.org/v1/X25519".utf8),
            outputByteCount: 32)
        let wrapped = try ChaChaPoly.seal(fileKey.withUnsafeBytes { Data($0) }, using: wrapKey, nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        let header = "age-encryption.org/v1\n\(stanzasBefore)-> X25519 \(Age.base64(share))\n\(Age.base64(wrapped.ciphertext + wrapped.tag))\n---"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(header.utf8), using: HKDF<SHA256>.deriveKey(inputKeyMaterial: fileKey, info: Data("header".utf8), outputByteCount: 32))
        let nonce = Data((0..<16).map { UInt8($0) })
        var file = Data("\(header) \(Age.base64(Data(mac)))\n".utf8) + nonce
        let payloadKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: fileKey, salt: nonce, info: Data("payload".utf8), outputByteCount: 32)
        for (index, chunk) in chunks.enumerated() {
            var chunkNonce = Data(count: 12)
            chunkNonce[10] = UInt8(index)
            chunkNonce[11] = index == chunks.count - 1 ? 1 : 0
            let box = try ChaChaPoly.seal(chunk, using: payloadKey, nonce: ChaChaPoly.Nonce(data: chunkNonce))
            file += box.ciphertext + box.tag
        }
        return file
    }

    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
