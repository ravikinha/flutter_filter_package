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
    CameraFilter(
      id: 'cyberpunkHud',
      name: 'Cyberpunk HUD',
      params: [
        FilterParam(key: 'edgeStrength', label: 'Edges', min: 0, max: 1, defaultValue: 0.7),
        FilterParam(key: 'cyberScan', label: 'Scanlines', min: 0, max: 1, defaultValue: 0.5),
        FilterParam(key: 'gridIntensity', label: 'Grid', min: 0, max: 1, defaultValue: 0.5),
      ],
    ),
    CameraFilter(
      id: 'hologram',
      name: 'Hologram',
      params: [
        FilterParam(key: 'holoIntensity', label: 'Strength', min: 0, max: 1, defaultValue: 0.8),
        FilterParam(key: 'holoScan', label: 'Scanlines', min: 0, max: 1, defaultValue: 0.6),
      ],
    ),
    CameraFilter(
      id: 'matrixVision',
      name: 'Matrix',
      params: [
        FilterParam(key: 'matrixGreen', label: 'Green', min: 0, max: 1, defaultValue: 0.85),
        FilterParam(key: 'matrixStreak', label: 'Streaks', min: 0, max: 1, defaultValue: 0.6),
      ],
    ),
    CameraFilter(
      id: 'neonOutline',
      name: 'Neon Outline',
      params: [
        FilterParam(key: 'outlineStrength', label: 'Outline', min: 0, max: 1, defaultValue: 0.85),
        FilterParam(key: 'neonHue', label: 'Hue', min: 0, max: 1, defaultValue: 0.55),
      ],
    ),
    CameraFilter(
      id: 'thermal',
      name: 'Thermal',
      params: [
        FilterParam(key: 'heatIntensity', label: 'Heat', min: 0, max: 1, defaultValue: 0.95),
      ],
    ),
    CameraFilter(
      id: 'crtRetro',
      name: 'CRT Retro',
      params: [
        FilterParam(key: 'crtScan', label: 'Scanlines', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'crtChroma', label: 'Chroma', min: 0, max: 1, defaultValue: 0.5),
        FilterParam(key: 'crtBarrel', label: 'Curve', min: 0, max: 1, defaultValue: 0.5),
      ],
    ),
    CameraFilter(
      id: 'vhsPro',
      name: 'VHS Pro',
      params: [
        FilterParam(key: 'tapeWear', label: 'Wear', min: 0, max: 1, defaultValue: 0.65),
        FilterParam(key: 'trackingError', label: 'Tracking', min: 0, max: 1, defaultValue: 0.5),
        FilterParam(key: 'vhsProScan', label: 'Scanlines', min: 0, max: 1, defaultValue: 0.55),
      ],
    ),
    CameraFilter(
      id: 'kaleidoscope',
      name: 'Kaleidoscope',
      params: [
        FilterParam(key: 'kaleidoSegments', label: 'Segments', min: 0, max: 1, defaultValue: 0.4),
        FilterParam(key: 'kaleidoRotation', label: 'Rotation', min: 0, max: 1, defaultValue: 0),
      ],
    ),
    CameraFilter(
      id: 'electricAura',
      name: 'Electric',
      params: [
        FilterParam(key: 'auraIntensity', label: 'Aura', min: 0, max: 1, defaultValue: 0.8),
      ],
    ),
    CameraFilter(
      id: 'scannerVision',
      name: 'Scanner',
      params: [
        FilterParam(key: 'scanSpeed', label: 'Speed', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'scannerGlow', label: 'Glow', min: 0, max: 1, defaultValue: 0.7),
      ],
    ),
    CameraFilter(
      id: 'liquidChrome',
      name: 'Liquid Chrome',
      params: [
        FilterParam(key: 'chromeIntensity', label: 'Chrome', min: 0, max: 1, defaultValue: 0.85),
        FilterParam(key: 'chromeReflection', label: 'Reflection', min: 0, max: 1, defaultValue: 0.75),
        FilterParam(key: 'chromeDistortion', label: 'Distortion', min: 0, max: 1, defaultValue: 0.5),
      ],
    ),
    CameraFilter(
      id: 'glassMorph',
      name: 'Glass Morph',
      params: [
        FilterParam(key: 'glassRefraction', label: 'Refraction', min: 0, max: 1, defaultValue: 0.7),
        FilterParam(key: 'glassTransparency', label: 'Transparency', min: 0, max: 1, defaultValue: 0.75),
        FilterParam(key: 'glassEdge', label: 'Edge Glow', min: 0, max: 1, defaultValue: 0.55),
      ],
    ),
    CameraFilter(
      id: 'prismLens',
      name: 'Prism Lens',
      params: [
        FilterParam(key: 'prismStrength', label: 'Prism', min: 0, max: 1, defaultValue: 0.7),
        FilterParam(key: 'prismRainbow', label: 'Rainbow', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'prismDispersion', label: 'Dispersion', min: 0, max: 1, defaultValue: 0.5),
      ],
    ),
    CameraFilter(
      id: 'cinematicAnamorphic',
      name: 'Anamorphic',
      params: [
        FilterParam(key: 'anamorphicFlare', label: 'Flare', min: 0, max: 1, defaultValue: 0.7),
        FilterParam(key: 'anamorphicBloom', label: 'Bloom', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'anamorphicGrain', label: 'Grain', min: 0, max: 1, defaultValue: 0.35),
      ],
    ),
    CameraFilter(
      id: 'dreamLens',
      name: 'Dream Lens',
      params: [
        FilterParam(key: 'dreamLensGlow', label: 'Glow', min: 0, max: 1, defaultValue: 0.75),
        FilterParam(key: 'dreamLensBloom', label: 'Bloom', min: 0, max: 1, defaultValue: 0.65),
        FilterParam(key: 'dreamLensLeak', label: 'Light Leak', min: 0, max: 1, defaultValue: 0.5),
      ],
    ),
    CameraFilter(
      id: 'aurora',
      name: 'Aurora',
      params: [
        FilterParam(key: 'auroraSpeed', label: 'Speed', min: 0, max: 1, defaultValue: 0.5),
        FilterParam(key: 'auroraStrength', label: 'Strength', min: 0, max: 1, defaultValue: 0.85),
        FilterParam(key: 'auroraGlow', label: 'Glow', min: 0, max: 1, defaultValue: 0.6),
      ],
    ),
    CameraFilter(
      id: 'lightRays',
      name: 'Light Rays',
      params: [
        FilterParam(key: 'rayIntensity', label: 'Rays', min: 0, max: 1, defaultValue: 0.8),
        FilterParam(key: 'rayLength', label: 'Length', min: 0, max: 1, defaultValue: 0.7),
        FilterParam(key: 'rayBloom', label: 'Bloom', min: 0, max: 1, defaultValue: 0.55),
      ],
    ),
    CameraFilter(
      id: 'holographicGlass',
      name: 'Holo Glass',
      params: [
        FilterParam(key: 'holoGlassStrength', label: 'Strength', min: 0, max: 1, defaultValue: 0.8),
        FilterParam(key: 'holoGlassRainbow', label: 'Rainbow', min: 0, max: 1, defaultValue: 0.7),
        FilterParam(key: 'holoGlassGlow', label: 'Glow', min: 0, max: 1, defaultValue: 0.55),
      ],
    ),
    CameraFilter(
      id: 'photonTrails',
      name: 'Photon Trails',
      params: [
        FilterParam(key: 'trailLength', label: 'Length', min: 0, max: 1, defaultValue: 0.75),
        FilterParam(key: 'trailBrightness', label: 'Brightness', min: 0, max: 1, defaultValue: 0.8),
        FilterParam(key: 'trailFade', label: 'Fade', min: 0, max: 1, defaultValue: 0.55),
      ],
    ),
    CameraFilter(
      id: 'neuralGrid',
      name: 'Neural Grid',
      params: [
        FilterParam(key: 'neuralDensity', label: 'Density', min: 0, max: 1, defaultValue: 0.55),
        FilterParam(key: 'neuralSpeed', label: 'Scan Speed', min: 0, max: 1, defaultValue: 0.6),
        FilterParam(key: 'neuralGlow', label: 'Glow', min: 0, max: 1, defaultValue: 0.75),
      ],
    ),
  ];

  static CameraFilter byId(String id) =>
      all.firstWhere((f) => f.id == id, orElse: () => all.first);
}
