// ignore_for_file: library_private_types_in_public_api

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/shaders/shaders_controller.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/logger.dart';
import 'package:kazumi/utils/proxy_utils.dart';
import 'package:kazumi/utils/storage.dart';
import 'package:kazumi/utils/utils.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobx/mobx.dart';

part 'player_playback_controller.g.dart';

class PlayerPlaybackController = _PlayerPlaybackController
    with _$PlayerPlaybackController;

abstract class _PlayerPlaybackController with Store {
  _PlayerPlaybackController({
    required this.setting,
    required this.shadersController,
    required this.debug,
    required this.videoUrl,
    required this.onExitSyncPlayRoom,
  });

  final Box setting;
  final ShadersController shadersController;
  final PlayerDebugController debug;
  final String Function() videoUrl;
  final Future<void> Function() onExitSyncPlayRoom;

  Player? mediaPlayer;
  VideoController? videoController;

  bool hAenable = true;
  late String hardwareDecoder;
  bool androidEnableOpenSLES = true;
  bool lowMemoryMode = false;
  bool autoPlay = true;
  bool playerDebugMode = false;
  int buttonSkipTime = 80;
  int arrowKeySkipTime = 10;

  /// 视频超分
  /// 1. OFF
  /// 2. Anime4K Efficiency
  /// 3. Anime4K Quality
  /// 4. MPV SDR to HDR
  /// 5. Anime4K Efficiency + MPV SDR to HDR
  /// 6. Anime4K Quality + MPV SDR to HDR
  @observable
  int superResolutionType = 1;

  @observable
  double volume = -1;

  @observable
  bool loading = true;
  @observable
  bool playing = false;
  @observable
  bool isBuffering = true;
  @observable
  bool completed = false;
  @observable
  Duration currentPosition = Duration.zero;
  @observable
  Duration buffer = Duration.zero;
  @observable
  Duration duration = Duration.zero;
  @observable
  double playerSpeed = 1.0;

  bool isCurrentPlayer(Player player) {
    return identical(mediaPlayer, player);
  }

  Future<Player?> _discardIfNotCurrent(Player player) async {
    if (isCurrentPlayer(player)) {
      return player;
    }
    try {
      await player.dispose();
    } catch (_) {}
    return null;
  }

  @action
  void resetForInit() {
    playing = false;
    loading = true;
    isBuffering = true;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
    completed = false;
  }

  bool get playerPlaying {
    try {
      return mediaPlayer?.state.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerBuffering {
    try {
      return mediaPlayer?.state.buffering ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerCompleted {
    try {
      return mediaPlayer?.state.completed ?? false;
    } catch (_) {
      return false;
    }
  }

  double get playerVolume {
    try {
      return mediaPlayer?.state.volume ?? volume;
    } catch (_) {
      return volume;
    }
  }

  Duration get playerPosition {
    try {
      return mediaPlayer?.state.position ?? currentPosition;
    } catch (_) {
      return currentPosition;
    }
  }

  Duration get playerBuffer {
    try {
      return mediaPlayer?.state.buffer ?? buffer;
    } catch (_) {
      return buffer;
    }
  }

  Duration get playerDuration {
    try {
      return mediaPlayer?.state.duration ?? duration;
    } catch (_) {
      return duration;
    }
  }

  Future<Player?> createVideoController(
      Map<String, String> httpHeaders, bool adBlockerEnabled,
      {int offset = 0}) async {
    superResolutionType =
        setting.get(SettingBoxKey.defaultSuperResolutionType, defaultValue: 1);
    if (!Platform.isWindows && _isMpvHdrType(superResolutionType)) {
      superResolutionType = 1;
    }
    hAenable = setting.get(SettingBoxKey.hAenable, defaultValue: true);
    androidEnableOpenSLES =
        setting.get(SettingBoxKey.androidEnableOpenSLES, defaultValue: true);
    hardwareDecoder =
        setting.get(SettingBoxKey.hardwareDecoder, defaultValue: 'auto-safe');
    autoPlay = setting.get(SettingBoxKey.autoPlay, defaultValue: true);
    lowMemoryMode =
        setting.get(SettingBoxKey.lowMemoryMode, defaultValue: false);
    playerDebugMode =
        setting.get(SettingBoxKey.playerDebugMode, defaultValue: false);

    final Player player = Player(
      configuration: PlayerConfiguration(
        vo: 'null',
        bufferSize: lowMemoryMode ? 15 * 1024 * 1024 : 1500 * 1024 * 1024,
        osc: Platform.isWindows && _isMpvHdrType(superResolutionType),
        logLevel: MPVLogLevel.values[debug.playerLogLevel],
        adBlocker: adBlockerEnabled,
      ),
    );
    mediaPlayer = player;

    debug.playerLog.clear();
    await debug.setup(
      player,
      isCurrentPlayer: isCurrentPlayer,
      playerDebugMode: playerDebugMode,
    );
    if (!isCurrentPlayer(player)) {
      return await _discardIfNotCurrent(player);
    }

    var pp = player.platform as NativePlayer;
    // media-kit 默认启用硬盘作为双重缓存，这可以维持大缓存的前提下减轻内存压力
    // media-kit 内部硬盘缓存目录按照 Linux 配置，这导致该功能在其他平台上被损坏
    // 该设置可以在所有平台上正确启用双重缓存
    await pp.setProperty("demuxer-cache-dir", await Utils.getPlayerTempPath());
    if (!isCurrentPlayer(player)) {
      return await _discardIfNotCurrent(player);
    }
    await pp.setProperty("af", "scaletempo2=max-speed=8");
    if (!isCurrentPlayer(player)) {
      return await _discardIfNotCurrent(player);
    }
    if (Platform.isAndroid) {
      await pp.setProperty("volume-max", "100");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(player);
      }
      if (androidEnableOpenSLES) {
        await pp.setProperty("ao", "opensles");
      } else {
        await pp.setProperty("ao", "audiotrack");
      }
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(player);
      }
    }
    final bool proxyEnable =
        setting.get(SettingBoxKey.proxyEnable, defaultValue: false);
    if (proxyEnable) {
      final String proxyUrl =
          setting.get(SettingBoxKey.proxyUrl, defaultValue: '');
      final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
      if (formattedProxy != null) {
        await pp.setProperty("http-proxy", formattedProxy);
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(player);
        }
        KazumiLogger().i('Player: HTTP 代理设置成功 $formattedProxy');
      }
    }

    await player.setAudioTrack(
      AudioTrack.auto(),
    );
    if (!isCurrentPlayer(player)) {
      return await _discardIfNotCurrent(player);
    }

    String? videoRenderer;
    if (Platform.isAndroid) {
      final String androidVideoRenderer =
          setting.get(SettingBoxKey.androidVideoRenderer, defaultValue: 'auto');

      if (androidVideoRenderer == 'auto') {
        // Android 14 及以上使用基于 Vulkan 的 MPV GPU-NEXT 视频输出，着色器性能更好
        // GPU-NEXT 需要 Vulkan 1.2 支持
        // 避免 Android 14 及以下设备上部分机型 Vulkan 支持不佳导致的黑屏问题
        final int androidSdkVersion = await Utils.getAndroidSdkVersion();
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(player);
        }
        if (androidSdkVersion >= 34) {
          videoRenderer = 'gpu-next';
        } else {
          videoRenderer = 'gpu';
        }
      } else {
        videoRenderer = androidVideoRenderer;
      }
    }

    if (videoRenderer == 'mediacodec_embed') {
      hAenable = true;
      hardwareDecoder = 'mediacodec';
      superResolutionType = 1;
    }
    if (Platform.isWindows && _isMpvHdrType(superResolutionType)) {
      videoRenderer = 'gpu-next';
      hAenable = true;
      hardwareDecoder = 'd3d11va';
      try {
        await pp.setProperty("gpu-api", "d3d11");
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(player);
        }
        await pp.setProperty("osc", "yes");
        await pp.setProperty("input-default-bindings", "yes");
        await pp.setProperty("input-vo-keyboard", "yes");
        await pp.setProperty("cursor-autohide", "1000");
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(player);
        }
        KazumiLogger()
            .i('Player: mpv HDR requested with Windows native gpu-next output');
      } catch (e) {
        KazumiLogger().w('PlayerController: failed to set HDR renderer options',
            error: e);
      }
    }

    videoController = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        vo: videoRenderer,
        enableHardwareAcceleration: hAenable,
        hwdec: hAenable ? hardwareDecoder : 'no',
        windowsNativeWindow:
            Platform.isWindows && _isMpvHdrType(superResolutionType),
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    player.setPlaylistMode(PlaylistMode.none);
    if (!isCurrentPlayer(player)) {
      return await _discardIfNotCurrent(player);
    }

    bool showPlayerError =
        setting.get(SettingBoxKey.showPlayerError, defaultValue: true);
    player.stream.error.listen((event) {
      if (showPlayerError) {
        if (!isCurrentPlayer(player)) {
          return;
        }
        if (event.toString().contains('Failed to open') && playerBuffering) {
          KazumiDialog.showToast(
              message: '加载失败, 请尝试更换其他视频来源', showActionButton: true);
        } else {
          KazumiDialog.showToast(
              message: '播放器内部错误 ${event.toString()} ${videoUrl()}',
              duration: const Duration(seconds: 5),
              showActionButton: true);
        }
      }
      KazumiLogger().e('PlayerController: Player intent error ${videoUrl()}',
          error: event);
    });

    if (superResolutionType != 1) {
      await setShader(superResolutionType, player: player);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(player);
      }
    }

    await player.open(
      Media(videoUrl(),
          start: Duration(seconds: offset), httpHeaders: httpHeaders),
      play: autoPlay,
    );
    if (!isCurrentPlayer(player)) {
      return await _discardIfNotCurrent(player);
    }

    return player;
  }

  Future<void> setShader(int type,
      {bool synchronized = true, Player? player}) async {
    final currentPlayer = player ?? mediaPlayer;
    if (currentPlayer == null) return;
    if (!Platform.isWindows && _isMpvHdrType(type)) {
      type = 1;
    }
    try {
      var pp = currentPlayer.platform as NativePlayer;
      await pp.waitForPlayerInitialization;
      await pp.waitForVideoControllerInitializationIfAttached;
      if (!identical(mediaPlayer, currentPlayer)) {
        return;
      }
      if (type == 2) {
        await _setMpvHdrOutput(pp, enabled: false);
        await pp.command(['change-list', 'vf', 'clr', '']);
        await pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          Utils.buildShadersAbsolutePath(
              shadersController.shadersDirectory.path, mpvAnime4KShadersLite),
        ]);
        superResolutionType = 2;
        return;
      }
      if (type == 3) {
        await _setMpvHdrOutput(pp, enabled: false);
        await pp.command(['change-list', 'vf', 'clr', '']);
        await pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          Utils.buildShadersAbsolutePath(
              shadersController.shadersDirectory.path, mpvAnime4KShaders),
        ]);
        superResolutionType = 3;
        return;
      }
      if (_isMpvHdrType(type)) {
        await pp.setProperty("gpu-api", "d3d11");
        await pp.setProperty("hwdec", "d3d11va");
        if (_usesAnime4KLite(type)) {
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            Utils.buildShadersAbsolutePath(
                shadersController.shadersDirectory.path, mpvAnime4KShadersLite),
          ]);
        } else if (_usesAnime4KQuality(type)) {
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            Utils.buildShadersAbsolutePath(
                shadersController.shadersDirectory.path, mpvAnime4KShaders),
          ]);
        } else {
          await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
        }
        await _setMpvHdrOutput(pp, enabled: true);
        superResolutionType = type;
        return;
      }
      await _setMpvHdrOutput(pp, enabled: false);
      await pp.command(['change-list', 'vf', 'clr', '']);
      await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
      superResolutionType = 1;
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to set shader', error: e);
    }
  }

  bool _isMpvHdrType(int type) {
    return type >= 4 && type <= 6;
  }

  bool get usesWindowsNativeHdr =>
      Platform.isWindows && _isMpvHdrType(superResolutionType);

  bool _usesAnime4KLite(int type) {
    return type == 2 || type == 5;
  }

  bool _usesAnime4KQuality(int type) {
    return type == 3 || type == 6;
  }

  Future<void> _setMpvHdrOutput(NativePlayer pp,
      {required bool enabled}) async {
    if (enabled) {
      await _applyMpvProfile(pp, 'gpu-hq');
      await pp.command([
        'change-list',
        'vf',
        'set',
        'format=primaries=bt.2020',
      ]);
      await pp.setProperty("target-colorspace-hint", "yes");
      await pp.setProperty("target-colorspace-hint-strict", "no");
      await pp.setProperty("d3d11-output-format", "rgb10_a2");
      await pp.setProperty("d3d11-output-csp", "pq");
      await pp.setProperty("dither-depth", "10");
      await pp.setProperty("target-trc", "pq");
      await pp.setProperty("target-prim", "bt.2020");
      await pp.setProperty("target-peak", _mpvHdrTargetPeak().toString());
      await pp.setProperty("hdr-compute-peak", "yes");
      await pp.setProperty("tone-mapping", "bt.2446a");
      await pp.setProperty("tone-mapping-param", "0.0");
      await pp.setProperty("tone-mapping-max-boost", "1.0");
      await pp.setProperty("inverse-tone-mapping", "yes");
      return;
    }
    await pp.command(['change-list', 'vf', 'clr', '']);
    await pp.setProperty("inverse-tone-mapping", "no");
    await pp.setProperty("hdr-compute-peak", "no");
    await pp.setProperty("target-peak", "auto");
    await pp.setProperty("dither-depth", "auto");
    await pp.setProperty("tone-mapping", "auto");
    await pp.setProperty("tone-mapping-param", "0.0");
    await pp.setProperty("tone-mapping-max-boost", "1.0");
    await pp.setProperty("target-prim", "auto");
    await pp.setProperty("target-trc", "auto");
    await pp.setProperty("target-colorspace-hint", "auto");
    await pp.setProperty("target-colorspace-hint-strict", "yes");
    await pp.setProperty("d3d11-output-format", "auto");
    await pp.setProperty("d3d11-output-csp", "auto");
  }

  int _mpvHdrTargetPeak() {
    final peak = setting.get(SettingBoxKey.mpvHdrTargetPeak, defaultValue: 410);
    if (peak is int) {
      return peak.clamp(100, 10000);
    }
    if (peak is double) {
      return peak.round().clamp(100, 10000);
    }
    return int.tryParse(peak.toString())?.clamp(100, 10000) ?? 410;
  }

  Future<void> _applyMpvProfile(NativePlayer pp, String profile) async {
    try {
      await pp.command(['apply-profile', profile]);
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to apply mpv profile $profile',
          error: e);
    }
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    this.playerSpeed = playerSpeed;
    try {
      mediaPlayer!.setRate(playerSpeed);
    } catch (e) {
      KazumiLogger()
          .e('PlayerController: failed to set playback speed', error: e);
    }
  }

  Future<void> setVolume(double value) async {
    value = value.clamp(0.0, 100.0);
    volume = value;
    try {
      if (Utils.isDesktop()) {
        await mediaPlayer!.setVolume(value);
      } else {
        await FlutterVolumeController.setVolume(value / 100);
      }
    } catch (_) {}
  }

  @action
  void syncPlaybackState() {
    final player = mediaPlayer;
    if (player == null) return;

    final PlayerState state;
    try {
      state = player.state;
    } catch (_) {
      return;
    }
    if (playing != state.playing) {
      playing = state.playing;
    }
    if (isBuffering != state.buffering) {
      isBuffering = state.buffering;
    }
    if (currentPosition != state.position) {
      currentPosition = state.position;
    }
    if (buffer != state.buffer) {
      buffer = state.buffer;
    }
    if (duration != state.duration) {
      duration = state.duration;
    }
    if (completed != state.completed) {
      completed = state.completed;
    }
  }

  Future<void> playOrPause({
    required Future<void> Function() pause,
    required Future<void> Function() play,
  }) async {
    if (playerPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> dispose({
    bool disposeSyncPlayController = true,
  }) async {
    final player = mediaPlayer;
    mediaPlayer = null;
    videoController = null;
    final cancelDebugInfoFuture = debug.cancel();
    if (disposeSyncPlayController) {
      try {
        await onExitSyncPlayRoom();
      } catch (_) {}
    }
    try {
      await cancelDebugInfoFuture;
    } catch (_) {}
    try {
      await player?.dispose();
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      final player = mediaPlayer;
      mediaPlayer = null;
      videoController = null;
      await debug.cancel();
      await player?.stop();
      await player?.dispose();
      loading = true;
    } catch (_) {}
  }

  Future<Uint8List?> screenshot({String format = 'image/jpeg'}) async {
    return await mediaPlayer!.screenshot(format: format);
  }
}
