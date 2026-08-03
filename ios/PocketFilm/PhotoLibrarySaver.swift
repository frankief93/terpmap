import Foundation
import Photos
import UniformTypeIdentifiers

/// Saves captures to the Photos library. Tries HEIC+DNG as a paired asset first;
/// if Photos rejects the pair, falls back to the photo alone, then the DNG as
/// its own asset — a capture should never be lost to a validation error.
enum PhotoLibrarySaver {

    static func save(processedData: Data, rawData: Data?, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false, "Photos access denied. Enable it in Settings > PocketFilm.")
                return
            }
            if let rawData {
                savePaired(processedData: processedData, rawData: rawData) { success, error in
                    if success {
                        completion(true, nil)
                    } else {
                        // Pairing rejected (e.g. PHPhotosErrorDomain 3300): save separately.
                        saveSingle(data: processedData, type: .heic, resourceType: .photo) { photoOK, photoErr in
                            saveSingle(data: rawData, type: .dng, resourceType: .photo) { _, _ in
                                completion(photoOK, photoOK ? nil : (photoErr ?? error))
                            }
                        }
                    }
                }
            } else {
                saveSingle(data: processedData, type: .heic, resourceType: .photo, completion: completion)
            }
        }
    }

    private static func savePaired(processedData: Data, rawData: Data?, completion: @escaping (Bool, String?) -> Void) {
        let stamp = Int(Date().timeIntervalSince1970)
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.uniformTypeIdentifier = UTType.heic.identifier
            photoOptions.originalFilename = "PocketFilm_\(stamp).heic"
            request.addResource(with: .photo, data: processedData, options: photoOptions)
            if let rawData {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.uniformTypeIdentifier = UTType.dng.identifier
                rawOptions.originalFilename = "PocketFilm_\(stamp).dng"
                request.addResource(with: .alternatePhoto, data: rawData, options: rawOptions)
            }
        }) { success, error in
            completion(success, error.map { "Save failed: \($0.localizedDescription)" })
        }
    }

    private static func saveSingle(data: Data, type: UTType,
                                   resourceType: PHAssetResourceType,
                                   completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = type.identifier
            request.addResource(with: resourceType, data: data, options: options)
        }) { success, error in
            completion(success, error.map { "Save failed: \($0.localizedDescription)" })
        }
    }
}
