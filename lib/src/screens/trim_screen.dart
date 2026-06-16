import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../engine/filter_engine.dart';

/// Picks a start/end range in milliseconds. Pop with the trimmed file path
/// on save, null on cancel.
class TrimScreen extends StatefulWidget {
  final File source;
  const TrimScreen({super.key, required this.source});

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> {
  VideoPlayerController? _controller;
  Duration _duration = Duration.zero;
  Duration _start = Duration.zero;
  Duration _end = Duration.zero;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.file(widget.source);
    _controller = c;
    c.initialize().then((_) {
      if (!mounted) { c.dispose(); return; }
      setState(() {
        _duration = c.value.duration;
        _end = _duration;
      });
      c..setLooping(false)..play();
      c.addListener(_onTick);
    }).catchError((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot open video: $e')),
      );
    });
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    // Loop the playback within the trim window so the user hears the trimmed
    // range as they tune it.
    if (c.value.position >= _end) {
      c.seekTo(_start);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
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
        title: const Text('Trim'),
        actions: [
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
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: Center(child: _buildPlayer())),
            _buildTimeRow(),
            _buildTimeline(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayer() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const CircularProgressIndicator();
    }
    return AspectRatio(
      aspectRatio: c.value.aspectRatio,
      child: GestureDetector(
        onTap: () => setState(() {
          c.value.isPlaying ? c.pause() : c.play();
        }),
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            if (!c.value.isPlaying)
              const Icon(Icons.play_circle_fill, size: 72, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(_fmt(_start), style: const TextStyle(color: Colors.white)),
          Text(
            '${_fmt(_end - _start)} selected',
            style: const TextStyle(color: Color(0xFFFFD400),
              fontWeight: FontWeight.w600),
          ),
          Text(_fmt(_end), style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox(height: 60);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: _RangeBar(
        duration: _duration,
        start: _start,
        end: _end,
        playhead: c.value.position,
        onChanged: (s, e) {
          // Enforce a 0.5s minimum window.
          final minWindow = const Duration(milliseconds: 500);
          if (e - s < minWindow) {
            if (s != _start) s = e - minWindow;
            if (e != _end) e = s + minWindow;
          }
          setState(() {
            _start = s.isNegative ? Duration.zero : s;
            _end = e > _duration ? _duration : e;
          });
          // Seek playhead so the user sees what they just dragged to.
          c.seekTo(s == _start ? _start : _end);
        },
        onScrub: (pos) => c.seekTo(pos),
      ),
    );
  }

  Future<void> _save() async {
    if (_duration == Duration.zero) return;
    setState(() => _saving = true);
    _controller?.pause();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final out = '${dir.path}/CFE_trim_$ts.mp4';
      final saved = await FilterEngine.instance.trimVideo(
        inputPath: widget.source.path,
        outputPath: out,
        startMs: _start.inMilliseconds,
        endMs: _end.inMilliseconds,
      );
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Trim failed: $e')),
      );
      setState(() => _saving = false);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = ((d.inMilliseconds % 1000) ~/ 100);
    return '$m:$s.$ms';
  }
}

/// Single-pan range bar. A bar-wide GestureDetector decides which handle
/// to move (or whether to scrub the playhead) based on where the pan
/// started, so nothing gets eaten by the gesture arena the way per-handle
/// GestureDetectors did on Android.
class _RangeBar extends StatefulWidget {
  final Duration duration;
  final Duration start;
  final Duration end;
  final Duration playhead;
  final void Function(Duration start, Duration end) onChanged;
  final void Function(Duration position) onScrub;
  const _RangeBar({
    required this.duration,
    required this.start,
    required this.end,
    required this.playhead,
    required this.onChanged,
    required this.onScrub,
  });

  @override
  State<_RangeBar> createState() => _RangeBarState();
}

enum _Drag { startHandle, endHandle, playhead }

class _RangeBarState extends State<_RangeBar> {
  _Drag? _dragging;

  static const double _handleW = 20;   // bigger touch target
  static const double _barHeight = 60;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final width = c.maxWidth;
      final usable = width - _handleW * 2;
      double frac(Duration d) =>
          widget.duration.inMilliseconds == 0
              ? 0
              : d.inMilliseconds / widget.duration.inMilliseconds;
      final sx = frac(widget.start) * usable;
      final ex = frac(widget.end) * usable;
      final px = frac(widget.playhead) * usable;

      Duration msAtLocalX(double x) {
        final t = ((x - _handleW / 2) / usable).clamp(0.0, 1.0);
        return Duration(milliseconds: (t * widget.duration.inMilliseconds).round());
      }

      return SizedBox(
        height: _barHeight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (d) {
            // Decide which thing to drag based on which is closest to the
            // touch X (with a slight bias toward handles so the playhead
            // doesn't steal handle hits when they're at the same spot).
            final x = d.localPosition.dx;
            final centerStart = sx + _handleW / 2;
            final centerEnd = ex + _handleW / 2;
            final centerPlay = px + _handleW / 2;
            final dStart = (x - centerStart).abs() - 4;   // handle bias
            final dEnd = (x - centerEnd).abs() - 4;
            final dPlay = (x - centerPlay).abs();
            _dragging = (dStart <= dEnd && dStart <= dPlay)
                ? _Drag.startHandle
                : (dEnd <= dPlay)
                    ? _Drag.endHandle
                    : _Drag.playhead;
            // Immediate scrub on a tap-to-position.
            if (_dragging == _Drag.playhead) {
              widget.onScrub(msAtLocalX(x));
            }
          },
          onPanUpdate: (d) {
            final pos = msAtLocalX(d.localPosition.dx);
            switch (_dragging) {
              case _Drag.startHandle:
                final maxStart = widget.end - const Duration(milliseconds: 500);
                final s = pos > maxStart ? maxStart : pos;
                widget.onChanged(s.isNegative ? Duration.zero : s, widget.end);
                break;
              case _Drag.endHandle:
                final minEnd = widget.start + const Duration(milliseconds: 500);
                final e = pos < minEnd ? minEnd : pos;
                widget.onChanged(widget.start,
                    e > widget.duration ? widget.duration : e);
                break;
              case _Drag.playhead:
                widget.onScrub(pos);
                break;
              case null: break;
            }
          },
          onPanEnd: (_) => _dragging = null,
          onTapDown: (d) {
            // Pure tap-to-scrub (not on a handle) — same logic but no drag.
            final x = d.localPosition.dx;
            final centerStart = sx + _handleW / 2;
            final centerEnd = ex + _handleW / 2;
            if ((x - centerStart).abs() > _handleW &&
                (x - centerEnd).abs() > _handleW) {
              widget.onScrub(msAtLocalX(x));
            }
          },
          child: Stack(children: [
            // Track
            Positioned(
              left: _handleW / 2, right: _handleW / 2,
              top: _barHeight / 2 - 2,
              height: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Selected band
            Positioned(
              left: sx + _handleW / 2,
              top: _barHeight / 2 - 8,
              width: math.max(0.0, ex - sx),
              height: 16,
              child: Container(color: const Color(0x55FFD400)),
            ),
            // Playhead
            Positioned(
              left: px + _handleW / 2 - 1,
              top: _barHeight / 2 - 16,
              width: 2, height: 32,
              child: Container(color: Colors.white),
            ),
            // Start handle (visual only — gestures live on the bar)
            Positioned(
              left: sx, top: _barHeight / 2 - 18,
              child: _HandleVisual(left: true),
            ),
            // End handle
            Positioned(
              left: ex, top: _barHeight / 2 - 18,
              child: _HandleVisual(left: false),
            ),
          ]),
        ),
      );
    });
  }
}

class _HandleVisual extends StatelessWidget {
  final bool left;
  const _HandleVisual({required this.left});
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: _RangeBarState._handleW, height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFFFFD400),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(left ? 4 : 0),
            bottomLeft: Radius.circular(left ? 4 : 0),
            topRight: Radius.circular(left ? 0 : 4),
            bottomRight: Radius.circular(left ? 0 : 4),
          ),
        ),
        child: Center(
          child: Icon(
            left ? Icons.chevron_left : Icons.chevron_right,
            size: 16, color: Colors.black,
          ),
        ),
      ),
    );
  }
}

