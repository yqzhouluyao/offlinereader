import SwiftUI

struct EmptyLibraryView: View {
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "books.vertical")
        } description: {
            Text("library.empty.description")
        } actions: {
            Button(action: onImport) {
                Label("library.empty.import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

