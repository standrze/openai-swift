import Foundation
import XCTest

@testable import OpenAI

final class AgentFileTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    func testPrepareAndStageWireContract() async throws {
        let directory = try directory()
        let source = try file("a.txt", in: directory)
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"id":"f","filename":"a.txt"}"#)), .response(jsonResponse(#"{"id":"live"}"#)),
        ])
        let service = AgentsService(client: OpenAIClient(configuration: testConfiguration(), transport: transport))
        let staged = try await service.uploadEnvironmentFile(
            environmentID: "env", source: source, destination: "/workspace/a.txt")
        XCTAssertEqual(staged.upload.id, "f")
        XCTAssertEqual(staged.file["id"], "live")
        let requests = await transport.requests
        XCTAssertTrue(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("user_data"))
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!),
            [
                "type": "file_id", "file_id": "f", "path": "/workspace/a.txt",
            ])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "OpenAI-Beta"), "agents=v1")
    }

    func testPreflightAllFilesBeforeNetwork() async throws {
        let directory = try directory()
        let source = try file("a.txt", in: directory)
        let transport = RecordingTransport()
        let service = AgentsService(client: OpenAIClient(configuration: testConfiguration(), transport: transport))
        for files in [
            ["/workspace/a": source, "/workspace/a/child": source],
            ["/workspace/.codex/private": source], ["/workspace/../bad": source],
            ["/workspace/a": source, "/workspace/z": directory.appendingPathComponent("missing")],
        ] {
            do {
                _ = try await service.prepareFiles(files)
                XCTFail("Invalid selection accepted")
            } catch {}
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPartialUploadRetentionAndIdempotencyRejection() async throws {
        let directory = try directory()
        let source = try file("a.txt", in: directory)
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"id":"f","filename":"a.txt"}"#)), .response(jsonResponse("{}", status: 400)),
        ])
        let service = AgentsService(client: OpenAIClient(configuration: testConfiguration(), transport: transport))
        let files = ["/workspace/a": source, "/workspace/b": source]
        do {
            _ = try await service.prepareFiles(files)
            XCTFail("Expected upload failure")
        } catch let error as AgentFilePreparationError {
            XCTAssertEqual(error.prepared.uploads.map(\.id), ["f"])
            XCTAssertEqual(error.prepared.files.first?["path"], "/workspace/a")
        }
        do {
            _ = try await service.prepareFiles(files, options: .init(headers: ["idempotency-key": "one"]))
            XCTFail("Reused key")
        } catch is OpenAIClientError {}
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testDirectoryGlobSkipsSymlinksAndPreservesLiteralRoot() throws {
        let directory = try directory().appendingPathComponent("[literal]*")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try file("a.txt", in: directory)
        _ = try file("b.bin", in: directory)
        let child = directory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        _ = try file("c.txt", in: child)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("alias"), withDestinationURL: child)
        let selected = try AgentLocalFiles.select(
            directory: directory, destination: "/workspace/in", include: ["*.txt", "child/*.txt", "alias/*.txt"])
        XCTAssertEqual(Set(selected.keys), ["/workspace/in/a.txt", "/workspace/in/child/c.txt"])
        for pattern in ["../*", "/tmp/*", "*[", "foo\\"] {
            XCTAssertThrowsError(
                try AgentLocalFiles.select(directory: directory, destination: "/workspace/in", include: [pattern]))
        }
    }

    func testStagingFailureRetainsOwnedUpload() async throws {
        let source = try file("a.txt", in: directory())
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"id":"f","filename":"a.txt"}"#)), .response(jsonResponse("{}", status: 400)),
        ])
        let service = AgentsService(client: OpenAIClient(configuration: testConfiguration(), transport: transport))
        do {
            _ = try await service.uploadEnvironmentFile(
                environmentID: "env", source: source, destination: "/workspace/a")
            XCTFail("Expected staging failure")
        } catch let error as AgentFilePreparationError { XCTAssertEqual(error.prepared.uploads.map(\.id), ["f"]) }
    }

    func testArtifactExactTurnPaginationAndWriterFailureClosesBody() async throws {
        let cancelled = CancellationRecorder()
        let transport = RecordingTransport(
            send: [
                .response(
                    jsonResponse(
                        #"{"data":[{"id":"wrong","turn_id":"other","path":"/output"}],"has_more":true,"last_id":"wrong"}"#
                    )),
                .response(jsonResponse(#"{"data":[{"id":"a","turn_id":"t","path":"/output"}],"has_more":false}"#)),
            ], stream: [.response(streamResponse(text: "bytes", headers: [:], cancel: { cancelled.record() }))])
        let service = AgentsService(client: OpenAIClient(configuration: testConfiguration(), transport: transport))
        let artifacts = service.artifacts(for: AgentTurnResult(turn: ["id": "t", "session_id": "s"], messages: []))
        do {
            try await artifacts.download(path: "/output") { _ in throw OpenAIClientError.invalidResponse }
            XCTFail("Writer failure ignored")
        } catch let error as AgentArtifactDownloadError { XCTAssertEqual(error.artifact["id"], "a") }
        XCTAssertGreaterThan(cancelled.count, 0)
        let requests = await transport.requests
        XCTAssertTrue(requests[1].url!.absoluteString.contains("after=wrong"))
        XCTAssertTrue(requests[2].url!.path.hasSuffix("/artifacts/a/content"))
    }

    func testAmbiguousArtifactsAreRejected() async throws {
        let transport = RecordingTransport(send: [
            .response(
                jsonResponse(
                    #"{"data":[{"id":"a","turn_id":"t","path":"p"},{"id":"b","turn_id":"t","path":"p"}],"has_more":false}"#
                ))
        ])
        let service = AgentsService(client: OpenAIClient(configuration: testConfiguration(), transport: transport))
        do {
            _ = try await service.artifacts(for: .init(turn: ["id": "t", "session_id": "s"], messages: [])).find(
                path: "p")
            XCTFail("Ambiguous match accepted")
        } catch {}
    }
}
