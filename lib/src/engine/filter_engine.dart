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
  }) async {
    final r = await _method.invokeMethod<String>('previewFilter', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'filterId': filterId,
      'isVideo': isVideo,
      'atSeconds': atSeconds,
      if (params != null) 'params': params,
    });
    return r ?? outputPath;
  }

  /// Apply a filter to an existing image file on disk. Returns the saved path.
  Future<String> processImage({
    required String inputPath,
    required String outputPath,
    required String filterId,
    Map<String, double>? params,
    String? lutPath,
  }) async {
    final r = await _method.invokeMethod<String>('processImage', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'filterId': filterId,
      if (params != null) 'params': params,
      if (lutPath != null) 'lutPath': lutPath,
    });
    return r ?? outputPath;
  }

  /// Cancel the in-flight [processVideo] job, if any. The future returned by
  /// processVideo resolves with an empty string when cancelled.
  Future<void> cancelProcessing() =>
      _method.invokeMethod('cancelProcessing');

  /// Apply a filter to an existing video file (audio is passed through).
  Future<String> processVideo({
    required String inputPath,
    required String outputPath,
    required String filterId,
    Map<String, double>? params,
    String? lutPath,
  }) async {
    final r = await _method.invokeMethod<String>('processVideo', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'filterId': filterId,
      if (params != null) 'params': params,
      if (lutPath != null) 'lutPath': lutPath,
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
