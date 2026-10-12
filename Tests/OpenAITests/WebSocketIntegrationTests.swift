import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if os(macOS) || os(Linux)
    final class WebSocketIntegrationTests: XCTestCase {
        func testNativeAbortImmediatelyReleasesIdleSocket() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }
            let connection = try await URLSessionWebSocketTransport().connect(server.request("idle"))
            await connection.abort()
            let closed = try await server.waitUntilClosed()
            XCTAssertTrue(closed)
        }

        func testNativeResponsesHandshakeFragmentationControlFramesAndFinalPayload() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }
            let client = OpenAIClient(
                configuration: ClientConfiguration(apiKey: "ws-loopback", baseURL: server.baseURL))
            let connection = try await client.responses.connect()

            try await connection.createResponse(ResponseRequest(model: "fixture-model", input: "Hello"))
            let response = try await connection.finalResponse()
            await connection.close()

            XCTAssertEqual(response.id, "resp-loopback")
            XCTAssertEqual(response.outputText, "Hello from WebSocket")
            let closed = try await server.waitUntilClosed()
            XCTAssertTrue(closed)
            let record = try server.record()
            XCTAssertEqual(record["authorization"], "Bearer ws-loopback")
            XCTAssertEqual(record["path"], "/v1/responses")
            XCTAssertEqual(record["message"]?["type"], "response.create")
            XCTAssertEqual(record["message"]?["model"], "fixture-model")
            XCTAssertNil(record["message"]?["response"])
            XCTAssertEqual(record["pong"], true)
            XCTAssertEqual(record["close_code"], 1000)
        }

        func testNativeBinaryMessagesRoundTripWithExtendedPayloadLength() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }
            let connection = try await URLSessionWebSocketTransport().connect(server.request("binary"))
            let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })

            try await connection.send(.data(payload))
            let echoed = try await connection.receive()
            await connection.close()

            XCTAssertEqual(echoed, .data(payload))
            let closed = try await server.waitUntilClosed()
            XCTAssertTrue(closed)
        }

        func testRejectedUpgradeReportsHTTPStatusAndDoesNotReplay() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }

            do {
                let connection = try await URLSessionWebSocketTransport().connect(server.request("reject"))
                await connection.close()
                XCTFail("Expected failed upgrade")
            } catch OpenAIWebSocketError.handshakeFailed(let status, _, _) {
                XCTAssertEqual(status, 403)
            }

            XCTAssertEqual(try server.record()["request_count"], 1)
        }

        func testHandshakeTimeoutClosesPendingConnection() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }

            do {
                let connection = try await URLSessionWebSocketTransport().connect(
                    server.request("slow"), options: WebSocketOptions(handshakeTimeout: 0.1)
                )
                await connection.close()
                XCTFail("Expected handshake timeout")
            } catch OpenAIWebSocketError.handshakeTimeout {}

            let closed = try await server.waitUntilClosed()
            XCTAssertTrue(closed)
        }

        func testCancellingNativeReceiveClosesSocket() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }
            let connection = try await URLSessionWebSocketTransport().connect(server.request("idle"))
            let receive = Task { try await connection.receive() }
            try await Task.sleep(for: .milliseconds(30))

            receive.cancel()

            do {
                let _ = try await receive.value
                XCTFail("Expected cancelled receive")
            } catch is CancellationError {}
            let closed = try await server.waitUntilClosed()
            XCTAssertTrue(closed)
        }

        func testNativeMessageLimitRejectsOversizedInboundPayload() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }
            let connection = try await URLSessionWebSocketTransport().connect(
                server.request("oversized"), options: WebSocketOptions(maxMessageBytes: 32)
            )

            do {
                let _ = try await connection.receive()
                XCTFail("Expected native inbound message limit")
            } catch {
                // Foundation reports its platform error when maximumMessageSize rejects a frame.
            }
            await connection.close()
        }

        func testCrossOriginRedirectDoesNotForwardCredentials() async throws {
            let server = try await LoopbackWebSocketServer.start()
            defer { server.stop() }
            var request = server.request("redirect")
            request.setValue("Bearer must-stay-local", forHTTPHeaderField: "Authorization")

            do {
                let connection = try await URLSessionWebSocketTransport().connect(request)
                await connection.close()
                XCTFail("A cross-origin redirect must not establish a connection")
            } catch OpenAIWebSocketError.handshakeFailed {}

            XCTAssertEqual(try server.record()["request_count"], 1)
        }
    }

    private enum WebSocketFixtureError: Error {
        case startup(String)
    }

    /// A minimal RFC 6455 server using only Python's standard library. It verifies client masking,
    /// extended lengths, continuation frames, ping/pong, close frames, and actual socket disposal.
    private final class LoopbackWebSocketServer: @unchecked Sendable {
        let baseURL: URL
        private let process: Process
        private let directory: URL

        private init(baseURL: URL, process: Process, directory: URL) {
            self.baseURL = baseURL
            self.process = process
            self.directory = directory
        }

        static func start() async throws -> LoopbackWebSocketServer {
            let candidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw XCTSkip("Python 3 is required for the loopback WebSocket fixture")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openai-ws-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-u", "-c", script, directory.path]
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
            for _ in 0..<150 {
                if let portText = try? String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8),
                    let port = Int(portText), let url = URL(string: "http://127.0.0.1:\(port)/v1")
                {
                    return LoopbackWebSocketServer(baseURL: url, process: process, directory: directory)
                }
                if !process.isRunning {
                    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    try? FileManager.default.removeItem(at: directory)
                    throw WebSocketFixtureError.startup(message)
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch {
                    process.terminate()
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }
            process.terminate()
            try? FileManager.default.removeItem(at: directory)
            throw WebSocketFixtureError.startup("The WebSocket fixture did not publish its port")
        }

        func request(_ path: String) -> URLRequest {
            var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.scheme = "ws"
            return URLRequest(url: components.url!, timeoutInterval: 5)
        }

        func record() throws -> JSONValue {
            try JSONDecoder().decode(
                JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("record.json")))
        }

        func waitUntilClosed() async throws -> Bool {
            for _ in 0..<100 {
                if (try? record()["closed"]?.boolValue) == true { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        func stop() {
            if process.isRunning {
                process.terminate()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        private static let script = #"""
            import base64
            import hashlib
            import json
            import pathlib
            import socket
            import socketserver
            import struct
            import sys
            import threading

            root = pathlib.Path(sys.argv[1])
            lock = threading.Lock()
            state = {"request_count": 0, "closed": False, "pong": False}

            def update(**values):
                with lock:
                    state.update(values)
                    temporary = root / "record.tmp"
                    temporary.write_text(json.dumps(state), encoding="utf-8")
                    temporary.replace(root / "record.json")

            class Handler(socketserver.BaseRequestHandler):
                def exact(self, length):
                    data = b""
                    while len(data) < length:
                        chunk = self.request.recv(length - len(data))
                        if not chunk:
                            raise EOFError()
                        data += chunk
                    return data

                def frame(self, opcode, payload, final=True):
                    length = len(payload)
                    header = bytes([(0x80 if final else 0) | opcode])
                    if length < 126:
                        header += bytes([length])
                    elif length < 65536:
                        header += b"\x7e" + struct.pack("!H", length)
                    else:
                        header += b"\x7f" + struct.pack("!Q", length)
                    self.request.sendall(header + payload)

                def read_frame(self):
                    first, second = self.exact(2)
                    length = second & 0x7f
                    if length == 126:
                        length = struct.unpack("!H", self.exact(2))[0]
                    elif length == 127:
                        length = struct.unpack("!Q", self.exact(8))[0]
                    if not second & 0x80:
                        raise ValueError("Client WebSocket frames must be masked")
                    if length > 8 * 1024 * 1024:
                        raise ValueError("Fixture payload limit exceeded")
                    mask = self.exact(4)
                    encoded = self.exact(length)
                    payload = bytes(value ^ mask[index % 4] for index, value in enumerate(encoded))
                    return bool(first & 0x80), first & 0x0f, payload

                def message(self):
                    kind = None
                    data = b""
                    while True:
                        final, opcode, payload = self.read_frame()
                        if opcode == 8:
                            code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 1005
                            update(closed=True, close_code=code)
                            self.frame(8, payload)
                            raise EOFError()
                        if opcode == 9:
                            self.frame(10, payload)
                            continue
                        if opcode == 10:
                            update(pong=True)
                            continue
                        if opcode in (1, 2):
                            kind = opcode
                        elif opcode != 0 or kind is None:
                            raise ValueError("Unexpected opcode")
                        data += payload
                        if final:
                            return kind, data

                def handle(self):
                    self.request.settimeout(5)
                    try:
                        header = b""
                        while not header.endswith(b"\r\n\r\n"):
                            header += self.exact(1)
                            if len(header) > 65536:
                                raise ValueError("Oversized HTTP handshake")
                        lines = header.decode("iso-8859-1").split("\r\n")
                        path = lines[0].split(" ")[1]
                        headers = dict(line.split(": ", 1) for line in lines[1:] if ": " in line)
                        headers = {key.lower(): value for key, value in headers.items()}
                        with lock:
                            count = state["request_count"] + 1
                        update(request_count=count, path=path, authorization=headers.get("authorization"))
                        endpoint = path.split("?", 1)[0]
                        if endpoint == "/v1/reject":
                            self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            return
                        if endpoint == "/v1/redirect":
                            location = "ws://localhost:%d/v1/stolen" % self.server.server_address[1]
                            self.request.sendall(("HTTP/1.1 302 Found\r\nLocation: " + location +
                                "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").encode("ascii"))
                            return
                        if endpoint == "/v1/slow":
                            if self.request.recv(1) == b"":
                                update(closed=True)
                            return
                        key = headers["sec-websocket-key"]
                        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest())
                        self.request.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
                            accept + b"\r\n\r\n")
                        if endpoint == "/v1/responses":
                            _, payload = self.message()
                            update(message=json.loads(payload))
                            created = b'{"type":"response.created","response":{"id":"resp-loopback","output":[]}}'
                            midpoint = len(created) // 2
                            self.frame(1, created[:midpoint], final=False)
                            self.frame(9, b"keepalive")
                            self.frame(0, created[midpoint:])
                            self.frame(1, b'{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"draft"}')
                            self.frame(1, b'{"type":"response.completed","response":{"id":"resp-loopback","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello from WebSocket"}]}]}}')
                        elif endpoint == "/v1/binary":
                            opcode, payload = self.message()
                            self.frame(opcode, payload)
                        elif endpoint == "/v1/oversized":
                            self.frame(1, b"x" * 4096)
                        while True:
                            self.message()
                    except (EOFError, ConnectionResetError, BrokenPipeError):
                        update(closed=True)
                    except Exception as error:
                        update(fixture_error=str(error))

            class Server(socketserver.ThreadingTCPServer):
                daemon_threads = True
                allow_reuse_address = True

            server = Server(("127.0.0.1", 0), Handler)
            update()
            (root / "port").write_text(str(server.server_address[1]), encoding="ascii")
            server.serve_forever(poll_interval=0.05)
            """#
    }
#endif
