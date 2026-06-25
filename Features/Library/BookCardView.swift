import SwiftUI
import UIKit

struct BookCardView: View {
    let book: BookRecord
    let fileStore: BookFileStore
    @State private var coverImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            Text(book.title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(book.displayAuthor)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(book.displayProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.displayAuthor), \(book.displayProgress)")
        .task(id: book.coverRelativePath) {
            await loadCover()
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let coverImage {
            Image(uiImage: coverImage)
                .resizable()
                .scaledToFill()
        } else {
            PlaceholderCoverView(title: book.title)
        }
    }

    private func loadCover() async {
        guard let relativePath = book.coverRelativePath,
              let url = try? await fileStore.resolve(relativePath: relativePath),
              let image = UIImage(contentsOfFile: url.path)
        else {
            coverImage = nil
            return
        }
        coverImage = image
    }
}

struct PlaceholderCoverView: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Text(firstCharacter)
                    .font(.system(size: 42, weight: .semibold, design: .serif))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
        }
    }

    private var firstCharacter: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "?"
    }

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.18, green: 0.32, blue: 0.38), Color(red: 0.68, green: 0.38, blue: 0.22)],
            [Color(red: 0.23, green: 0.40, blue: 0.27), Color(red: 0.72, green: 0.55, blue: 0.20)],
            [Color(red: 0.42, green: 0.22, blue: 0.30), Color(red: 0.20, green: 0.45, blue: 0.54)],
            [Color(red: 0.16, green: 0.25, blue: 0.46), Color(red: 0.62, green: 0.30, blue: 0.38)]
        ]
        return palettes[abs(title.hashValue) % palettes.count]
    }
}

