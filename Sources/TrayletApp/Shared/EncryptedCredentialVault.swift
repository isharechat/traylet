import Foundation
import CryptoKit
import Darwin
import IOKit

/// Local AES-256-GCM credential vault stored under the v2 application directory with 0600 permissions
/// and HKDF key derivation bound to the current machine UUID and UID.
struct LocalEncryptedCredentialVault: Sendable {
    private static let magicHeader = Data([0x54, 0x52, 0x43, 0x56, 0x01]) // "TRCV" + v1
    private static let aad = Data("local.traylet.v2.credentials.v1".utf8)
    private static let keyDerivationInfo = Data("local.traylet.v2.credentials.aes-gcm-256".utf8)
    private static let keyMaterialLength = 32

    private struct Payload: Codable {
        let version: Int
        var entries: [String: String]
    }

    private let vaultStore: TranslationConfigurationStore
    private let keyStore: TranslationConfigurationStore
    private let machineIDProvider: @Sendable () -> String
    private let userIDProvider: @Sendable () -> UInt32

    init(
        directory: URL,
        machineIDProvider: @escaping @Sendable () -> String = LocalEncryptedCredentialVault.currentMachineUUID,
        userIDProvider: @escaping @Sendable () -> UInt32 = { getuid() }
    ) {
        self.vaultStore = TranslationConfigurationStore(
            url: directory.appendingPathComponent("credentials.enc"),
            maxBytes: 256 * 1024,
            temporaryPrefix: ".credentials-"
        )
        self.keyStore = TranslationConfigurationStore(
            url: directory.appendingPathComponent(".credentials.key"),
            maxBytes: 64,
            temporaryPrefix: ".credentials-key-"
        )
        self.machineIDProvider = machineIDProvider
        self.userIDProvider = userIDProvider
    }

    static func currentMachineUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return "" }
        return value
    }

    func read(service: String, account: String) -> String? {
        guard let sealedData = try? vaultStore.read(),
              let rawKey = try? keyStore.read(),
              rawKey.count == Self.keyMaterialLength else { return nil }
        return decrypt(sealedData, using: rawKey)?.entries[entryKey(service: service, account: account)]
    }

    func write(_ value: String, service: String, account: String) {
        guard !value.isEmpty else {
            remove(service: service, account: account)
            return
        }
        do {
            let existingVault = try vaultStore.read()
            let rawKey: Data
            if let existingKey = try keyStore.read(), existingKey.count == Self.keyMaterialLength {
                rawKey = existingKey
            } else {
                let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try keyStore.write(generated)
                rawKey = generated
            }
            var entries = existingVault.flatMap { decrypt($0, using: rawKey)?.entries } ?? [:]
            entries[entryKey(service: service, account: account)] = value
            guard let blob = try seal(Payload(version: 1, entries: entries), using: rawKey) else { return }
            try vaultStore.write(blob)
        } catch {
            return
        }
    }

    func remove(service: String, account: String) {
        do {
            guard let sealedData = try vaultStore.read(),
                  let rawKey = try keyStore.read(),
                  rawKey.count == Self.keyMaterialLength,
                  var payload = decrypt(sealedData, using: rawKey)
            else { return }
            let key = entryKey(service: service, account: account)
            guard payload.entries.removeValue(forKey: key) != nil else { return }
            if payload.entries.isEmpty {
                try vaultStore.remove()
            } else if let blob = try seal(payload, using: rawKey) {
                try vaultStore.write(blob)
            }
        } catch {
            return
        }
    }

    private func entryKey(service: String, account: String) -> String {
        "\(service)\0\(account)"
    }

    private func deriveKey(from rawKey: Data) -> SymmetricKey {
        let salt = Data("local.traylet.v2.credentials.salt.v1:\(machineIDProvider()):\(userIDProvider())".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawKey),
            salt: salt,
            info: Self.keyDerivationInfo,
            outputByteCount: 32
        )
    }

    private func seal(_ payload: Payload, using rawKey: Data) throws -> Data? {
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: deriveKey(from: rawKey), nonce: AES.GCM.Nonce(), authenticating: Self.aad)
        guard let combined = sealed.combined else { return nil }
        var blob = Self.magicHeader
        blob.append(combined)
        return blob
    }

    private func decrypt(_ data: Data, using rawKey: Data) -> Payload? {
        guard rawKey.count == Self.keyMaterialLength,
              data.count > Self.magicHeader.count,
              data.prefix(Self.magicHeader.count) == Self.magicHeader else { return nil }
        let combined = data.dropFirst(Self.magicHeader.count)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: deriveKey(from: rawKey), authenticating: Self.aad)
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            guard payload.version == 1 else { return nil }
            return payload
        } catch {
            return nil
        }
    }
}
