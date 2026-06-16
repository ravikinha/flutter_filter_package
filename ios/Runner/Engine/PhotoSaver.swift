import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers

enum PhotoSaver {
    private static let ciContext = CIContext()

    static func saveJPEG(pixelBuffer: CVPixelBuffer, to path: String,
                         completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
                completion(); return
            }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let type: CFString
            if #available(iOS 14.0, *) { type = UTType.jpeg.identifier as CFString }
            else { type = kUTTypeJPEG }
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, type, 1, nil
            ) else { completion(); return }
            CGImageDestinationAddImage(dest, cg, [
                kCGImageDestinationLossyCompressionQuality: 0.92
            ] as CFDictionary)
            CGImageDestinationFinalize(dest)
            completion()
        }
    }
}
