import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'capture_viewer.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<File> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await getApplicationDocumentsDirectory();
    // Async stream so a docs folder with hundreds of files doesn't block
    // the UI thread.
    final entries = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.contains('CFE_')) entries.add(e);
    }
    entries.sort((a, b) => b.path.compareTo(a.path));
    if (!mounted) return;
    setState(() {
      _files = entries;
      _loading = false;
    });
  }

  Future<void> _open(File f) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CaptureViewer(file: f)),
    );
    _load(); // refresh in case the user shared/deleted from the viewer
  }

  Future<void> _share(BuildContext ctx, File f) async {
    final box = ctx.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 1, 1);
    await Share.shareXFiles(
      [XFile(f.path)],
      sharePositionOrigin: origin,
    );
  }

  Future<void> _delete(File f) async {
    try { await f.delete(); } catch (_) {}
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gallery')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(child: Text('No captures yet'))
              : GridView.builder(
                  padding: const EdgeInsets.all(6),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: _files.length,
                  itemBuilder: (context, i) {
                    final f = _files[i];
                    final isVideo = f.path.toLowerCase().endsWith('.mp4');
                    return _Tile(
                      file: f,
                      isVideo: isVideo,
                      onTap: () => _open(f),
                      onShare: (ctx) => _share(ctx, f),
                      onDelete: () => _delete(f),
                    );
                  },
                ),
    );
  }
}

class _Tile extends StatefulWidget {
  final File file;
  final bool isVideo;
  final VoidCallback onTap;
  final void Function(BuildContext ctx) onShare;
  final VoidCallback onDelete;
  const _Tile({
    required this.file,
    required this.isVideo,
    required this.onTap,
    required this.onShare,
    required this.onDelete,
  });

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  VideoPlayerController? _videoForThumb;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      // Use the video controller just to grab the first frame as a poster.
      final c = VideoPlayerController.file(widget.file);
      _videoForThumb = c;
      c.initialize().then((_) {
        if (!mounted) { c.dispose(); return; }
        setState(() {});
      }).catchError((_) {
        if (!mounted) return;
        c.dispose();
        setState(() => _videoForThumb = null);
      });
    }
  }

  @override
  void dispose() {
    _videoForThumb?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: () => _showActions(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!widget.isVideo)
            Image.file(widget.file, fit: BoxFit.cover)
          else if (_videoForThumb != null && _videoForThumb!.value.isInitialized)
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _videoForThumb!.value.size.width,
                height: _videoForThumb!.value.size.height,
                child: VideoPlayer(_videoForThumb!),
              ),
            )
          else
            Container(color: Colors.white10),
          if (widget.isVideo)
            const Positioned(
              right: 4,
              bottom: 4,
              child: Icon(Icons.play_circle_fill, color: Colors.white, size: 24),
            ),
        ],
      ),
    );
  }

  void _showActions(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(builder: (innerCtx) {
              return ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('Share'),
                onTap: () {
                  Navigator.pop(innerCtx);
                  widget.onShare(innerCtx);
                },
              );
            }),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(context);
                widget.onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}
