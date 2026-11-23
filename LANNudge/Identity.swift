import CryptoKit
import Foundation
import Network
import Security
import X509

enum Fingerprint {
    /// SHA-256 of the certificate DER, 64 uppercase hex digits.
    static func of(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }.joined()
    }

    /// Prefix advertised over Bonjour. The sender checks the receiver's real certificate against it,
    /// so a spoofed record can't redirect a nudge (forging a 64-bit prefix is infeasible).
    static func hint(_ fingerprint: String) -> String { String(fingerprint.prefix(16)) }
}

struct LocalIdentity {
    let identity: SecIdentity
    let fingerprint: String

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Only "not found" creates a new identity. Any other failure (user denied Keychain access,
    /// locked keychain…) is reported instead: silently regenerating would change the fingerprint
    /// and break every existing pairing.
    static func loadOrCreate(label: String) throws -> LocalIdentity {
        var found: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &found)
        switch status {
        case errSecSuccess:
            return try identity(for: found as! SecCertificate)
        case errSecItemNotFound:
            return try create(label: label)
        default:
            throw failure("讀取鑰匙圈中的裝置身分失敗", status)
        }
    }

    private static func create(label: String) throws -> LocalIdentity {
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrLabel: label] as CFDictionary) // orphan from a half-finished create

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrLabel: label],
        ] as CFDictionary, &error) else {
            throw Failure(errorDescription: "建立私鑰失敗：\(error!.takeRetainedValue())")
        }

        let signer = try Certificate.PrivateKey(key)
        // The file-based keychain ignores kSecAttrLabel on certificate add and labels it with the
        // subject CN, so the CN must equal the lookup label or the identity is never found again.
        let name = try DistinguishedName { CommonName(label) }
        let now = Date()
        // Validity is irrelevant to trust (peers pin the fingerprint), so make it outlive the app.
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: signer.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(30 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            },
            issuerPrivateKey: signer
        )
        let der = Data(try certificate.serializeAsPEM().derBytes)
        guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw Failure(errorDescription: "產生的憑證無法解析")
        }
        let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCertificate] as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure("儲存憑證到鑰匙圈失敗", status) }
        return try identity(for: secCertificate)
    }

    private static func identity(for certificate: SecCertificate) throws -> LocalIdentity {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw failure("找不到與憑證配對的私鑰（可能被拒絕存取）", status)
        }
        return LocalIdentity(identity: identity, fingerprint: Fingerprint.of(certificate))
    }

    private static func failure(_ message: String, _ status: OSStatus) -> Failure {
        let detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "\(status)"
        return Failure(errorDescription: "\(message)：\(detail)")
    }
}

enum TLSSetup {
    /// Mutual TLS 1.3 with this Mac's identity. `accept` gets the peer's leaf-certificate
    /// fingerprint and is the only trust decision: self-signed certs never pass default evaluation.
    @MainActor
    static func parameters(identity: SecIdentity, accept: @escaping @MainActor (String) -> Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, sec_identity_create(identity)!)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let fingerprint = chain?.first.map(Fingerprint.of)
            complete(MainActor.assumeIsolated { fingerprint.map(accept) ?? false })
        }, .main)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func peerFingerprint(_ connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        var chain: [SecCertificate] = []
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) {
            chain.append(sec_certificate_copy_ref($0).takeRetainedValue())
        }
        return chain.first.map(Fingerprint.of)
    }
}
