import Flutter
import UIKit

public class CameraFilterEnginePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private weak var registrar: FlutterPluginRegistrar?
    private var engine: FilterEngine?
    private var progressSink: FlutterEventSink?
    private var currentVideoCancel: MediaProcessor.CancelFlag?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "camera_filter_engine",
            binaryMessenger: registrar.messenger()
        )
        let instance = CameraFilterEnginePlugin()
        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)

        let events = FlutterEventChannel(
            name: "camera_filter_engine/progress",
            binaryMessenger: registrar.messenger()
        )
        events.setStreamHandler(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        progressSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        progressSink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "initialize":
            initialize(args: args, result: result)
        case "dispose":
            engine?.shutdown()
            engine = nil
            result(nil)
        case "setFilter":
            let id = args["id"] as? String ?? "none"
            let params = (args["params"] as? [String: NSNumber])?
                .mapValues { $0.floatValue }
            engine?.setFilter(id: id, params: params)
            result(nil)
        case "setParam":
            if let k = args["key"] as? String,
               let v = (args["value"] as? NSNumber)?.floatValue {
                engine?.setParam(key: k, value: v)
            }
            result(nil)
        case "setLut":
            engine?.setLut(path: args["path"] as? String)
            result(nil)
        case "switchCamera":
            let front = engine?.switchCamera() ?? false
            result(front ? "front" : "back")
        case "setZoom":
            let level = (args["level"] as? NSNumber)?.floatValue ?? 0
            engine?.setZoom(level: level)
            result(nil)
        case "takePicture":
            if let path = args["path"] as? String {
                engine?.takePicture(path: path) { saved in result(saved) }
            } else {
                result(FlutterError(code: "ARG", message: "path required", details: nil))
            }
        case "startRecording":
            if let path = args["path"] as? String {
                engine?.startRecording(path: path)
            }
            result(nil)
        case "stopRecording":
            engine?.stopRecording { path in result(path) }
        case "saveToGallery":
            let path = args["path"] as? String ?? ""
            let isVideo = (args["isVideo"] as? Bool) ?? false
            GallerySaver.save(path: path, isVideo: isVideo) { ok in
                DispatchQueue.main.async { result(ok) }
            }
        case "processImage":
            processImage(args: args, result: result)
        case "processVideo":
            processVideo(args: args, result: result)
        case "previewFilter":
            previewFilter(args: args, result: result)
        case "cropImage":
            cropImage(args: args, result: result)
        case "cropVideo":
            cropVideo(args: args, result: result)
        case "composeVideo":
            composeVideo(args: args, result: result)
        case "trimVideo":
            trimVideo(args: args, result: result)
        case "cancelProcessing":
            currentVideoCancel?.cancelled = true
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func initialize(args: [String: Any], result: @escaping FlutterResult) {
        guard let registrar = registrar else {
            result(FlutterError(code: "STATE", message: "registrar missing", details: nil))
            return
        }
        let width  = (args["width"]  as? Int) ?? 1280
        let height = (args["height"] as? Int) ?? 720
        let lens   = (args["lens"]   as? String) ?? "back"
        do {
            let e = try FilterEngine(
                textureRegistry: registrar.textures(),
                width: width,
                height: height,
                startFront: lens == "front"
            )
            try e.start()
            engine = e
            result([
                "textureId": e.textureId,
                "width": width,
                "height": height,
            ])
        } catch {
            result(FlutterError(code: "INIT", message: error.localizedDescription, details: nil))
        }
    }

    private func processImage(args: [String: Any], result: @escaping FlutterResult) {
        guard let input = args["inputPath"] as? String,
              let output = args["outputPath"] as? String,
              let filterId = args["filterId"] as? String else {
            result(FlutterError(code: "ARG", message: "missing args", details: nil))
            return
        }
        let params = (args["params"] as? [String: NSNumber])?.mapValues { $0.floatValue }
        let lut = args["lutPath"] as? String
        let filterId2 = args["filterId2"] as? String
        let params2 = (args["params2"] as? [String: NSNumber])?.mapValues { $0.floatValue }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try MediaProcessor.processImage(
                    inputPath: input,
                    outputPath: output,
                    filterId: filterId,
                    params: params,
                    lutPath: lut,
                    filterId2: filterId2,
                    params2: params2
                )
                DispatchQueue.main.async { result(path) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PROC", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func previewFilter(args: [String: Any], result: @escaping FlutterResult) {
        guard let input = args["inputPath"] as? String,
              let output = args["outputPath"] as? String,
              let filterId = args["filterId"] as? String else {
            result(FlutterError(code: "ARG", message: "missing args", details: nil))
            return
        }
        let params = (args["params"] as? [String: NSNumber])?.mapValues { $0.floatValue }
        let lut = args["lutPath"] as? String
        let isVideo = (args["isVideo"] as? Bool) ?? false
        let atSeconds = (args["atSeconds"] as? NSNumber)?.doubleValue ?? 1.0
        let filterId2 = args["filterId2"] as? String
        let params2 = (args["params2"] as? [String: NSNumber])?.mapValues { $0.floatValue }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try MediaProcessor.previewFilter(
                    inputPath: input, outputPath: output,
                    filterId: filterId, params: params, lutPath: lut,
                    isVideo: isVideo, atSeconds: atSeconds,
                    filterId2: filterId2, params2: params2
                )
                DispatchQueue.main.async { result(path) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PROC", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func cropImage(args: [String: Any], result: @escaping FlutterResult) {
        guard let input = args["inputPath"] as? String,
              let output = args["outputPath"] as? String else {
            result(FlutterError(code: "ARG", message: "missing args", details: nil))
            return
        }
        let l = (args["left"] as? NSNumber)?.doubleValue ?? 0.0
        let t = (args["top"] as? NSNumber)?.doubleValue ?? 0.0
        let r = (args["right"] as? NSNumber)?.doubleValue ?? 1.0
        let b = (args["bottom"] as? NSNumber)?.doubleValue ?? 1.0
        let flipH = (args["flipH"] as? Bool) ?? false
        let flipV = (args["flipV"] as? Bool) ?? false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try MediaProcessor.cropImage(
                    inputPath: input, outputPath: output,
                    left: l, top: t, right: r, bottom: b,
                    flipH: flipH, flipV: flipV
                )
                DispatchQueue.main.async { result(path) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "CROP", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func composeVideo(args: [String: Any], result: @escaping FlutterResult) {
        guard let input = args["inputPath"] as? String,
              let output = args["outputPath"] as? String,
              let overlay = args["overlayPngPath"] as? String else {
            result(FlutterError(code: "ARG", message: "missing args", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try MediaProcessor.composeVideo(
                    inputPath: input, outputPath: output,
                    overlayPngPath: overlay
                )
                DispatchQueue.main.async { result(path) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "COMPOSE", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func cropVideo(args: [String: Any], result: @escaping FlutterResult) {
        guard let input = args["inputPath"] as? String,
              let output = args["outputPath"] as? String else {
            result(FlutterError(code: "ARG", message: "missing args", details: nil))
            return
        }
        let l = (args["left"] as? NSNumber)?.doubleValue ?? 0.0
        let t = (args["top"] as? NSNumber)?.doubleValue ?? 0.0
        let r = (args["right"] as? NSNumber)?.doubleValue ?? 1.0
        let b = (args["bottom"] as? NSNumber)?.doubleValue ?? 1.0
        let flipH = (args["flipH"] as? Bool) ?? false
        let flipV = (args["flipV"] as? Bool) ?? false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try MediaProcessor.cropVideo(
                    inputPath: input, outputPath: output,
                    left: l, top: t, right: r, bottom: b,
                    flipH: flipH, flipV: flipV
                )
                DispatchQueue.main.async { result(path) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "CROP", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func trimVideo(args: [String: Any], result: @escaping FlutterResult) {
        guard let input = args["inputPath"] as? String,
              let output = args["outputPath"] as? String else {
            result(FlutterError(code: "ARG", message: "missing args", details: nil))
            return
        }
        let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
        let endMs = (args["endMs"] as? NSNumber)?.int64Value ?? Int64.max
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try MediaProcessor.trimVideo(
                    inputPath: input, outputPath: output,
                    startMs: startMs, endMs: endMs
                )
                DispatchQueue.main.async { result(path) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "TRIM", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func processVideo(args: [String: Any], result: @escaping FlutterResult) {
        guard let input = args["inputPath"] as? String,
              let output = args["outputPath"] as? String,
              let filterId = args["filterId"] as? String else {
            result(FlutterError(code: "ARG", message: "missing args", details: nil))
            return
        }
        let params = (args["params"] as? [String: NSNumber])?.mapValues { $0.floatValue }
        let lut = args["lutPath"] as? String
        let filterId2 = args["filterId2"] as? String
        let params2 = (args["params2"] as? [String: NSNumber])?.mapValues { $0.floatValue }

        // Tell any in-flight processVideo to stop, then own the new flag.
        currentVideoCancel?.cancelled = true
        let cancel = MediaProcessor.CancelFlag()
        currentVideoCancel = cancel

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                if self?.currentVideoCancel === cancel { self?.currentVideoCancel = nil }
            }
            do {
                let path = try MediaProcessor.processVideo(
                    inputPath: input,
                    outputPath: output,
                    filterId: filterId,
                    params: params,
                    lutPath: lut,
                    progress: { p in
                        self?.progressSink?(p)
                    },
                    cancel: cancel,
                    filterId2: filterId2,
                    params2: params2
                )
                DispatchQueue.main.async { result(path) }
            } catch is MediaProcessor.CancelledError {
                // Cancelled — return nil so Dart can ignore quietly.
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PROC", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
}
