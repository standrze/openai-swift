import Foundation
import XCTest

@testable import OpenAI

#if os(macOS)
    final class TLSIdentityTests: XCTestCase, @unchecked Sendable {
        func testNativeTLSActuallyPresentsTheImportedCertificate() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openai-tls-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let openssl = "/opt/homebrew/bin/openssl"
            guard FileManager.default.isExecutableFile(atPath: openssl) else {
                throw XCTSkip("OpenSSL 3 fixture tool is unavailable")
            }
            try await run(
                openssl,
                [
                    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext",
                    "subjectAltName=IP:127.0.0.1,DNS:localhost", "-addext", "extendedKeyUsage=serverAuth",
                    "-keyout", "server.key", "-out", "server.crt",
                ], at: directory)
            try await run(
                openssl,
                [
                    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=openai-fixture-client",
                    "-addext", "extendedKeyUsage=clientAuth", "-keyout", "client.key", "-out", "client.crt",
                ], at: directory)
            try await run(
                openssl,
                [
                    "pkcs12", "-export", "-legacy", "-inkey", "client.key", "-in", "client.crt", "-passout",
                    "pass:fixture", "-out", "identity.p12",
                ], at: directory)
            try await run(
                openssl, ["x509", "-in", "server.crt", "-outform", "DER", "-out", "server.der"], at: directory)
            let identity = try TLSClientIdentity(
                pkcs12: Data(contentsOf: directory.appendingPathComponent("identity.p12")),
                password: "fixture", trustRootsDER: [Data(contentsOf: directory.appendingPathComponent("server.der"))])
            XCTAssertThrowsError(
                try X509WorkloadIdentity(
                    identity: identity, identityProviderID: "idp", serviceAccountID: "account", refreshBuffer: -1))
            XCTAssertThrowsError(
                try X509WorkloadIdentity(
                    identity: identity, identityProviderID: "idp", serviceAccountID: "account", tokenExchangeTimeout: 0)
            )
            let fixture = Bundle.module.url(forResource: "tls-server", withExtension: "rb", subdirectory: "Fixtures")!
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
            server.arguments = [fixture.path, directory.path]
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            defer { if server.isRunning { server.terminate() } }
            let portFile = directory.appendingPathComponent("port")
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: portFile.path) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let port = try String(contentsOf: portFile, encoding: .utf8)
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/identity")!)
            request.timeoutInterval = 5
            // Rejecting an untrusted server before headers must release the response stream without deadlocking.
            let untrustedIdentity = try TLSClientIdentity(
                pkcs12: Data(contentsOf: directory.appendingPathComponent("identity.p12")), password: "fixture")
            do {
                _ = try await URLSessionTransport(resourceTimeout: 5, clientIdentity: untrustedIdentity).send(request)
                XCTFail("Untrusted server was accepted")
            } catch {}
            let response = try await URLSessionTransport(
                redirectPolicy: .rejectAll, resourceTimeout: 5, clientIdentity: identity
            ).send(
                request)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(String(decoding: response.data, as: UTF8.self).contains("openai-fixture-client"))
            let capability = try X509WorkloadIdentity(
                identity: identity, identityProviderID: "idp", serviceAccountID: "sa")
            _ = try capability.client()
            capability.close()
            XCTAssertThrowsError(try capability.client())
            do {
                _ = try await capability.send(request)
                XCTFail("Closed capability admitted a new request")
            } catch {}
        }

        func testInvalidIdentityFailsBeforeNetwork() {
            XCTAssertThrowsError(try TLSClientIdentity(pkcs12: Data("invalid".utf8), password: ""))
        }

        private func run(_ path: String, _ arguments: [String], at directory: URL) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            for _ in 0..<500 {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !process.isRunning else {
                process.terminate()
                throw CocoaError(.executableRuntimeMismatch)
            }
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        }
    }
#endif
