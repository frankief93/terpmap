import Foundation
import Photos

/// Saves captures to the Photos library, pairing the styled HEIF with its DNG when present.
enum PhotoLibrarySaver {

    static func save(processedData: Data, rawData: Data?, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false, "Photos access denied. Enable it in Settings > PocketFilm.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                request.addResource(with: .photo, data: processedData, options: options)
                if let rawData {
                    let rawOptions = PHAssetResourceCreationOptions()
                    rawOptions.originalFilename = "PocketFilm_\(Int(Date().timeIntervalSince1970)).dng"
                    request.addResource(with: .alternatePhoto, data: rawData, options: rawOptions)
                }
            }) { success, error in
                completion(success, error?.localizedDescription)
            }
        }
    }
}
