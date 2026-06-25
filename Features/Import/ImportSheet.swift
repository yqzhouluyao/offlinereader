import SwiftUI

struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onFiles: () -> Void
    let onWiFi: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onFiles()
                } label: {
                    Label("import.files", systemImage: "folder")
                }
                Button {
                    onWiFi()
                } label: {
                    Label("import.wifi", systemImage: "wifi")
                }
                Section {
                    Text("import.supported_formats")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("import.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

