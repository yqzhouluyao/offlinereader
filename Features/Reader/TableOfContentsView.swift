import SwiftUI

struct TableOfContentsView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [TableOfContentsItem]
    let onSelect: (TableOfContentsItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("reader.toc.empty", systemImage: "list.bullet")
                } else {
                    List(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            Text(item.title)
                                .padding(.leading, CGFloat(item.depth) * 18)
                        }
                    }
                }
            }
            .navigationTitle("reader.toc")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                }
            }
        }
    }
}

