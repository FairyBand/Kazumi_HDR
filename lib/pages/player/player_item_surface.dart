import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/pages/player/player_controller.dart';

class PlayerItemSurface extends StatefulWidget {
  const PlayerItemSurface({
    super.key,
    required this.playerController,
  });

  final PlayerController playerController;

  @override
  State<PlayerItemSurface> createState() => _PlayerItemSurfaceState();
}

class _PlayerItemSurfaceState extends State<PlayerItemSurface> {
  static const MethodChannel _mediaKitVideoChannel =
      MethodChannel('com.alexmercerind/media_kit_video');
  static const String _androidNativeSurfaceViewType =
      'com.alexmercerind/media_kit_video/native_surface_view';

  Rect? _lastHdrRect;
  Rect? _pendingHdrRect;
  bool _hdrPostFrameScheduled = false;
  bool _hdrRectSyncInFlight = false;

  bool get _usesWindowsDcompHdr =>
      Platform.isWindows &&
      widget.playerController.playback.usesWindowsDcompHdr;

  void _scheduleHdrRectSync() {
    if (!_usesWindowsDcompHdr) {
      _lastHdrRect = null;
      _pendingHdrRect = null;
      return;
    }
    if (_hdrPostFrameScheduled) return;
    _hdrPostFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hdrPostFrameScheduled = false;
      if (!mounted || !_usesWindowsDcompHdr) return;
      _queueHdrRectSync();
    });
  }

  void _queueHdrRectSync() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final topLeft = renderObject.localToGlobal(Offset.zero);
    // Compare integral physical pixels. Fractional logical coordinates can
    // otherwise enqueue several native resizes that all produce the same DComp
    // bounds.
    final left = (topLeft.dx * pixelRatio).roundToDouble();
    final top = (topLeft.dy * pixelRatio).roundToDouble();
    final right =
        ((topLeft.dx + renderObject.size.width) * pixelRatio).roundToDouble();
    final bottom =
        ((topLeft.dy + renderObject.size.height) * pixelRatio).roundToDouble();
    final rect = Rect.fromLTWH(
      left,
      top,
      (right - left).clamp(1.0, double.infinity),
      (bottom - top).clamp(1.0, double.infinity),
    );
    if (_lastHdrRect == rect || _pendingHdrRect == rect) return;
    _pendingHdrRect = rect;
    if (!_hdrRectSyncInFlight) {
      unawaited(_drainHdrRectSync());
    }
  }

  Future<void> _drainHdrRectSync() async {
    _hdrRectSyncInFlight = true;
    try {
      while (mounted && _usesWindowsDcompHdr && _pendingHdrRect != null) {
        final rect = _pendingHdrRect!;
        _pendingHdrRect = null;
        if (_lastHdrRect == rect) continue;

        final player = widget.playerController.playback.mediaPlayer;
        if (player == null) continue;
        final handle = await player.handle;
        if (!mounted ||
            !_usesWindowsDcompHdr ||
            !identical(player, widget.playerController.playback.mediaPlayer)) {
          continue;
        }
        await _mediaKitVideoChannel.invokeMethod<void>(
          'VideoOutputManager.SetNativeRect',
          {
            'handle': handle.toString(),
            'left': rect.left.toInt().toString(),
            'top': rect.top.toInt().toString(),
            'width': rect.width.toInt().toString(),
            'height': rect.height.toInt().toString(),
          },
        );
        _lastHdrRect = rect;
      }
    } on PlatformException {
      // Output disposal can race the final layout callback during HDR/SDR
      // switching. The next layout pass will retry the newest rectangle.
    } finally {
      _hdrRectSyncInFlight = false;
      if (mounted && _usesWindowsDcompHdr && _pendingHdrRect != null) {
        unawaited(_drainHdrRectSync());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerController = widget.playerController;
    return Observer(builder: (context) {
      Widget surface;
      if (playerController.playback.loading ||
          playerController.playback.videoController == null) {
        surface = Container(
          color: _usesWindowsDcompHdr ? Colors.transparent : Colors.black,
          child: const Center(
            child: CircularProgressIndicator(),
          ),
        );
      } else {
        final aspectRatioMode = playerController.panel.aspectRatioMode;
        final Widget video;
        if (playerController.playback.usesAndroidNativeMpvHdr) {
          video = _AndroidNativeSurfaceVideo(
            playerController: playerController,
            fit: aspectRatioMode.fit,
          );
        } else {
          video = Video(
            controller: playerController.playback.videoController!,
            controls: NoVideoControls,
            pauseUponEnteringBackgroundMode: false,
            fill: _usesWindowsDcompHdr ? Colors.transparent : Colors.black,
            fit: aspectRatioMode.fit,
            subtitleViewConfiguration: SubtitleViewConfiguration(
              style: TextStyle(
                color: Colors.pink,
                fontSize: 48.0,
                background: Paint()..color = Colors.transparent,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.bold,
                shadows: const [
                  Shadow(
                    offset: Offset(1.0, 1.0),
                    blurRadius: 3.0,
                    color: Color.fromARGB(255, 255, 255, 255),
                  ),
                  Shadow(
                    offset: Offset(-1.0, -1.0),
                    blurRadius: 3.0,
                    color: Color.fromARGB(125, 255, 255, 255),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              padding: const EdgeInsets.all(24.0),
            ),
          );
        }
        final frameAspectRatio = aspectRatioMode.frameAspectRatio;
        surface = frameAspectRatio == null
            ? video
            : AspectRatio(aspectRatio: frameAspectRatio, child: video);
      }

      if (!_usesWindowsDcompHdr) {
        _scheduleHdrRectSync();
        return surface;
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          _scheduleHdrRectSync();
          return CustomPaint(
            painter: const _ClearFlutterSurfacePainter(),
            child: surface,
          );
        },
      );
    });
  }
}

class _AndroidNativeSurfaceVideo extends StatefulWidget {
  const _AndroidNativeSurfaceVideo({
    required this.playerController,
    required this.fit,
  });

  final PlayerController playerController;
  final BoxFit fit;

  @override
  State<_AndroidNativeSurfaceVideo> createState() =>
      _AndroidNativeSurfaceVideoState();
}

class _AndroidNativeSurfaceVideoState
    extends State<_AndroidNativeSurfaceVideo> {
  Future<int>? _handleFuture;

  @override
  void initState() {
    super.initState();
    _handleFuture = widget.playerController.playback.mediaPlayer?.handle;
  }

  @override
  void didUpdateWidget(_AndroidNativeSurfaceVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPlayer = oldWidget.playerController.playback.mediaPlayer;
    final player = widget.playerController.playback.mediaPlayer;
    if (!identical(oldPlayer, player)) {
      _handleFuture = player?.handle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final videoController = widget.playerController.playback.videoController;
    final handleFuture = _handleFuture;
    if (videoController == null || handleFuture == null) {
      return const ColoredBox(color: Colors.black);
    }

    return FutureBuilder<int>(
      future: handleFuture,
      builder: (context, snapshot) {
        final handle = snapshot.data;
        if (handle == null) {
          return const ColoredBox(color: Colors.black);
        }
        return ValueListenableBuilder<Rect?>(
          valueListenable: videoController.rect,
          builder: (context, rect, _) {
            final width = (rect?.width ?? 1).clamp(1.0, double.infinity);
            final height = (rect?.height ?? 1).clamp(1.0, double.infinity);
            return PlatformViewLink(
              key: ValueKey('android-native-surface-$handle'),
              viewType: _PlayerItemSurfaceState._androidNativeSurfaceViewType,
              surfaceFactory: (context, controller) {
                return AndroidViewSurface(
                  controller: controller as AndroidViewController,
                  hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                  gestureRecognizers: const <Factory<
                      OneSequenceGestureRecognizer>>{},
                );
              },
              onCreatePlatformView: (params) {
                return PlatformViewsService.initExpensiveAndroidView(
                  id: params.id,
                  viewType: params.viewType,
                  layoutDirection: TextDirection.ltr,
                  creationParams: {
                    'handle': handle.toString(),
                    'width': width.round().toString(),
                    'height': height.round().toString(),
                    'fit': widget.fit.name,
                  },
                  creationParamsCodec: const StandardMessageCodec(),
                  onFocus: () => params.onFocusChanged(true),
                )
                  ..addOnPlatformViewCreatedListener(
                    params.onPlatformViewCreated,
                  )
                  ..create();
              },
            );
          },
        );
      },
    );
  }
}

class _ClearFlutterSurfacePainter extends CustomPainter {
  const _ClearFlutterSurfacePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..blendMode = BlendMode.clear,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
