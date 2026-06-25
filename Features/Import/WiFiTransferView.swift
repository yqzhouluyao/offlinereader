import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct WiFiTransferView: View {
    let container: AppContainer
    let onOpenBook: (UUID) -> Void
    @State private var viewModel: WiFiTransferViewModel

    init(container: AppContainer, onOpenBook: @escaping (UUID) -> Void) {
        self.container = container
        self.onOpenBook = onOpenBook
        _viewModel = State(initialValue: WiFiTransferViewModel(container: container))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("wifi.title")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .requestingPermission, .starting:
            VStack(spacing: 18) {
                ProgressView()
                Text("wifi.starting")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .ready(let url, let expiresAt):
            readyView(url: url, expiresAt: expiresAt)
        case .receiving(let fileName, let progress):
            transferProgress(title: fileName, subtitle: "wifi.receiving", progress: progress)
        case .importing(let fileName):
            transferProgress(title: fileName, subtitle: "wifi.importing", progress: 1)
        case .succeeded(let bookID, let title):
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text(String(localized: "wifi.succeeded \(title)"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("wifi.open_book") {
                    onOpenBook(bookID)
                }
                .buttonStyle(.borderedProminent)
                Button("wifi.continue_transfer") {
                    viewModel.restart()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message, let recoverable):
            ContentUnavailableView {
                Label("wifi.failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if recoverable {
                    Button("common.retry") {
                        viewModel.restart()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private func readyView(url: URL, expiresAt: Date) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("wifi.permission_note")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                QRCodeView(text: url.absoluteString)
                    .frame(width: 220, height: 220)
                    .padding(.vertical, 8)
                Text(url.absoluteString)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("wifi.copy_url", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Text("wifi.keep_open")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(expiresAt, style: .timer)
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel(Text("wifi.time_remaining"))
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private func transferProgress(title: String, subtitle: LocalizedStringKey, progress: Double) -> some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .foregroundStyle(.secondary)
            ProgressView(value: progress.clamped(to: 0 ... 1))
                .frame(maxWidth: 360)
            Text(progress.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QRCodeView: View {
    let text: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(Text("wifi.qr_code"))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.12))
                .overlay {
                    Image(systemName: "qrcode")
                }
        }
    }

    private var image: UIImage? {
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage else {
            return nil
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

