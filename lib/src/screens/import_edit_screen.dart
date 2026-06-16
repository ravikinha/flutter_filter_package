import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../engine/filter_engine.dart';
import '../models/filter.dart';
import '../widgets/filter_picker.dart';
import 'annotate_screen.dart';
import 'capture_viewer.dart';
import 'crop_screen.dart';
import 'trim_screen.dart';

class ImportEditScreen extends StatefulWidget {
  const ImportEditScreen({super.key});

  @override
  State<ImportEditScreen> createState() => _ImportEditScreenState();
}

class _ImportEditScreenState extends State<ImportEditScreen> {
  final ImagePicker _picker = ImagePicker();
  XFile? _source;
  bool _isVideo = false;
  VideoPlayerController? _video;

  CameraFilter _filter = FilterRegistry.all.first;
  Map<String, double> _params = {};

  bool _processing = false;
  double _progress = 0;
  StreamSubscription<double>? _progressSub;

  // Live shader-accurate preview state.
  String? _previewPath;   // file we render in the UI
  int _previewVersion = 0; // bust Image.file cache
  Timer? _previewDebounce;
  int _previewSeq = 0;     // request-id to ignore stale completions

  // Cached full-video preview: when the user taps an effect filter we render
  // the whole video through the shader once and cache the result keyed by
  // (filter id, params). Subsequent taps with the same selection reuse it.
  String? _videoPreviewPath;          // path of the rendered preview file
  String? _videoPreviewKey;           // filter+params signature it belongs to
  String? _videoPreviewInFlightKey;   // signature of the job currently running
  VideoPlayerController? _videoPreview;
  bool _videoPreviewProcessing = false;
  double _videoPreviewProgress = 0;
  int _videoPreviewSeq = 0;

  @override
  void initState() {
    super.initState();
    // Open the picker right away.
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _video?.dispose();
    _videoPreview?.dispose();
    _progressSub?.cancel();
    _previewDebounce?.cancel();
    // Best-effort cancel of any in-flight native render so it doesn't keep
    // burning CPU after we're gone.
    FilterEngine.instance.cancelProcessing();
    super.dispose();
  }

  // Filters whose visual signature can't be reproduced by a ColorFilter
  // matrix on a live VideoPlayer — they need a real GPU shader pass per
  // frame. Picking one of these on a video kicks off processVideo to a
  // temp file and we play that back.
  static const Set<String> _effectFilters = {
    'blur', 'bwGlitch', 'grain', 'vhs', 'dreamGlow',
    'cyberpunkHud', 'hologram', 'neonOutline', 'crtRetro',
    'vhsPro', 'kaleidoscope', 'electricAura', 'scannerVision',
    // Premium set
    'liquidChrome', 'glassMorph', 'prismLens', 'cinematicAnamorphic',
    'dreamLens', 'aurora', 'lightRays', 'holographicGlass',
    'photonTrails', 'neuralGrid',
    // Dogpatch Pro relies on bloom + grain + vignette which a ColorFilter
    // matrix can't reproduce — needs the real shader render.
    'dogpatchPro',
  };

  Future<void> _pick() async {
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
    if (!mounted) return;
    if (action == null) {
      Navigator.pop(context);
      return;
    }
    final isVideo = action == 'video';
    final picked = isVideo
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) {
      if (!mounted) return;
      Navigator.pop(context);
      return;
    }
    // image_picker hands back a path in a temporary directory that the OS may
    // clean at any time. Copy into our docs dir so the path stays valid
    // through later Apply / share / re-enter cycles.
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = isVideo ? 'mp4' : 'jpg';
    final localPath = '${dir.path}/CFE_pick_$ts.$ext';
    try {
      await File(picked.path).copy(localPath);
    } catch (_) {
      // Fall back to the picker's own path if copy fails.
    }
    final XFile source = File(localPath).existsSync()
        ? XFile(localPath)
        : picked;
    if (!mounted) return;
    setState(() {
      _source = source;
      _isVideo = isVideo;
      _filter = FilterRegistry.all.first;
      _params = _filter.defaultParams;
    });
    if (isVideo) {
      final c = VideoPlayerController.file(File(source.path));
      _video = c;
      c.initialize().then((_) {
        if (!mounted) { c.dispose(); return; }
        setState(() {});
        c..setLooping(true)..play();
      }).catchError((_) {
        if (!mounted) return;
        c.dispose();
        setState(() => _video = null);
      });
    }
  }

  Future<void> _openCrop() async {
    final src = _source;
    if (src == null) return;
    // Pause the live video before handing off so the crop screen owns playback.
    if (_isVideo) _video?.pause();
    final cropped = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => CropScreen(
          source: File(src.path),
          isVideo: _isVideo,
        ),
      ),
    );
    if (!mounted) return;
    if (cropped != null) {
      await _replaceSource(XFile(cropped), isVideo: _isVideo);
    } else if (_isVideo) {
      _video?.play();
    }
  }

  Future<void> _openAnnotate() async {
    final src = _source;
    if (src == null) return;
    if (_isVideo) _video?.pause();
    final saved = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => AnnotateScreen(
          source: File(src.path),
          isVideo: _isVideo,
        ),
      ),
    );
    if (!mounted) return;
    if (saved != null) {
      await _replaceSource(XFile(saved), isVideo: _isVideo);
    } else if (_isVideo) {
      _video?.play();
    }
  }

  Future<void> _openTrim() async {
    final src = _source;
    if (src == null) return;
    // Pause the live VideoPlayer so the trim screen owns playback.
    _video?.pause();
    final trimmed = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => TrimScreen(source: File(src.path))),
    );
    if (!mounted) return;
    if (trimmed != null) {
      await _replaceSource(XFile(trimmed), isVideo: true);
    } else {
      // No change — resume.
      _video?.play();
    }
  }

  Future<void> _replaceSource(XFile newSource, {required bool isVideo}) async {
    // Throw away any cached video render — it belongs to the previous source.
    await _dropVideoPreview();
    final oldVideo = _video;
    _video = null;
    oldVideo?.dispose();

    // Reset filter back to Original and clear the rendered preview file.
    setState(() {
      _source = newSource;
      _isVideo = isVideo;
      _filter = FilterRegistry.all.first;
      _params = _filter.defaultParams;
      _previewPath = null;
      _previewVersion++;
    });

    if (isVideo) {
      final c = VideoPlayerController.file(File(newSource.path));
      _video = c;
      c.initialize().then((_) {
        if (!mounted) { c.dispose(); return; }
        setState(() {});
        c..setLooping(true)..play();
      }).catchError((_) {
        if (!mounted) return;
        c.dispose();
        setState(() => _video = null);
      });
    }
  }

  void _onFilterSelected(CameraFilter f) {
    setState(() {
      _filter = f;
      _params = f.defaultParams;
    });
    _schedulePreview();
  }

  /// Debounce filter taps so the user can scrub through the strip without
  /// firing a native render for every intermediate filter. ~120 ms feels snappy.
  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 120), _runPreview);
  }

  Future<void> _runPreview() async {
    if (_source == null) return;
    // Videos: keep the live player for colour-only filters; for effect
    // filters (blur, glitch, grain, scanlines, glow) actually render the
    // whole clip through the shader, with a progress overlay, and play the
    // result back when it's done.
    if (_isVideo) {
      if (_previewPath != null) {
        setState(() {
          _previewPath = null;
          _previewVersion++;
        });
      }
      if (_effectFilters.contains(_filter.id)) {
        await _renderVideoPreview();
      } else {
        // Coming back to a colour filter — cancel any in-flight effect render,
        // drop the cached preview player and resume the original video.
        await _dropVideoPreview();
      }
      return;
    }
    if (_filter.id == 'none') {
      setState(() {
        _previewPath = null;
        _previewVersion++;
      });
      return;
    }
    final seq = ++_previewSeq;
    try {
      final dir = await getApplicationDocumentsDirectory();
      // Unique path per request so:
      //   1) Flutter's FileImage cache can't serve a stale decode (its cache
      //      key is the file path; same path = same cached pixels).
      //   2) Two concurrent native renders can't clobber each other's output.
      final outPath = '${dir.path}/CFE_preview_$seq.jpg';
      final at = 1.0;
      await FilterEngine.instance.previewFilter(
        inputPath: _source!.path,
        outputPath: outPath,
        filterId: _filter.id,
        isVideo: false,
        params: _params,
        atSeconds: at,
      );
      if (!mounted || seq != _previewSeq) {
        // Stale completion — newer request already kicked off; throw the file
        // away so the docs dir doesn't grow.
        try { File(outPath).deleteSync(); } catch (_) {}
        return;
      }
      // Delete the previous preview file now that we have a new one ready.
      final prev = _previewPath;
      setState(() {
        _previewPath = outPath;
        _previewVersion++;
      });
      if (prev != null && prev != outPath) {
        try { File(prev).delete(); } catch (_) {}
      }
    } catch (_) {
      // A failed preview just falls back to the unfiltered source — no
      // need to surface an error mid-scrub.
    }
  }

  Future<void> _apply() async {
    if (_source == null) return;
    setState(() {
      _processing = true;
      _progress = 0;
    });
    _progressSub?.cancel();
    if (_isVideo) {
      _progressSub = FilterEngine.instance.videoProgress.listen((p) {
        if (mounted) setState(() => _progress = p);
      });
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = _isVideo
          ? '${dir.path}/CFE_imported_$ts.mp4'
          : '${dir.path}/CFE_imported_$ts.jpg';
      String saved;
      final sig = _signatureFor(_filter.id, _params);
      if (_isVideo &&
          _videoPreviewPath != null &&
          _videoPreviewKey == sig &&
          File(_videoPreviewPath!).existsSync()) {
        // The auto-preview render is full quality and already exists for
        // this exact filter + params selection. Copy it instead of
        // re-rendering — saves the full processVideo run on Apply.
        await File(_videoPreviewPath!).copy(outPath);
        saved = outPath;
      } else if (_isVideo) {
        saved = await FilterEngine.instance.processVideo(
          inputPath: _source!.path,
          outputPath: outPath,
          filterId: _filter.id,
          params: _params,
        );
      } else {
        saved = await FilterEngine.instance.processImage(
          inputPath: _source!.path,
          outputPath: outPath,
          filterId: _filter.id,
          params: _params,
        );
      }

      await FilterEngine.instance.saveToGallery(saved, isVideo: _isVideo);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CaptureViewer(file: File(saved))),
      );
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    } finally {
      _progressSub?.cancel();
      if (mounted) {
        setState(() {
          _processing = false;
          _progress = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Import & Filter'),
        actions: [
          if (_source != null)
            IconButton(
              icon: const Icon(Icons.crop, color: Colors.white),
              tooltip: 'Crop',
              onPressed: _processing ? null : _openCrop,
            ),
          if (_source != null && _isVideo)
            IconButton(
              icon: const Icon(Icons.content_cut, color: Colors.white),
              tooltip: 'Trim',
              onPressed: _processing ? null : _openTrim,
            ),
          if (_source != null)
            IconButton(
              icon: const Icon(Icons.draw, color: Colors.white),
              tooltip: 'Annotate',
              onPressed: _processing ? null : _openAnnotate,
            ),
          if (_source != null)
            TextButton(
              onPressed: _processing ? null : _apply,
              child: const Text(
                'Apply',
                style: TextStyle(color: Color(0xFFFFD400), fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBody(),
          if (_processing)
            Container(
              color: Colors.black87,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    _isVideo
                        ? 'Rendering video… ${(_progress * 100).toStringAsFixed(0)}%'
                        : 'Applying filter…',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_source == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: _isVideo ? _buildVideoPreview() : _buildImagePreview(),
          ),
        ),
        FilterPicker(
          filters: FilterRegistry.all,
          selectedId: _filter.id,
          onSelected: _onFilterSelected,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildImagePreview() {
    // If we have a shader-rendered preview on disk, prefer it — that's the
    // only way to show blur / glitch / grain / scanlines accurately. Otherwise
    // fall back to the picked image with the ColorFilter approximation.
    if (_previewPath != null) {
      return Center(
        child: Image.file(
          File(_previewPath!),
          key: ValueKey('preview-$_previewVersion'),
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      );
    }
    return Center(
      child: ColorFiltered(
        colorFilter: _previewMatrix(_filter.id),
        child: Image.file(File(_source!.path), fit: BoxFit.contain),
      ),
    );
  }

  Widget _buildVideoPreview() {
    // If we have a finished shader-rendered preview for the current filter,
    // play that. It contains the real effect (blur / glitch / grain / etc).
    final preview = _videoPreview;
    if (preview != null && preview.value.isInitialized) {
      return Center(
        child: AspectRatio(
          aspectRatio: preview.value.aspectRatio,
          child: VideoPlayer(preview),
        ),
      );
    }
    final v = _video;
    if (v == null || !v.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final isEffectFilter = _effectFilters.contains(_filter.id);
    final originalPlayer = AspectRatio(
      aspectRatio: v.value.aspectRatio,
      child: ColorFiltered(
        colorFilter: _previewMatrix(_filter.id),
        child: VideoPlayer(v),
      ),
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        Center(child: originalPlayer),
        if (isEffectFilter && _videoPreviewProcessing)
          Container(
            color: Colors.black54,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(
                    value: _videoPreviewProgress > 0 ? _videoPreviewProgress : null,
                    strokeWidth: 4,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Rendering ${_filter.name} preview… '
                  '${(_videoPreviewProgress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _signatureFor(String id, Map<String, double> params) {
    final keys = params.keys.toList()..sort();
    final body = keys.map((k) => '$k=${params[k]!.toStringAsFixed(3)}').join('&');
    return '$id|$body';
  }

  Future<void> _renderVideoPreview() async {
    final sig = _signatureFor(_filter.id, _params);
    // Already showing this exact selection? Nothing to do.
    if (_videoPreviewPath != null && _videoPreviewKey == sig) return;
    // Same job already in flight? Let it finish.
    if (_videoPreviewInFlightKey == sig && _videoPreviewProcessing) return;

    // Cancel a stale in-flight render, drop the old preview player.
    await FilterEngine.instance.cancelProcessing();
    _progressSub?.cancel();
    final oldPath = _videoPreviewPath;
    final oldPlayer = _videoPreview;
    setState(() {
      _videoPreviewPath = null;
      _videoPreviewKey = null;
      _videoPreview = null;
      _videoPreviewProcessing = true;
      _videoPreviewProgress = 0;
      _videoPreviewInFlightKey = sig;
    });
    // Pause the live video while we render — having two videos playing on
    // a phone GPU is wasteful.
    _video?.pause();
    oldPlayer?.dispose();
    if (oldPath != null) {
      try { File(oldPath).delete(); } catch (_) {}
    }

    _progressSub = FilterEngine.instance.videoProgress.listen((p) {
      if (!mounted || _videoPreviewInFlightKey != sig) return;
      setState(() => _videoPreviewProgress = p);
    });

    final seq = ++_videoPreviewSeq;
    String? rendered;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outPath = '${dir.path}/CFE_vpreview_$seq.mp4';
      // Render at full quality — this is also what Apply will save, so the
      // user gets to assess the exact final result, and Apply is instant
      // because it just copies this cached file.
      final r = await FilterEngine.instance.processVideo(
        inputPath: _source!.path,
        outputPath: outPath,
        filterId: _filter.id,
        params: _params,
      );
      // Native returns the output path on success, '' on cancellation.
      if (r.isNotEmpty && File(r).existsSync()) rendered = r;
    } catch (_) {
      // ignore — fall through and resume the original video
    }
    if (!mounted) {
      if (rendered != null) {
        try { File(rendered).delete(); } catch (_) {}
      }
      return;
    }
    if (seq != _videoPreviewSeq || _videoPreviewInFlightKey != sig) {
      // Superseded by a newer request; discard the result.
      if (rendered != null) {
        try { File(rendered).delete(); } catch (_) {}
      }
      return;
    }
    _videoPreviewInFlightKey = null;
    if (rendered == null) {
      // Render failed or was cancelled before producing a file.
      setState(() {
        _videoPreviewProcessing = false;
        _videoPreviewProgress = 0;
      });
      return;
    }
    final c = VideoPlayerController.file(File(rendered));
    try {
      await c.initialize();
      if (!mounted) { c.dispose(); return; }
      await c.setLooping(true);
      await c.play();
    } catch (_) {
      c.dispose();
      setState(() {
        _videoPreviewProcessing = false;
        _videoPreviewProgress = 0;
      });
      return;
    }
    setState(() {
      _videoPreview = c;
      _videoPreviewPath = rendered;
      _videoPreviewKey = sig;
      _videoPreviewProcessing = false;
      _videoPreviewProgress = 1;
    });
  }

  Future<void> _dropVideoPreview() async {
    if (_videoPreview == null &&
        !_videoPreviewProcessing &&
        _videoPreviewPath == null) {
      // Nothing to clean up, just make sure the original video is playing.
      if (_video?.value.isInitialized == true && !_video!.value.isPlaying) {
        _video!.play();
      }
      return;
    }
    await FilterEngine.instance.cancelProcessing();
    _progressSub?.cancel();
    final old = _videoPreview;
    final oldPath = _videoPreviewPath;
    setState(() {
      _videoPreview = null;
      _videoPreviewPath = null;
      _videoPreviewKey = null;
      _videoPreviewInFlightKey = null;
      _videoPreviewProcessing = false;
      _videoPreviewProgress = 0;
    });
    old?.dispose();
    if (oldPath != null) {
      try { File(oldPath).delete(); } catch (_) {}
    }
    if (_video?.value.isInitialized == true) {
      _video!.play();
    }
  }

  /// Approximate per-filter preview matrix — the real per-pixel shader runs
  /// only on Apply. Effect filters (blur/vhs/glitch/grain/glow) just show the
  /// untreated frame here because their look needs the shader.
  ColorFilter _previewMatrix(String id) {
    switch (id) {
      case 'kodak':
        return const ColorFilter.matrix([
          1.15, 0.05, 0, 0, 8,
          0, 1.10, 0, 0, 4,
          0, 0, 0.95, 0, -10,
          0, 0, 0, 1, 0,
        ]);
      case 'vintage':
        return const ColorFilter.matrix([
          0.393, 0.769, 0.189, 0, 0,
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ]);
      case 'cinematic':
        return const ColorFilter.matrix([
          1.18, -0.10, 0, 0, 8,
          -0.05, 1.05, -0.10, 0, 0,
          -0.20, 0.05, 1.15, 0, -8,
          0, 0, 0, 1, 0,
        ]);
      case 'coolBlue':
        return const ColorFilter.matrix([
          0.85, 0, 0.05, 0, -8,
          0, 0.95, 0.10, 0, -2,
          0.05, 0.05, 1.20, 0, 12,
          0, 0, 0, 1, 0,
        ]);
      case 'bwGlitch':
        return const ColorFilter.matrix([
          0.299, 0.587, 0.114, 0, 0,
          0.299, 0.587, 0.114, 0, 0,
          0.299, 0.587, 0.114, 0, 0,
          0, 0, 0, 1, 0,
        ]);
      case 'retro':
        return const ColorFilter.matrix([
          1.10, 0.05, 0, 0, 18,
          0.95, 1.00, 0.05, 0, 6,
          0.95, 0, 0.90, 0, 8,
          0, 0, 0, 1, 0,
        ]);
      case 'thermal':
        return const ColorFilter.matrix([
          1.50, 0.20, 0.00, 0, -20,
          0.50, 0.80, 0.00, 0, -30,
          -0.20, -0.30, 0.40, 0, 20,
          0,    0,    0,    1, 0,
        ]);
      case 'matrixVision':
        return const ColorFilter.matrix([
          0.05, 0.10, 0.00, 0, -10,
          0.30, 1.20, 0.20, 0, -2,
          0.05, 0.20, 0.10, 0, -10,
          0,    0,    0,    1, 0,
        ]);
      case 'hologram':
        return const ColorFilter.matrix([
          0.10, 0.20, 0.40, 0, -10,
          0.30, 0.75, 0.60, 0,  4,
          0.40, 0.80, 1.10, 0, 18,
          0,    0,    0,    1, 0,
        ]);
      default:
        return const ColorFilter.mode(Colors.transparent, BlendMode.multiply);
    }
  }
}
