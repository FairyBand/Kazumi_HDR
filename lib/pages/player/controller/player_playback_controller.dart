// ignore_for_file: library_private_types_in_public_api

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/player/player_screenshot_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

part 'player_playback_controller.g.dart';

class PlayerPlaybackController = _PlayerPlaybackController
    with _$PlayerPlaybackController;

abstract class _PlayerPlaybackController with Store {
  static const MethodChannel _mediaKitVideoChannel =
      MethodChannel('com.alexmercerind/media_kit_video');

  _PlayerPlaybackController({
    required this.setting,
    required this.shaderAssetService,
    required this.debug,
    required this.videoUrl,
    required this.onExitSyncPlayRoom,
  });

  final Box setting;
  final ShaderAssetService shaderAssetService;
  final PlayerDebugController debug;
  final String Function() videoUrl;
  final Future<void> Function() onExitSyncPlayRoom;
  final PlayerScreenshotService screenshotService =
      const PlayerScreenshotService();

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
  /// 7. RTX HDR
  /// 8. Anime4K Efficiency + RTX HDR
  /// 9. Anime4K Quality + RTX HDR
  @observable
  int superResolutionType = 1;

  @observable
  double volume = -1;

  /// 手势调节时的精确音量，避免 UI 节流导致累计误差
  double preciseVolume = -1;

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
    if (!Platform.isWindows && _isWindowsNativeHdrType(superResolutionType)) {
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
        osc: Platform.isWindows && _isWindowsNativeHdrType(superResolutionType),
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
    await pp.setProperty("demuxer-cache-dir", await getPlayerTempPath());
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
        final int androidSdkVersion =
            await PlatformEnvironmentService.getAndroidSdkVersion();
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
    if (Platform.isWindows && _isWindowsNativeHdrType(superResolutionType)) {
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
        KazumiLogger().i('Player: Windows native gpu-next output requested');
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
            Platform.isWindows && _isWindowsNativeHdrType(superResolutionType),
        windowsNativeRtxHdr:
            Platform.isWindows && _isRtxHdrType(superResolutionType),
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
    if (_isRtxHdrType(superResolutionType)) {
      await _applyRtxHdrAfterOpen(player);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(player);
      }
    }

    return player;
  }

  Future<void> setShader(int type,
      {bool synchronized = true, Player? player}) async {
    final currentPlayer = player ?? mediaPlayer;
    if (currentPlayer == null) return;
    if (!Platform.isWindows && _isWindowsNativeHdrType(type)) {
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
          buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path, mpvAnime4KShadersLite),
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
          buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path, mpvAnime4KShaders),
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
            _buildShaderChain(shaders: mpvAnime4KShadersLite),
          ]);
        } else if (_usesAnime4KQuality(type)) {
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            _buildShaderChain(shaders: mpvAnime4KShaders),
          ]);
        } else {
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            _buildShaderChain(),
          ]);
        }
        await _setMpvHdrOutput(pp, enabled: true);
        superResolutionType = type;
        return;
      }
      if (_isRtxHdrType(type)) {
        await pp.setProperty("gpu-api", "d3d11");
        await pp.setProperty("hwdec", "d3d11va");
        if (_usesAnime4KLite(type)) {
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            _buildShaderChain(
              shaders: mpvAnime4KShadersLite,
              includeMpvHdr: false,
            ),
          ]);
        } else if (_usesAnime4KQuality(type)) {
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            _buildShaderChain(
              shaders: mpvAnime4KShaders,
              includeMpvHdr: false,
            ),
          ]);
        } else {
          await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
        }
        await _setMpvHdrOutput(pp, enabled: false, clearVideoFilters: false);
        await _setRtxHdrCandidateOutput(pp);
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

  bool _isRtxHdrType(int type) {
    return type >= 7 && type <= 9;
  }

  bool _isWindowsNativeHdrType(int type) {
    return _isMpvHdrType(type) || _isRtxHdrType(type);
  }

  bool get usesWindowsNativeHdr =>
      Platform.isWindows && _isWindowsNativeHdrType(superResolutionType);

  bool _usesAnime4KLite(int type) {
    return type == 2 || type == 5 || type == 8;
  }

  bool _usesAnime4KQuality(int type) {
    return type == 3 || type == 6 || type == 9;
  }

  String _buildShaderChain({
    List<String> shaders = const [],
    bool includeMpvHdr = true,
  }) {
    return buildShadersAbsolutePath(
      shaderAssetService.shadersDirectory.path,
      [
        ...shaders,
        if (includeMpvHdr) mpvHdrItmShader,
      ],
    );
  }

  Future<void> _setMpvHdrOutput(
    NativePlayer pp, {
    required bool enabled,
    bool clearVideoFilters = true,
  }) async {
    if (enabled) {
      await _applyMpvProfile(pp, 'gpu-hq');
      if (clearVideoFilters) {
        await pp.command(['change-list', 'vf', 'clr', '']);
      }
      await pp.setProperty("target-trc", "pq");
      await pp.setProperty("target-prim", "bt.2020");
      await pp.setProperty("target-peak", _mpvHdrTargetPeak().toString());
      await pp.setProperty("hdr-reference-white", "203");
      await pp.setProperty("hdr-compute-peak", "yes");
      await pp.setProperty("hdr-peak-percentile", "99.9");
      await pp.setProperty("hdr-peak-decay-rate", "20.0");
      await pp.setProperty("tone-mapping", "spline");
      await pp.setProperty("gamut-mapping-mode", "darken");
      await pp.setProperty("hdr-contrast-recovery", "0.3");
      await pp.setProperty("hdr-contrast-smoothness", "3.5");
      await pp.setProperty("inverse-tone-mapping", "yes");
      await pp.setProperty("video-sync", "display-resample");
      await pp.setProperty("interpolation", "no");
      return;
    }
    if (clearVideoFilters) {
      await pp.command(['change-list', 'vf', 'clr', '']);
    }
    await pp.setProperty("inverse-tone-mapping", "no");
    await pp.setProperty("hdr-compute-peak", "no");
    await pp.setProperty("hdr-peak-percentile", "auto");
    await pp.setProperty("hdr-peak-decay-rate", "auto");
    await pp.setProperty("target-peak", "auto");
    await pp.setProperty("hdr-reference-white", "auto");
    await pp.setProperty("dither-depth", "auto");
    await pp.setProperty("tone-mapping", "auto");
    await pp.setProperty("tone-mapping-param", "0.0");
    await pp.setProperty("tone-mapping-max-boost", "1.0");
    await pp.setProperty("gamut-mapping-mode", "auto");
    await pp.setProperty("hdr-contrast-recovery", "auto");
    await pp.setProperty("hdr-contrast-smoothness", "auto");
    await pp.setProperty("target-prim", "auto");
    await pp.setProperty("target-trc", "auto");
    await pp.setProperty("target-colorspace-hint", "auto");
    await pp.setProperty("target-colorspace-hint-strict", "yes");
    await pp.setProperty("d3d11-output-format", "auto");
    await pp.setProperty("d3d11-output-csp", "auto");
    await pp.setProperty("video-sync", "audio");
    await pp.setProperty("interpolation", "no");
  }

  Future<void> _setRtxHdrCandidateOutput(NativePlayer pp) async {
    final rtxHdrFilter = _rtxHdrFilter();
    await _applyMpvProfile(pp, 'gpu-hq');
    await pp.setProperty("target-colorspace-hint", "auto");
    await pp.setProperty("target-colorspace-hint-strict", "yes");
    await pp.setProperty("d3d11-output-format", "auto");
    await pp.setProperty("d3d11-output-csp", "auto");
    await pp.setProperty("dither-depth", "auto");
    await pp.setProperty("target-trc", "auto");
    await pp.setProperty("target-prim", "auto");
    await pp.setProperty("target-peak", "auto");
    await pp.setProperty("tone-mapping", "auto");
    await pp.setProperty("tone-mapping-param", "0.0");
    await pp.setProperty("tone-mapping-max-boost", "1.0");
    await pp.setProperty("hdr-compute-peak", "no");
    await pp.setProperty("inverse-tone-mapping", "no");
    await pp.setProperty("vf", rtxHdrFilter);
    KazumiLogger().i('Player: RTX HDR candidate path applied vf=$rtxHdrFilter');
  }

  Future<void> _applyRtxHdrAfterOpen(Player player) async {
    if (!isCurrentPlayer(player) || !_isRtxHdrType(superResolutionType)) {
      return;
    }
    try {
      var pp = player.platform as NativePlayer;
      await _setRtxHdrCandidateOutput(pp);
      await _applyNativeRtxHdrFilter(player);
      try {
        await player.stream.videoParams
            .firstWhere((params) =>
                (params.dw ?? 0) > 0 &&
                (params.dh ?? 0) > 0 &&
                (params.pixelformat ?? '').isNotEmpty)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (!isCurrentPlayer(player) || !_isRtxHdrType(superResolutionType)) {
        return;
      }
      await _setRtxHdrCandidateOutput(pp);
      await _applyNativeRtxHdrFilter(player);
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to re-apply RTX HDR filter', error: e);
    }
  }

  Future<void> _applyNativeRtxHdrFilter(Player player) async {
    if (!Platform.isWindows ||
        !isCurrentPlayer(player) ||
        !_isRtxHdrType(superResolutionType)) {
      return;
    }
    try {
      final handle = await player.handle;
      final result = await _mediaKitVideoChannel.invokeMethod(
        'VideoOutputManager.ApplyNativeRtxHdr',
        {
          'handle': handle.toString(),
          'filter': _rtxHdrFilter(),
        },
      );
      KazumiLogger().i('RTX HDR native result: $result');
    } catch (e) {
      KazumiLogger().w('PlayerController: native RTX HDR filter request failed',
          error: e);
    }
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

  String _rtxHdrFilter() {
    return 'd3d11vpp=format=x2bgr10:nvidia-true-hdr=yes,'
        'format=max-luma=${_rtxHdrMaxLuma()}';
  }

  int _rtxHdrMaxLuma() {
    final peak = setting.get(SettingBoxKey.rtxHdrMaxLuma, defaultValue: 1000);
    if (peak is int) {
      return peak.clamp(100, 10000);
    }
    if (peak is double) {
      return peak.round().clamp(100, 10000);
    }
    return int.tryParse(peak.toString())?.clamp(100, 10000) ?? 1000;
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
    updateVolume(value);
    await syncVolumeToDevice(preciseVolume >= 0 ? preciseVolume : volume);
  }

  @action
  void updateVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = value;
    if (volume.toInt() == value.toInt()) {
      return;
    }
    volume = value;
  }

  /// 外部来源（硬件键、系统面板等）变更音量时同步，并清除手势缓存
  @action
  void applyExternalVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = -1;
    volume = value;
  }

  void invalidatePreciseVolume() {
    preciseVolume = -1;
  }

  Future<void> syncVolumeToDevice([double? value]) async {
    final vol = (value ?? volume).clamp(0.0, 100.0);
    try {
      if (isDesktop()) {
        await mediaPlayer!.setVolume(vol);
      } else {
        await FlutterVolumeController.setVolume(vol / 100);
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

  Future<Uint8List?> screenshotPng() async {
    final player = mediaPlayer;
    if (player == null) {
      return null;
    }
    return await screenshotService.capturePng(player);
  }
}
