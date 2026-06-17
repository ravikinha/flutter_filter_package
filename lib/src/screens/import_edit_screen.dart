import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../engine/filter_engine.dart';
import '../models/filter.dart';
import '../widgets/filter_picker.dart';
import '../widgets/param_sheet.dart';
import 'annotate_screen.dart';
import 'capture_viewer.dart';
import 'crop_screen.dart';
import 'trim_screen.dart';

class ImportEditScreen extends StatefulWidget {
  /// Optional source to load straight away (skips the pick sheet). Used when
  /// pushed from the camera capture/record flow so the just-taken photo or
  /// video lands directly in the editor.
  final XFile? initialSource;
  final bool? initialIsVideo;
  final CameraFilter? initialFilter;
  final Map<String, double>? initialParams;

  const ImportEditScreen({
    super.key,
    this.initialSource,
    this.initialIsVideo,
    this.initialFilter,
    this.initialParams,
  });

  @override
  State<ImportEditScreen> createState() => _ImportEditScreenState();
}

class _ImportEditScreenState extends State<ImportEditScreen> {
  final ImagePicker _picker = ImagePicker();
  XFile? _source;
  bool _isVideo = false;
  VideoPlayerController? _video;

  // Two stacked selections: an effect (drives the shader render) and a colour
  // grade (a cheap per-pixel pass on top). Either can be Original (none).
  CameraFilter _filter = FilterRegistry.all.first;       // effect slot
  Map<String, double> _params = {};
  CameraFilter _color = FilterRegistry.all.first;        // colour slot
  Map<String, double> _colorParams = {};
  // Which slot the Tune button edits (set on selection).
  bool _tuneColor = false;

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
    // When pushed with a pre-supplied source (camera capture / record path,
    // or the camera screen's library button), skip the picker and load that
    // file directly with the caller's filter selection.
    if (widget.initialSource != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadInitial());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
    }
  }

  Future<void> _loadInitial() async {
    final src = widget.initialSource!;
    final isVideo = widget.initialIsVideo ?? false;
    final filter = widget.initialFilter ?? FilterRegistry.all.first;
    final params = Map<String, double>.from(
      widget.initialParams ?? filter.defaultParams,
    );
    // Route the camera's filter into the correct slot.
    final intoEffect = _effectFilters.contains(filter.id);
    setState(() {
      _source = src;
      _isVideo = isVideo;
      if (intoEffect) {
        _filter = filter;
        _params = params;
      } else {
        _color = filter;
        _colorParams = params;
        _tuneColor = filter.id != 'none';
      }
    });
    if (isVideo) {
      final c = VideoPlayerController.file(File(src.path));
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
    // If the caller pre-selected an effect/colour filter, kick the preview
    // render so the user immediately sees their filter applied.
    if (filter.id != 'none') {
      _schedulePreview();
    }
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
      _resetFilters();
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

    // Reset both filter slots back to Original and clear the rendered preview.
    setState(() {
      _source = newSource;
      _isVideo = isVideo;
      _resetFilters();
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

  // Whichever filter the Tune button currently edits.
  CameraFilter get _tuneFilter => _tuneColor ? _color : _filter;
  Map<String, double> get _tuneParams => _tuneColor ? _colorParams : _params;

  String? get _colorFilterArg => _color.id == 'none' ? null : _color.id;
  Map<String, double>? get _colorParamsArg =>
      _color.id == 'none' ? null : _colorParams;

  Future<void> _openParamSheet() async {
    if (_tuneFilter.params.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ParamSheet(
        filter: _tuneFilter,
        values: _tuneParams,
        onChanged: (k, v) {
          _tuneParams[k] = v;
          // Re-render preview on release of any slider so the on-screen
          // image / video reflects the new params.
          _schedulePreview();
        },
      ),
    );
  }

  void _resetFilters() {
    final none = FilterRegistry.all.first;
    _filter = none;
    _params = none.defaultParams;
    _color = none;
    _colorParams = none.defaultParams;
    _tuneColor = false;
  }

  /// Effect-slot selection (drives the shader render). Effects section.
  void _onEffectSelected(CameraFilter f) {
    setState(() {
      _filter = f;
      _params = f.defaultParams;
      _tuneColor = false;
      _effectExpanded = true;
      _colorExpanded = false;
    });
    _schedulePreview();
  }

  /// Colour-slot selection (stacked grade). Color section.
  void _onColorSelected(CameraFilter f) {
    setState(() {
      _color = f;
      _colorParams = f.defaultParams;
      _tuneColor = f.id != 'none';
      _colorExpanded = true;
      _effectExpanded = false;
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
      // An effect needs a shader render. A colour-only selection is shown live
      // with a ColorFilter matrix on the playing video (no render needed).
      if (_filter.id != 'none') {
        await _renderVideoPreview();
      } else {
        await _dropVideoPreview();
      }
      return;
    }
    // Images: render whenever either slot is non-Original (both stack in one
    // pass). If both are Original, just show the source.
    if (_filter.id == 'none' && _color.id == 'none') {
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
        colorFilterId: _colorFilterArg,
        colorParams: _colorParamsArg,
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
      final sig = _combinedSignature();
      if (_isVideo &&
          _videoPreviewPath != null &&
          _videoPreviewKey == sig &&
          File(_videoPreviewPath!).existsSync()) {
        // The auto-preview render is full quality and already exists for
        // this exact effect + colour + params selection. Copy it instead of
        // re-rendering — saves the full processVideo run on Apply.
        await File(_videoPreviewPath!).copy(outPath);
        saved = outPath;
      } else if (_isVideo) {
        saved = await FilterEngine.instance.processVideo(
          inputPath: _source!.path,
          outputPath: outPath,
          filterId: _filter.id,
          params: _params,
          colorFilterId: _colorFilterArg,
          colorParams: _colorParamsArg,
        );
      } else {
        saved = await FilterEngine.instance.processImage(
          inputPath: _source!.path,
          outputPath: outPath,
          filterId: _filter.id,
          params: _params,
          colorFilterId: _colorFilterArg,
          colorParams: _colorParamsArg,
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

  // Section expand state for the bottom toolbar.
  bool _colorExpanded = true;
  bool _effectExpanded = false;

  /// Filters that work as direct ColorFilter overlays on a playing video and
  /// don't need a shader render to preview — the "Color" tab.
  List<CameraFilter> get _colorFilters => FilterRegistry.all
      .where((f) => !_effectFilters.contains(f.id))
      .toList();

  /// Filters that require the GPU shader pipeline — Blur, Glitch, VHS,
  /// Cyberpunk, Aurora, Dogpatch Pro, etc. The "Effects" tab. Original (none)
  /// is prepended so the user can clear the effect.
  List<CameraFilter> get _renderFilters => [
        FilterRegistry.all.first, // Original / none
        ...FilterRegistry.all.where((f) => _effectFilters.contains(f.id)),
      ];

  /// Signature of the full effect+colour+params combination, used to key the
  /// cached video render so Apply can reuse it and so a re-tap of the same
  /// combo doesn't re-render.
  String _combinedSignature() =>
      '${_signatureFor(_filter.id, _params)}#${_signatureFor(_color.id, _colorParams)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Import & Filter'),
        actions: [
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
        _buildBottomToolbar(),
      ],
    );
  }

  Widget _buildBottomToolbar() {
    return Container(
      color: Colors.black87,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tool icons row — Crop / Trim (video only) / Annotate / Tune.
            _buildToolRow(),
            const Divider(color: Colors.white12, height: 1),
            // Expandable Color filters — applied as a per-pixel grade.
            _buildFilterSection(
              title: 'Color',
              icon: Icons.palette_outlined,
              filters: _colorFilters,
              selectedId: _color.id,
              activeName: _color.id == 'none' ? null : _color.name,
              onSelected: _onColorSelected,
              expanded: _colorExpanded,
              onToggle: () => setState(() {
                _colorExpanded = !_colorExpanded;
                if (_colorExpanded) _effectExpanded = false;
              }),
            ),
            const Divider(color: Colors.white12, height: 1),
            // Expandable Effect filters — the primary shader pass.
            _buildFilterSection(
              title: 'Effects',
              icon: Icons.auto_fix_high_outlined,
              filters: _renderFilters,
              selectedId: _filter.id,
              activeName: _filter.id == 'none' ? null : _filter.name,
              onSelected: _onEffectSelected,
              expanded: _effectExpanded,
              onToggle: () => setState(() {
                _effectExpanded = !_effectExpanded;
                if (_effectExpanded) _colorExpanded = false;
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _toolButton(
            icon: Icons.crop,
            label: 'Crop',
            onTap: _processing ? null : _openCrop,
          ),
          if (_isVideo)
            _toolButton(
              icon: Icons.content_cut,
              label: 'Trim',
              onTap: _processing ? null : _openTrim,
            ),
          _toolButton(
            icon: Icons.draw,
            label: 'Annotate',
            onTap: _processing ? null : _openAnnotate,
          ),
          _toolButton(
            icon: Icons.tune,
            label: 'Tune',
            onTap: _tuneFilter.params.isEmpty || _processing ? null : _openParamSheet,
            dimmed: _tuneFilter.params.isEmpty,
          ),
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool dimmed = false,
  }) {
    final color = onTap == null || dimmed ? Colors.white38 : Colors.white;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterSection({
    required String title,
    required IconData icon,
    required List<CameraFilter> filters,
    required String selectedId,
    required String? activeName,
    required ValueChanged<CameraFilter> onSelected,
    required bool expanded,
    required VoidCallback onToggle,
  }) {
    final activeHere = activeName != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(icon, color: Colors.white70, size: 18),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600,
                  ),
                ),
                if (activeHere) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0x33FFD400),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      activeName,
                      style: const TextStyle(
                        color: Color(0xFFFFD400), fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  '${filters.length}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(
                    Icons.expand_more, color: Colors.white70, size: 22,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: FilterPicker(
                    filters: filters,
                    selectedId: selectedId,
                    onSelected: onSelected,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
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

    final hasEffect = _filter.id != 'none';
    // Live video shows the colour grade as a ColorFilter matrix overlay; the
    // effect (if any) is rendered into _videoPreview above, so here we only
    // need the colour approximation underneath the render-progress overlay.
    final originalPlayer = AspectRatio(
      aspectRatio: v.value.aspectRatio,
      child: ColorFiltered(
        colorFilter: _previewMatrix(_color.id),
        child: VideoPlayer(v),
      ),
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        Center(child: originalPlayer),
        if (hasEffect && _videoPreviewProcessing)
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
    final sig = _combinedSignature();
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
        colorFilterId: _colorFilterArg,
        colorParams: _colorParamsArg,
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
