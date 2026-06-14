import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:window_manager/window_manager.dart';

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

  Rect? _lastNativeHdrRect;
  bool? _lastNativeHdrTransparency;

  bool get _usesWindowsNativeHdr =>
      Platform.isWindows &&
      widget.playerController.playback.superResolutionType >= 4;

  void _scheduleNativeHdrRectSync() {
    _syncNativeHdrTransparency();
    if (!_usesWindowsNativeHdr) {
      _lastNativeHdrRect = null;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_usesWindowsNativeHdr) {
        return;
      }
      _syncNativeHdrRect();
    });
  }

  Future<void> _syncNativeHdrTransparency() async {
    final enabled = _usesWindowsNativeHdr;
    if (_lastNativeHdrTransparency == enabled) {
      return;
    }
    _lastNativeHdrTransparency = enabled;
    if (!Platform.isWindows) {
      return;
    }
    try {
      await windowManager.setBackgroundColor(
        enabled ? Colors.transparent : Colors.black,
      );
      await _mediaKitVideoChannel.invokeMethod(
        'VideoOutputManager.SetFlutterOverlayTransparency',
        {'enabled': enabled},
      );
    } catch (_) {}
  }

  Future<void> _syncNativeHdrRect() async {
    final player = widget.playerController.playback.mediaPlayer;
    if (player == null) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final size = renderObject.size;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final rect = Rect.fromLTWH(
      topLeft.dx * devicePixelRatio,
      topLeft.dy * devicePixelRatio,
      size.width * devicePixelRatio,
      size.height * devicePixelRatio,
    );
    if (_lastNativeHdrRect == rect) {
      return;
    }
    _lastNativeHdrRect = rect;
    final handle = await player.handle;
    if (!mounted || !_usesWindowsNativeHdr) {
      return;
    }
    await _mediaKitVideoChannel.invokeMethod(
      'VideoOutputManager.SetNativeRect',
      {
        'handle': handle.toString(),
        'left': rect.left.round().toString(),
        'top': rect.top.round().toString(),
        'width': rect.width.round().clamp(1, 1 << 31).toString(),
        'height': rect.height.round().clamp(1, 1 << 31).toString(),
      },
    );
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _lastNativeHdrTransparency = false;
      unawaited(
        Future.wait([
          windowManager.setBackgroundColor(Colors.black),
          _mediaKitVideoChannel.invokeMethod<void>(
            'VideoOutputManager.SetFlutterOverlayTransparency',
            {'enabled': false},
          ),
        ]).catchError((_) => <void>[]),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerController = widget.playerController;
    return Observer(builder: (context) {
      _scheduleNativeHdrRectSync();
      if (playerController.playback.loading ||
          playerController.playback.videoController == null) {
        return Container(
          color: playerController.playback.usesWindowsNativeHdr
              ? Colors.transparent
              : Colors.black,
          child: const Center(
            child: CircularProgressIndicator(),
          ),
        );
      }

      if (playerController.playback.usesAndroidNativeMpvHdr) {
        return _AndroidNativeSurfaceVideo(
          playerController: playerController,
          fit: playerController.panel.aspectRatioType == 1
              ? BoxFit.contain
              : playerController.panel.aspectRatioType == 2
                  ? BoxFit.cover
                  : BoxFit.fill,
        );
      }

      return Video(
        controller: playerController.playback.videoController!,
        controls: NoVideoControls,
        pauseUponEnteringBackgroundMode: false,
        fill: playerController.playback.usesWindowsNativeHdr
            ? Colors.transparent
            : Colors.black,
        fit: playerController.panel.aspectRatioType == 1
            ? BoxFit.contain
            : playerController.panel.aspectRatioType == 2
                ? BoxFit.cover
                : BoxFit.fill,
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
                  onFocus: () {
                    params.onFocusChanged(true);
                  },
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
