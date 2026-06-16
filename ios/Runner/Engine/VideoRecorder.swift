import AVFoundation
import CoreMedia
import CoreVideo

/// Encodes filtered CVPixelBuffers (BGRA) to an H.264 .mp4 via AVAssetWriter.
final class VideoRecorder {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "cfe.recorder")
    private var sessionStarted = false
    private var firstPTS: CMTime?
    private(set) var path: String

    init(path: String, width: Int, height: Int) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "cfe", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot add video input"
            ])
        }
        writer.add(videoInput)
        writer.startWriting()
    }

    func append(buffer: CVPixelBuffer, pts: CMTime) {
        queue.async { [weak self] in
            guard let self = self,
                  self.writer.status == .writing,
                  self.videoInput.isReadyForMoreMediaData else { return }
            if !self.sessionStarted {
                self.writer.startSession(atSourceTime: pts)
                self.firstPTS = pts
                self.sessionStarted = true
            }
            _ = self.adaptor.append(buffer, withPresentationTime: pts)
        }
    }

    func stop(completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { completion(""); return }
            self.videoInput.markAsFinished()
            self.writer.finishWriting {
                completion(self.path)
            }
        }
    }
}
