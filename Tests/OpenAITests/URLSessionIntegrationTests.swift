import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if os(macOS) || os(Linux)
    final class URLSessionIntegrationTests: XCTestCase {
        func testDefaultUnlimitedTimeoutUsesNativeTransport() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            var configuration = server.client().configuration
            configuration.timeout = 0
            let response: JSONEcho = try await OpenAIClient(configuration: configuration).send(
                .post, path: "echo", body: TestDocument(value: "default timeout"))
            XCTAssertEqual(response.value, "default timeout")
        }

        func testJSONRoundTripThroughRealHTTPServer() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            let client = server.client()

            let response: JSONEcho = try await client.send(
                .post,
                path: "echo",
                body: TestDocument(value: "café 🌙")
            )

            XCTAssertEqual(response.value, "café 🌙")
            XCTAssertEqual(response.authorization, "Bearer loopback-key")
            XCTAssertEqual(response.contentType, "application/json")
        }

        func testRawResponsePreservesBytesAndHeaders() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            let transport = URLSessionTransport()
            let response = try await transport.send(server.request("json"))

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.header("X-Request-ID"), "req-loopback")
            let document = try JSONDecoder().decode(TestDocument.self, from: response.data)
            XCTAssertEqual(document.value, "ready")
        }

        func testTransportFollowsOnlySameOriginRedirects() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            let transport = URLSessionTransport()
            let sameOrigin = try await transport.send(server.request("redirect-same"))
            XCTAssertEqual(sameOrigin.statusCode, 200)
            let crossOrigin = try await transport.send(server.request("redirect-cross"))
            XCTAssertEqual(crossOrigin.statusCode, 307)
            XCTAssertTrue(crossOrigin.header("location")?.contains("localhost:") == true)
        }

        func testTokenTransportCanRejectEveryRedirect() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            let transport = URLSessionTransport(redirectPolicy: .rejectAll)
            var request = server.request("redirect-same")
            request.setValue("Basic local-credential", forHTTPHeaderField: "Authorization")

            let response = try await transport.send(request)
            XCTAssertEqual(response.statusCode, 307)
            let stream = try await transport.stream(request)
            defer { stream.cancel() }
            XCTAssertEqual(stream.statusCode, 307)
        }

        func testMultipartUploadPreservesFieldsAndBinaryFileBytes() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            let bytes = Data([0, 1, 255, 13, 10, 128, 34])

            let response: MultipartEcho = try await server.client().upload(
                path: "upload",
                fields: ["purpose": "fine-tune", "description": "training fixture"],
                files: [MultipartFile(fieldName: "file", filename: "training.jsonl", data: bytes)]
            )

            XCTAssertEqual(response.fields, ["purpose": "fine-tune", "description": "training fixture"])
            XCTAssertEqual(response.filename, "training.jsonl")
            XCTAssertEqual(response.fileBytes, Array(bytes))
        }

        func testChunkedSSEDeliversEventBeforeServerFinishesResponse() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            let stream: OpenAIStream<TestDocument> = try await server.client().stream(
                path: "events",
                body: TestDocument(value: "request")
            )
            defer { stream.cancel() }
            var iterator = stream.makeAsyncIterator()

            let first = try await iterator.next()
            XCTAssertEqual(first?.value, "one")
            let stateBeforeRelease: ServerState = try await server.client().send(.get, path: "state")
            XCTAssertFalse(stateBeforeRelease.streamFinished, "The first event must arrive while the HTTP body is open")

            let _: JSONValue = try await server.client().send(.post, path: "release", body: [String: String]())
            let second = try await iterator.next()
            let end = try await iterator.next()

            XCTAssertEqual(second?.value, "two")
            XCTAssertNil(end)
        }

        func testCancellingStreamClosesActualHTTPConnection() async throws {
            let server = try await LoopbackHTTPServer.start()
            defer { server.stop() }
            let transport = URLSessionTransport()
            let response = try await transport.stream(server.request("cancel"))
            var iterator = response.body.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertFalse(try XCTUnwrap(first).isEmpty)

            response.cancel()

            do {
                let _ = try await iterator.next()
                XCTFail("A cancelled transport stream must end with cancellation")
            } catch is CancellationError {
                // The transport reports cancellation consistently across URLSession platforms.
            }

            var observedClosedConnection = false
            for _ in 0..<100 {
                let state: ServerState = try await server.client().send(.get, path: "state")
                if state.cancelled {
                    observedClosedConnection = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(observedClosedConnection, "The server must observe a closed socket after cancellation")
        }
    }

    private struct JSONEcho: Decodable, Sendable {
        let value: String
        let authorization: String?
        let contentType: String?

        enum CodingKeys: String, CodingKey {
            case value, authorization
            case contentType = "content_type"
        }
    }

    private struct MultipartEcho: Decodable, Sendable {
        let fields: [String: String]
        let filename: String?
        let fileBytes: [UInt8]

        enum CodingKeys: String, CodingKey {
            case fields, filename
            case fileBytes = "file_bytes"
        }
    }

    private struct ServerState: Decodable, Sendable {
        let streamFinished: Bool
        let cancelled: Bool

        enum CodingKeys: String, CodingKey {
            case streamFinished = "stream_finished"
            case cancelled
        }
    }

    private enum LoopbackServerError: Error {
        case startup(String)
    }

    /// A Python standard-library HTTP server. Every test owns its process and ephemeral port.
    private final class LoopbackHTTPServer: @unchecked Sendable {
        let baseURL: URL
        private let process: Process
        private let directory: URL

        private init(baseURL: URL, process: Process, directory: URL) {
            self.baseURL = baseURL
            self.process = process
            self.directory = directory
        }

        static func start() async throws -> LoopbackHTTPServer {
            let pythonCandidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            guard let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else {
                throw XCTSkip("Python 3 is required for loopback HTTP integration tests")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openai-http-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-u", "-c", pythonServer, directory.path]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
                try? errors.fileHandleForWriting.close()
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }

            let portFile = directory.appendingPathComponent("port")
            for _ in 0..<150 {
                if let portText = try? String(contentsOf: portFile, encoding: .utf8),
                    let port = Int(portText), (1...65_535).contains(port),
                    let url = URL(string: "http://127.0.0.1:\(port)/v1")
                {
                    return LoopbackHTTPServer(baseURL: url, process: process, directory: directory)
                }
                if !process.isRunning {
                    let diagnostics =
                        String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    try? FileManager.default.removeItem(at: directory)
                    throw LoopbackServerError.startup(diagnostics)
                }
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    process.terminate()
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }
            process.terminate()
            try? FileManager.default.removeItem(at: directory)
            throw LoopbackServerError.startup("HTTP fixture did not publish its port within three seconds")
        }

        func client() -> OpenAIClient {
            OpenAIClient(
                configuration: ClientConfiguration(
                    apiKey: "loopback-key",
                    baseURL: baseURL,
                    timeout: 5,
                    maxRetries: 0
                ))
        }

        func request(_ path: String) -> URLRequest {
            URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 5)
        }

        func stop() {
            if process.isRunning {
                process.terminate()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        private static let pythonServer = #"""
            import http.server
            import json
            import pathlib
            import socket
            import sys
            import threading
            from email import policy
            from email.parser import BytesParser

            root = pathlib.Path(sys.argv[1])
            release = threading.Event()
            finished = threading.Event()
            cancelled = threading.Event()

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *_):
                    pass

                def reply(self, value):
                    data = json.dumps(value).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("X-Request-ID", "req-loopback")
                    self.end_headers()
                    self.wfile.write(data)
                    self.wfile.flush()

                def chunk(self, data):
                    self.wfile.write(("%X\r\n" % len(data)).encode("ascii") + data + b"\r\n")
                    self.wfile.flush()

                def do_GET(self):
                    self.route(b"")

                def do_POST(self):
                    data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                    self.route(data)

                def route(self, data):
                    path = self.path.split("?", 1)[0]
                    if path == "/v1/json":
                        self.reply({"value": "ready"})
                    elif path == "/v1/redirect-same" or path == "/v1/redirect-cross":
                        self.send_response(307)
                        location = "/v1/json" if path.endswith("same") else "http://localhost:%s/v1/json" % self.server.server_port
                        self.send_header("Location", location)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                    elif path == "/v1/echo":
                        value = json.loads(data)
                        value["authorization"] = self.headers.get("Authorization")
                        value["content_type"] = self.headers.get("Content-Type")
                        self.reply(value)
                    elif path == "/v1/upload":
                        content_type = self.headers.get("Content-Type", "")
                        message = BytesParser(policy=policy.default).parsebytes(
                            b"Content-Type: " + content_type.encode("ascii") + b"\r\nMIME-Version: 1.0\r\n\r\n" + data)
                        fields = {}
                        filename = None
                        file_bytes = []
                        for part in message.iter_parts():
                            name = part.get_param("name", header="content-disposition")
                            payload = part.get_payload(decode=True)
                            if part.get_filename() is not None:
                                filename = part.get_filename()
                                file_bytes = list(payload)
                            else:
                                fields[name] = payload.decode("utf-8")
                        self.reply({"fields": fields, "filename": filename, "file_bytes": file_bytes})
                    elif path == "/v1/state":
                        self.reply({"stream_finished": finished.is_set(), "cancelled": cancelled.is_set()})
                    elif path == "/v1/release":
                        release.set()
                        self.reply({"released": True})
                    elif path in ("/v1/events", "/v1/cancel"):
                        self.send_response(200)
                        self.send_header("Content-Type", "text/event-stream")
                        self.send_header("Transfer-Encoding", "chunked")
                        self.end_headers()
                        self.chunk(b'data: {"value":"one"}\n\n')
                        if path == "/v1/events":
                            release.wait(3)
                            finished.set()
                            self.chunk(b'data: {"value":"two"}\n\ndata: [DONE]\n\n')
                            self.wfile.write(b"0\r\n\r\n")
                            self.wfile.flush()
                        else:
                            self.connection.settimeout(5)
                            try:
                                if self.connection.recv(1) == b"":
                                    cancelled.set()
                            except (ConnectionResetError, BrokenPipeError):
                                cancelled.set()
                            except socket.timeout:
                                pass
                            self.close_connection = True
                    else:
                        self.send_error(404)

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.daemon_threads = True
            (root / "port").write_text(str(server.server_address[1]), encoding="ascii")
            server.serve_forever(poll_interval=0.05)
            """#
    }
#endif
