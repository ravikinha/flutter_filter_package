import 'package:flutter/material.dart';

import 'src/screens/camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CameraFilterApp());
}

class CameraFilterApp extends StatelessWidget {
  const CameraFilterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Filter Engine',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFD400),
          surface: Colors.black,
        ),
      ),
      home: const CameraScreen(),
    );
  }
}
