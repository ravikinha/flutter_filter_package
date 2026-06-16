import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

class CaptureViewer extends StatefulWidget {
  final File file;
  const CaptureViewer({super.key, required this.file});

  @override
  State<CaptureViewer> createState() => _CaptureViewerState();
}

class _CaptureViewerState extends State<CaptureViewer> {
  VideoPlayerController? _video;
  bool get _isVideo => widget.file.path.toLowerCase().endsWith('.mp4');

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      final c = VideoPlayerController.file(widget.file);
      _video = c;
      c.initialize().then((_) {
        if (!mounted) {
          c.dispose();
          return;
        }
        setState(() {});
        c..setLooping(true)..play();
      }).catchError((_) {
        // Corrupted or unsupported file: dispose and surface a placeholder.
        if (!mounted) return;
        c.dispose();
        setState(() => _video = null);
      });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.file.uri.pathSegments.last,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        actions: [
          Builder(builder: (ctx) {
            return IconButton(
              icon: const Icon(Icons.ios_share, color: Colors.white),
              onPressed: () => _share(ctx),
            );
          }),
        ],
      ),
      body: Center(
        child: _isVideo ? _buildVideo() : _buildImage(),
      ),
      bottomNavigationBar: _isVideo ? _buildVideoBar() : null,
    );
  }

  Widget _buildImage() {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Image.file(widget.file, fit: BoxFit.contain),
    );
  }

  Widget _buildVideo() {
    final v = _video;
    if (v == null || !v.value.isInitialized) {
      return const CircularProgressIndicator();
    }
    return AspectRatio(
      aspectRatio: v.value.aspectRatio,
      child: GestureDetector(
        onTap: () => setState(() {
          v.value.isPlaying ? v.pause() : v.play();
        }),
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(v),
            if (!v.value.isPlaying)
              const Icon(Icons.play_circle_fill, size: 72, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoBar() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return const SizedBox.shrink();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: VideoProgressIndicator(
          v,
          allowScrubbing: true,
          colors: const VideoProgressColors(
            playedColor: Color(0xFFFFD400),
            bufferedColor: Colors.white24,
            backgroundColor: Colors.white12,
          ),
        ),
      ),
    );
  }

  Future<void> _share(BuildContext ctx) async {
    // share_plus on iPad / certain iOS contexts needs an origin rect, or it
    // throws "sharePositionOrigin must be set". Anchor it to the share button.
    final box = ctx.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 1, 1);
    await Share.shareXFiles(
      [XFile(widget.file.path)],
      sharePositionOrigin: origin,
    );
  }
}
