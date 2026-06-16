import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: const [
          ListTile(
            leading: Icon(Icons.speed),
            title: Text('Render target'),
            subtitle: Text('60 FPS · GPU shaders'),
          ),
          ListTile(
            leading: Icon(Icons.tune),
            title: Text('LUT support'),
            subtitle: Text('32x32x32 .cube files'),
          ),
          ListTile(
            leading: Icon(Icons.memory),
            title: Text('Pipeline'),
            subtitle: Text(
              'Android: CameraX → OpenGL ES → SurfaceTexture\n'
              'iOS: AVCaptureSession → Metal → CVPixelBuffer',
            ),
          ),
          ListTile(
            leading: Icon(Icons.face_retouching_natural),
            title: Text('Beauty filters'),
            subtitle: Text('MediaPipe — coming in Phase 2'),
          ),
          ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text('1.0.0'),
          ),
        ],
      ),
    );
  }
}
