import Foundation

/// A multipart text field. Arrays preserve repeated names such as `timestamp_granularities[]`.
public struct MultipartField: Sendable, Equatable {
    public let name: String
    public let value: String
    public let contentType: String?

    public init(name: String, value: String, contentType: String? = nil) {
        self.name = name
        self.value = value
        self.contentType = contentType
    }
}

/// An in-memory file part. `fieldName` is usually `file`, `image`, or `mask`.
public struct MultipartFile: Sendable {
    public let fieldName: String
    public let filename: String
    public let data: Data
    public let contentType: String

    public init(fieldName: String, filename: String, data: Data, contentType: String = "application/octet-stream") {
        self.fieldName = fieldName
        self.filename = filename
        self.data = data
        self.contentType = contentType
    }
}

struct MultipartBody {
    let data: Data
    let contentType: String

    init(fields: [String: String], files: [MultipartFile]) throws {
        try self.init(
            fields: fields.sorted { $0.key < $1.key }.map { MultipartField(name: $0.key, value: $0.value) },
            files: files)
    }

    init(fields: [MultipartField], files: [MultipartFile]) throws {
        let boundary = "OpenAI-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        func quoted(_ string: String) throws -> String {
            guard !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw OpenAIClientError.invalidConfiguration("Multipart names must not contain control characters")
            }
            return string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        for field in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(try quoted(field.name))\"\r\n")
            if let contentType = field.contentType {
                guard !contentType.isEmpty,
                    contentType.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }
                    )
                else { throw OpenAIClientError.invalidConfiguration("Invalid multipart MIME type") }
                append("Content-Type: \(contentType)\r\n")
            }
            append("\r\n")
            append(field.value)
            append("\r\n")
        }
        for file in files {
            guard !file.contentType.isEmpty,
                file.contentType.unicodeScalars.allSatisfy({
                    $0.isASCII && !CharacterSet.controlCharacters.contains($0)
                })
            else { throw OpenAIClientError.invalidConfiguration("Invalid multipart MIME type") }
            append(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(try quoted(file.fieldName))\"; filename=\"\(try quoted(file.filename))\"\r\n"
            )
            append("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        data = body
        contentType = "multipart/form-data; boundary=\(boundary)"
    }
}

extension MultipartBody {
    /// Reads one textual routing field without decoding binary file contents as UTF-8.
    static func routingField(_ name: String, data: Data, contentType: String) throws -> String? {
        let parameters = contentType.split(separator: ";").dropFirst()
        guard
            let parameter = parameters.first(where: {
                $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("boundary=")
            })
        else {
            throw OpenAIClientError.invalidConfiguration("Multipart body is missing its boundary")
        }
        var boundary = parameter.trimmingCharacters(in: .whitespaces).dropFirst("boundary=".count).trimmingCharacters(
            in: .whitespaces)
        if boundary.hasPrefix("\""), boundary.hasSuffix("\"") { boundary = String(boundary.dropFirst().dropLast()) }
        guard !boundary.isEmpty, boundary.utf8.count <= 70,
            !boundary.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw OpenAIClientError.invalidConfiguration("Invalid multipart boundary")
        }
        let delimiter = Data(("\r\n--" + boundary).utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var cursor = data.startIndex
        while let headers = data.range(of: headerEnd, in: cursor..<data.endIndex) {
            guard let text = String(data: data[cursor..<headers.lowerBound], encoding: .utf8) else { return nil }
            let start = headers.upperBound
            guard let end = data.range(of: delimiter, in: start..<data.endIndex) else { return nil }
            let disposition = text.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("content-disposition:")
            }
            let field = disposition?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first {
                $0.hasPrefix("name=")
            }
            if field == "name=\"\(name)\"" || field == "name=\(name)" {
                guard end.lowerBound - start <= 1024 * 1024,
                    let value = String(data: data[start..<end.lowerBound], encoding: .utf8)
                else { throw OpenAIClientError.invalidConfiguration("Invalid multipart routing field") }
                return value
            }
            cursor = end.upperBound
        }
        return nil
    }
}
