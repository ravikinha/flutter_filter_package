import Foundation
import Photos

enum GallerySaver {
    static func save(path: String, isVideo: Bool, completion: @escaping (Bool) -> Void) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            completion(false); return
        }
        request { granted in
            guard granted else { completion(false); return }
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }, completionHandler: { ok, _ in completion(ok) })
        }
    }

    private static func request(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 14.0, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                done(status == .authorized || status == .limited)
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                done(status == .authorized)
            }
        }
    }
}
