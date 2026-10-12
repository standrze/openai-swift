import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct AgentLocalFile {
    let destination: String
    let source: URL
    let identity: stat

    func read() throws -> Data {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, opened.st_dev == identity.st_dev,
            opened.st_ino == identity.st_ino, opened.st_size == identity.st_size
        else {
            throw OpenAIClientError.invalidConfiguration("Source changed after preflight")
        }
        let data = try handle.readToEnd() ?? Data()
        guard data.count == identity.st_size else {
            throw OpenAIClientError.invalidConfiguration("Source size changed")
        }
        return data
    }
}

enum AgentLocalFiles {
    static func preflight(_ files: [String: URL]) throws -> [AgentLocalFile] {
        try files.keys.sorted().map { destination in
            try Task.checkCancellation()
            try validateDestination(destination)
            let parts = destination.split(separator: "/")
            for length in 2..<parts.count where files["/" + parts.prefix(length).joined(separator: "/")] != nil {
                throw OpenAIClientError.invalidConfiguration("File destinations overlap")
            }
            let source = files[destination]!
            guard source.isFileURL, !source.path.utf8.contains(0) else { throw invalid("Source must be a file URL") }
            let identity = try info(source.path)
            guard identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw invalid("Source must be regular") }
            return AgentLocalFile(destination: destination, source: source, identity: identity)
        }
    }

    static func validateDestination(_ destination: String) throws {
        let parts = destination.split(separator: "/", omittingEmptySubsequences: false)
        guard destination.hasPrefix("/workspace/"), !destination.contains("\\"), !destination.utf8.contains(0),
            parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            destination != "/workspace/outputs", parts.count > 2,
            parts[2] != ".codex", parts[2] != ".managed-agents", !parts[2].hasPrefix(".managed-agents-")
        else {
            throw invalid("Destination must name a clean, nonreserved file inside /workspace")
        }
    }

    static func select(directory: URL, destination: String, include: [String]) throws -> [String: URL] {
        try Task.checkCancellation()
        guard directory.isFileURL, !include.isEmpty else {
            throw invalid("Directory and include patterns must be explicit")
        }
        for pattern in include { try validatePattern(pattern) }
        guard try info(directory.path).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw invalid("Directory must not be a symlink")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let escaped = root.reduce(into: "") { result, character in
            if "\\[*?".contains(character) { result.append("\\") }
            result.append(character)
        }
        var files: [String: URL] = [:]
        for pattern in include {
            try Task.checkCancellation()
            var matches = glob_t()
            let code = glob(escaped + "/" + pattern, 0, nil, &matches)
            defer { globfree(&matches) }
            guard code == 0 || code == GLOB_NOMATCH else { throw invalid("Cannot expand include pattern") }
            for index in 0..<Int(matches.gl_pathc) {
                guard let pointer = matches.gl_pathv[index] else { continue }
                let path = String(cString: pointer)
                guard path.hasPrefix(root + "/") else { throw invalid("Selected file is outside directory") }
                let relative = String(path.dropFirst(root.count + 1))
                var current = root
                var selected = true
                for part in relative.split(separator: "/") {
                    current += "/" + part
                    if try info(current).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        selected = false
                        break
                    }
                }
                if selected, try info(path).st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                    files[destination + "/" + relative] = URL(fileURLWithPath: path)
                }
            }
        }
        return files
    }

    private static func validatePattern(_ pattern: String) throws {
        guard !pattern.isEmpty, !pattern.hasPrefix("/"), !pattern.utf8.contains(0),
            !pattern.split(separator: "/").contains("..")
        else { throw invalid("Include patterns must stay local") }
        var escaped = false
        var bracket = false
        var bracketCount = 0
        for character in pattern {
            if escaped {
                escaped = false
                if bracket { bracketCount += 1 }
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[", !bracket {
                bracket = true
                bracketCount = 0
            } else if character == "]", bracket {
                guard bracketCount > 0 else { throw invalid("Invalid glob pattern") }
                bracket = false
            } else if bracket {
                bracketCount += 1
            }
        }
        guard !escaped, !bracket else { throw invalid("Invalid glob pattern") }
    }

    private static func info(_ path: String) throws -> stat {
        var result = stat()
        guard lstat(path, &result) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return result
    }

    private static func invalid(_ message: String) -> OpenAIClientError { .invalidConfiguration(message) }
}
