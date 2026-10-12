import Foundation
import OpenAPIRuntime

extension HTTPBody {
    /// Streams a file in bounded chunks. Each retry opens a fresh handle at byte zero.
    /// Keep the file unchanged until the operation completes. Handles close on completion or cancellation.
    public convenience init(fileURL: URL, chunkSize: Int = 64 * 1024) throws {
        guard fileURL.isFileURL, chunkSize > 0, chunkSize <= 8 * 1024 * 1024 else {
            throw FileBodyError.invalidFileOrChunkSize
        }
        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        guard let size else { throw FileBodyError.invalidFileOrChunkSize }
        self.init(
            FileBytes(url: fileURL, chunkSize: chunkSize, length: size.int64Value),
            length: .known(size.int64Value), iterationBehavior: .multiple)
    }
}

/// A file was changed while being uploaded, or the input cannot be streamed.
public enum FileBodyError: Error, Sendable {
    case invalidFileOrChunkSize
    case changedDuringUpload
}

private struct FileBytes: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>
    let url: URL
    let chunkSize: Int
    let length: Int64
    func makeAsyncIterator() -> Iterator { Iterator(reader: Reader(url: url, chunkSize: chunkSize, length: length)) }
    struct Iterator: AsyncIteratorProtocol {
        let reader: Reader
        mutating func next() async throws -> Element? { try await reader.next() }
    }
    actor Reader {
        let url: URL
        let chunkSize: Int
        let length: Int64
        var handle: FileHandle?
        var read: Int64 = 0
        var finished = false
        init(url: URL, chunkSize: Int, length: Int64) {
            self.url = url
            self.chunkSize = chunkSize
            self.length = length
        }
        deinit { try? handle?.close() }
        func next() throws -> ArraySlice<UInt8>? {
            do {
                try Task.checkCancellation()
                if finished { return nil }
                if handle == nil { handle = try FileHandle(forReadingFrom: url) }
                let data = try handle!.read(upToCount: chunkSize) ?? Data()
                read += Int64(data.count)
                guard read <= length else { throw FileBodyError.changedDuringUpload }
                if data.isEmpty {
                    guard read == length else { throw FileBodyError.changedDuringUpload }
                    finished = true
                    try handle?.close()
                    handle = nil
                    return nil
                }
                return ArraySlice(data)
            } catch {
                finished = true
                try? handle?.close()
                handle = nil
                throw error
            }
        }
    }
}
