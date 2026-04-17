import Foundation
import SwiftUI

struct FileItem: Identifiable, Hashable {
    // Use path as stable ID so selection survives streaming reloads
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedDate: Date?

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    var displaySize: String {
        guard let bytes = size else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var displayDate: String {
        guard let date = modifiedDate else { return "" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    var systemIcon: String {
        guard !isDirectory else { return "folder.fill" }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp": return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v":                  return "film"
        case "mp3", "aac", "flac", "wav", "m4a", "ogg":          return "music.note"
        case "pdf":                                               return "doc.richtext"
        case "zip", "tar", "gz", "rar", "7z":                    return "archivebox"
        case "txt", "md", "log":                                  return "doc.text"
        case "apk":                                               return "shippingbox"
        default:                                                  return "doc"
        }
    }

    var iconColor: Color {
        isDirectory ? Color(red: 0.98, green: 0.76, blue: 0.18) : .secondary
    }

    // Non-optional sort keys for TableColumn comparators
    var sortDate: Date { modifiedDate ?? .distantPast }
    var sortSize: Int64 { size ?? 0 }

    var isImage: Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ["jpg","jpeg","png","gif","heic","webp","bmp"].contains(ext)
    }
}
