# flutter_filter_package

Instagram-style on-device GPU camera filter engine built in Flutter, with
fully native rendering pipelines on both platforms.

- **Android:** Kotlin + CameraX + OpenGL ES 3.0 + GLSL shaders
- **iOS:** Swift + AVFoundation + Metal + Metal shaders
- **Flutter:** UI, filter picker, gallery, import-and-edit, MethodChannel
  bridge

The same shader runs on both platforms (one GLSL file, one Metal file with
the same dispatch logic) so every filter looks identical on Android and
iOS.

## Filters

| Filter         | Look                                                |
| -------------- | --------------------------------------------------- |
| Kodak          | Warm highlights, yellow tint, soft shadows          |
| Vintage        | Sepia + faded blacks + vignette                     |
| Retro          | 80s warmth + fade + light leak                      |
| Film Grain     | Procedural analog grain                             |
| VHS            | RGB split + scanlines + noise                       |
| B&W Glitch     | Slice jitter + block tears + chromatic split, B&W   |
| Blur           | 5-tap separable Gaussian                            |
| Cinematic      | Teal shadows + orange highlights                    |
| Cool Blue      | Cold modern tint                                    |
| Dream Glow     | Bloom + soft tint                                   |

All filters support 32×32×32 `.cube` LUT overlays at runtime.

## Pipeline

```
Flutter UI
   ↓ MethodChannel("camera_filter_engine")
Native Plugin
   ↓
Android: CameraX → SurfaceTexture(OES) → GLES3 → filter.frag → Flutter Texture + MediaCodec
iOS:     AVCaptureSession → CVPixelBuffer → Metal → filter_fs → FlutterTexture + AVAssetWriter
```

## Features

- Live camera preview at 60 FPS through the GPU shader
- Photo capture (saves to Photos / Gallery)
- Video recording (saves to Photos / Gallery)
- Front/back camera switch
- Gallery import: apply any filter to existing photos and videos with
  audio passthrough and source-rotation preserved
- Single-frame shader-accurate preview for images
- Full-video preview render with progress + cancellation for effect
  filters on video (Blur, Glitch, Grain, VHS, Dream Glow)
- LUT support via runtime `setLut()` call

## Run

```bash
flutter pub get
cd ios && pod install && cd ..      # iOS only
flutter run                          # real device required
```

## Project layout

```
lib/
  main.dart
  src/
    engine/filter_engine.dart        # MethodChannel + EventChannel bridge
    models/filter.dart               # Filter registry + parameter schema
    screens/                         # Camera, Gallery, Import-and-edit, ...
    widgets/                         # Filter picker, param sheet

android/app/src/main/
  kotlin/.../engine/                 # Plugin, GLRenderer, MediaProcessor, ...
  assets/shaders/                    # filter.frag, filter2d.frag, oes.vert

ios/Runner/Engine/                   # Plugin, MetalRenderer, MediaProcessor, ...
  Shaders.metal
```
