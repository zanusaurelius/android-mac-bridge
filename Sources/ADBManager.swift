import Foundation

class ADBManager: ObservableObject {
    @Published var isConnected = false
    @Published var deviceSerial: String? = nil

    let adbPath: String

    init() {
        // Prefer the adb binary bundled inside the app (Contents/MacOS/adb).
        // Fall back to system-installed adb for dev builds run outside the app bundle.
        let fm = FileManager.default
        if let execDir = Bundle.main.executablePath.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().path }) {
            let bundled = execDir + "/adb"
            if fm.fileExists(atPath: bundled) {
                adbPath = bundled
                return
            }
        }
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        adbPath = candidates.first { fm.fileExists(atPath: $0) } ?? "adb"
    }

    // MARK: - Async API

    func checkDevice() async {
        let path = adbPath
        let output = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Self.runCommand(path, args: ["devices"]))
            }
        }
        let lines = output.components(separatedBy: "\n")
        var serial: String? = nil
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: "\t")
            if parts.count == 2 && parts[1].trimmingCharacters(in: .whitespaces) == "device" {
                serial = parts[0].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let resolved = serial
        await MainActor.run {
            self.isConnected = resolved != nil
            self.deviceSerial = resolved
        }
    }

    // Streaming version: yields batches as output arrives.
    // Uses a blocking read loop to avoid the race between readabilityHandler and terminationHandler.
    func listFilesStream(path: String) -> AsyncStream<[FileItem]> {
        let adbPath = self.adbPath
        return AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = ["shell", "ls", "-la", path]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do { try process.run() } catch { continuation.finish(); return }

                let handle = pipe.fileHandleForReading
                var lineBuffer = ""
                var batch: [FileItem] = []
                let batchSize = 40

                // availableData blocks until data arrives or EOF (empty Data)
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break } // EOF
                    guard let str = String(data: data, encoding: .utf8) else { continue }

                    lineBuffer += str
                    var lines = lineBuffer.components(separatedBy: "\n")
                    lineBuffer = lines.removeLast()

                    for line in lines {
                        if let item = Self.parseLine(line, basePath: path) {
                            batch.append(item)
                        }
                    }

                    if batch.count >= batchSize {
                        continuation.yield(batch)
                        batch = []
                    }
                }

                // Flush remainder
                if !lineBuffer.isEmpty, let item = Self.parseLine(lineBuffer, basePath: path) {
                    batch.append(item)
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
                process.waitUntilExit()
            }
        }
    }

    func pushFile(from localURL: URL, to remotePath: String) async -> Bool {
        let adbPath = self.adbPath
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = Self.runCommand(adbPath, args: ["push", localURL.path, remotePath])
                cont.resume(returning: output.contains("pushed") || output.contains("file pushed"))
            }
        }
    }

    // MARK: - Static helpers

    static func runCommand(_ executablePath: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out + err
    }

    private static let lsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Compiled once, reused for every line
    private static let lsPattern = #"^([dlrwxsStT-]{10})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\S+)(?:\s+[+-]\d{4})?\s+(.+)$"#
    private static let lsRegex: NSRegularExpression? = try? NSRegularExpression(pattern: lsPattern)

    // Parse a single ls -la line into a FileItem
    static func parseLine(_ line: String, basePath: String) -> FileItem? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines) // strip \r from ADB PTY output
        guard !t.isEmpty, !t.hasPrefix("total"), let regex = lsRegex else { return nil }
        guard let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }

        func capture(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: t) else { return nil }
            return String(t[r])
        }

        guard let perms   = capture(1),
              let sizeStr = capture(2),
              let dateStr = capture(3),
              let timeStr = capture(4),
              let rawName = capture(5) else { return nil }

        guard rawName != "." && rawName != ".." else { return nil }

        let isDir  = perms.hasPrefix("d")
        let isLink = perms.hasPrefix("l")

        let name: String
        if isLink, let arrow = rawName.range(of: " -> ") {
            name = String(rawName[..<arrow.lowerBound])
        } else {
            name = rawName
        }

        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        // Android ls -la time is either "HH:mm" or "HH:mm:ss" or "HH:mm:ss.nnnnnnnnn"
        let cleanTime = timeStr.count <= 5 ? timeStr + ":00" : String(timeStr.prefix(8))
        let date = lsDateFormatter.date(from: "\(dateStr) \(cleanTime)")

        return FileItem(
            name: name,
            path: "\(base)/\(name)",
            isDirectory: isDir || isLink,
            size: isDir ? nil : Int64(sizeStr),
            modifiedDate: date
        )
    }

    // Streaming version of listDirFast — yields batches as ls -F output arrives.
    // Use this for inline folder expansion so the first items appear immediately
    // even when a directory has thousands of files.
    static func listDirStream(_ adbPath: String, path: String) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = ["shell", "ls", "-F", path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do { try process.run() } catch { continuation.finish(); return }
                let handle = pipe.fileHandleForReading
                let base = path.hasSuffix("/") ? String(path.dropLast()) : path
                var lineBuffer = ""
                var batch: [FileItem] = []
                let batchSize = 50
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    guard let str = String(data: data, encoding: .utf8) else { continue }
                    lineBuffer += str
                    var lines = lineBuffer.components(separatedBy: "\n")
                    lineBuffer = lines.removeLast()
                    for line in lines {
                        var name = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { continue }
                        name = name.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
                        let isDir = name.hasSuffix("/")
                        let cleanName = isDir ? String(name.dropLast()) : String(name.filter { !"/\\*@|=".contains($0) })
                        guard !cleanName.isEmpty, cleanName != ".", cleanName != ".." else { continue }
                        batch.append(FileItem(name: cleanName, path: "\(base)/\(cleanName)", isDirectory: isDir, size: nil, modifiedDate: nil))
                    }
                    if batch.count >= batchSize {
                        continuation.yield(batch)
                        batch = []
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
                process.waitUntilExit()
            }
        }
    }

    // Fast listing for tree expansion — names + directory flag only
    static func listDirFast(_ adbPath: String, path: String) -> [FileItem] {
        let output = runCommand(adbPath, args: ["shell", "ls", "-F", path])
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        return output.components(separatedBy: "\n").compactMap { line in
            var name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            name = name.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
            let isDir = name.hasSuffix("/")
            let cleanName = isDir ? String(name.dropLast()) : String(name.filter { !"/\\*@|=".contains($0) })
            guard !cleanName.isEmpty, cleanName != ".", cleanName != ".." else { return nil }
            return FileItem(name: cleanName, path: "\(base)/\(cleanName)", isDirectory: isDir, size: nil, modifiedDate: nil)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // Non-streaming fallback (used by pushFile result check etc.)
    static func parseLSOutput(_ output: String, basePath: String) -> [FileItem] {
        let items = output.components(separatedBy: "\n").compactMap { parseLine($0, basePath: basePath) }
        return items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
