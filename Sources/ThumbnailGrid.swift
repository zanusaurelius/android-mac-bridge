import SwiftUI
import ImageIO

// MARK: - Grid container

struct ThumbnailGrid: View {
    let files: [FileItem]
    let adbPath: String
    let deviceSerial: String
    @Binding var selectedFileIDs: Set<FileItem.ID>
    @Binding var isDropTargeted: Bool
    let onNavigate: (FileItem) -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onCreateFolder: () -> Void
    let onDelete: ([FileItem]) -> Void

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(files) { file in
                    ThumbnailCell(
                        file: file,
                        adbPath: adbPath,
                        deviceSerial: deviceSerial,
                        isSelected: selectedFileIDs.contains(file.id)
                    )
                    .onTapGesture {
                        if selectedFileIDs.contains(file.id) {
                            selectedFileIDs.remove(file.id)
                        } else {
                            selectedFileIDs.insert(file.id)
                        }
                    }
                    .onTapGesture(count: 2) {
                        if file.isDirectory { onNavigate(file) }
                    }
                }
            }
            .padding(12)
        }
        .overlay(dropHighlight)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: onDrop)
        .contextMenu {
            Button("New Folder") { onCreateFolder() }
            if !selectedFileIDs.isEmpty {
                Divider()
                Button("Delete", role: .destructive) {
                    let selected = files.filter { selectedFileIDs.contains($0.id) }
                    onDelete(selected)
                }
            }
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.08))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Single cell

struct ThumbnailCell: View {
    let file: FileItem
    let adbPath: String
    let deviceSerial: String
    let isSelected: Bool

    @State private var thumbnail: NSImage? = nil
    @State private var isLoadingThumb = false

    private let cellSize: CGFloat = 130
    private let thumbHeight: CGFloat = 110

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))

                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cellSize, height: thumbHeight)  // constrain before ZStack sees it
                } else if file.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 44))
                        .foregroundColor(file.iconColor)
                } else if isLoadingThumb {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: file.systemIcon)
                        .font(.system(size: 30))
                        .foregroundColor(file.iconColor)
                }
            }
            .frame(width: cellSize, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: cellSize)
        }
        .task(id: file.path) { await loadThumbnail() }
        .onDrag {
            guard !file.isDirectory else { return NSItemProvider() }
            return makeFileItemProvider(adbPath: adbPath, remotePath: file.path, fileName: file.name)
        }
    }

    private func loadThumbnail() async {
        guard file.isImage else { return }

        let url = cacheURL()

        if FileManager.default.fileExists(atPath: url.path) {
            thumbnail = makeThumbnail(from: url)
            return
        }

        isLoadingThumb = true
        let remotePath = file.path
        let adb = adbPath
        let result = await Task.detached {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return ADBManager.runCommand(adb, args: ["pull", remotePath, url.path])
        }.value
        isLoadingThumb = false

        if result.contains("pulled") || result.contains("file pulled") {
            thumbnail = makeThumbnail(from: url)
        }
    }

    func cacheURL() -> URL {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/android-transfer/\(deviceSerial)")
        let safeName = file.path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return cacheDir.appendingPathComponent(safeName)
    }

    private func makeThumbnail(from url: URL) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 260,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
