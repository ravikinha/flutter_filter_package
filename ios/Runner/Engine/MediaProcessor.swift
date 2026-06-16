import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UIKit

/// One-shot pipeline that runs an existing on-disk image or video through the
/// same Metal filter shader the camera uses, then writes the result to disk.
///
/// The renderer is NOT registered with Flutter's texture cache (this isn't a
/// preview), so it can be created and torn down per-job without colliding with
/// the live camera renderer.
enum MediaProcessor {

    // MARK: - Image

    static func processImage(
        inputPath: String,
        outputPath: String,
        filterId: String,
        params: [String: Float]?,
        lutPath: String?
    ) throws -> String {
        guard let image = UIImage(contentsOfFile: inputPath),
              let cg = image.cgImage else {
            throw NSError(domain: "cfe", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "cannot decode image at \(inputPath)"
            ])
        }
        // Bake EXIF orientation into the pixels so the saved file isn't
        // rotated incorrectly.
        let upright = normalize(image: image, cgImage: cg)
        let w = upright.width
        let h = upright.height

        guard let srcBuffer = pixelBuffer(from: upright, width: w, height: h) else {
            throw NSError(domain: "cfe", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "pixel buffer from CGImage failed"
            ])
        }

        let renderer = try MetalRenderer(width: w, height: h)
        renderer.setFilter(id: filterId, params: params)
        if let lutPath = lutPath { renderer.setLut(path: lutPath) }

        let sem = DispatchSemaphore(value: 0)
        var out: CVPixelBuffer?
        renderer.render(source: srcBuffer) { buf in
            out = buf
            sem.signal()
        }
        sem.wait()
        guard let outBuf = out else {
            throw NSError(domain: "cfe", code: 102, userInfo: [
                NSLocalizedDescriptionKey: "render returned no buffer"
            ])
        }

        try writeJpeg(pixelBuffer: outBuf, to: outputPath)
        return outputPath
    }

    private static func normalize(image: UIImage, cgImage: CGImage) -> CGImage {
        if image.imageOrientation == .up { return cgImage }
        UIGraphicsBeginImageContextWithOptions(image.size, false, 1)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let upright = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return upright?.cgImage ?? cgImage
    }

    private static func pixelBuffer(from cg: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                     | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buf
    }

    private static func writeJpeg(pixelBuffer: CVPixelBuffer, to path: String) throws {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else {
            throw NSError(domain: "cfe", code: 110, userInfo: [
                NSLocalizedDescriptionKey: "CGImage from pixelbuffer failed"
            ])
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw NSError(domain: "cfe", code: 111, userInfo: nil)
        }
        CGImageDestinationAddImage(dest, cg, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Crop (image)

    /// Crop the image at [inputPath] to the normalised rect
    /// (left, top, right, bottom) in 0..1 of the EXIF-uprighted image and
    /// write a JPEG to [outputPath]. Lossless within the crop window — no
    /// re-scale of the kept pixels.
    static func cropImage(
        inputPath: String,
        outputPath: String,
        left: Double, top: Double, right: Double, bottom: Double,
        flipH: Bool = false, flipV: Bool = false
    ) throws -> String {
        guard let image = UIImage(contentsOfFile: inputPath),
              let cg = image.cgImage else {
            throw NSError(domain: "cfe", code: 130, userInfo: [
                NSLocalizedDescriptionKey: "cannot decode image"
            ])
        }
        let upright = normalize(image: image, cgImage: cg)
        let w = CGFloat(upright.width)
        let h = CGFloat(upright.height)
        var l = max(0, left * Double(w))
        var t = max(0, top * Double(h))
        var r = min(Double(w), right * Double(w))
        var b = min(Double(h), bottom * Double(h))
        if r - l < 1 { r = l + 1 }
        if b - t < 1 { b = t + 1 }
        let rect = CGRect(
            x: CGFloat(l).rounded(.down),
            y: CGFloat(t).rounded(.down),
            width: CGFloat(r - l).rounded(.down),
            height: CGFloat(b - t).rounded(.down)
        )
        guard let cropped = upright.cropping(to: rect) else {
            throw NSError(domain: "cfe", code: 131, userInfo: [
                NSLocalizedDescriptionKey: "cropping failed"
            ])
        }
        var finalImage = cropped
        if flipH || flipV {
            let cw = cropped.width
            let ch = cropped.height
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: cw, height: ch,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw NSError(domain: "cfe", code: 133, userInfo: [
                    NSLocalizedDescriptionKey: "cgcontext flip failed"
                ])
            }
            // Apply each flip by mirroring on that axis.
            ctx.translateBy(x: flipH ? CGFloat(cw) : 0,
                            y: flipV ? CGFloat(ch) : 0)
            ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            if let flipped = ctx.makeImage() {
                finalImage = flipped
            }
        }
        try writeJpeg(cgImage: finalImage, to: outputPath, quality: 0.95)
        return outputPath
    }

    /// Crop + optional flip a video losslessly-as-much-as-possible. Uses
    /// AVMutableVideoComposition to define a render size matching the crop
    /// rect, with a transform that translates the cropped region to the
    /// output origin and mirrors on the requested axes. Audio is preserved
    /// (passthrough), and the source's preferredTransform is composed in so
    /// the output is upright.
    static func cropVideo(
        inputPath: String,
        outputPath: String,
        left: Double, top: Double, right: Double, bottom: Double,
        flipH: Bool = false, flipV: Bool = false
    ) throws -> String {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: inputURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "cfe", code: 150, userInfo: [
                NSLocalizedDescriptionKey: "no video track"
            ])
        }
        // Display-space dimensions (after orientation).
        let natural = track.naturalSize
        let xf = track.preferredTransform
        let displaySize = natural.applying(xf)
        let displayW = abs(displaySize.width)
        let displayH = abs(displaySize.height)
        // Crop rect in display pixels.
        let cropX = max(0.0, left * Double(displayW))
        let cropY = max(0.0, top  * Double(displayH))
        let cropW = max(2.0, (right - left) * Double(displayW))
        let cropH = max(2.0, (bottom - top) * Double(displayH))
        let outSize = CGSize(width: CGFloat(cropW).rounded(.down),
                             height: CGFloat(cropH).rounded(.down))

        let composition = AVMutableVideoComposition()
        composition.renderSize = outSize
        let nominal = track.nominalFrameRate
        composition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(nominal > 0 ? Int32(nominal.rounded()) : 30)
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // Compose: source preferred transform → translate so crop top-left
        // lands at the output origin → flip if requested.
        var t = xf
        t = t.concatenating(
            CGAffineTransform(translationX: -CGFloat(cropX), y: -CGFloat(cropY))
        )
        if flipH {
            // Mirror on output X axis around output width.
            t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            t = t.concatenating(CGAffineTransform(translationX: outSize.width, y: 0))
        }
        if flipV {
            t = t.concatenating(CGAffineTransform(scaleX: 1, y: -1))
            t = t.concatenating(CGAffineTransform(translationX: 0, y: outSize.height))
        }
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "cfe", code: 151, userInfo: [
                NSLocalizedDescriptionKey: "exporter init failed"
            ])
        }
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = composition
        exporter.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { sem.signal() }
        sem.wait()

        switch exporter.status {
        case .completed: return outputPath
        case .failed, .cancelled:
            throw exporter.error ?? NSError(domain: "cfe", code: 152, userInfo: [
                NSLocalizedDescriptionKey: "crop export \(exporter.status.rawValue)"
            ])
        default:
            throw NSError(domain: "cfe", code: 153, userInfo: [
                NSLocalizedDescriptionKey: "crop export did not finish"
            ])
        }
    }

    private static func writeJpeg(cgImage cg: CGImage, to path: String, quality: Float) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw NSError(domain: "cfe", code: 132, userInfo: nil)
        }
        CGImageDestinationAddImage(dest, cg, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Compose (overlay PNG onto every frame)

    /// Composite a transparent PNG onto every frame of the video. The overlay
    /// is rendered through AVFoundation's animation tool, so it lives in
    /// *display orientation* (post-preferred-transform). The caller renders
    /// the PNG at display dimensions and AVFoundation places it 1:1 over the
    /// uprighted video frames. Audio is preserved.
    static func composeVideo(
        inputPath: String,
        outputPath: String,
        overlayPngPath: String
    ) throws -> String {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: inputURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "cfe", code: 160, userInfo: [
                NSLocalizedDescriptionKey: "no video track"
            ])
        }
        let natural = track.naturalSize
        let xf = track.preferredTransform
        let display = natural.applying(xf)
        let renderSize = CGSize(
            width: abs(display.width).rounded(.down),
            height: abs(display.height).rounded(.down)
        )

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        let nominal = track.nominalFrameRate
        composition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(nominal > 0 ? Int32(nominal.rounded()) : 30)
        )

        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // The preferredTransform alone lays the source upright into the
        // renderSize; no further translate/scale needed for compose.
        layer.setTransform(xf, at: .zero)
        instr.layerInstructions = [layer]
        composition.instructions = [instr]

        // Overlay layer.
        guard let overlayImage = UIImage(contentsOfFile: overlayPngPath),
              let overlayCG = overlayImage.cgImage else {
            throw NSError(domain: "cfe", code: 161, userInfo: [
                NSLocalizedDescriptionKey: "cannot load overlay"
            ])
        }
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        let overlayLayer = CALayer()
        overlayLayer.frame = parent.frame
        overlayLayer.contents = overlayCG
        overlayLayer.contentsGravity = .resize
        overlayLayer.masksToBounds = true
        // Core Animation flips Y vs. the video render space — when the tool
        // composes, the overlay's bottom corresponds to the video's top.
        // Pre-flip the layer's geometry so the user sees what they drew.
        overlayLayer.transform = CATransform3DScale(CATransform3DIdentity, 1, -1, 1)
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlayLayer)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent
        )

        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "cfe", code: 162, userInfo: [
                NSLocalizedDescriptionKey: "exporter init failed"
            ])
        }
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = composition
        exporter.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { sem.signal() }
        sem.wait()
        switch exporter.status {
        case .completed: return outputPath
        case .failed, .cancelled:
            throw exporter.error ?? NSError(domain: "cfe", code: 163, userInfo: [
                NSLocalizedDescriptionKey: "compose export \(exporter.status.rawValue)"
            ])
        default:
            throw NSError(domain: "cfe", code: 164, userInfo: [
                NSLocalizedDescriptionKey: "compose export did not finish"
            ])
        }
    }

    // MARK: - Trim (video, passthrough)

    /// Trim the video at [inputPath] to [startMs..endMs] using
    /// AVAssetExportSession with the passthrough preset, so video + audio
    /// are copied bit-identical with the source's orientation flag intact.
    static func trimVideo(
        inputPath: String,
        outputPath: String,
        startMs: Int64,
        endMs: Int64
    ) throws -> String {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: inputURL)
        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else {
            throw NSError(domain: "cfe", code: 140, userInfo: [
                NSLocalizedDescriptionKey: "exporter init failed"
            ])
        }
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        let durationMs = Int64(CMTimeGetSeconds(asset.duration) * 1000.0)
        let s = max(0, min(startMs, durationMs - 1))
        let e = max(s + 1, min(endMs, durationMs))
        let start = CMTime(value: s, timescale: 1000)
        let dur = CMTime(value: e - s, timescale: 1000)
        exporter.timeRange = CMTimeRange(start: start, duration: dur)

        let sem = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { sem.signal() }
        sem.wait()

        switch exporter.status {
        case .completed:
            return outputPath
        case .failed, .cancelled:
            throw exporter.error ?? NSError(domain: "cfe", code: 141, userInfo: [
                NSLocalizedDescriptionKey: "trim export \(exporter.status.rawValue)"
            ])
        default:
            throw NSError(domain: "cfe", code: 142, userInfo: [
                NSLocalizedDescriptionKey: "trim export did not finish"
            ])
        }
    }

    // MARK: - Preview (single frame, shader-accurate)

    /// For images: same as processImage.
    /// For videos: extract a frame near [atSeconds] and run it through the
    /// shader, so the user sees the real blur/glitch/grain effect on a
    /// representative frame before they commit to processing the whole clip.
    static func previewFilter(
        inputPath: String,
        outputPath: String,
        filterId: String,
        params: [String: Float]?,
        lutPath: String?,
        isVideo: Bool,
        atSeconds: Double
    ) throws -> String {
        if !isVideo {
            return try processImage(
                inputPath: inputPath, outputPath: outputPath,
                filterId: filterId, params: params, lutPath: lutPath
            )
        }
        // Extract a frame at the requested time. Cap to clip duration so very
        // short videos don't fail.
        let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
        let duration = CMTimeGetSeconds(asset.duration)
        let t = max(0.0, min(atSeconds, max(0.0, duration - 0.1)))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true   // bake EXIF/track rotation
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let cg = try gen.copyCGImage(
            at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil
        )
        // Write the raw frame to a sibling .pre.jpg so the existing image
        // pipeline can re-decode it into a CVPixelBuffer.
        let frameURL = URL(fileURLWithPath: outputPath)
            .deletingPathExtension()
            .appendingPathExtension("frame.jpg")
        try writeCGImageAsJpeg(cg, to: frameURL.path)
        defer { try? FileManager.default.removeItem(at: frameURL) }
        return try processImage(
            inputPath: frameURL.path, outputPath: outputPath,
            filterId: filterId, params: params, lutPath: lutPath
        )
    }

    private static func writeCGImageAsJpeg(_ cg: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw NSError(domain: "cfe", code: 120, userInfo: nil)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Cancellation

    /// Toggleable flag handed to processVideo; setting it true bails the
    /// pipeline out at the next chunk boundary.
    final class CancelFlag {
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _cancelled }
            set { lock.lock(); defer { lock.unlock() }; _cancelled = newValue }
        }
    }

    struct CancelledError: Error {}

    // MARK: - Video

    static func processVideo(
        inputPath: String,
        outputPath: String,
        filterId: String,
        params: [String: Float]?,
        lutPath: String?,
        progress: @escaping (Double) -> Void,
        cancel: CancelFlag = CancelFlag()
    ) throws -> String {
        let inputURL = URL(fileURLWithPath: inputPath)
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "cfe", code: 200, userInfo: [
                NSLocalizedDescriptionKey: "no video track"
            ])
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first

        // Preferred transform encodes EXIF-like rotation. Apply it so saved
        // video is upright regardless of how the source was recorded.
        let natural = videoTrack.naturalSize
        let xf = videoTrack.preferredTransform
        let rotatedSize = natural.applying(xf)
        let outW = Int(abs(rotatedSize.width).rounded())
        let outH = Int(abs(rotatedSize.height).rounded())
        let targetBitrate: Int = 8_000_000

        // Reader
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let at = audioTrack {
            let o = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            reader.add(o)
            audioOutput = o
        }

        // Writer
        let outURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // We bake rotation into pixels via the renderer's source, so no
        // additional transform on the writer input.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH,
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let at = audioTrack {
            // Passthrough — reader outputs the source's compressed samples and
            // the writer accepts them as-is. mp4 passthrough requires a
            // sourceFormatHint so the muxer knows the codec/sample-rate ahead
            // of the first sample.
            let fmt = (at.formatDescriptions.first as! CMFormatDescription?)
            let ai = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: fmt
            )
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            audioInput = ai
        }

        let renderer = try MetalRenderer(width: outW, height: outH)
        renderer.setFilter(id: filterId, params: params)
        if let lutPath = lutPath { renderer.setLut(path: lutPath) }

        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)

        let durationSec = CMTimeGetSeconds(asset.duration)
        let videoQueue = DispatchQueue(label: "cfe.proc.video")
        let audioQueue = DispatchQueue(label: "cfe.proc.audio")
        let group = DispatchGroup()

        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if cancel.cancelled {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard let sample = videoOutput.copyNextSampleBuffer(),
                      let src = CMSampleBufferGetImageBuffer(sample) else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)

                // Apply rotation so the source fed to the shader is already
                // upright. We use Core Image to apply the preferred transform
                // before handing the buffer to Metal.
                let uprightBuf = rotated(srcBuffer: src, transform: xf,
                                         outWidth: outW, outHeight: outH)
                let bufToRender = uprightBuf ?? src

                let sem = DispatchSemaphore(value: 0)
                var out: CVPixelBuffer?
                renderer.render(source: bufToRender) { rendered in
                    out = rendered
                    sem.signal()
                }
                sem.wait()
                if let o = out { _ = adaptor.append(o, withPresentationTime: pts) }

                let p = max(0.0, min(1.0, CMTimeGetSeconds(pts) / max(durationSec, 0.001)))
                DispatchQueue.main.async { progress(p) }
            }
        }

        if let ai = audioInput, let ao = audioOutput {
            group.enter()
            ai.requestMediaDataWhenReady(on: audioQueue) {
                while ai.isReadyForMoreMediaData {
                    if cancel.cancelled {
                        ai.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sample = ao.copyNextSampleBuffer() else {
                        ai.markAsFinished()
                        group.leave()
                        return
                    }
                    ai.append(sample)
                }
            }
        }

        let waitSem = DispatchSemaphore(value: 0)
        group.notify(queue: .global()) {
            writer.finishWriting {
                waitSem.signal()
            }
        }
        waitSem.wait()
        if cancel.cancelled {
            try? FileManager.default.removeItem(atPath: outputPath)
            throw CancelledError()
        }
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "cfe", code: 201, userInfo: [
                NSLocalizedDescriptionKey: "writer failed"
            ])
        }
        DispatchQueue.main.async { progress(1.0) }
        return outputPath
    }

    private static let ciContext = CIContext()

    /// Apply the video track's preferredTransform to a buffer so the renderer
    /// always sees an upright frame.
    private static func rotated(srcBuffer: CVPixelBuffer, transform: CGAffineTransform,
                                outWidth: Int, outHeight: Int) -> CVPixelBuffer? {
        if transform == .identity { return srcBuffer }

        let src = CIImage(cvPixelBuffer: srcBuffer)
        // Move into output space.
        let srcW = src.extent.width
        let srcH = src.extent.height
        var ci = src
        ci = ci.transformed(by: transform)
        // Re-anchor to (0,0).
        let tx = -ci.extent.origin.x
        let ty = -ci.extent.origin.y
        ci = ci.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        _ = (srcW, srcH)

        var out: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, outWidth, outHeight, kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            &out
        )
        guard let target = out else { return nil }
        ciContext.render(ci, to: target)
        return target
    }
}
