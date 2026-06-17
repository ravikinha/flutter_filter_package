import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/filter_engine.dart';
import '../models/filter.dart';
import '../widgets/filter_picker.dart';
import '../widgets/param_sheet.dart';
import 'import_edit_screen.dart';

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
  Timer? _tapTimer;

  bool _recording = false;
  bool _recordingTransition = false; // guards against double-tap mid-toggle
  DateTime? _recordStart;
  Timer? _recordTicker;
  Duration _recordElapsed = Duration.zero;

  // Zoom: normalized 0..1, driven by vertical swipes over the preview.
  double _zoom = 0.0;
  double _zoomAtDragStart = 0.0;
  bool _showZoomHud = false;
  Timer? _zoomHudTimer;

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
    _zoomHudTimer?.cancel();
    FilterEngine.instance.dispose();
    super.dispose();
  }

  // ----- gestures: vertical swipe = zoom, double tap = flip -------------

  void _onZoomDragStart(DragStartDetails _) {
    _zoomAtDragStart = _zoom;
  }

  void _onZoomDragUpdate(DragUpdateDetails d, double previewHeight) {
    if (_handle == null) return;
    // Swipe UP (negative dy) zooms in. Full-height swipe ≈ full zoom range.
    final delta = -d.primaryDelta! / (previewHeight * 0.6);
    final next = (_zoomAtDragStart + delta).clamp(0.0, 1.0);
    _zoomAtDragStart = next; // accumulate incrementally
    if (next == _zoom) return;
    setState(() {
      _zoom = next;
      _showZoomHud = true;
    });
    FilterEngine.instance.setZoom(_zoom);
    _zoomHudTimer?.cancel();
    _zoomHudTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showZoomHud = false);
    });
  }

  Future<void> _onDoubleTapFlip() async {
    if (_handle == null) return;
    await _switchCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Releasing the GL/camera resources on background is necessary, but we
      // MUST null the handle too — otherwise resume sees a stale (released)
      // texture id, skips re-init, and the preview stays black until restart.
      // This path also fires when image_picker / permission dialogs push the
      // app to the background, which is the common "black screen after going
      // to gallery and coming back" case.
      FilterEngine.instance.dispose();
      if (mounted) setState(() => _handle = null);
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
      // Preserve the user's current filter selection + tuned params across a
      // re-init; only fall back to defaults the very first time.
      if (_params.isEmpty) _params = _filter.defaultParams;
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
    setState(() {
      _lens = lens;
      _zoom = 0.0; // lenses have different zoom ranges; reset to widest
    });
    FilterEngine.instance.setZoom(0.0);
  }

  Future<void> _capturePhoto() async {
    // If the user taps capture while a recording is active, treat the tap as
    // "stop recording" and route the recorded video to the editor.
    if (_recording) {
      await _toggleRecording();
      return;
    }
    if (_handle == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/CFE_$ts.jpg';
    final saved = await FilterEngine.instance.takePicture(path);
    if (!mounted) return;
    _gotoEditor(XFile(saved), isVideo: false);
  }

  /// Push the editor with the supplied source preselected to the current
  /// filter + params so the user can keep iterating before saving.
  Future<void> _gotoEditor(XFile src, {required bool isVideo}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImportEditScreen(
          initialSource: src,
          initialIsVideo: isVideo,
          initialFilter: _filter,
          initialParams: Map<String, double>.from(_params),
        ),
      ),
    );
    // Some devices don't fire a reliable resume after returning from a pushed
    // route that backgrounded the app (image_picker, etc.). Re-init if the
    // engine got torn down so the preview doesn't stay black.
    if (mounted && _handle == null) _bootstrap();
  }

  /// Open the gallery picker sheet, then push the editor with the picked
  /// file. Done here (instead of inside the editor) so the user gets a
  /// sheet directly on tap and a cancel doesn't leave them on a blank
  /// editor screen.
  Future<void> _openLibrary() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Pick a photo'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.movie_outlined),
              title: const Text('Pick a video'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final isVideo = action == 'video';
    final picker = ImagePicker();
    final picked = isVideo
        ? await picker.pickVideo(source: ImageSource.gallery)
        : await picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    // image_picker hands back a path in a temporary directory that the OS may
    // clean at any time. Copy into our docs dir so it survives later screens.
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = isVideo ? 'mp4' : 'jpg';
    final localPath = '${dir.path}/CFE_pick_$ts.$ext';
    try {
      await File(picked.path).copy(localPath);
    } catch (_) {
      // Fall back to picker's own path if copy fails.
    }
    final source = File(localPath).existsSync() ? XFile(localPath) : picked;
    if (!mounted) return;
    _gotoEditor(source, isVideo: isVideo);
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
      if (!mounted || path.isEmpty) return;
      _gotoEditor(XFile(path), isVideo: true);
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
    final screenH = MediaQuery.of(context).size.height;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Gesture layer over the preview: vertical swipe zooms, double-tap
          // flips the camera. Placed below the bars so their buttons keep
          // their own taps.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: _onZoomDragStart,
            onVerticalDragUpdate: (d) => _onZoomDragUpdate(d, screenH),
            onDoubleTap: _onDoubleTapFlip,
            child: _buildPreview(),
          ),
          if (_showZoomHud) _buildZoomHud(),
          _buildTopBar(context),
          _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildZoomHud() {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            // Show as a multiplier-ish readout (1.0×–~max). Purely indicative.
            '${(1.0 + _zoom * 5.0).toStringAsFixed(1)}×',
            style: const TextStyle(
              color: Color(0xFFFFD400),
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ),
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
        child: Column(
          children: [
            Row(
              children: [

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
                  icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                  onPressed: _handle == null ? null : _switchCamera,
                ),
              ],
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
                    icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
                    tooltip: 'Apply filter to a saved photo or video',
                    onPressed: _openLibrary,
                  ),
                  GestureDetector(
                    onTap: () {
                      _tapTimer = Timer(const Duration(milliseconds: 250), () {
                        if (_handle != null) {
                          _capturePhoto();
                        }
                      });
                    },
                    onDoubleTap: () {
                      _tapTimer?.cancel();
                      _switchCamera();
                    },
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
