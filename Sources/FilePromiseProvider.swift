import AppKit
import UniformTypeIdentifiers

// Returns an NSItemProvider that lazily pulls the file from the device when dropped
func makeFileItemProvider(adbPath: String, remotePath: String, fileName: String) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = fileName

    let ext = URL(fileURLWithPath: fileName).pathExtension
    let utType = UTType(filenameExtension: ext) ?? .data

    provider.registerFileRepresentation(
        forTypeIdentifier: utType.identifier,
        fileOptions: [],
        visibility: .all
    ) { completion in
        DispatchQueue.global(qos: .userInitiated).async {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let tempURL = tempDir.appendingPathComponent(fileName)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let output = ADBManager.runCommand(adbPath, args: ["pull", remotePath, tempURL.path])
            let ok = output.contains("pulled") || output.contains("file pulled")
            completion(
                ok ? tempURL : nil,
                false,
                ok ? nil : NSError(domain: "AndroidTransfer", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "Failed to pull file"])
            )
        }
        return nil
    }

    return provider
}
