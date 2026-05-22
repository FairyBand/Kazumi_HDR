import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
        ]).catchError((_) {}),
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
