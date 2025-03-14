
import CryptoSwift
import Foundation
import Security
import TronCore

/// Key definition.
public struct KeystoreKey {
    /// Ethereum address.
    public var address: TronCore.Address

    /// Account type.
    public var type: AccountType

    /// Wallet UUID, optional.
    public var id: String?

    /// Key header with encrypted private key and crypto parameters.
    public var crypto: KeystoreKeyHeader

    /// Mnemonic passphrase
    public var passphrase = ""
    public var mnemonic: String?

    /// Mnemonic derivation path
    public var derivationPath = Wallet.defaultPath

    /// Key version, must be 3.
    public var version = 3

    /// Creates a new `Key` with a password.
    public init(password: String, type: AccountType) throws {
        switch type {
        case .encryptedKey:
            let privateAttributes: [String: Any] = [
                kSecAttrIsExtractable as String: true,
            ]
            let parameters: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeEC,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: privateAttributes,
            ]

            var pubKey: SecKey?
            var privKey: SecKey?
            let status = SecKeyGeneratePair(parameters as CFDictionary, &pubKey, &privKey)
            guard let privateKey = privKey, status == noErr else {
                throw EncryptError.generateKeyPairFail
            }

            guard let keyRepresentation = SecKeyCopyExternalRepresentation(privateKey, nil) as Data? else {
                throw EncryptError.extractPrivateKeyFail
            }
            
            let key = keyRepresentation[(keyRepresentation.count - 32)...]
            try self.init(password: password, key: key)
        case .hierarchicalDeterministicWallet:
            let mnemonic = Mnemonic.generate(strength: 128)
            try self.init(password: password, mnemonic: mnemonic, passphrase: "")
        }
    }

    /// Initializes a `Key` from a JSON wallet.
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        self = try JSONDecoder().decode(KeystoreKey.self, from: data)
    }

    /// Initializes a `Key` by encrypting a private key with a password.
    public init(password: String, key: Data) throws {
        id = UUID().uuidString.lowercased()
        crypto = try KeystoreKeyHeader(password: password, data: key)

        let pubKey = EthereumCrypto.getPublicKey(from: key)
        address = KeystoreKey.decodeAddress(from: pubKey)
        type = .encryptedKey
    }

    /// Initializes a `Key` by encrypting a mnemonic phrase with a password.
    public init(password: String, mnemonic: String, passphrase: String = "", derivationPath: String = Wallet.defaultPath) throws {
        id = UUID().uuidString.lowercased()

        guard let cstring = mnemonic.cString(using: .ascii) else {
            throw EncryptError.invalidMnemonic
        }
        let data = Data(bytes: cstring.map({ UInt8($0) }))
        crypto = try KeystoreKeyHeader(password: password, data: data)

        let key = Wallet(mnemonic: mnemonic, passphrase: passphrase, path: derivationPath).getKey(at: 0)
        let pubKey = key.publicKey
        address = KeystoreKey.decodeAddress(from: pubKey)
        type = .hierarchicalDeterministicWallet
        self.passphrase = passphrase
        self.mnemonic = mnemonic
        self.derivationPath = derivationPath
    }

    /// Decodes an Ethereum address from a public key.
    static func decodeAddress(from publicKey: Data) -> TronCore.Address {
        precondition(publicKey.count == 65, "Expect 64-byte public key")
        precondition(publicKey[0] == 4, "Invalid public key")
        let sha3 = publicKey[1...].sha3(.keccak256)
        var data = Data(hex: "41")
        data.append(sha3[12..<32])
        return TronCore.Address(data: data)
    }

    /// Decrypts the key and returns the private key.
    public func decrypt(password: String) throws -> Data {
        let derivedKey: Data
        switch crypto.kdf {
        case "scrypt":
            let scrypt = Scrypt(params: crypto.kdfParams)
            derivedKey = try scrypt.calculate(password: password)
        default:
            throw DecryptError.unsupportedKDF
        }

        let mac = KeystoreKey.computeMAC(prefix: derivedKey[derivedKey.count - 16 ..< derivedKey.count], key: crypto.cipherText)
        if mac != crypto.mac {
            throw DecryptError.invalidPassword
        }

        let decryptionKey = derivedKey[0...15]
        let decryptedPK: [UInt8]
        switch crypto.cipher {
        case "aes-128-ctr":
            let aesCipher = try AES(key: decryptionKey.bytes, blockMode: CTR(iv: crypto.cipherParams.iv.bytes), padding: .noPadding)
            decryptedPK = try aesCipher.decrypt(crypto.cipherText.bytes)
        case "aes-128-cbc":
            let aesCipher = try AES(key: decryptionKey.bytes, blockMode: CBC(iv: crypto.cipherParams.iv.bytes), padding: .noPadding)
            decryptedPK = try aesCipher.decrypt(crypto.cipherText.bytes)
        default:
            throw DecryptError.unsupportedCipher
        }

        return Data(bytes: decryptedPK)
    }

    static func computeMAC(prefix: Data, key: Data) -> Data {
        var data = Data(capacity: prefix.count + key.count)
        data.append(prefix)
        data.append(key)
        return data.sha3(.keccak256)
    }

    /// Signs a hash with the given password.
    ///
    /// - Parameters:
    ///   - hash: hash to sign
    ///   - password: key password
    /// - Returns: signature
    /// - Throws: `DecryptError` or `Secp256k1Error`
    public func sign(hash: Data, password: String) throws -> Data {
        switch type {
        case .encryptedKey:
            var key = try decrypt(password: password)
            defer {
                // Clear memory after signing
                key.resetBytes(in: 0..<key.count)
            }
            return EthereumCrypto.sign(hash: hash, privateKey: key)
        case .hierarchicalDeterministicWallet:
            guard var mnemonic = String(data: try decrypt(password: password), encoding: .ascii) else {
                throw DecryptError.invalidPassword
            }
            defer {
                // Clear memory after signing
                mnemonic.replaceSubrange(mnemonic.startIndex ..< mnemonic.endIndex, with: repeatElement(Character(" "), count: mnemonic.count))
            }
            let wallet = Wallet(mnemonic: mnemonic, passphrase: passphrase, path: derivationPath)
            return EthereumCrypto.sign(hash: hash, privateKey: wallet.getKey(at: 0).privateKey)
        }
    }

    /// Signs multiple hashes with the given password.
    ///
    /// - Parameters:
    ///   - hashes: array of hashes to sign
    ///   - password: key password
    /// - Returns: [signature]
    /// - Throws: `DecryptError` or `Secp256k1Error`
    public func signHashes(_ hashes: [Data], password: String) throws -> [Data] {
        switch type {
        case .encryptedKey:
            var key = try decrypt(password: password)
            defer {
                // Clear memory after signing
                key.resetBytes(in: 0..<key.count)
            }
            return hashes.map({ EthereumCrypto.sign(hash: $0, privateKey: key) })
        case .hierarchicalDeterministicWallet:
            guard var mnemonic = String(data: try decrypt(password: password), encoding: .ascii) else {
                throw DecryptError.invalidPassword
            }
            defer {
                // Clear memory after signing
                mnemonic.replaceSubrange(mnemonic.startIndex ..< mnemonic.endIndex, with: repeatElement(Character(" "), count: mnemonic.count))
            }
            let wallet = Wallet(mnemonic: mnemonic)
            let key = wallet.getKey(at: 0).privateKey
            return hashes.map({ EthereumCrypto.sign(hash: $0, privateKey: key) })
        }
    }
}

public enum DecryptError: Error {
    case unsupportedKDF
    case unsupportedCipher
    case invalidCipher
    case invalidPassword
    case missingAccountKey
}

public enum EncryptError: Error {
    case invalidMnemonic
    case generateKeyPairFail
    case extractPrivateKeyFail
}

extension KeystoreKey: Codable {
    enum CodingKeys: String, CodingKey {
        case address
        case type
        case id
        case crypto
        case derivationPath
        case version
    }

    enum UppercaseCodingKeys: String, CodingKey {
        case crypto = "Crypto"
    }

    struct TypeString {
        static let privateKey = "private-key"
        static let mnemonic = "mnemonic"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let altValues = try decoder.container(keyedBy: UppercaseCodingKeys.self)

        address = TronCore.Address(data: try values.decodeHexString(forKey: .address))
        switch try values.decodeIfPresent(String.self, forKey: .type) {
        case TypeString.mnemonic?:
            type = .hierarchicalDeterministicWallet
            derivationPath = try values.decodeIfPresent(String.self, forKey: .derivationPath) ?? Wallet.defaultPath
        default:
            type = .encryptedKey
        }

        id = try values.decode(String.self, forKey: .id)
        if let crypto = try? values.decode(KeystoreKeyHeader.self, forKey: .crypto) {
            self.crypto = crypto
        } else {
            // Workaround for myEtherWallet files
            self.crypto = try altValues.decode(KeystoreKeyHeader.self, forKey: .crypto)
        }
        version = try values.decode(Int.self, forKey: .version)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address.description.drop0x(), forKey: .address)
        switch type {
        case .encryptedKey:
            try container.encode(TypeString.privateKey, forKey: .type)
        case .hierarchicalDeterministicWallet:
            try container.encode(TypeString.mnemonic, forKey: .type)
            try container.encode(derivationPath, forKey: .derivationPath)
        }
        try container.encode(id, forKey: .id)
        try container.encode(crypto, forKey: .crypto)
        try container.encode(version, forKey: .version)
    }
}

private extension String {
    func drop0x() -> String {
        if hasPrefix("0x") {
            return String(dropFirst(2))
        }
        return self
    }
}
