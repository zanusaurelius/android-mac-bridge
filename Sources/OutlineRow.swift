import SwiftUI

struct OutlineRow: View {
    let file: FileItem
    let adbPath: String
    let onNavigate: (String) -> Void
    let onPreview: (FileItem) -> Void
    @Binding var selectedFileForPreview: FileItem?

    @State private var isExpanded = false
    @State private var children: [FileItem] = []
    @State private var hasLoaded = false
    @State private var isLoading = false

    var body: some View {
        if file.isDirectory {
            DisclosureGroup(isExpanded: expandBinding) {
                if isLoading {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading…").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    ForEach(children) { child in
                        OutlineRow(
                            file: child,
                            adbPath: adbPath,
                            onNavigate: onNavigate,
                            onPreview: onPreview,
                            selectedFileForPreview: $selectedFileForPreview
                        )
                    }
                }
            } label: {
                rowContent
                    .onTapGesture(count: 2) { onNavigate(file.path) }
            }
        } else {
            rowContent
                .onTapGesture(count: 2) { onPreview(file) }
                .onDrag {
                    makeFileItemProvider(
                        adbPath: adbPath,
                        remotePath: file.path,
                        fileName: file.name
                    )
                }
        }
    }

    private var expandBinding: Binding<Bool> {
        Binding(
            get: { isExpanded },
            set: { val in
                isExpanded = val
                if val && !hasLoaded { Task { await loadChildren() } }
            }
        )
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: file.systemIcon)
                .foregroundColor(file.iconColor)
                .frame(width: 18, alignment: .center)

            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(file.displayDate)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 130, alignment: .trailing)

            Text(file.isDirectory ? "" : file.displaySize)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 65, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            selectedFileForPreview = file
        })
    }

    private func loadChildren() async {
        isLoading = true
        let path = file.path
        let adb = adbPath
        let result = await Task.detached {
            ADBManager.listDirFast(adb, path: path)
        }.value
        children = result
        hasLoaded = true
        isLoading = false
    }
}
