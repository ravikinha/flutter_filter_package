import AVFoundation
import CoreVideo
import Flutter
import Metal
import MetalKit

/// Top-level orchestrator for iOS. Owns:
///  - AVCaptureSession producing CMSampleBuffers
///  - MetalRenderer that converts buffers → CVPixelBuffer used as FlutterTexture
///  - VideoRecorder (AVAssetWriter) that consumes the same rendered buffers.
final class FilterEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let textureId: Int64

    private let textureRegistry: FlutterTextureRegistry
    private let width: Int
    private let height: Int
    private var lensFront: Bool

    private let renderer: MetalRenderer
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "cfe.video")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentInput: AVCaptureDeviceInput?

    private var recorder: VideoRecorder?
    private var pendingPhotoPath: String?
    private var pendingPhotoCallback: ((String) -> Void)?

    private var lastPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    init(
        textureRegistry: FlutterTextureRegistry,
        width: Int,
        height: Int,
        startFront: Bool
    ) throws {
        // Build renderer + register texture using the parameter (not self),
        // so all stored properties are initialized before super.init.
        let r = try MetalRenderer(width: width, height: height)
        let id = textureRegistry.register(r)

        self.textureRegistry = textureRegistry
        self.width = width
        self.height = height
        self.lensFront = startFront
        self.renderer = r
        self.textureId = id
        super.init()

        r.onPixelBufferReady = { [weak self] _ in
            guard let self = self else { return }
            self.textureRegistry.textureFrameAvailable(self.textureId)
            self.handlePostFrame()
        }
    }

    func start() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        try addCameraInput(front: lensFront)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "cfe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "cannot add video output"
            ])
        }
        session.addOutput(output)
        if let conn = output.connection(with: .video) {
            conn.videoOrientation = .portrait
            conn.isVideoMirrored = lensFront
        }
        videoOutput = output

        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func shutdown() {
        if let r = recorder {
            r.stop { _ in }
            recorder = nil
        }
        session.stopRunning()
        textureRegistry.unregisterTexture(textureId)
    }

    private func addCameraInput(front: Bool) throws {
        let pos: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: pos
        ) else {
            throw NSError(domain: "cfe", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no camera for position \(pos.rawValue)"
            ])
        }
        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        if let old = currentInput { session.removeInput(old) }
        guard session.canAddInput(input) else {
            throw NSError(domain: "cfe", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "cannot add camera input"
            ])
        }
        session.addInput(input)
        currentInput = input
    }

    // MARK: - control

    func setFilter(id: String, params: [String: Float]?) {
        renderer.setFilter(id: id, params: params)
    }
    func setParam(key: String, value: Float) {
        renderer.setParam(key: key, value: value)
    }
    func setLut(path: String?) {
        renderer.setLut(path: path)
    }

    func switchCamera() -> Bool {
        lensFront.toggle()
        session.beginConfiguration()
        do { try addCameraInput(front: lensFront) }
        catch { print("switchCamera failed: \(error)") }
        if let conn = videoOutput?.connection(with: .video) {
            conn.videoOrientation = .portrait
            conn.isVideoMirrored = lensFront
        }
        session.commitConfiguration()
        return lensFront
    }

    /// Normalized 0..1 zoom mapped onto the device's usable zoom range
    /// (capped at 6× so the digital crop doesn't get unusably soft).
    func setZoom(level: Float) {
        guard let device = currentInput?.device else { return }
        let clamped = max(0.0, min(1.0, CGFloat(level)))
        let maxUseful = min(device.activeFormat.videoMaxZoomFactor, 6.0)
        let factor = 1.0 + clamped * (maxUseful - 1.0)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
            device.unlockForConfiguration()
        } catch {
            print("setZoom failed: \(error)")
        }
    }

    func takePicture(path: String, callback: @escaping (String) -> Void) {
        pendingPhotoPath = path
        pendingPhotoCallback = callback
    }

    func startRecording(path: String) {
        do {
            let r = try VideoRecorder(path: path, width: width, height: height)
            recorder = r
        } catch {
            print("recorder start failed: \(error)")
        }
    }

    func stopRecording(callback: @escaping (String) -> Void) {
        guard let r = recorder else { callback(""); return }
        r.stop { path in
            self.recorder = nil
            callback(path)
        }
    }

    // MARK: - capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        renderer.render(source: srcBuffer) { [weak self] outBuf in
            guard let self = self, let outBuf = outBuf else { return }
            self.lock.lock()
            self.lastPixelBuffer = outBuf
            self.lock.unlock()
            self.recorder?.append(buffer: outBuf, pts: pts)
        }
    }

    private func handlePostFrame() {
        guard let path = pendingPhotoPath else { return }
        let cb = pendingPhotoCallback
        pendingPhotoPath = nil
        pendingPhotoCallback = nil
        lock.lock()
        let pb = lastPixelBuffer
        lock.unlock()
        if let pb = pb {
            PhotoSaver.saveJPEG(pixelBuffer: pb, to: path) { cb?(path) }
        } else {
            cb?(path)
        }
    }
}
