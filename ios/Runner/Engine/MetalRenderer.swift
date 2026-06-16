import CoreVideo
import Flutter
import Metal
import MetalKit

/// Renders camera CVPixelBuffer (BGRA or YpCbCr) through the filter pipeline
/// into a BGRA CVPixelBuffer that is exposed to Flutter via FlutterTexture.
final class MetalRenderer: NSObject, FlutterTexture {
    var onPixelBufferReady: ((CVPixelBuffer) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let pipeline: MTLRenderPipelineState

    private let width: Int
    private let height: Int
    private var pixelBufferPool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?

    private var lutTexture: MTLTexture?
    private var lutMix: Float = 0

    private let lock = NSLock()
    private var currentOut: CVPixelBuffer?
    private let startDate = Date()

    private var filterIdx: Int32 = 0
    private var params: [Float] = [0, 0, 0]

    private let textureSampler: MTLSamplerState
    private let lutSampler: MTLSamplerState

    init(width: Int, height: Int) throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "cfe", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "no Metal device"
            ])
        }
        self.device = dev
        guard let q = dev.makeCommandQueue() else {
            throw NSError(domain: "cfe", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "no command queue"
            ])
        }
        self.commandQueue = q
        self.library = try dev.makeDefaultLibrary(bundle: Bundle.main)
        self.width = width
        self.height = height

        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = library.makeFunction(name: "fsq_vs")
        pdesc.fragmentFunction = library.makeFunction(name: "filter_fs")
        pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try dev.makeRenderPipelineState(descriptor: pdesc)

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        guard let s = dev.makeSamplerState(descriptor: sdesc) else {
            throw NSError(domain: "cfe", code: 12, userInfo: nil)
        }
        self.textureSampler = s

        let lsdesc = MTLSamplerDescriptor()
        lsdesc.minFilter = .linear
        lsdesc.magFilter = .linear
        lsdesc.sAddressMode = .clampToEdge
        lsdesc.tAddressMode = .clampToEdge
        lsdesc.rAddressMode = .clampToEdge
        guard let ls = dev.makeSamplerState(descriptor: lsdesc) else {
            throw NSError(domain: "cfe", code: 13, userInfo: nil)
        }
        self.lutSampler = ls

        super.init()
        try buildPool()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    private func buildPool() throws {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        if status != kCVReturnSuccess {
            throw NSError(domain: "cfe", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "pool create \(status)"
            ])
        }
        self.pixelBufferPool = pool
    }

    // MARK: - controls

    func setFilter(id: String, params: [String: Float]?) {
        filterIdx = filterIndex(for: id)
        self.params = [0, 0, 0]
        if let p = params { applyParams(id: id, p: p) }
    }

    func setParam(key: String, value: Float) {
        switch key {
        case "warmth", "sepiaStrength", "rgbOffset", "glitchAmount",
             "blurRadius", "tealStrength", "coolness", "glowIntensity",
             "grainIntensity":
            params[0] = value
        case "contrast", "vignetteStrength", "fade", "scanlineIntensity",
             "distortionAmount", "orangeStrength", "bloomRadius":
            params[1] = value
        case "saturation", "lightLeakStrength", "noiseIntensity":
            params[2] = value
        default: break
        }
    }

    func setLut(path: String?) {
        guard let path = path else {
            lutTexture = nil
            lutMix = 0
            return
        }
        if let tex = LutLoader.load(device: device, path: path) {
            lutTexture = tex
            lutMix = 1
        }
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        guard let pb = currentOut else { return nil }
        return Unmanaged.passRetained(pb)
    }

    // MARK: - render

    func render(source: CVPixelBuffer, completion: @escaping (CVPixelBuffer?) -> Void) {
        guard let pool = pixelBufferPool,
              let cache = textureCache else { completion(nil); return }

        // Source CVPixelBuffer → Metal texture (BGRA path; YCbCr is auto-converted
        // because the capture session here is set to BGRA-friendly format; if you
        // switch to YpCbCr the cache returns two planes — we keep BGRA for brevity).
        var srcMtlRef: CVMetalTexture?
        let w = CVPixelBufferGetWidth(source)
        let h = CVPixelBufferGetHeight(source)
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, source, nil, .bgra8Unorm, w, h, 0, &srcMtlRef
        )
        guard let srcRef = srcMtlRef,
              let srcTex = CVMetalTextureGetTexture(srcRef) else {
            completion(nil); return
        }

        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let outPB = outBuffer else { completion(nil); return }
        var outMtlRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, outPB, nil, .bgra8Unorm, width, height, 0, &outMtlRef
        )
        guard let outRef = outMtlRef,
              let outTex = CVMetalTextureGetTexture(outRef) else {
            completion(nil); return
        }

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = outTex
        rpDesc.colorAttachments[0].loadAction = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpDesc) else {
            completion(nil); return
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(srcTex, index: 0)
        if let lut = lutTexture {
            enc.setFragmentTexture(lut, index: 1)
        }
        enc.setFragmentSamplerState(textureSampler, index: 0)
        enc.setFragmentSamplerState(lutSampler, index: 1)

        var u = Uniforms(
            time: Float(Date().timeIntervalSince(startDate)),
            resolution: SIMD2<Float>(Float(width), Float(height)),
            filterIdx: filterIdx,
            lutMix: lutMix,
            p0: params[0], p1: params[1], p2: params[2]
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        // The CVMetalTexture refs must outlive the GPU work — the MTLTexture
        // they back is owned by the ref, not by the texture cache. Capturing
        // them in the completion handler keeps them retained until the GPU
        // has finished sampling.
        let srcHold = srcRef
        let outHold = outRef
        cmd.addCompletedHandler { [weak self] _ in
            _ = (srcHold, outHold) // keep alive across GPU work
            guard let self = self else { return }
            self.lock.lock()
            self.currentOut = outPB
            self.lock.unlock()
            self.onPixelBufferReady?(outPB)
            completion(outPB)
        }
        cmd.commit()
    }

    // MARK: - helpers

    private func filterIndex(for id: String) -> Int32 {
        switch id {
        case "kodak": return 1
        case "vintage": return 2
        case "retro": return 3
        case "grain": return 4
        case "vhs": return 5
        case "bwGlitch": return 6
        case "blur": return 7
        case "cinematic": return 8
        case "coolBlue": return 9
        case "dreamGlow": return 10
        default: return 0
        }
    }

    private func applyParams(id: String, p: [String: Float]) {
        params = [0, 0, 0]
        switch id {
        case "kodak":
            params[0] = p["warmth"] ?? 0
            params[1] = p["contrast"] ?? 0
            params[2] = p["saturation"] ?? 0
        case "vintage":
            params[0] = p["sepiaStrength"] ?? 0
            params[1] = p["vignetteStrength"] ?? 0
        case "retro":
            params[0] = p["warmth"] ?? 0
            params[1] = p["fade"] ?? 0
            params[2] = p["lightLeakStrength"] ?? 0
        case "grain":
            params[0] = p["grainIntensity"] ?? 0
        case "vhs":
            params[0] = p["rgbOffset"] ?? 0
            params[1] = p["scanlineIntensity"] ?? 0
            params[2] = p["noiseIntensity"] ?? 0
        case "bwGlitch":
            params[0] = p["glitchAmount"] ?? 0
            params[1] = p["distortionAmount"] ?? 0
        case "blur":
            params[0] = p["blurRadius"] ?? 0
        case "cinematic":
            params[0] = p["tealStrength"] ?? 0
            params[1] = p["orangeStrength"] ?? 0
            params[2] = p["contrast"] ?? 0
        case "coolBlue":
            params[0] = p["coolness"] ?? 0
            params[1] = p["contrast"] ?? 0
        case "dreamGlow":
            params[0] = p["glowIntensity"] ?? 0
            params[1] = p["bloomRadius"] ?? 0
        default: break
        }
    }
}

private struct Uniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var filterIdx: Int32
    var lutMix: Float
    var p0: Float
    var p1: Float
    var p2: Float
}
