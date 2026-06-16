import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../engine/filter_engine.dart';

/// Free-style annotation: brush + text + emoji stickers on top of an image or
/// video. Returns the path of the rendered output (JPEG for images, MP4 for
/// videos) via Navigator.pop, or null on cancel.
class AnnotateScreen extends StatefulWidget {
  final File source;
  final bool isVideo;
  const AnnotateScreen({super.key, required this.source, this.isVideo = false});

  @override
  State<AnnotateScreen> createState() => _AnnotateScreenState();
}

enum _Mode { paint, text, emoji }

/// Stroke = a series of points in normalised media space (0..1 of canvas
/// dimensions) plus paint parameters.
class _Stroke {
  final List<Offset> points;
  final Color color;
  final double width;      // pixels at 1080-px reference resolution
  final double opacity;
  _Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.opacity,
  });
}

/// Text or emoji sticker. Position/scale/rotation are in normalised media space.
class _Sticker {
  final String id;
  final bool isEmoji;
  String content;
  Offset center;       // 0..1 of canvas
  double scale;        // visual scale
  double rotation;     // radians
  Color color;
  double baseFontSize; // px at 1080-px reference resolution
  FontWeight weight;
  _Sticker({
    required this.id,
    required this.isEmoji,
    required this.content,
    required this.center,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.color = Colors.white,
    this.baseFontSize = 72,
    this.weight = FontWeight.w800,
  });

  _Sticker clone() => _Sticker(
    id: id, isEmoji: isEmoji, content: content, center: center,
    scale: scale, rotation: rotation, color: color,
    baseFontSize: baseFontSize, weight: weight,
  );
}

class _Snapshot {
  final List<_Stroke> strokes;
  final List<_Sticker> stickers;
  _Snapshot(this.strokes, this.stickers);
}

class _AnnotateScreenState extends State<AnnotateScreen> {
  _Mode _mode = _Mode.paint;
  final List<_Stroke> _strokes = [];
  final List<_Sticker> _stickers = [];
  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];

  // Brush state
  Color _brushColor = const Color(0xFFFF3B30);
  double _brushWidth = 8;
  double _brushOpacity = 1.0;

  // Active stroke during drag
  List<Offset>? _activePoints;

  // Selected sticker (for delete / colour change)
  String? _selectedSticker;

  // Source preview
  Size? _mediaSize;
  VideoPlayerController? _video;

  bool _saving = false;

  static const _palette = <Color>[
    Color(0xFFFFFFFF), Color(0xFF000000),
    Color(0xFFFF3B30), Color(0xFFFFCC00), Color(0xFF34C759),
    Color(0xFF00C7BE), Color(0xFF007AFF), Color(0xFFAF52DE),
    Color(0xFFFF2D55),
  ];

  // Compact emoji set; users can also paste from clipboard.
  static const _emojis = [
    '😀','😂','😍','🥰','😎','🤩','🥳','😜',
    '🤔','😴','🙃','😇','🤯','🥺','😡','🤡',
    '🔥','✨','⭐','💯','💫','🎉','🎊','🌈',
    '❤️','💔','💖','💕','💜','💙','💚','💛',
    '👍','👎','👏','🙏','💪','✌️','🤝','🤞',
    '🐶','🐱','🦄','🐼','🐯','🦁','🐸','🐔',
    '🌹','🌸','🌺','🌻','🍀','🌙','☀️','🌧️',
    '🍕','🍔','🍟','🍦','🍩','☕','🍷','🥂',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _initVideo();
    } else {
      _resolveImageSize();
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _resolveImageSize() async {
    final image = Image.file(widget.source);
    final stream = image.image.resolve(const ImageConfiguration());
    stream.addListener(ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() => _mediaSize = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      ));
    }));
  }

  Future<void> _initVideo() async {
    final c = VideoPlayerController.file(widget.source);
    _video = c;
    try {
      await c.initialize();
      if (!mounted) { c.dispose(); return; }
      setState(() => _mediaSize = c.value.size);
      await c.setLooping(true);
      await c.play();
    } catch (_) {
      if (!mounted) return;
      c.dispose();
      setState(() => _video = null);
    }
  }

  void _pushSnapshot() {
    _undo.add(_Snapshot(
      _strokes.map((s) => _Stroke(
        points: List.from(s.points), color: s.color,
        width: s.width, opacity: s.opacity,
      )).toList(),
      _stickers.map((s) => s.clone()).toList(),
    ));
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    _redo.add(_Snapshot(
      _strokes.map((s) => _Stroke(
        points: List.from(s.points), color: s.color,
        width: s.width, opacity: s.opacity,
      )).toList(),
      _stickers.map((s) => s.clone()).toList(),
    ));
    final snap = _undo.removeLast();
    setState(() {
      _strokes
        ..clear()
        ..addAll(snap.strokes);
      _stickers
        ..clear()
        ..addAll(snap.stickers);
      _selectedSticker = null;
    });
  }

  void _redoLast() {
    if (_redo.isEmpty) return;
    _undo.add(_Snapshot(
      _strokes.map((s) => _Stroke(
        points: List.from(s.points), color: s.color,
        width: s.width, opacity: s.opacity,
      )).toList(),
      _stickers.map((s) => s.clone()).toList(),
    ));
    final snap = _redo.removeLast();
    setState(() {
      _strokes
        ..clear()
        ..addAll(snap.strokes);
      _stickers
        ..clear()
        ..addAll(snap.stickers);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Annotate'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            color: Colors.white,
            onPressed: _undo.isEmpty ? null : _undoLast,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            color: Colors.white,
            onPressed: _redo.isEmpty ? null : _redoLast,
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(
              _saving ? 'Saving…' : 'Done',
              style: const TextStyle(
                color: Color(0xFFFFD400), fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildCanvas()),
          _buildToolbar(),
        ],
      ),
    );
  }

  // ----- canvas ---------------------------------------------------------

  Widget _buildCanvas() {
    return LayoutBuilder(builder: (ctx, c) {
      final size = _mediaSize;
      if (size == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final viewport = Size(c.maxWidth, c.maxHeight);
      final scale = math.min(viewport.width / size.width, viewport.height / size.height);
      final rectSize = Size(size.width * scale, size.height * scale);
      final offset = Offset(
        (viewport.width - rectSize.width) / 2,
        (viewport.height - rectSize.height) / 2,
      );
      return Stack(children: [
        Positioned(
          left: offset.dx, top: offset.dy,
          width: rectSize.width, height: rectSize.height,
          child: _buildMedia(),
        ),
        Positioned(
          left: offset.dx, top: offset.dy,
          width: rectSize.width, height: rectSize.height,
          child: _buildPaintLayer(rectSize),
        ),
        // Stickers
        for (final sticker in _stickers)
          _StickerWidget(
            sticker: sticker,
            canvasOffset: offset,
            canvasSize: rectSize,
            selected: _selectedSticker == sticker.id,
            paintMode: _mode == _Mode.paint,
            onSelect: () => setState(() => _selectedSticker = sticker.id),
            onChanged: (s) {
              // Throttle snapshot — only push on gesture start.
              setState(() {});
            },
            onDelete: () {
              _pushSnapshot();
              setState(() {
                _stickers.removeWhere((s) => s.id == sticker.id);
                if (_selectedSticker == sticker.id) _selectedSticker = null;
              });
            },
            onStart: _pushSnapshot,
          ),
      ]);
    });
  }

  Widget _buildMedia() {
    if (widget.isVideo) {
      final v = _video;
      if (v == null || !v.value.isInitialized) {
        return const ColoredBox(color: Colors.black);
      }
      return VideoPlayer(v);
    }
    return Image.file(widget.source, fit: BoxFit.fill);
  }

  Widget _buildPaintLayer(Size canvasSize) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _mode == _Mode.paint
          ? (d) {
              _pushSnapshot();
              setState(() {
                _selectedSticker = null;
                _activePoints = [_normalize(d.localPosition, canvasSize)];
              });
            }
          : null,
      onPanUpdate: _mode == _Mode.paint
          ? (d) {
              if (_activePoints == null) return;
              setState(() {
                _activePoints!.add(_normalize(d.localPosition, canvasSize));
              });
            }
          : null,
      onPanEnd: _mode == _Mode.paint
          ? (_) {
              if (_activePoints == null) return;
              setState(() {
                _strokes.add(_Stroke(
                  points: _activePoints!,
                  color: _brushColor,
                  width: _brushWidth,
                  opacity: _brushOpacity,
                ));
                _activePoints = null;
              });
            }
          : null,
      onTapUp: (d) {
        if (_mode == _Mode.text) {
          _addText(_normalize(d.localPosition, canvasSize));
        } else if (_mode == _Mode.emoji) {
          _openEmojiPicker(_normalize(d.localPosition, canvasSize));
        } else {
          // Paint mode tap = deselect any sticker
          setState(() => _selectedSticker = null);
        }
      },
      child: CustomPaint(
        size: canvasSize,
        painter: _StrokesPainter(
          strokes: _strokes,
          active: _activePoints == null
              ? null
              : _Stroke(
                  points: _activePoints!,
                  color: _brushColor,
                  width: _brushWidth,
                  opacity: _brushOpacity,
                ),
          canvasSize: canvasSize,
        ),
      ),
    );
  }

  Offset _normalize(Offset local, Size size) =>
      Offset(local.dx / size.width, local.dy / size.height);

  // ----- toolbar --------------------------------------------------------

  Widget _buildToolbar() {
    return Container(
      color: Colors.black87,
      child: SafeArea(
        top: false,
        child: Column(children: [
          if (_mode == _Mode.paint) _buildPaintControls(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _modeButton(_Mode.paint, Icons.brush, 'Paint'),
              _modeButton(_Mode.text, Icons.title, 'Text'),
              _modeButton(_Mode.emoji, Icons.emoji_emotions, 'Emoji'),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _modeButton(_Mode m, IconData icon, String label) {
    final active = _mode == m;
    return InkWell(
      onTap: () => setState(() => _mode = m),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: active ? const Color(0xFFFFD400) : Colors.white, size: 26),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: active ? const Color(0xFFFFD400) : Colors.white,
                  fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildPaintControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(children: [
        // Color row
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: _palette.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final c = _palette[i];
              final selected = _brushColor == c;
              return GestureDetector(
                onTap: () => setState(() => _brushColor = c),
                child: Container(
                  width: 32,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? const Color(0xFFFFD400) : Colors.white24,
                      width: selected ? 3 : 1,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Row(children: [
          const Icon(Icons.brush, color: Colors.white54, size: 18),
          Expanded(
            child: Slider(
              value: _brushWidth, min: 2, max: 40,
              onChanged: (v) => setState(() => _brushWidth = v),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(_brushWidth.toStringAsFixed(0),
                style: const TextStyle(color: Colors.white70)),
          ),
        ]),
        Row(children: [
          const Icon(Icons.opacity, color: Colors.white54, size: 18),
          Expanded(
            child: Slider(
              value: _brushOpacity, min: 0.10, max: 1.0,
              onChanged: (v) => setState(() => _brushOpacity = v),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text((_brushOpacity * 100).toStringAsFixed(0),
                style: const TextStyle(color: Colors.white70)),
          ),
        ]),
      ]),
    );
  }

  // ----- text + emoji ---------------------------------------------------

  Future<void> _addText(Offset normalisedCenter) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const _TextInputDialog(),
    );
    if (result == null || result.trim().isEmpty) return;
    _pushSnapshot();
    setState(() {
      final s = _Sticker(
        id: 't_${DateTime.now().microsecondsSinceEpoch}',
        isEmoji: false,
        content: result,
        center: normalisedCenter,
        color: _brushColor,
      );
      _stickers.add(s);
      _selectedSticker = s.id;
    });
  }

  Future<void> _openEmojiPicker(Offset normalisedCenter) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (_) => GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 8,
        ),
        itemCount: _emojis.length,
        itemBuilder: (_, i) {
          final e = _emojis[i];
          return InkWell(
            onTap: () => Navigator.pop(context, e),
            child: Center(child: Text(e, style: const TextStyle(fontSize: 30))),
          );
        },
      ),
    );
    if (chosen == null) return;
    _pushSnapshot();
    setState(() {
      final s = _Sticker(
        id: 'e_${DateTime.now().microsecondsSinceEpoch}',
        isEmoji: true,
        content: chosen,
        center: normalisedCenter,
        baseFontSize: 96,
      );
      _stickers.add(s);
      _selectedSticker = s.id;
    });
  }

  // ----- save -----------------------------------------------------------

  Future<void> _save() async {
    if (_mediaSize == null) return;
    setState(() => _saving = true);
    _video?.pause();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      if (widget.isVideo) {
        // 1. Render overlay PNG at media's display dims.
        final overlayPath = '${dir.path}/CFE_overlay_$ts.png';
        await _renderOverlayPng(overlayPath, _mediaSize!, includeMedia: false);
        // 2. Native compose at display orientation + audio passthrough.
        final out = '${dir.path}/CFE_annotated_$ts.mp4';
        final saved = await FilterEngine.instance.composeVideo(
          inputPath: widget.source.path,
          outputPath: out,
          overlayPngPath: overlayPath,
        );
        try { File(overlayPath).delete(); } catch (_) {}
        if (!mounted) return;
        Navigator.pop(context, saved);
      } else {
        // Image — composite locally in one PictureRecorder, save JPEG.
        final out = '${dir.path}/CFE_annotated_$ts.jpg';
        await _renderImageJpeg(out, _mediaSize!);
        if (!mounted) return;
        Navigator.pop(context, out);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
      setState(() => _saving = false);
    }
  }

  Future<void> _renderImageJpeg(String path, Size mediaSize) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Draw the source image at full resolution.
    final bytes = await widget.source.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    canvas.drawImage(image, Offset.zero, Paint());
    _drawAnnotations(canvas, mediaSize);
    final picture = recorder.endRecording();
    final out = await picture.toImage(image.width, image.height);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('PNG encode failed');
    await File(path).writeAsBytes(png.buffer.asUint8List());
  }

  /// Render the annotations (paint + stickers) to a transparent PNG at the
  /// given media [size]. Used as the overlay layer for the native video
  /// compose path. When [includeMedia] is true the media is drawn first
  /// (used for the image path).
  Future<void> _renderOverlayPng(
      String path, Size size, {required bool includeMedia}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (includeMedia && !widget.isVideo) {
      final bytes = await widget.source.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      canvas.drawImage(frame.image, Offset.zero, Paint());
    }
    _drawAnnotations(canvas, size);
    final picture = recorder.endRecording();
    final out = await picture.toImage(size.width.toInt(), size.height.toInt());
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('PNG encode failed');
    await File(path).writeAsBytes(png.buffer.asUint8List());
  }

  void _drawAnnotations(Canvas canvas, Size size) {
    // Strokes — convert normalised points back to pixel space.
    // Reference resolution for widths was 1080 px on the long edge of the
    // edit canvas; scale to media size for consistent appearance.
    final long = math.max(size.width, size.height);
    final widthScale = long / 1080.0;
    for (final stroke in _strokes) {
      if (stroke.points.length < 2) continue;
      final paint = Paint()
        ..color = stroke.color.withValues(alpha: stroke.opacity)
        ..strokeWidth = stroke.width * widthScale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      final path = Path();
      final first = stroke.points.first;
      path.moveTo(first.dx * size.width, first.dy * size.height);
      for (int i = 1; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
    // Stickers
    for (final s in _stickers) {
      final fontSize = s.baseFontSize * widthScale * s.scale;
      final tp = TextPainter(
        text: TextSpan(
          text: s.content,
          style: TextStyle(
            color: s.color,
            fontSize: fontSize,
            fontWeight: s.weight,
            shadows: s.isEmoji ? null : [
              const Shadow(blurRadius: 6, color: Colors.black54, offset: Offset(0, 2)),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      canvas.save();
      canvas.translate(s.center.dx * size.width, s.center.dy * size.height);
      canvas.rotate(s.rotation);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }
}

class _StrokesPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final _Stroke? active;
  final Size canvasSize;
  _StrokesPainter({
    required this.strokes,
    required this.active,
    required this.canvasSize,
  });
  @override
  void paint(Canvas canvas, Size size) {
    void draw(_Stroke s) {
      if (s.points.length < 2) return;
      final paint = Paint()
        ..color = s.color.withValues(alpha: s.opacity)
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      final path = Path();
      final first = s.points.first;
      path.moveTo(first.dx * size.width, first.dy * size.height);
      for (int i = 1; i < s.points.length; i++) {
        final p = s.points[i];
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
    for (final s in strokes) { draw(s); }
    if (active != null) draw(active!);
  }
  @override
  bool shouldRepaint(covariant _StrokesPainter old) => true;
}

class _StickerWidget extends StatefulWidget {
  final _Sticker sticker;
  final Offset canvasOffset;
  final Size canvasSize;
  final bool selected;
  final bool paintMode;
  final VoidCallback onSelect;
  final ValueChanged<_Sticker> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onStart;
  const _StickerWidget({
    required this.sticker,
    required this.canvasOffset,
    required this.canvasSize,
    required this.selected,
    required this.paintMode,
    required this.onSelect,
    required this.onChanged,
    required this.onDelete,
    required this.onStart,
  });
  @override
  State<_StickerWidget> createState() => _StickerWidgetState();
}

class _StickerWidgetState extends State<_StickerWidget> {
  Offset? _startFocal;
  Offset? _startCenter;
  double? _startScale;
  double? _startRotation;

  @override
  Widget build(BuildContext context) {
    final s = widget.sticker;
    final fontSize = s.baseFontSize *
        (math.max(widget.canvasSize.width, widget.canvasSize.height) / 1080.0) *
        s.scale;
    final tp = TextPainter(
      text: TextSpan(
        text: s.content,
        style: TextStyle(
          color: s.color,
          fontSize: fontSize,
          fontWeight: s.weight,
          shadows: s.isEmoji ? null : [
            const Shadow(blurRadius: 6, color: Colors.black54, offset: Offset(0, 2)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    final centerPx = Offset(
      widget.canvasOffset.dx + s.center.dx * widget.canvasSize.width,
      widget.canvasOffset.dy + s.center.dy * widget.canvasSize.height,
    );
    final left = centerPx.dx - tp.width / 2;
    final top = centerPx.dy - tp.height / 2;
    return Positioned(
      left: left, top: top,
      width: tp.width, height: tp.height,
      child: IgnorePointer(
        // While painting, stickers don't intercept — the user can draw over
        // and under them. Tapping the mode bar back to text/emoji re-arms.
        ignoring: widget.paintMode,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          onLongPress: widget.onDelete,
          onScaleStart: (d) {
            widget.onSelect();
            widget.onStart();
            _startFocal = d.focalPoint;
            _startCenter = s.center;
            _startScale = s.scale;
            _startRotation = s.rotation;
          },
          onScaleUpdate: (d) {
            if (_startFocal == null) return;
            final dx = (d.focalPoint.dx - _startFocal!.dx) / widget.canvasSize.width;
            final dy = (d.focalPoint.dy - _startFocal!.dy) / widget.canvasSize.height;
            setState(() {
              s.center = Offset(
                (_startCenter!.dx + dx).clamp(0.0, 1.0),
                (_startCenter!.dy + dy).clamp(0.0, 1.0),
              );
              s.scale = (_startScale! * d.scale).clamp(0.2, 6.0);
              s.rotation = _startRotation! + d.rotation;
            });
            widget.onChanged(s);
          },
          child: Transform.rotate(
            angle: s.rotation,
            child: Container(
              decoration: widget.selected
                  ? BoxDecoration(
                      border: Border.all(color: const Color(0xFFFFD400), width: 1.5),
                    )
                  : null,
              alignment: Alignment.center,
              child: Text(
                s.content,
                style: TextStyle(
                  color: s.color,
                  fontSize: fontSize,
                  fontWeight: s.weight,
                  shadows: s.isEmoji ? null : [
                    const Shadow(blurRadius: 6, color: Colors.black54, offset: Offset(0, 2)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog();
  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  final _ctrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.black87,
      title: const Text('Add text', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 80,
        style: const TextStyle(color: Colors.white, fontSize: 18),
        cursorColor: const Color(0xFFFFD400),
        decoration: const InputDecoration(
          hintText: 'Type something…',
          hintStyle: TextStyle(color: Colors.white38),
          counterStyle: TextStyle(color: Colors.white24),
        ),
        inputFormatters: [LengthLimitingTextInputFormatter(80)],
        onSubmitted: (_) => Navigator.pop(context, _ctrl.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Add',
              style: TextStyle(color: Color(0xFFFFD400))),
        ),
      ],
    );
  }
}
