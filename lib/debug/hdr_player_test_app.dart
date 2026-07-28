import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// End-to-end diagnostic for mpv -> DXGI PQ swapchain -> Flutter DComp.
class HdrPlayerTestApp extends StatefulWidget {
  const HdrPlayerTestApp({super.key, required this.path});

  final String path;

  @override
  State<HdrPlayerTestApp> createState() => _HdrPlayerTestAppState();
}

class _HdrPlayerTestAppState extends State<HdrPlayerTestApp> {
  late final Player _player;
  late final VideoController _controller;
  int? _handle;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        // Deliberately match the formal player's historical renderer value.
        // The Windows HDR controller must coerce this to libmpv without
        // allowing mpv to create a separate top-level window.
        vo: 'gpu-next',
        hwdec: 'd3d11va',
        windowsNativeWindow: true,
      ),
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    final native = _player.platform as NativePlayer;
    await native.waitForPlayerInitialization;
    _handle = await _player.handle;
    if (mounted) setState(() {});
    // The normal widget path updates this from its RenderBox. Send an initial
    // full-view rectangle as well so this standalone diagnostic is independent
    // of Video's asynchronous first texture layout.
    await const MethodChannel('com.alexmercerind/media_kit_video')
        .invokeMethod<void>('VideoOutputManager.SetNativeRect', {
      'handle': _handle.toString(),
      'left': '0',
      'top': '0',
      'width': '1280',
      'height': '720',
    });
    await native.setProperty('gpu-api', 'd3d11');
    await native.setProperty('d3d11-output-format', 'rgb10_a2');
    await native.setProperty('d3d11-output-csp', 'pq');
    await native.setProperty('target-trc', 'pq');
    await native.setProperty('target-prim', 'bt.2020');
    await native.setProperty('target-peak', '1000');
    await native.setProperty('inverse-tone-mapping', 'yes');
    await native.setProperty('hdr-compute-peak', 'no');
    await _player.open(Media(widget.path), play: true);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: _HdrVideoRegion(
                  player: _player,
                  controller: _controller,
                  handle: _handle,
                ),
              ),
              const Positioned(
                left: 24,
                top: 24,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xB0000000),
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Text('Flutter UI over embedded mpv HDR'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HdrVideoRegion extends StatefulWidget {
  const _HdrVideoRegion({
    required this.player,
    required this.controller,
    required this.handle,
  });

  final Player player;
  final VideoController controller;
  final int? handle;

  @override
  State<_HdrVideoRegion> createState() => _HdrVideoRegionState();
}

class _HdrVideoRegionState extends State<_HdrVideoRegion> {
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');
  Rect? _lastRect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncRect());
        return CustomPaint(
          painter: const _ClearPainter(),
          child: Video(
            controller: widget.controller,
            controls: NoVideoControls,
            fill: Colors.transparent,
          ),
        );
      },
    );
  }

  Future<void> _syncRect() async {
    if (!mounted) return;
    final handle = widget.handle;
    if (handle == null) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final origin = renderObject.localToGlobal(Offset.zero);
    final rect = Rect.fromLTWH(origin.dx * ratio, origin.dy * ratio,
        renderObject.size.width * ratio, renderObject.size.height * ratio);
    if (_lastRect == rect) return;
    debugPrint('HDR player test: sending rect $rect for $handle');
    await _channel.invokeMethod<void>('VideoOutputManager.SetNativeRect', {
      'handle': handle.toString(),
      'left': rect.left.round().toString(),
      'top': rect.top.round().toString(),
      'width': rect.width.round().toString(),
      'height': rect.height.round().toString(),
    });
    _lastRect = rect;
  }
}

class _ClearPainter extends CustomPainter {
  const _ClearPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..blendMode = BlendMode.clear);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
