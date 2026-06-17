import 'package:flutter/services.dart';

/// Dart-side bridge for the native filter engine.
///
/// All heavy work (camera capture, GPU shader rendering, recording) lives on
/// the native side. The Dart layer only:
/// - asks the native side to initialize and returns a Flutter [Texture] id
/// - sends filter switch / parameter updates
/// - triggers recording and snapshots
class FilterEngine {
  FilterEngine._();
  static final FilterEngine instance = FilterEngine._();

  static const _method = MethodChannel('camera_filter_engine');
  static const _progressEvents = EventChannel('camera_filter_engine/progress');

  /// 0.0–1.0 progress for the last [processVideo] call.
  Stream<double> get videoProgress => _progressEvents
      .receiveBroadcastStream()
      .map((e) => (e as num).toDouble());

  /// Initialize camera + GPU pipeline. Returns the Flutter external texture id.
  Future<EngineHandle> initialize({
    int width = 720,
    int height = 1280,
    CameraLens lens = CameraLens.back,
  }) async {
    final result = await _method.invokeMapMethod<String, dynamic>(
      'initialize',
      {
        'width': width,
        'height': height,
        'lens': lens.name,
      },
    );
    if (result == null) {
      throw StateError('Native initialize returned null');
    }
    return EngineHandle(
      textureId: result['textureId'] as int,
      width: result['width'] as int,
      height: result['height'] as int,
    );
  }

  Future<void> dispose() => _method.invokeMethod('dispose');

  /// Switch the active filter (id matches FilterRegistry ids).
  Future<void> setFilter(String id, {Map<String, double>? params}) {
    return _method.invokeMethod('setFilter', {
      'id': id,
      if (params != null) 'params': params,
    });
  }

  Future<void> setParam(String key, double value) {
    return _method.invokeMethod('setParam', {'key': key, 'value': value});
  }

  /// Load an external .cube LUT from absolute file path or asset key.
  Future<void> setLut({String? path}) {
    return _method.invokeMethod('setLut', {'path': path});
  }

  Future<CameraLens> switchCamera() async {
    final r = await _method.invokeMethod<String>('switchCamera');
    return r == 'front' ? CameraLens.front : CameraLens.back;
  }

  /// Set the camera zoom as a normalized 0..1 value (0 = widest, 1 = max).
  Future<void> setZoom(double level) {
    return _method.invokeMethod('setZoom', {
      'level': level.clamp(0.0, 1.0),
    });
  }

  Future<String> takePicture(String path) async {
    final r = await _method.invokeMethod<String>('takePicture', {'path': path});
    return r ?? path;
  }

  Future<void> startRecording(String path) {
    return _method.invokeMethod('startRecording', {'path': path});
  }

  Future<String> stopRecording() async {
    final r = await _method.invokeMethod<String>('stopRecording');
    return r ?? '';
  }

  /// Render a single-frame preview of [filterId] applied to [inputPath].
  /// For video sources, a frame at [atSeconds] is extracted, filtered, and
  /// saved as a JPEG at [outputPath]. Use this to give the user a real
  /// shader-accurate preview (blur, glitch, grain, scanlines etc.) without
  /// processing the whole file.
  Future<String> previewFilter({
    required String inputPath,
    required String outputPath,
    required String filterId,
    required bool isVideo,
    Map<String, double>? params,
    double atSeconds = 1.0,
    String? colorFilterId,
    Map<String, double>? colorParams,
  }) async {
    final r = await _method.invokeMethod<String>('previewFilter', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'filterId': filterId,
      'isVideo': isVideo,
      'atSeconds': atSeconds,
      if (params != null) 'params': params,
      if (colorFilterId != null) 'filterId2': colorFilterId,
      if (colorParams != null) 'params2': colorParams,
    });
    return r ?? outputPath;
  }

  /// Apply a filter to an existing image file on disk. An optional second
  /// [colorFilterId] (a pure colour grade) is stacked on top of the primary
  /// effect filter in the same shader pass. Returns the saved path.
  Future<String> processImage({
    required String inputPath,
    required String outputPath,
    required String filterId,
    Map<String, double>? params,
    String? lutPath,
    String? colorFilterId,
    Map<String, double>? colorParams,
  }) async {
    final r = await _method.invokeMethod<String>('processImage', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'filterId': filterId,
      if (params != null) 'params': params,
      if (lutPath != null) 'lutPath': lutPath,
      if (colorFilterId != null) 'filterId2': colorFilterId,
      if (colorParams != null) 'params2': colorParams,
    });
    return r ?? outputPath;
  }

  /// Cancel the in-flight [processVideo] job, if any. The future returned by
  /// processVideo resolves with an empty string when cancelled.
  Future<void> cancelProcessing() =>
      _method.invokeMethod('cancelProcessing');

  /// Apply a filter to an existing video file (audio is passed through).
  /// Always renders at the source's full resolution and bitrate. An optional
  /// second [colorFilterId] colour grade is stacked on top of the primary
  /// effect filter in the same shader pass.
  Future<String> processVideo({
    required String inputPath,
    required String outputPath,
    required String filterId,
    Map<String, double>? params,
    String? lutPath,
    String? colorFilterId,
    Map<String, double>? colorParams,
  }) async {
    final r = await _method.invokeMethod<String>('processVideo', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'filterId': filterId,
      if (params != null) 'params': params,
      if (lutPath != null) 'lutPath': lutPath,
      if (colorFilterId != null) 'filterId2': colorFilterId,
      if (colorParams != null) 'params2': colorParams,
    });
    return r ?? outputPath;
  }

  /// Crop an image to the normalized rect [left, top, right, bottom] (each
  /// in 0..1 of the source image) and optionally flip [flipH]/[flipV]. The
  /// crop is lossless within the kept region; flips reuse the same pixels
  /// with no resampling. Returns the saved JPEG path.
  Future<String> cropImage({
    required String inputPath,
    required String outputPath,
    required double left,
    required double top,
    required double right,
    required double bottom,
    bool flipH = false,
    bool flipV = false,
  }) async {
    final r = await _method.invokeMethod<String>('cropImage', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
      'flipH': flipH,
      'flipV': flipV,
    });
    return r ?? outputPath;
  }

  /// Composite a transparent PNG [overlayPngPath] over every frame of the
  /// source video. Audio is passed through, source orientation is preserved.
  /// Use this to bake paint strokes, text and emoji stickers into a video.
  Future<String> composeVideo({
    required String inputPath,
    required String outputPath,
    required String overlayPngPath,
  }) async {
    final r = await _method.invokeMethod<String>('composeVideo', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'overlayPngPath': overlayPngPath,
    });
    return r ?? outputPath;
  }

  /// Crop + optional flip a video. Native re-encodes the chosen window at
  /// source quality; audio is passthrough; source orientation is preserved
  /// in the output's metadata so players show it upright.
  Future<String> cropVideo({
    required String inputPath,
    required String outputPath,
    required double left,
    required double top,
    required double right,
    required double bottom,
    bool flipH = false,
    bool flipV = false,
  }) async {
    final r = await _method.invokeMethod<String>('cropVideo', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
      'flipH': flipH,
      'flipV': flipV,
    });
    return r ?? outputPath;
  }

  /// Trim a video to [startMs..endMs] without re-encoding. Audio + video
  /// tracks are copied through bit-identical from the source; the source's
  /// orientation flag is preserved.
  Future<String> trimVideo({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
  }) async {
    final r = await _method.invokeMethod<String>('trimVideo', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'endMs': endMs,
    });
    return r ?? outputPath;
  }

  /// Copy a file at [path] into the OS Photos / Gallery.
  /// Returns true on success.
  Future<bool> saveToGallery(String path, {required bool isVideo}) async {
    final r = await _method.invokeMethod<bool>('saveToGallery', {
      'path': path,
      'isVideo': isVideo,
    });
    return r ?? false;
  }
}

enum CameraLens { back, front }

class EngineHandle {
  final int textureId;
  final int width;
  final int height;
  const EngineHandle({
    required this.textureId,
    required this.width,
    required this.height,
  });
}
