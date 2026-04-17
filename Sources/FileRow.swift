import SwiftUI

struct FileRow: View {
    let file: FileItem
    let adbPath: String

    var body: some View {
        Group {
            if file.isDirectory {
                rowContent
            } else {
                rowContent
                    .onDrag {
                        makeFileItemProvider(
                            adbPath: adbPath,
                            remotePath: file.path,
                            fileName: file.name
                        )
                    }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: file.systemIcon)
                .foregroundColor(file.iconColor)
                .frame(width: 20, alignment: .center)

            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(file.displayDate)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 130, alignment: .trailing)

            if !file.isDirectory {
                Text(file.displaySize)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(width: 60, alignment: .trailing)
            } else {
                Spacer().frame(width: 60)
            }
        }
        .padding(.vertical, 3)
    }
}
