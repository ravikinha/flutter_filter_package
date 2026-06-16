import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../engine/filter_engine.dart';

/// Pushed when the user wants to crop a picked image OR video. Returns the
/// path of the new file via Navigator.pop, or null on cancel.
class CropScreen extends StatefulWidget {
  final File source;
  final bool isVideo;
  const CropScreen({super.key, required this.source, this.isVideo = false});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

enum _AspectLock { free, square, portrait45, landscape169 }

class _CropScreenState extends State<CropScreen> {
  // Defaults — full frame, no flips, free aspect.
  static const Rect _initialRect = Rect.fromLTWH(0.05, 0.10, 0.90, 0.80);

  Rect _rect = _initialRect;
  _AspectLock _lock = _AspectLock.free;
  bool _flipH = false;
  bool _flipV = false;
  bool _saving = false;

  // For image sources we need intrinsic size.
  Size? _imgSize;
  // For video sources we use a VideoPlayer to preview the first frame.
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _initVideo();
    } else {
      _resolveImageSize();
    }
  }

  Future<void> _resolveImageSize() async {
    final image = Image.file(widget.source);
    final stream = image.image.resolve(const ImageConfiguration());
    stream.addListener(ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() => _imgSize = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      ));
      _applyAspect();
    }));
  }

  Future<void> _initVideo() async {
    final c = VideoPlayerController.file(widget.source);
    _video = c;
    try {
      await c.initialize();
      if (!mounted) { c.dispose(); return; }
      setState(() => _imgSize = c.value.size);
      await c.setLooping(true);
      await c.play();
      _applyAspect();
    } catch (_) {
      if (!mounted) return;
      c.dispose();
      setState(() => _video = null);
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  double? _aspectRatio() {
    switch (_lock) {
      case _AspectLock.free: return null;
      case _AspectLock.square: return 1.0;
      case _AspectLock.portrait45: return 4 / 5;
      case _AspectLock.landscape169: return 16 / 9;
    }
  }

  void _applyAspect() {
    final ratio = _aspectRatio();
    if (ratio == null || _imgSize == null) return;
    final imgAspect = _imgSize!.width / _imgSize!.height;
    final normAspect = ratio / imgAspect;
    final cx = _rect.center.dx;
    final cy = _rect.center.dy;
    double w = _rect.width;
    double h = w / normAspect;
    if (h > 1.0) { h = 1.0; w = h * normAspect; }
    if (w > 1.0) { w = 1.0; h = w / normAspect; }
    var l = (cx - w / 2).clamp(0.0, 1.0 - w);
    var t = (cy - h / 2).clamp(0.0, 1.0 - h);
    setState(() => _rect = Rect.fromLTWH(l.toDouble(), t.toDouble(), w, h));
  }

  void _reset() {
    setState(() {
      _rect = _initialRect;
      _lock = _AspectLock.free;
      _flipH = false;
      _flipV = false;
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
        title: Text(widget.isVideo ? 'Crop video' : 'Crop'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore, color: Colors.white),
            tooltip: 'Reset',
            onPressed: _saving ? null : _reset,
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
          Expanded(child: _buildCropArea()),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildCropArea() {
    return LayoutBuilder(builder: (ctx, c) {
      if (_imgSize == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final viewport = Size(c.maxWidth, c.maxHeight);
      final imgW = _imgSize!.width;
      final imgH = _imgSize!.height;
      final scale = math.min(viewport.width / imgW, viewport.height / imgH);
      final imgRectSize = Size(imgW * scale, imgH * scale);
      final offset = Offset(
        (viewport.width - imgRectSize.width) / 2,
        (viewport.height - imgRectSize.height) / 2,
      );
      // Live flip preview — Transform.scale around the image's own center.
      Widget mediaPreview;
      if (widget.isVideo) {
        final v = _video;
        if (v != null && v.value.isInitialized) {
          mediaPreview = VideoPlayer(v);
        } else {
          mediaPreview = const ColoredBox(color: Colors.black);
        }
      } else {
        mediaPreview = Image.file(widget.source, fit: BoxFit.fill);
      }
      mediaPreview = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          _flipH ? -1.0 : 1.0,
          _flipV ? -1.0 : 1.0,
          1.0,
        ),
        child: mediaPreview,
      );
      return _CropArea(
        imageRect: offset & imgRectSize,
        rect: _rect,
        onRectChanged: (r) => setState(() => _rect = r),
        imageSize: _imgSize!,
        aspectRatio: _aspectRatio(),
        child: Positioned(
          left: offset.dx,
          top: offset.dy,
          width: imgRectSize.width,
          height: imgRectSize.height,
          child: mediaPreview,
        ),
      );
    });
  }

  Widget _buildToolbar() {
    return Container(
      color: Colors.black87,
      child: SafeArea(
        top: false,
        child: Column(children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _ToolButton(
                icon: Icons.flip,
                label: 'Flip H',
                active: _flipH,
                onTap: () => setState(() => _flipH = !_flipH),
              ),
              _ToolButton(
                icon: Icons.flip_to_back,
                // Visual hint: rotate the flip icon 90° for vertical.
                rotateIcon: true,
                label: 'Flip V',
                active: _flipV,
                onTap: () => setState(() => _flipV = !_flipV),
              ),
              _ToolButton(
                icon: Icons.restore,
                label: 'Reset',
                active: false,
                onTap: _reset,
              ),
            ],
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              _aspectChip('Free', _AspectLock.free, Icons.crop_free),
              _aspectChip('1:1', _AspectLock.square, Icons.crop_square),
              _aspectChip('4:5', _AspectLock.portrait45, Icons.crop_portrait),
              _aspectChip('16:9', _AspectLock.landscape169, Icons.crop_16_9),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _aspectChip(String label, _AspectLock value, IconData icon) {
    final selected = _lock == value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: ChoiceChip(
        selected: selected,
        avatar: Icon(icon, size: 16,
            color: selected ? Colors.black : Colors.white70),
        label: Text(label),
        labelStyle: TextStyle(
          color: selected ? Colors.black : Colors.white,
          fontWeight: FontWeight.w600,
        ),
        backgroundColor: Colors.white12,
        selectedColor: const Color(0xFFFFD400),
        onSelected: (_) {
          setState(() => _lock = value);
          _applyAspect();
        },
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    _video?.pause();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = widget.isVideo
          ? '${dir.path}/CFE_crop_$ts.mp4'
          : '${dir.path}/CFE_crop_$ts.jpg';
      final String saved;
      if (widget.isVideo) {
        saved = await FilterEngine.instance.cropVideo(
          inputPath: widget.source.path,
          outputPath: outPath,
          left: _rect.left,
          top: _rect.top,
          right: _rect.right,
          bottom: _rect.bottom,
          flipH: _flipH,
          flipV: _flipV,
        );
      } else {
        saved = await FilterEngine.instance.cropImage(
          inputPath: widget.source.path,
          outputPath: outPath,
          left: _rect.left,
          top: _rect.top,
          right: _rect.right,
          bottom: _rect.bottom,
          flipH: _flipH,
          flipV: _flipV,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Crop failed: $e')),
      );
      setState(() => _saving = false);
    }
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool rotateIcon;
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.rotateIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFFFFD400) : Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: rotateIcon ? math.pi / 2 : 0,
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _CropArea extends StatefulWidget {
  final Rect imageRect;
  final Rect rect;
  final ValueChanged<Rect> onRectChanged;
  final Size imageSize;
  final double? aspectRatio;
  final Widget child;
  const _CropArea({
    required this.imageRect,
    required this.rect,
    required this.onRectChanged,
    required this.imageSize,
    required this.aspectRatio,
    required this.child,
  });

  @override
  State<_CropArea> createState() => _CropAreaState();
}

class _CropAreaState extends State<_CropArea> {
  static const double _handle = 24;
  Rect? _dragStart;
  Offset? _dragOrigin;

  Rect _screenRect() {
    return Rect.fromLTWH(
      widget.imageRect.left + widget.rect.left * widget.imageRect.width,
      widget.imageRect.top + widget.rect.top * widget.imageRect.height,
      widget.rect.width * widget.imageRect.width,
      widget.rect.height * widget.imageRect.height,
    );
  }

  Offset _toNormDelta(Offset d) => Offset(
    d.dx / widget.imageRect.width,
    d.dy / widget.imageRect.height,
  );

  @override
  Widget build(BuildContext context) {
    final r = _screenRect();
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          child: CustomPaint(
            painter: _CropOverlayPainter(rect: r),
            size: Size.infinite,
          ),
        ),
        Positioned.fromRect(
          rect: r.deflate(_handle),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) {
              _dragStart = widget.rect;
              _dragOrigin = d.globalPosition;
            },
            onPanUpdate: (d) {
              if (_dragStart == null || _dragOrigin == null) return;
              final dn = _toNormDelta(d.globalPosition - _dragOrigin!);
              double newL = (_dragStart!.left + dn.dx)
                  .clamp(0.0, 1.0 - _dragStart!.width);
              double newT = (_dragStart!.top + dn.dy)
                  .clamp(0.0, 1.0 - _dragStart!.height);
              widget.onRectChanged(
                Rect.fromLTWH(newL, newT, _dragStart!.width, _dragStart!.height),
              );
            },
            child: const SizedBox.expand(),
          ),
        ),
        for (final corner in _Corner.values) _buildHandle(r, corner),
      ],
    );
  }

  Widget _buildHandle(Rect r, _Corner corner) {
    Offset pos;
    switch (corner) {
      case _Corner.tl: pos = Offset(r.left, r.top); break;
      case _Corner.tr: pos = Offset(r.right - _handle, r.top); break;
      case _Corner.bl: pos = Offset(r.left, r.bottom - _handle); break;
      case _Corner.br: pos = Offset(r.right - _handle, r.bottom - _handle); break;
    }
    return Positioned(
      left: pos.dx, top: pos.dy, width: _handle, height: _handle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _dragStart = widget.rect;
          _dragOrigin = d.globalPosition;
        },
        onPanUpdate: (d) {
          if (_dragStart == null || _dragOrigin == null) return;
          final dn = _toNormDelta(d.globalPosition - _dragOrigin!);
          widget.onRectChanged(_resize(_dragStart!, corner, dn));
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFFFD400), width: 3),
            color: Colors.black26,
          ),
        ),
      ),
    );
  }

  Rect _resize(Rect start, _Corner corner, Offset d) {
    double l = start.left, t = start.top, r = start.right, b = start.bottom;
    switch (corner) {
      case _Corner.tl: l += d.dx; t += d.dy; break;
      case _Corner.tr: r += d.dx; t += d.dy; break;
      case _Corner.bl: l += d.dx; b += d.dy; break;
      case _Corner.br: r += d.dx; b += d.dy; break;
    }
    const minSize = 0.10;
    l = l.clamp(0.0, 1.0 - minSize);
    t = t.clamp(0.0, 1.0 - minSize);
    r = r.clamp(l + minSize, 1.0);
    b = b.clamp(t + minSize, 1.0);
    var rect = Rect.fromLTRB(l, t, r, b);
    if (widget.aspectRatio != null) {
      final imgAspect = widget.imageSize.width / widget.imageSize.height;
      final normAspect = widget.aspectRatio! / imgAspect;
      final newW = rect.width;
      final newH = newW / normAspect;
      double left = rect.left, top = rect.top;
      switch (corner) {
        case _Corner.tl: left = rect.right - newW; top = rect.bottom - newH; break;
        case _Corner.tr: top = rect.bottom - newH; break;
        case _Corner.bl: left = rect.right - newW; break;
        case _Corner.br: break;
      }
      rect = Rect.fromLTWH(
        left.clamp(0.0, 1.0 - newW).toDouble(),
        top.clamp(0.0, 1.0 - newH).toDouble(),
        newW.clamp(0.0, 1.0),
        newH.clamp(0.0, 1.0),
      );
    }
    return rect;
  }
}

enum _Corner { tl, tr, bl, br }

class _CropOverlayPainter extends CustomPainter {
  final Rect rect;
  _CropOverlayPainter({required this.rect});
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final full = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRect(rect);
    final mask = Path.combine(PathOperation.difference, full, hole);
    canvas.drawPath(mask, p);
    final guide = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final r = rect;
    for (int i = 1; i <= 2; i++) {
      final x = r.left + r.width * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), guide);
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), guide);
    }
    final border = Paint()
      ..color = const Color(0xFFFFD400)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, border);
  }
  @override
  bool shouldRepaint(covariant _CropOverlayPainter old) => old.rect != rect;
}
