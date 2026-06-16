import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/filter.dart';

class FilterPicker extends StatelessWidget {
  final List<CameraFilter> filters;
  final String selectedId;
  final ValueChanged<CameraFilter> onSelected;

  const FilterPicker({
    super.key,
    required this.filters,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final f = filters[i];
          final selected = f.id == selectedId;
          return GestureDetector(
            onTap: () => onSelected(f),
            child: SizedBox(
              width: 64,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _FilterThumb(filterId: f.id, selected: selected),
                  const SizedBox(height: 6),
                  Text(
                    f.name,
                    style: TextStyle(
                      fontSize: 11,
                      color: selected ? const Color(0xFFFFD400) : Colors.white,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FilterThumb extends StatelessWidget {
  final String filterId;
  final bool selected;
  const _FilterThumb({required this.filterId, required this.selected});

  @override
  Widget build(BuildContext context) {
    final scene = ClipOval(
      child: SizedBox(
        width: 52,
        height: 52,
        child: ColorFiltered(
          colorFilter: _matrixFor(filterId),
          child: CustomPaint(
            painter: _ScenePainter(filterId: filterId),
          ),
        ),
      ),
    );
    final overlayIcon = _overlayIconFor(filterId);
    return Container(
      width: 56,
      height: 56,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? const Color(0xFFFFD400) : Colors.white24,
          width: selected ? 2.5 : 1,
        ),
        boxShadow: selected
            ? [const BoxShadow(color: Color(0x55FFD400), blurRadius: 10, spreadRadius: 1)]
            : null,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          scene,
          if (overlayIcon != null) overlayIcon,
        ],
      ),
    );
  }
}

/// Paints a tiny "sample scene" — sky, sun, ground — so each thumbnail looks
/// like a real photo before the filter is applied on top via ColorFiltered.
/// Some filters also add their own characteristic textures (grain dots,
/// scanlines) painted here as well.
class _ScenePainter extends CustomPainter {
  final String filterId;
  _ScenePainter({required this.filterId});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // sky
    final sky = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(0, size.height),
        const [Color(0xFF87C8FF), Color(0xFFD9F0FF)],
      );
    canvas.drawRect(rect, sky);
    // sun
    final sun = Paint()..color = const Color(0xFFFFD27A);
    canvas.drawCircle(Offset(size.width * 0.72, size.height * 0.32), size.width * 0.18, sun);
    // ground
    final ground = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, size.height * 0.55),
        Offset(0, size.height),
        const [Color(0xFF6FA85B), Color(0xFF2E5523)],
      );
    canvas.drawRect(
      Rect.fromLTRB(0, size.height * 0.55, size.width, size.height),
      ground,
    );
    // "subject" silhouette so faces-on-the-ground filters read as portraits
    final subject = Paint()..color = const Color(0xFF3A2A20);
    canvas.drawCircle(Offset(size.width * 0.32, size.height * 0.55), size.width * 0.10, subject);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width * 0.32, size.height * 0.75),
          width: size.width * 0.26,
          height: size.height * 0.30,
        ),
        const Radius.circular(6),
      ),
      subject,
    );

    // Per-filter characteristic textures painted in addition to the matrix.
    switch (filterId) {
      case 'grain':
        final r = Paint()..color = Colors.white.withValues(alpha: 0.55);
        final r2 = Paint()..color = Colors.black.withValues(alpha: 0.55);
        // pseudo-random grain dots
        for (int i = 0; i < 80; i++) {
          final dx = (i * 17 % 100) / 100 * size.width;
          final dy = (i * 31 % 100) / 100 * size.height;
          canvas.drawCircle(Offset(dx, dy), 0.5, i.isEven ? r : r2);
        }
        break;
      case 'vhs':
        final scan = Paint()..color = Colors.black.withValues(alpha: 0.35);
        for (double y = 0; y < size.height; y += 3) {
          canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), scan);
        }
        break;
      case 'bwGlitch':
        final glitch = Paint()..color = const Color(0xFFFF2266).withValues(alpha: 0.6);
        canvas.drawRect(Rect.fromLTWH(0, size.height * 0.35, size.width, 2), glitch);
        canvas.drawRect(Rect.fromLTWH(0, size.height * 0.62, size.width, 1.5), glitch);
        break;
      case 'dreamGlow':
        final glow = Paint()
          ..color = Colors.white.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        canvas.drawCircle(Offset(size.width * 0.72, size.height * 0.32), size.width * 0.32, glow);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) => old.filterId != filterId;
}

ColorFilter _matrixFor(String id) {
  switch (id) {
    case 'kodak':
      // Warm push: lift R, slight G, drop B, contrast +15%.
      return const ColorFilter.matrix([
        1.15, 0.05, 0.00, 0, 8,
        0.00, 1.10, 0.00, 0, 4,
        0.00, 0.00, 0.95, 0, -10,
        0,    0,    0,    1, 0,
      ]);
    case 'vintage':
      // Sepia.
      return const ColorFilter.matrix([
        0.393, 0.769, 0.189, 0, 0,
        0.349, 0.686, 0.168, 0, 0,
        0.272, 0.534, 0.131, 0, 0,
        0,     0,     0,     1, 0,
      ]);
    case 'retro':
      // Pink/warm + fade.
      return const ColorFilter.matrix([
        1.10, 0.05, 0.00, 0, 18,
        0.95, 1.00, 0.05, 0, 6,
        0.95, 0.00, 0.90, 0, 8,
        0,    0,    0,    1, 0,
      ]);
    case 'cinematic':
      // Teal shadows, orange highlights, contrast.
      return const ColorFilter.matrix([
        1.18, -0.10, 0.00, 0, 8,
        -0.05, 1.05, -0.10, 0, 0,
        -0.20, 0.05, 1.15, 0, -8,
        0,    0,    0,    1, 0,
      ]);
    case 'coolBlue':
      return const ColorFilter.matrix([
        0.85, 0.00, 0.05, 0, -8,
        0.00, 0.95, 0.10, 0, -2,
        0.05, 0.05, 1.20, 0, 12,
        0,    0,    0,    1, 0,
      ]);
    case 'bwGlitch':
      return const ColorFilter.matrix([
        0.299, 0.587, 0.114, 0, 0,
        0.299, 0.587, 0.114, 0, 0,
        0.299, 0.587, 0.114, 0, 0,
        0,     0,     0,     1, 0,
      ]);
    case 'grain':
      // Slightly desaturated, neutral.
      return const ColorFilter.matrix([
        0.95, 0.025, 0.025, 0, 0,
        0.025, 0.95, 0.025, 0, 0,
        0.025, 0.025, 0.95, 0, 0,
        0,    0,    0,    1, 0,
      ]);
    case 'cyberpunkHud':
      return const ColorFilter.matrix([
        1.10, -0.05, 0.20, 0, 12,
        -0.20, 1.00, 0.30, 0, -4,
        0.40, 0.30, 1.10, 0, 22,
        0,    0,    0,    1, 0,
      ]);
    case 'hologram':
      return const ColorFilter.matrix([
        0.10, 0.20, 0.40, 0, -10,
        0.30, 0.75, 0.60, 0,  4,
        0.40, 0.80, 1.10, 0, 18,
        0,    0,    0,    1, 0,
      ]);
    case 'matrixVision':
      return const ColorFilter.matrix([
        0.05, 0.10, 0.00, 0, -10,
        0.30, 1.20, 0.20, 0, -2,
        0.05, 0.20, 0.10, 0, -10,
        0,    0,    0,    1, 0,
      ]);
    case 'neonOutline':
      return const ColorFilter.matrix([
        0.60, 0.10, 0.30, 0, 12,
        0.20, 0.30, 0.40, 0,  4,
        0.40, 0.30, 0.80, 0, 16,
        0,    0,    0,    1, 0,
      ]);
    case 'thermal':
      return const ColorFilter.matrix([
        1.50, 0.20, 0.00, 0, -20,
        0.50, 0.80, 0.00, 0, -30,
        -0.20, -0.30, 0.40, 0, 20,
        0,    0,    0,    1, 0,
      ]);
    case 'crtRetro':
      return const ColorFilter.matrix([
        1.05, 0.05, 0.00, 0, -6,
        0.00, 0.95, 0.00, 0, -4,
        0.00, 0.00, 0.85, 0, -10,
        0,    0,    0,    1, 0,
      ]);
    case 'vhsPro':
      return const ColorFilter.matrix([
        1.10, 0.00, 0.20, 0,  6,
        0.00, 0.85, 0.10, 0, -2,
        0.20, 0.05, 1.10, 0,  6,
        0,    0,    0,    1, 0,
      ]);
    case 'kaleidoscope':
      return const ColorFilter.matrix([
        1.10, 0.05, 0.10, 0, 4,
        0.10, 1.05, 0.10, 0, 4,
        0.10, 0.05, 1.10, 0, 8,
        0,    0,    0,    1, 0,
      ]);
    case 'electricAura':
      return const ColorFilter.matrix([
        0.55, 0.05, 0.30, 0, 4,
        0.20, 0.45, 0.30, 0, 2,
        0.30, 0.20, 0.95, 0, 18,
        0,    0,    0,    1, 0,
      ]);
    case 'scannerVision':
      return const ColorFilter.matrix([
        0.10, 0.15, 0.00, 0, -8,
        0.30, 1.00, 0.20, 0, -2,
        0.15, 0.40, 0.20, 0, -6,
        0,    0,    0,    1, 0,
      ]);
    case 'liquidChrome':
      return const ColorFilter.matrix([
        0.90, 0.10, 0.10, 0, 14,
        0.10, 0.95, 0.10, 0, 14,
        0.10, 0.10, 1.05, 0, 22,
        0,    0,    0,    1, 0,
      ]);
    case 'glassMorph':
      return const ColorFilter.matrix([
        0.85, 0.10, 0.20, 0, 4,
        0.05, 0.95, 0.20, 0, 8,
        0.10, 0.15, 1.10, 0, 18,
        0,    0,    0,    1, 0,
      ]);
    case 'prismLens':
      return const ColorFilter.matrix([
        1.20, -0.05, 0.00, 0, 8,
        -0.05, 1.10, -0.05, 0, 0,
        -0.05, -0.05, 1.20, 0, 8,
        0,    0,    0,    1, 0,
      ]);
    case 'cinematicAnamorphic':
      return const ColorFilter.matrix([
        1.20, -0.05, 0.00, 0, 6,
        -0.05, 1.05, -0.05, 0, -2,
        -0.20, 0.05, 1.10, 0, -10,
        0,    0,    0,    1, 0,
      ]);
    case 'dreamLens':
      return const ColorFilter.matrix([
        1.15, 0.05, 0.00, 0, 14,
        0.05, 1.05, 0.05, 0, 8,
        0.00, 0.05, 1.00, 0, 0,
        0,    0,    0,    1, 0,
      ]);
    case 'aurora':
      return const ColorFilter.matrix([
        0.30, 0.20, 0.40, 0, 8,
        0.10, 0.95, 0.20, 0, 14,
        0.30, 0.30, 0.85, 0, 20,
        0,    0,    0,    1, 0,
      ]);
    case 'lightRays':
      return const ColorFilter.matrix([
        1.15, 0.10, 0.00, 0, 16,
        0.10, 1.10, 0.00, 0, 8,
        -0.10, 0.05, 0.95, 0, -8,
        0,    0,    0,    1, 0,
      ]);
    case 'holographicGlass':
      return const ColorFilter.matrix([
        0.85, 0.20, 0.20, 0, 8,
        0.10, 0.90, 0.30, 0, 8,
        0.30, 0.20, 1.10, 0, 16,
        0,    0,    0,    1, 0,
      ]);
    case 'photonTrails':
      return const ColorFilter.matrix([
        0.80, 0.05, 0.30, 0, 10,
        0.05, 0.65, 0.30, 0, 6,
        0.40, 0.25, 1.05, 0, 18,
        0,    0,    0,    1, 0,
      ]);
    case 'neuralGrid':
      return const ColorFilter.matrix([
        0.10, 0.20, 0.00, 0, -10,
        0.20, 1.10, 0.20, 0, 2,
        0.10, 0.40, 0.30, 0, -4,
        0,    0,    0,    1, 0,
      ]);
    case 'dogpatchPro':
      // Warm Kodak grade approximation: lift R, slight G, drop B, golden
      // highlights, +contrast. Mirrors the shader at default params.
      return const ColorFilter.matrix([
        1.18, 0.05, 0.00, 0, 14,
        0.00, 1.10, 0.00, 0,  6,
        -0.05, 0.00, 0.92, 0, -8,
        0,    0,    0,    1, 0,
      ]);
    case 'blur':
    case 'dreamGlow':
    case 'vhs':
    case 'none':
    default:
      return const ColorFilter.mode(Colors.transparent, BlendMode.multiply);
  }
}

Widget? _overlayIconFor(String id) {
  IconData? icon;
  Color color = Colors.white;
  switch (id) {
    case 'blur':
      icon = Icons.blur_on;
      break;
    case 'vhs':
      icon = Icons.tv;
      color = Colors.cyanAccent;
      break;
    case 'bwGlitch':
      icon = Icons.flash_on;
      color = const Color(0xFFFF2266);
      break;
    case 'grain':
      icon = Icons.grain;
      break;
    case 'dreamGlow':
      icon = Icons.auto_awesome;
      color = Colors.pinkAccent;
      break;
    case 'cyberpunkHud':
      icon = Icons.grid_3x3;
      color = const Color(0xFF00E5FF);
      break;
    case 'hologram':
      icon = Icons.view_in_ar;
      color = const Color(0xFF80EEFF);
      break;
    case 'matrixVision':
      icon = Icons.code;
      color = const Color(0xFF55FF77);
      break;
    case 'neonOutline':
      icon = Icons.gesture;
      color = const Color(0xFFB388FF);
      break;
    case 'thermal':
      icon = Icons.thermostat;
      color = const Color(0xFFFFEB3B);
      break;
    case 'crtRetro':
      icon = Icons.tv_off;
      color = const Color(0xFFD7C58A);
      break;
    case 'vhsPro':
      icon = Icons.cast_connected;
      color = const Color(0xFFFF40C0);
      break;
    case 'kaleidoscope':
      icon = Icons.bubble_chart;
      color = const Color(0xFFFFC1E3);
      break;
    case 'electricAura':
      icon = Icons.bolt;
      color = const Color(0xFF82B1FF);
      break;
    case 'scannerVision':
      icon = Icons.radar;
      color = const Color(0xFF00E676);
      break;
    case 'liquidChrome':
      icon = Icons.water_drop;
      color = const Color(0xFFE0E0E0);
      break;
    case 'glassMorph':
      icon = Icons.diamond;
      color = const Color(0xFFB3E5FC);
      break;
    case 'prismLens':
      icon = Icons.color_lens;
      color = const Color(0xFFFFD740);
      break;
    case 'cinematicAnamorphic':
      icon = Icons.movie_filter;
      color = const Color(0xFFFFAB40);
      break;
    case 'dreamLens':
      icon = Icons.brightness_5;
      color = const Color(0xFFFFD0B0);
      break;
    case 'aurora':
      icon = Icons.air;
      color = const Color(0xFF40C4FF);
      break;
    case 'lightRays':
      icon = Icons.wb_sunny;
      color = const Color(0xFFFFE57F);
      break;
    case 'holographicGlass':
      icon = Icons.layers;
      color = const Color(0xFF80EEFF);
      break;
    case 'photonTrails':
      icon = Icons.flash_auto;
      color = const Color(0xFFB388FF);
      break;
    case 'neuralGrid':
      icon = Icons.developer_board;
      color = const Color(0xFF00E676);
      break;
    case 'dogpatchPro':
      icon = Icons.wb_iridescent;
      color = const Color(0xFFFFD27A);
      break;
  }
  if (icon == null) return null;
  return Positioned(
    right: 2,
    bottom: 2,
    child: Container(
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 11, color: color),
    ),
  );
}
