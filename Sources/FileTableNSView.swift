import AppKit
import SwiftUI
import UniformTypeIdentifiers

// One row in the flattened tree: the file plus its nesting depth.
private struct FlatRow {
    let file: FileItem
    let depth: Int
}

struct FileTableNSView: NSViewRepresentable {
    let files: [FileItem]
    let adbPath: String
    let sortField: SortField
    let sortAscending: Bool
    @Binding var selectedFileIDs: Set<FileItem.ID>
    let onNavigate: (FileItem) -> Void
    let onPreview: (FileItem) -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onCreateFolder: () -> Void
    let onDelete: ([FileItem]) -> Void
    let onSortChange: (SortField, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.tableView

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 180
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        tv.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Date Modified"
        dateCol.width = 130
        dateCol.minWidth = 100
        dateCol.maxWidth = 160
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
        tv.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 65
        sizeCol.minWidth = 55
        sizeCol.maxWidth = 90
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        tv.addTableColumn(sizeCol)

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        return sv
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scrollView.documentView as! NSTableView
        context.coordinator.sync(files: files, selectedIDs: selectedFileIDs, in: tv)
        context.coordinator.syncSort(field: sortField, ascending: sortAscending, in: tv)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSFilePromiseProviderDelegate {
        var parent: FileTableNSView
        let tableView: NSTableView

        // The top-level file list received from ContentView (changes on navigation/streaming)
        private var baseFiles: [FileItem] = []
        // The flattened tree: base files interleaved with expanded children
        private var flatRows: [FlatRow] = []
        // Paths the user has opened. Persists across navigations so back-button restores state.
        private var expandedPaths: Set<String> = []
        // Children per directory path. Persists as a cache — never cleared.
        private var childCache: [String: [FileItem]] = [:]
        private var loadingPaths: Set<String> = []
        private var suppressSelectionCallback = false
        private var suppressSortCallback = false
        private var lastSortKey: String = "name"
        private var lastSortAscending: Bool = true
        private var sortKVO: NSKeyValueObservation?

        func syncSort(field: SortField, ascending: Bool, in tv: NSTableView) {
            let key: String
            switch field {
            case .name: key = "name"
            case .date: key = "date"
            case .size: key = "size"
            }
            guard key != lastSortKey || ascending != lastSortAscending else { return }
            lastSortKey = key
            lastSortAscending = ascending
            suppressSortCallback = true
            tv.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            suppressSortCallback = false
        }

        lazy var operationQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            return q
        }()

        init(_ parent: FileTableNSView) {
            self.parent = parent
            self.tableView = NSTableView()
            super.init()
            tableView.delegate = self
            tableView.dataSource = self
            tableView.target = self
            tableView.doubleAction = #selector(doubleClicked)

            sortKVO = tableView.observe(\.sortDescriptors, options: [.new]) { [weak self] tv, _ in
                guard let self, !self.suppressSortCallback,
                      let first = tv.sortDescriptors.first, let key = first.key else { return }
                let field: SortField
                switch key {
                case "name": field = .name
                case "date": field = .date
                case "size": field = .size
                default: return
                }
                self.lastSortKey = key
                self.lastSortAscending = first.ascending
                self.parent.onSortChange(field, first.ascending)
            }
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.allowsMultipleSelection = true
            tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
            tableView.registerForDraggedTypes(
                NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL]
            )

            let menu = NSMenu()
            let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(newFolderMenuClicked), keyEquivalent: "")
            newFolderItem.target = self
            menu.addItem(newFolderItem)
            menu.addItem(NSMenuItem.separator())
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteMenuClicked), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
            tableView.menu = menu
        }

        @objc func newFolderMenuClicked() {
            DispatchQueue.main.async { self.parent.onCreateFolder() }
        }

        @objc func deleteMenuClicked() {
            let clicked = tableView.clickedRow
            guard clicked >= 0, clicked < flatRows.count else { return }
            let files: [FileItem]
            if tableView.selectedRowIndexes.contains(clicked) {
                files = tableView.selectedRowIndexes.compactMap { row in
                    row < flatRows.count ? flatRows[row].file : nil
                }
            } else {
                files = [flatRows[clicked].file]
            }
            DispatchQueue.main.async { self.parent.onDelete(files) }
        }

        // Rebuild the flat row list from baseFiles, recursively inserting children
        // for every directory whose path is in expandedPaths.
        private func buildFlatRows() -> [FlatRow] {
            var result: [FlatRow] = []
            func add(_ items: [FileItem], depth: Int) {
                for item in items {
                    result.append(FlatRow(file: item, depth: depth))
                    if item.isDirectory,
                       expandedPaths.contains(item.path),
                       let children = childCache[item.path] {
                        add(children, depth: depth + 1)
                    }
                }
            }
            add(baseFiles, depth: 0)
            return result
        }

        func sync(files: [FileItem], selectedIDs: Set<FileItem.ID>, in tv: NSTableView) {
            let changed = files.map(\.id) != baseFiles.map(\.id)
            baseFiles = files
            if changed {
                // Rebuild flat rows (expansion state automatically preserved via expandedPaths/childCache)
                flatRows = buildFlatRows()
                tv.reloadData()
                restoreSelection(selectedIDs, in: tv)
                return
            }
            guard !suppressSelectionCallback else { return }
            let wanted = IndexSet(selectedIDs.compactMap { id in flatRows.firstIndex { $0.file.id == id } })
            if tv.selectedRowIndexes != wanted {
                suppressSelectionCallback = true
                tv.selectRowIndexes(wanted, byExtendingSelection: false)
                if let row = wanted.first { tv.scrollRowToVisible(row) }
                suppressSelectionCallback = false
            }
        }

        private func restoreSelection(_ selectedIDs: Set<FileItem.ID>, in tv: NSTableView) {
            let wanted = IndexSet(selectedIDs.compactMap { id in flatRows.firstIndex { $0.file.id == id } })
            suppressSelectionCallback = true
            tv.selectRowIndexes(wanted, byExtendingSelection: false)
            if let row = wanted.first { tv.scrollRowToVisible(row) }
            suppressSelectionCallback = false
        }

        // Called by NameCell's chevron button.
        func toggleExpansion(for file: FileItem) {
            guard file.isDirectory else { return }
            if expandedPaths.contains(file.path) {
                collapseItem(file)
            } else {
                expandItem(file)
            }
        }

        private func collapseItem(_ file: FileItem) {
            // Remove this dir and all nested expansions under it
            expandedPaths = expandedPaths.filter { path in
                path != file.path && !path.hasPrefix(file.path + "/")
            }
            flatRows = buildFlatRows()
            tableView.reloadData()
        }

        private func expandItem(_ file: FileItem) {
            if let children = childCache[file.path] {
                // Children already cached — expand instantly
                guard !children.isEmpty else { return }
                expandedPaths.insert(file.path)
                flatRows = buildFlatRows()
                tableView.reloadData()
            } else if !loadingPaths.contains(file.path) {
                // Start streaming from device
                loadingPaths.insert(file.path)
                // childCache stays nil during load so isKnownEmpty stays false
                // Refresh the chevron cell to show the loading indicator
                if let row = flatRows.firstIndex(where: { $0.file.id == file.id }) {
                    tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                                         columnIndexes: IndexSet(integer: 0))
                }
                let adbPath = parent.adbPath
                let path = file.path
                let tv = tableView
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for await batch in ADBManager.listDirStream(adbPath, path: path) {
                        guard self.loadingPaths.contains(path) else { break }
                        // Append batch to cache (initialising on first batch)
                        var arr = self.childCache[path] ?? []
                        arr.append(contentsOf: batch)
                        self.childCache[path] = arr
                        // Expand on first non-empty batch so rows appear immediately
                        if !self.expandedPaths.contains(path) {
                            self.expandedPaths.insert(path)
                        }
                        self.flatRows = self.buildFlatRows()
                        tv.reloadData()
                    }
                    // Streaming finished
                    self.loadingPaths.remove(path)
                    if self.childCache[path] == nil {
                        // ls returned nothing at all — mark as empty
                        self.childCache[path] = []
                    }
                    self.flatRows = self.buildFlatRows()
                    tv.reloadData()
                }
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { flatRows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < flatRows.count else { return nil }
            let flatRow = flatRows[row]
            let file = flatRow.file
            switch tableColumn?.identifier.rawValue {
            case "name":
                let cell = dequeue(tableView, id: "name", as: NameCell.self)
                // Only hide the chevron when loading is complete AND the result is empty
                let isKnownEmpty = childCache[file.path]?.isEmpty == true
                                && !loadingPaths.contains(file.path)
                cell.configure(
                    file: file,
                    depth: flatRow.depth,
                    isExpanded: expandedPaths.contains(file.path),
                    isLoading: loadingPaths.contains(file.path),
                    isKnownEmpty: isKnownEmpty
                )
                cell.onToggle = { [weak self] in self?.toggleExpansion(for: file) }
                return cell
            case "date":
                let cell = dequeue(tableView, id: "date", as: TextCell.self)
                cell.label.stringValue = file.displayDate
                cell.label.alignment = .left
                return cell
            case "size":
                let cell = dequeue(tableView, id: "size", as: TextCell.self)
                cell.label.stringValue = file.isDirectory ? "" : file.displaySize
                cell.label.alignment = .right
                return cell
            default:
                return nil
            }
        }

        private func dequeue<T: NSView>(_ tv: NSTableView, id: String, as type: T.Type) -> T {
            let key = NSUserInterfaceItemIdentifier(id)
            if let v = tv.makeView(withIdentifier: key, owner: nil) as? T { return v }
            let v = T(); v.identifier = key; return v
        }

        // MARK: Drag Source — one file promise per selected row

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < flatRows.count else { return nil }
            let file = flatRows[row].file
            guard !file.isDirectory else { return nil }
            let ext = URL(fileURLWithPath: file.name).pathExtension
            let utType = UTType(filenameExtension: ext) ?? .data
            let promise = NSFilePromiseProvider(fileType: utType.identifier, delegate: self)
            promise.userInfo = ["remotePath": file.path, "fileName": file.name, "adbPath": parent.adbPath]
            return promise
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? [String: String])?["fileName"] ?? "file"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            guard let info = filePromiseProvider.userInfo as? [String: String],
                  let remotePath = info["remotePath"],
                  let adbPath = info["adbPath"] else {
                completionHandler(NSError(domain: "transfer", code: -1, userInfo: nil))
                return
            }
            let out = ADBManager.runCommand(adbPath, args: ["pull", remotePath, url.path])
            let ok = out.contains("pulled") || out.contains("file pulled")
            completionHandler(ok ? nil : NSError(domain: "adb", code: -1,
                                                 userInfo: [NSLocalizedDescriptionKey: out]))
        }

        // MARK: Drop Destination (Mac → Android)

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView !== tableView else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let pb = info.draggingPasteboard
            guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            let providers = urls.map { url -> NSItemProvider in
                let p = NSItemProvider()
                p.registerObject(url as NSURL, visibility: .all)
                return p
            }
            return parent.onDrop(providers)
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { row -> FileItem.ID? in
                guard row < flatRows.count else { return nil }
                return flatRows[row].file.id
            })
            suppressSelectionCallback = true
            DispatchQueue.main.async {
                self.parent.selectedFileIDs = ids
                self.suppressSelectionCallback = false
            }
        }

        // MARK: Double Click

        @objc func doubleClicked() {
            let row = tableView.clickedRow
            guard row >= 0, row < flatRows.count else { return }
            let file = flatRows[row].file
            DispatchQueue.main.async {
                if file.isDirectory { self.parent.onNavigate(file) }
                else { self.parent.onPreview(file) }
            }
        }
    }
}

// MARK: - Cell Views

private class NameCell: NSTableCellView {
    private let chevron = NSButton()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var indentConstraint: NSLayoutConstraint!

    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(chevronClicked)

        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        addSubview(chevron)
        addSubview(icon)
        addSubview(label)
        textField = label

        indentConstraint = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            indentConstraint,
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 13),
            chevron.heightAnchor.constraint(equalToConstant: 13),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func chevronClicked() { onToggle?() }

    func configure(file: FileItem, depth: Int, isExpanded: Bool, isLoading: Bool, isKnownEmpty: Bool) {
        indentConstraint.constant = 2 + CGFloat(depth) * 16

        label.stringValue = file.name
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.image = NSImage(systemSymbolName: file.systemIcon, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = NSColor(file.iconColor)

        if file.isDirectory && !isKnownEmpty {
            // Show chevron for directories unless we've loaded and confirmed they're empty
            chevron.isHidden = false
            let symName: String
            if isLoading {
                symName = "ellipsis.circle"
            } else {
                symName = isExpanded ? "chevron.down" : "chevron.right"
            }
            let chevronCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            chevron.image = NSImage(systemSymbolName: symName, accessibilityDescription: nil)?
                .withSymbolConfiguration(chevronCfg)
            chevron.contentTintColor = .tertiaryLabelColor
        } else {
            chevron.isHidden = true
        }
    }
}

private class TextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
