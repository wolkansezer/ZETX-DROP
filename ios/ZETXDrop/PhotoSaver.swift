import Foundation
import Photos

enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Fotoğraflar'a erişim izni yok. Ayarlar → ZETX DROP → Fotoğraflar → \"Yalnızca Ekle\" seçin."
        }
    }

    /// Saves an image or video straight into the Photos library (add-only permission).
    static func save(_ url: URL) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        let isVideo = FileKind.isVideo(url.lastPathComponent)
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = url.lastPathComponent
            req.addResource(with: isVideo ? .video : .photo, fileURL: url, options: opts)
        }
    }
}
