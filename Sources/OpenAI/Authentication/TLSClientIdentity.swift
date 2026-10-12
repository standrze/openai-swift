import Foundation

#if canImport(Security)
    import Security

    /// An immutable certificate/private-key identity loaded by the platform TLS stack.
    /// Custom roots apply only to transports using this identity and never change the system trust store.
    public final class TLSClientIdentity: @unchecked Sendable {
        private let trustQueue = DispatchQueue(label: "OpenAI.TLS.trust", qos: .utility)
        let identity: SecIdentity
        let certificates: [SecCertificate]
        let roots: [SecCertificate]
        public let certificateDER: Data

        public convenience init(pkcs12: Data, password: String, trustRootsDER: [Data] = []) throws {
            var imported: CFArray?
            var options: [String: Any] = [kSecImportExportPassphrase as String: password]
            #if os(macOS)
                guard #available(macOS 15, *) else {
                    throw OpenAIClientError.invalidConfiguration("In-memory PKCS#12 import requires macOS 15")
                }
                options[kSecImportToMemoryOnly as String] = true
            #endif
            let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &imported)
            guard status == errSecSuccess, let entries = imported as? [[String: Any]], entries.count == 1,
                let value = entries.first?[kSecImportItemIdentity as String]
            else {
                throw OpenAIClientError.invalidConfiguration("PKCS#12 must contain exactly one usable TLS identity")
            }
            let parsedIdentity = value as! SecIdentity
            let chain =
                (entries[0][kSecImportItemCertChain as String] as? [SecCertificate])?.map {
                    SecCertificateCopyData($0) as Data
                } ?? []
            try self.init(identity: parsedIdentity, certificateChainDER: chain, trustRootsDER: trustRootsDER)
        }

        /// Uses an application-owned native identity, including identities backed by a keychain or hardware key.
        /// The application owns any key-access authorization policy. Certificate selection remains static.
        public init(identity: SecIdentity, certificateChainDER: [Data] = [], trustRootsDER: [Data] = []) throws {
            self.identity = identity
            var certificate: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, key != nil
            else {
                throw OpenAIClientError.invalidConfiguration("TLS identity requires a certificate and private key")
            }
            certificateDER = SecCertificateCopyData(certificate) as Data
            guard certificateChainDER.isEmpty || certificateChainDER.first == certificateDER else {
                throw OpenAIClientError.invalidConfiguration("TLS certificate chain must begin with the identity leaf")
            }
            certificates =
                certificateChainDER.isEmpty
                ? [certificate]
                : try certificateChainDER.map { data in
                    guard let value = SecCertificateCreateWithData(nil, data as CFData) else {
                        throw OpenAIClientError.invalidConfiguration("Invalid TLS certificate chain")
                    }
                    return value
                }
            roots = try trustRootsDER.map { data in
                guard let root = SecCertificateCreateWithData(nil, data as CFData) else {
                    throw OpenAIClientError.invalidConfiguration("Invalid TLS trust root")
                }
                return root
            }
        }

        func handle(
            _ challenge: URLAuthenticationChallenge,
            completion: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodClientCertificate:
                completion(
                    .useCredential,
                    URLCredential(identity: identity, certificates: certificates, persistence: .forSession))
            case NSURLAuthenticationMethodServerTrust where !roots.isEmpty:
                guard let trust = challenge.protectionSpace.serverTrust,
                    SecTrustSetAnchorCertificates(trust, roots as CFArray) == errSecSuccess,
                    SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
                else {
                    completion(.cancelAuthenticationChallenge, nil)
                    return
                }
                let evaluation = TLSTrustEvaluation(trust: trust, completion: completion)
                let queue = trustQueue
                queue.async { evaluation.start(on: queue) }
            default: completion(.performDefaultHandling, nil)
            }
        }
    }
    // Security requires evaluation to start and finish on the supplied dispatch queue.
    // This box transfers the challenge-owned trust reference to that single queue.
    private final class TLSTrustEvaluation: @unchecked Sendable {
        let trust: SecTrust
        let completion: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

        init(
            trust: SecTrust,
            completion: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            self.trust = trust
            self.completion = completion
        }

        func start(on queue: DispatchQueue) {
            let status = SecTrustEvaluateAsyncWithError(trust, queue) { [completion] evaluatedTrust, trusted, _ in
                if trusted {
                    completion(.useCredential, URLCredential(trust: evaluatedTrust))
                } else {
                    completion(.cancelAuthenticationChallenge, nil)
                }
            }
            if status != errSecSuccess { completion(.cancelAuthenticationChallenge, nil) }
        }
    }
#else
    /// Client certificate identity support requires an Apple Security framework TLS transport.
    public final class TLSClientIdentity: Sendable {
        public init(pkcs12: Data, password: String, trustRootsDER: [Data] = []) throws {
            throw OpenAIClientError.invalidConfiguration(
                "Native client certificate identities require the Security framework")
        }
    }
#endif
