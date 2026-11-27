import Foundation
import Photos

struct PhotoLibraryImporter: PhotoImporting {
    func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ImportFailure(message: "Photo access denied. Allow adding photos in Settings → Fuji X Open → Photos.")
        }
    }

    static func resourceOptions(originalFilename: String) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = originalFilename
        return options
    }

    func importPhoto(at url: URL, originalFilename: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(
                with: .photo, fileURL: url, options: Self.resourceOptions(originalFilename: originalFilename))
        }
    }
}
