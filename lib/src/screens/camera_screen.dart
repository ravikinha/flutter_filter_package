import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/filter_engine.dart';
import '../models/filter.dart';
import '../widgets/filter_picker.dart';
import '../widgets/param_sheet.dart';
import 'gallery_screen.dart';
import 'import_edit_screen.dart';
import 'settings_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  EngineHandle? _handle;
  bool _initializing = true;
  String? _error;

  CameraFilter _filter = FilterRegistry.all.first;
  Map<String, double> _params = {};
  CameraLens _lens = CameraLens.back;

  bool _recording = false;
  bool _recordingTransition = false; // guards against double-tap mid-toggle
  DateTime? _recordStart;
  Timer? _recordTicker;
  Duration _recordElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTicker?.cancel();
    FilterEngine.instance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      FilterEngine.instance.dispose();
    } else if (state == AppLifecycleState.resumed && _handle == null) {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final cam = await Permission.camera.request();
      final mic = await Permission.microphone.request();
      if (!cam.isGranted) {
        throw StateError('Camera permission denied');
      }
      if (!mic.isGranted) {
        // Recording will be silent; not fatal.
      }
      final h = await FilterEngine.instance.initialize(lens: _lens);
      _params = _filter.defaultParams;
      await FilterEngine.instance.setFilter(_filter.id, params: _params);
      if (!mounted) return;
      setState(() {
        _handle = h;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _onFilterSelected(CameraFilter f) async {
    // Close any open param sheet — its params belong to the previous filter
    // and would otherwise post writes against the wrong filter.
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) nav.maybePop();
    setState(() {
      _filter = f;
      _params = f.defaultParams;
    });
    await FilterEngine.instance.setFilter(f.id, params: _params);
  }

  Future<void> _openParamSheet() async {
    if (_filter.params.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ParamSheet(
        filter: _filter,
        values: _params,
        onChanged: (k, v) async {
          _params[k] = v;
          await FilterEngine.instance.setParam(k, v);
        },
      ),
    );
  }

  Future<void> _switchCamera() async {
    final lens = await FilterEngine.instance.switchCamera();
    setState(() => _lens = lens);
  }

  Future<void> _capturePhoto() async {
    if (_handle == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/CFE_$ts.jpg';
    final saved = await FilterEngine.instance.takePicture(path);
    final ok = await FilterEngine.instance.saveToGallery(saved, isVideo: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Saved to Photos' : 'Saved (app only)')),
    );
  }

  Future<void> _toggleRecording() async {
    if (_handle == null) return;
    if (_recordingTransition) return; // a previous toggle is still in-flight
    _recordingTransition = true;
    try {
      await _toggleRecordingInner();
    } finally {
      _recordingTransition = false;
    }
  }

  Future<void> _toggleRecordingInner() async {
    if (_recording) {
      final path = await FilterEngine.instance.stopRecording();
      _recordTicker?.cancel();
      setState(() {
        _recording = false;
        _recordElapsed = Duration.zero;
      });
      final ok = path.isNotEmpty &&
          await FilterEngine.instance.saveToGallery(path, isVideo: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'Saved video to Photos' : 'Saved (app only)')),
      );
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/CFE_$ts.mp4';
      await FilterEngine.instance.startRecording(path);
      _recordStart = DateTime.now();
      _recordTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() {
          _recordElapsed = DateTime.now().difference(_recordStart!);
        });
      });
      setState(() => _recording = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildPreview(),
          _buildTopBar(context),
          _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _bootstrap, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final h = _handle!;
    // Fill the whole screen with the preview, cropping overflow on the sides —
    // matches how the iPhone Camera app composes.
    return Positioned.fill(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: h.width.toDouble(),
          height: h.height.toDouble(),
          child: Texture(textureId: h.textureId),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
            const Spacer(),
            if (_recording)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
                    const SizedBox(width: 6),
                    Text(
                      _fmtDuration(_recordElapsed),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
              tooltip: 'Apply filter to a saved photo or video',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ImportEditScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
              onPressed: _handle == null ? null : _switchCamera,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        padding: const EdgeInsets.only(bottom: 28, top: 8),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilterPicker(
                filters: FilterRegistry.all,
                selectedId: _filter.id,
                onSelected: _onFilterSelected,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.photo_library_outlined, color: Colors.white, size: 30),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const GalleryScreen()),
                    ),
                  ),
                  GestureDetector(
                    onTap: _handle == null ? null : _capturePhoto,
                    onLongPress: _handle == null ? null : _toggleRecording,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                        color: _recording ? Colors.red : Colors.white24,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _filter.params.isEmpty
                          ? Icons.tune_outlined
                          : Icons.tune,
                      color: _filter.params.isEmpty ? Colors.white38 : Colors.white,
                      size: 30,
                    ),
                    onPressed: _filter.params.isEmpty ? null : _openParamSheet,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Tap to capture · Long press to record',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
