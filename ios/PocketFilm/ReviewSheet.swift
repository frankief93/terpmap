import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Swipeable gallery of every photo taken this session. All shots are already
/// saved to the Photos library the moment they're taken — this is a quick look.
struct ReviewSheet: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    private var current: CameraManager.Capture? {
        camera.captures.first { $0.id == selection } ?? camera.captures.last
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if camera.captures.isEmpty {
                    Text("No photos this session").foregroundStyle(.secondary)
                } else {
                    TabView(selection: $selection) {
                        ForEach(camera.captures) { capture in
                            PhotoPage(url: capture.url)
                                .tag(Optional(capture.id))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if let current, let index = camera.captures.firstIndex(where: { $0.id == current.id }) {
                        Text("\(index + 1) of \(camera.captures.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let current {
                        ShareLink(item: PhotoTransfer(url: current.url),
                                  preview: SharePreview("PocketFilm photo",
                                                        image: Image(uiImage: current.thumbnail)))
                    }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { selection = camera.captures.last?.id }
    }
}

/// One photo page, decoded from its temp file at display size to keep memory sane.
private struct PhotoPage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            image = await Self.decode(url, maxPixels: 2400)
        }
    }

    private static func decode(_ url: URL, maxPixels: CGFloat) async -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Hands the HEIC file itself to the share sheet.
struct PhotoTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .heic) { SentTransferredFile($0.url) }
            .suggestedFileName("PocketFilm.heic")
    }
}
