import 'package:flutter/foundation.dart';

@immutable
class FilterParam {
  final String key;
  final String label;
  final double min;
  final double max;
  final double defaultValue;

  const FilterParam({
    required this.key,
    required this.label,
    required this.min,
    required this.max,
    required this.defaultValue,
  });
}

@immutable
class CameraFilter {
  final String id;
  final String name;
  final List<FilterParam> params;
  final String? lutAsset;

  const CameraFilter({
    required this.id,
    required this.name,
    this.params = const [],
    this.lutAsset,
  });

  Map<String, double> get defaultParams =>
      {for (final p in params) p.key: p.defaultValue};
}

class FilterRegistry {
  static const List<CameraFilter> all = [
    CameraFilter(
      id: 'none',
      name: 'Original',
    ),
    CameraFilter(
      id: 'kodak',
      name: 'Kodak',
      params: [
        FilterParam(key: 'warmth', label: 'Warmth', min: 0, max: 1, defaultValue: 0.55),
        FilterParam(key: 'contrast', label: 'Contrast', min: 0, max: 1, defaultValue: 0.65),
        FilterParam(key: 'saturation', label: 'Saturation', min: 0, max: 1, defaultValue: 0.45),
      ],
    ),
    CameraFilter(
      id: 'vintage',
      name: 'Vintage',
      params: [
        FilterParam(key: 'sepiaStrength', label: 'Sepia', min: 0, max: 1, defaultValue: 0.7),
        FilterParam(key: 'vignetteStrength', label: 'Vignette', min: 0, max: 1, defaultValue: 0.6),
      ],
    ),
    CameraFilter(
      id: 'retro',
      name: 'Retro',
      params: [
        FilterParam(key: 'warmth', label: 'Warmth', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'fade', label: 'Fade', min: 0, max: 1, defaultValue: 0.35),
        FilterParam(key: 'lightLeakStrength', label: 'Light Leak', min: 0, max: 1, defaultValue: 0.4),
      ],
    ),
    CameraFilter(
      id: 'grain',
      name: 'Film Grain',
      params: [
        FilterParam(key: 'grainIntensity', label: 'Grain', min: 0, max: 1, defaultValue: 0.5),
      ],
    ),
    CameraFilter(
      id: 'vhs',
      name: 'VHS',
      params: [
        FilterParam(key: 'rgbOffset', label: 'RGB Split', min: 0, max: 1, defaultValue: 0.5),
        FilterParam(key: 'scanlineIntensity', label: 'Scanlines', min: 0, max: 1, defaultValue: 0.5),
        FilterParam(key: 'noiseIntensity', label: 'Noise', min: 0, max: 1, defaultValue: 0.4),
      ],
    ),
    CameraFilter(
      id: 'bwGlitch',
      name: 'B&W Glitch',
      params: [
        FilterParam(key: 'glitchAmount', label: 'Glitch', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'distortionAmount', label: 'Distortion', min: 0, max: 1, defaultValue: 0.5),
      ],
    ),
    CameraFilter(
      id: 'blur',
      name: 'Blur',
      params: [
        FilterParam(key: 'blurRadius', label: 'Radius', min: 0, max: 1, defaultValue: 0.4),
      ],
    ),
    CameraFilter(
      id: 'cinematic',
      name: 'Cinematic',
      params: [
        FilterParam(key: 'tealStrength', label: 'Teal', min: 0, max: 1, defaultValue: 0.55),
        FilterParam(key: 'orangeStrength', label: 'Orange', min: 0, max: 1, defaultValue: 0.55),
        FilterParam(key: 'contrast', label: 'Contrast', min: 0, max: 1, defaultValue: 0.6),
      ],
    ),
    CameraFilter(
      id: 'coolBlue',
      name: 'Cool Blue',
      params: [
        FilterParam(key: 'coolness', label: 'Coolness', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'contrast', label: 'Contrast', min: 0, max: 1, defaultValue: 0.55),
      ],
    ),
    CameraFilter(
      id: 'dreamGlow',
      name: 'Dream Glow',
      params: [
        FilterParam(key: 'glowIntensity', label: 'Glow', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'bloomRadius', label: 'Bloom', min: 0, max: 1, defaultValue: 0.45),
      ],
    ),
  ];

  static CameraFilter byId(String id) =>
      all.firstWhere((f) => f.id == id, orElse: () => all.first);
}
