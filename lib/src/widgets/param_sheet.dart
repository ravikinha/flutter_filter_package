import 'package:flutter/material.dart';

import '../models/filter.dart';

class ParamSheet extends StatefulWidget {
  final CameraFilter filter;
  final Map<String, double> values;
  final void Function(String key, double value) onChanged;

  const ParamSheet({
    super.key,
    required this.filter,
    required this.values,
    required this.onChanged,
  });

  @override
  State<ParamSheet> createState() => _ParamSheetState();
}

class _ParamSheetState extends State<ParamSheet> {
  late Map<String, double> _values;

  @override
  void initState() {
    super.initState();
    _values = Map<String, double>.from(widget.values);
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    if (filter.params.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'This filter has no adjustable parameters.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              filter.name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final p in filter.params) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: Text(p.label, style: const TextStyle(color: Colors.white70))),
                  Text(
                    _values[p.key]!.toStringAsFixed(2),
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
              Slider(
                value: _values[p.key]!.clamp(p.min, p.max),
                min: p.min,
                max: p.max,
                // Live-update the local label as the user drags…
                onChanged: (v) => setState(() => _values[p.key] = v),
                // …but only push to native when the gesture ends, avoiding
                // ~60 MethodChannel hops per second and the GPU jank that
                // comes with re-binding uniforms on every paint.
                onChangeEnd: (v) => widget.onChanged(p.key, v),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
