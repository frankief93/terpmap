import ImageIO
import SwiftUI

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
                            PhotoPage(data: capture.data)
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
                        ShareLink(item: PhotoTransfer(data: current.data),
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

/// One zoomable-later photo page, decoded at display size to keep memory sane.
private struct PhotoPage: View {
    let data: Data
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
            image = await Self.decode(data, maxPixels: 2400)
        }
    }

    private static func decode(_ data: Data, maxPixels: CGFloat) async -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

/// Wraps HEIC data so ShareLink can hand the actual file to the share sheet.
struct PhotoTransfer: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .heic) { $0.data }
            .suggestedFileName("PocketFilm.heic")
    }
}
