import 'package:flutter/material.dart';

/// Transparent Flutter UI used with the runner's opt-in HDR composition test.
///
/// The four-quadrant PQ test surface is a DirectComposition visual below this
/// scene. The border and labels here prove that Flutter UI and HDR content are
/// being captured from the same window and composed in the intended order.
class HdrDcompTestApp extends StatelessWidget {
  const HdrDcompTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Container(
            margin: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Stack(
              children: [
                Positioned(
                  left: 20,
                  top: 20,
                  child: _TestLabel(
                    title: 'Flutter UI + HDR surface',
                    subtitle: 'Single-window DirectComposition diagnostic',
                  ),
                ),
                Positioned(
                  right: 20,
                  bottom: 20,
                  child: _TestLabel(
                    title: 'PQ / BT.2020 / 10-bit',
                    subtitle: 'Red · Green · Blue · Neutral',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TestLabel extends StatelessWidget {
  const _TestLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
