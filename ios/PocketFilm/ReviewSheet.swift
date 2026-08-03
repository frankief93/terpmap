import SwiftUI

/// Full-screen viewer for the most recent capture. Photos are already saved
/// to the library automatically; this adds share and a quick zoom look.
struct ReviewSheet: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image = camera.lastPhoto {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                } else {
                    Text("No photo yet").foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let data = camera.lastPhotoData {
                        ShareLink(item: PhotoTransfer(data: data),
                                  preview: SharePreview("PocketFilm photo",
                                                        image: Image(uiImage: camera.lastPhoto ?? UIImage())))
                    }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
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
