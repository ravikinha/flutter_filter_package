import Foundation
import Metal

/// Loads an Adobe .cube 3D LUT into a Metal 3D texture.
enum LutLoader {
    static func load(device: MTLDevice, path: String) -> MTLTexture? {
        let url: URL
        if FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else if let asset = Bundle.main.url(forResource: path, withExtension: nil) {
            url = asset
        } else {
            return nil
        }
        guard let text = try? String(contentsOf: url) else { return nil }
        guard let size = parseSize(text) else { return nil }
        guard let bytes = parseEntries(text, size: size) else { return nil }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba8Unorm
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.mipmapLevelCount = 1
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: size, height: size, depth: size))
        tex.replace(
            region: region, mipmapLevel: 0, slice: 0,
            withBytes: bytes,
            bytesPerRow: size * 4,
            bytesPerImage: size * size * 4
        )
        return tex
    }

    private static func parseSize(_ text: String) -> Int? {
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("LUT_3D_SIZE") {
                let parts = s.split(separator: " ")
                if parts.count >= 2, let n = Int(parts[1]) { return n }
            }
        }
        return nil
    }

    private static func parseEntries(_ text: String, size: Int) -> [UInt8]? {
        let expected = size * size * size
        var out = [UInt8](repeating: 0, count: expected * 4)
        var i = 0
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") || s.hasPrefix("TITLE")
                || s.hasPrefix("LUT_3D_SIZE") || s.hasPrefix("DOMAIN_") { continue }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count < 3 { continue }
            guard let r = Float(parts[0]),
                  let g = Float(parts[1]),
                  let b = Float(parts[2]) else { continue }
            out[i * 4 + 0] = UInt8(max(0, min(1, r)) * 255)
            out[i * 4 + 1] = UInt8(max(0, min(1, g)) * 255)
            out[i * 4 + 2] = UInt8(max(0, min(1, b)) * 255)
            out[i * 4 + 3] = 255
            i += 1
            if i == expected { break }
        }
        return i == expected ? out : nil
    }
}
