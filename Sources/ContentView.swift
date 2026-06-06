import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLook

enum ViewMode { case list, grid }

private struct TransferState {
    var label: String
    var current: Int
    var total: Int
    var currentFile: String
}

private enum ConflictResolution { case replace, keepBoth, skip }

enum SortField: CaseIterable {
    case name, date, size
    var label: String {
        switch self { case .name: "Name"; case .date: "Date"; case .size: "Size" }
    }
}

struct ContentView: View {
    @StateObject private var adb = ADBManager()

    @State private var files: [FileItem] = []
    @State private var currentPath = "/storage/emulated/0"
    @State private var pathHistory: [String] = []
    @State private var isLoading = false
    @State private var statusMessage: String? = nil
    @State private var transferState: TransferState? = nil
    @State private var isDropTargeted = false

    @State private var viewMode: ViewMode = .list
    @State private var sortField: SortField = .name
    @State private var sortAscending = true
    @State private var selectedFileIDs: Set<FileItem.ID> = []
    @State private var showHiddenFiles = false
    @State private var previewURL: URL? = nil
    @State private var keyMonitor: Any? = nil
    @State private var showHelp = false
    @State private var loadingTask: Task<Void, Never>? = nil
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteFiles: [FileItem] = []
    @State private var pendingDeleteNextFile: FileItem? = nil

    // Drives Table column-header sort indicators; stays in sync with sortField/sortAscending
    @State private var tableSortOrder: [KeyPathComparator<FileItem>] = [
        KeyPathComparator(\.name, order: .forward)
    ]

    var selectedFile: FileItem? {
        guard selectedFileIDs.count == 1, let id = selectedFileIDs.first else { return nil }
        return files.first { $0.id == id }
    }

    private var selectionSummary: String? {
        guard selectedFileIDs.count > 1 else { return nil }
        let count = selectedFileIDs.count
        // Collect sizes only for items visible in the current directory listing
        let sizes = files.filter { selectedFileIDs.contains($0.id) }.compactMap(\.size)
        guard !sizes.isEmpty else { return "\(count) selected" }
        let totalBytes = sizes.reduce(0, +)
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return "\(count) selected — \(fmt.string(fromByteCount: totalBytes))"
    }

    // Files shown in the Table (uses tableSortOrder, directories always first)
    var tableDisplayFiles: [FileItem] {
        let visible = showHiddenFiles ? files : files.filter { !$0.name.hasPrefix(".") }
        let dirs  = visible.filter {  $0.isDirectory }
        let plain = visible.filter { !$0.isDirectory }
        func sort(_ items: [FileItem]) -> [FileItem] {
            items.sorted { a, b in
                for comp in tableSortOrder {
                    switch comp.compare(a, b) {
                    case .orderedAscending:  return true
                    case .orderedDescending: return false
                    case .orderedSame:       continue
                    }
                }
                return false
            }
        }
        return sort(dirs) + sort(plain)
    }

    // Used by thumbnail grid
    var sortedFiles: [FileItem] {
        let visible = showHiddenFiles ? files : files.filter { !$0.name.hasPrefix(".") }
        return visible.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sortField {
            case .name:
                let c = a.name.localizedCaseInsensitiveCompare(b.name)
                return sortAscending ? c == .orderedAscending : c == .orderedDescending
            case .date:
                let da = a.modifiedDate ?? .distantPast
                let db = b.modifiedDate ?? .distantPast
                return sortAscending ? da < db : da > db
            case .size:
                return sortAscending ? (a.size ?? 0) < (b.size ?? 0) : (a.size ?? 0) > (b.size ?? 0)
            }
        }
    }

    var deleteAlertTitle: String {
        if pendingDeleteFiles.count == 1 {
            return "Delete \"\(pendingDeleteFiles.first?.name ?? "")\"?"
        }
        return "Delete \(pendingDeleteFiles.count) items?"
    }

    var deleteAlertMessage: String {
        if pendingDeleteFiles.count == 1 {
            return "\"\(pendingDeleteFiles.first?.name ?? "")\" will be permanently deleted from your device."
        }
        return "\(pendingDeleteFiles.count) items will be permanently deleted from your device."
    }

    var sortAscendingLabel: String {
        switch sortField {
        case .name: return sortAscending ? "A→Z" : "Z→A"
        case .date: return sortAscending ? "Oldest" : "Newest"
        case .size: return sortAscending ? "Smallest" : "Largest"
        }
    }

    // Build a KeyPathComparator for a given sort field + direction
    func makeComparator(field: SortField, ascending: Bool) -> KeyPathComparator<FileItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case .name: return KeyPathComparator(\.name,     order: order)
        case .date: return KeyPathComparator(\.sortDate, order: order)
        case .size: return KeyPathComparator(\.sortSize, order: order)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            sortBar
            Divider()
            ZStack {
                if !adb.isConnected {
                    noDeviceView
                } else if viewMode == .list {
                    fileTable
                } else {
                    thumbnailGrid
                }
                if isLoading { loadingOverlay }
            }
            if let ts = transferState {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: Double(ts.current), total: Double(ts.total))
                        .progressViewStyle(.linear)
                    Text("\(ts.label) \(ts.current) of \(ts.total)\(ts.currentFile.isEmpty ? "" : " — \(ts.currentFile)")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else if let msg = statusMessage {
                Divider()
                HStack {
                    Text(msg).font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .quickLookPreview($previewURL)
        .task { await pollForDevice() }
        .onChange(of: adb.isConnected) { _, connected in
            if connected {
                loadFiles(currentPath)
            } else {
                files = []
                pathHistory = []
                currentPath = "/storage/emulated/0"
            }
        }
        // Keep sortField/sortAscending in sync when column headers are clicked
        .onChange(of: tableSortOrder) { _, newOrder in
            guard let first = newOrder.first else { return }
            if      first.keyPath == \FileItem.name     { sortField = .name }
            else if first.keyPath == \FileItem.sortDate { sortField = .date }
            else if first.keyPath == \FileItem.sortSize { sortField = .size }
            sortAscending = (first.order == .forward)
        }
        .onAppear { setupKeyMonitor() }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
        .alert(deleteAlertTitle, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                let filesToDelete = pendingDeleteFiles
                let nextFile = pendingDeleteNextFile
                let wasPreviewOpen = previewURL != nil
                pendingDeleteFiles = []
                pendingDeleteNextFile = nil
                Task {
                    let ok = await adb.deleteFiles(filesToDelete.map(\.path))
                    let n = filesToDelete.count
                    showStatus(ok ? "Deleted \(n) item\(n == 1 ? "" : "s")"
                                 : "Some items could not be deleted")
                    if wasPreviewOpen { previewURL = nil }
                    if let next = nextFile {
                        selectedFileIDs = [next.id]
                        if wasPreviewOpen { await showPreview(for: next) }
                    } else {
                        selectedFileIDs = []
                    }
                    loadFiles(currentPath)
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteFiles = []; pendingDeleteNextFile = nil }
        } message: {
            Text(deleteAlertMessage)
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                newFolderName = ""
                guard !name.isEmpty else { return }
                Task {
                    let path = currentPath + "/" + name
                    let ok = await adb.createDirectory(path)
                    showStatus(ok ? "Created \"\(name)\"" : "Failed to create \"\(name)\"")
                    if ok { loadFiles(currentPath) }
                }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack(spacing: 8) {
            Button { navigateBack() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .disabled(pathHistory.isEmpty)
            .buttonStyle(.bordered)
            .help("Go back to the previous folder")

            Text(currentPath)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if adb.isConnected {
                Button { loadFiles(currentPath) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help("Refresh the current folder")

                Button {
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Create a new folder")
            }

            Button { showHelp = true } label: {
                Text("Guide")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Setup guide")
            .sheet(isPresented: $showHelp) {
                VStack(spacing: 0) {
                    HelpView()
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { showHelp = false }
                            .keyboardShortcut(.defaultAction)
                            .padding(12)
                    }
                }
                .frame(width: 500, height: 580)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sort Bar

    private var sortBar: some View {
        HStack(spacing: 4) {
            Text("Sort:")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(SortField.allCases, id: \.self) { field in
                Button {
                    let newAscending = (sortField == field) ? !sortAscending : true
                    tableSortOrder = [makeComparator(field: field, ascending: newAscending)]
                } label: {
                    Text(field.label).font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sortField == field ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .foregroundColor(sortField == field ? .primary : .secondary)
            }

            // Direction toggle
            Button {
                tableSortOrder = [makeComparator(field: sortField, ascending: !sortAscending)]
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    Text(sortAscendingLabel)
                }
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Reverse sort order")

            Spacer()

            if let summary = selectionSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }

            Button {
                showHiddenFiles.toggle()
            } label: {
                Image(systemName: showHiddenFiles ? "eye" : "eye.slash")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(showHiddenFiles ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help(showHiddenFiles ? "Hide hidden files" : "Show hidden files")

            Picker("", selection: $viewMode) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .frame(width: 64)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - No Device

    private var noDeviceView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No device connected — follow the steps below to get started")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            HelpView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Table

    private var fileTable: some View {
        FileTableNSView(
            files: tableDisplayFiles,
            adbPath: adb.adbPath,
            sortField: sortField,
            sortAscending: sortAscending,
            selectedFileIDs: $selectedFileIDs,
            onNavigate: { navigate(to: $0.path) },
            onPreview: { file in Task { @MainActor in await showPreview(for: file) } },
            onDrop: handleDrop,
            onCreateFolder: { newFolderName = ""; showNewFolderAlert = true },
            onDelete: requestDelete,
            onSortChange: { field, ascending in
                tableSortOrder = [makeComparator(field: field, ascending: ascending)]
            },
            onDownloadStart: { count in
                transferState = TransferState(label: "Downloading", current: 0, total: count, currentFile: "")
            },
            onFileDownloaded: { name in
                transferState?.current += 1
                transferState?.currentFile = name
            },
            onDownloadEnd: {
                transferState = nil
            }
        )
    }

    // MARK: - Thumbnail Grid

    private var thumbnailGrid: some View {
        ThumbnailGrid(
            files: sortedFiles,
            adbPath: adb.adbPath,
            deviceSerial: adb.deviceSerial ?? "unknown",
            selectedFileIDs: $selectedFileIDs,
            isDropTargeted: $isDropTargeted,
            onNavigate: { navigate(to: $0.path) },
            onDrop: handleDrop,
            onCreateFolder: { newFolderName = ""; showNewFolderAlert = true },
            onDelete: requestDelete
        )
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

    private var loadingOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.6)
            ProgressView()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func navigate(to path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        selectedFileIDs = []
        loadFiles(path)
    }

    private func navigateBack() {
        guard let prev = pathHistory.popLast() else { return }
        currentPath = prev
        selectedFileIDs = []
        loadFiles(prev)
    }

    private func loadFiles(_ path: String) {
        loadingTask?.cancel()
        loadingTask = Task { @MainActor in
            isLoading = true
            files = []
            for await batch in adb.listFilesStream(path: path) {
                guard !Task.isCancelled else { break }
                files.append(contentsOf: batch)
            }
            if !Task.isCancelled { isLoading = false }
        }
    }

    private func pollForDevice() async {
        while !Task.isCancelled {
            await adb.checkDevice()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // Recursively expand dropped URLs into (localURL, remotePath) pairs.
    // Directories are walked; individual files are added directly.
    private func collectTransfers(url: URL, remoteDir: String) -> [(local: URL, remote: String)] {
        var isDirObjC: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirObjC) else { return [] }
        let remotePath = remoteDir + "/" + url.lastPathComponent
        guard isDirObjC.boolValue else { return [(url, remotePath)] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return children.flatMap { collectTransfers(url: $0, remoteDir: remotePath) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let dest = currentPath
        Task { @MainActor in
            // Resolve URLs, then expand any directories into individual files
            var transfers: [(local: URL, remote: String)] = []
            for provider in providers {
                guard let url = await resolveURL(from: provider) else { continue }
                transfers.append(contentsOf: collectTransfers(url: url, remoteDir: dest))
            }
            let total = transfers.count
            transferState = TransferState(label: "Uploading", current: 0, total: max(total, 1), currentFile: "")
            var successCount = 0
            let currentListing = files
            for (localURL, remotePath) in transfers {
                let fileName = localURL.lastPathComponent
                transferState?.currentFile = fileName
                await adb.ensureDirectory((remotePath as NSString).deletingLastPathComponent)
                var finalRemotePath = remotePath
                let remoteParent = (remotePath as NSString).deletingLastPathComponent
                let alreadyExists: Bool
                if remoteParent == dest {
                    alreadyExists = currentListing.contains { $0.name == fileName }
                } else {
                    alreadyExists = await adb.fileExists(remotePath)
                }
                if alreadyExists {
                    let resolution = await awaitConflictResolution(for: fileName)
                    switch resolution {
                    case .replace:
                        break
                    case .keepBoth:
                        finalRemotePath = await adb.findUniquePath(for: remotePath)
                    case .skip:
                        transferState?.current += 1
                        continue
                    }
                }
                let ok = await adb.pushFile(from: localURL, to: finalRemotePath)
                if ok { successCount += 1 }
                transferState?.current += 1
            }
            transferState = nil
            showStatus("\(successCount) of \(total) file\(total == 1 ? "" : "s") uploaded")
            loadFiles(dest)
        }
        return true
    }

    private func resolveURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }

    @MainActor
    private func awaitConflictResolution(for filename: String) async -> ConflictResolution {
        await withCheckedContinuation { continuation in
            // Dispatch after suspension so the main thread is free when runModal() blocks.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "File Already Exists"
                alert.informativeText = "\"\(filename)\" already exists in this location. Do you want to replace it, keep both, or skip it?"
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Keep Both")
                alert.addButton(withTitle: "Skip")
                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn:  continuation.resume(returning: .replace)
                case .alertSecondButtonReturn: continuation.resume(returning: .keepBoth)
                default:                       continuation.resume(returning: .skip)
                }
            }
        }
    }

    private func nextPreviewableFile(after file: FileItem) -> FileItem? {
        let list = previewableFiles
        guard let idx = list.firstIndex(where: { $0.id == file.id }) else { return nil }
        if idx + 1 < list.count { return list[idx + 1] }
        if idx - 1 >= 0 { return list[idx - 1] }
        return nil
    }

    private func nextDisplayFile(after file: FileItem) -> FileItem? {
        let list = viewMode == .list ? tableDisplayFiles : sortedFiles
        guard let idx = list.firstIndex(where: { $0.id == file.id }) else { return nil }
        if idx + 1 < list.count { return list[idx + 1] }
        if idx - 1 >= 0 { return list[idx - 1] }
        return nil
    }

    private func requestDelete(_ files: [FileItem]) {
        guard !files.isEmpty else { return }
        if files.count == 1 {
            let file = files[0]
            let wasPreviewOpen = previewURL != nil
            let nextFile = wasPreviewOpen ? nextPreviewableFile(after: file) : nextDisplayFile(after: file)
            Task {
                let ok = await adb.deleteFiles([file.path])
                showStatus(ok ? "Deleted \"\(file.name)\"" : "Could not delete \"\(file.name)\"")
                if wasPreviewOpen { previewURL = nil }
                if let next = nextFile {
                    selectedFileIDs = [next.id]
                    if wasPreviewOpen { await showPreview(for: next) }
                } else {
                    selectedFileIDs = []
                }
                loadFiles(currentPath)
            }
        } else {
            pendingDeleteNextFile = nil
            pendingDeleteFiles = files
            showDeleteConfirmation = true
        }
    }

    private func showStatus(_ msg: String) {
        statusMessage = msg
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusMessage == msg { statusMessage = nil }
        }
    }

    // MARK: - Quick Look / Double-click / Spacebar

    // Files that can be previewed, in display order (directories excluded).
    private var previewableFiles: [FileItem] {
        tableDisplayFiles.filter { !$0.isDirectory }
    }

    private func navigatePreview(by delta: Int) {
        let list = previewableFiles
        guard let currentID = selectedFileIDs.first,
              let idx = list.firstIndex(where: { $0.id == currentID }) else { return }
        let newIdx = idx + delta
        guard newIdx >= 0 && newIdx < list.count else { return }
        let file = list[newIdx]
        selectedFileIDs = [file.id]
        Task { @MainActor in await showPreview(for: file) }
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 { // spacebar
                Task { @MainActor in
                    if self.previewURL != nil {
                        self.previewURL = nil
                    } else if let file = self.selectedFile, !file.isDirectory {
                        await self.showPreview(for: file)
                    }
                }
                return nil
            }
            if self.previewURL != nil {
                if event.keyCode == 126 { // up arrow
                    Task { @MainActor in self.navigatePreview(by: -1) }
                    return nil
                }
                if event.keyCode == 125 { // down arrow
                    Task { @MainActor in self.navigatePreview(by: 1) }
                    return nil
                }
            }
            if event.keyCode == 51 && event.modifierFlags.contains(.command) { // ⌘+Delete
                Task { @MainActor in
                    let selected = self.files.filter { self.selectedFileIDs.contains($0.id) }
                    if !selected.isEmpty { self.requestDelete(selected) }
                }
                return nil
            }
            return event
        }
    }

    private func showPreview(for file: FileItem) async {
        let serial = adb.deviceSerial ?? "unknown"
        let url = fileCacheURL(for: file, device: serial)

        if !FileManager.default.fileExists(atPath: url.path) {
            isLoading = true
            let path = file.path
            let adbPath = adb.adbPath
            _ = await Task.detached {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                return ADBManager.runCommand(adbPath, args: ["pull", path, url.path])
            }.value
            isLoading = false
        }

        if FileManager.default.fileExists(atPath: url.path) {
            previewURL = url
        }
    }

    func fileCacheURL(for file: FileItem, device: String) -> URL {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/android-transfer/\(device)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let safeName = file.path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return cacheDir.appendingPathComponent(safeName)
    }
}
