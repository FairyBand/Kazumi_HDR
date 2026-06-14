import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

class AndroidHdrDisplayCapabilities {
  const AndroidHdrDisplayCapabilities({
    this.maxLuminance,
    this.maxAverageLuminance,
    this.minLuminance,
    this.supportedHdrTypes = const [],
  });

  final double? maxLuminance;
  final double? maxAverageLuminance;
  final double? minLuminance;
  final List<int> supportedHdrTypes;

  bool get hasHdrSupport => supportedHdrTypes.isNotEmpty;
}

class PlatformEnvironmentService {
  PlatformEnvironmentService._();

  static const _intentChannel = MethodChannel('com.predidit.kazumi/intent');
  static Future<bool>? _supportedRtxGpuFuture;
  static bool? _supportedRtxGpu;

  static Future<bool> isInMultiWindowMode() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod('checkIfInMultiWindowMode');
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to check multi window mode: '${e.message}'.");
      return false;
    }
  }

  static Future<bool> isRunningOnX11() async {
    if (!Platform.isLinux) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod('isRunningOnX11');
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to check X11 environment: '${e.message}'.");
      return false;
    }
  }

  static Future<int> getAndroidSdkVersion() async {
    if (!Platform.isAndroid) {
      return 0;
    }
    try {
      return await _intentChannel.invokeMethod('getAndroidSdkVersion');
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to get Android SDK version: '${e.message}'.");
      return 0;
    }
  }

  static Future<double?> getAndroidHdrPeakBrightness() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final peak = await _intentChannel
          .invokeMethod<num?>('getAndroidHdrPeakBrightness');
      final value = peak?.toDouble();
      if (value == null || value <= 0 || !value.isFinite) {
        return null;
      }
      return value;
    } on PlatformException catch (e) {
      KazumiLogger()
          .e("Failed to get Android HDR peak brightness: '${e.message}'.");
      return null;
    }
  }

  static Future<AndroidHdrDisplayCapabilities?>
      getAndroidHdrDisplayCapabilities() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final result = await _intentChannel.invokeMethod<Map<dynamic, dynamic>?>(
          'getAndroidHdrDisplayCapabilities');
      if (result == null) {
        return null;
      }
      double? finitePositive(String key) {
        final value = result[key];
        if (value is! num) {
          return null;
        }
        final normalized = value.toDouble();
        return normalized > 0 && normalized.isFinite ? normalized : null;
      }

      final supportedHdrTypes = (result['supportedHdrTypes'] as List<dynamic>?)
              ?.whereType<num>()
              .map((value) => value.toInt())
              .toList(growable: false) ??
          const <int>[];
      final minLuminance = result['minLuminance'];
      return AndroidHdrDisplayCapabilities(
        maxLuminance: finitePositive('maxLuminance'),
        maxAverageLuminance: finitePositive('maxAverageLuminance'),
        minLuminance: minLuminance is num && minLuminance >= 0
            ? minLuminance.toDouble()
            : null,
        supportedHdrTypes: supportedHdrTypes,
      );
    } on PlatformException catch (e) {
      KazumiLogger()
          .e("Failed to get Android HDR display capabilities: '${e.message}'.");
      return null;
    }
  }

  static Future<bool> setAndroidHdrMode(bool enabled) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod(
        'setAndroidHdrMode',
        {'enabled': enabled},
      );
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to set Android HDR mode: '${e.message}'.");
      return false;
    }
  }

  static Future<bool> hasSupportedRtxGpu({bool refresh = false}) async {
    if (!Platform.isWindows) {
      return false;
    }
    if (!refresh && _supportedRtxGpu != null) {
      return _supportedRtxGpu!;
    }
    if (refresh) {
      _supportedRtxGpuFuture = null;
    }
    _supportedRtxGpuFuture ??= _detectSupportedRtxGpu();
    _supportedRtxGpu = await _supportedRtxGpuFuture!;
    return _supportedRtxGpu!;
  }

  static Future<bool> _detectSupportedRtxGpu() async {
    final powershellOutput = await _runGpuQuery(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        r'(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join "`n"',
      ],
    );
    if (powershellOutput != null) {
      final detected = _containsSupportedRtxGpu(powershellOutput);
      if (!detected) {
        KazumiLogger().i(
          'PlatformEnvironmentService: supported RTX GPU was not detected',
        );
      }
      return detected;
    }
    final wmicOutput = await _runGpuQuery(
      'wmic.exe',
      ['path', 'Win32_VideoController', 'get', 'Name'],
    );
    final detected = _containsSupportedRtxGpu(wmicOutput ?? '');
    if (!detected) {
      KazumiLogger().i(
        'PlatformEnvironmentService: supported RTX GPU was not detected',
      );
    }
    return detected;
  }

  static Future<String?> _runGpuQuery(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(
        executable,
        arguments,
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) {
        final output = result.stdout.toString().trim();
        return output.isEmpty ? null : output;
      }
      KazumiLogger().w(
        'PlatformEnvironmentService: GPU query failed: $executable',
        error: result.stderr,
      );
    } catch (e) {
      KazumiLogger().w(
        'PlatformEnvironmentService: failed to query GPU: $executable',
        error: e,
      );
    }
    return null;
  }

  static bool _containsSupportedRtxGpu(String gpuNames) {
    final lines = gpuNames
        .split(RegExp(r'[\r\n]+'))
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty);
    final rtxPattern = RegExp(r'\bRTX\b', caseSensitive: false);
    for (final name in lines) {
      final upperName = name.toUpperCase();
      final isNvidia = upperName.contains('NVIDIA') ||
          upperName.contains('GEFORCE') ||
          upperName.contains('QUADRO');
      if (isNvidia && rtxPattern.hasMatch(name)) {
        KazumiLogger().i('PlatformEnvironmentService: RTX GPU detected: $name');
        return true;
      }
    }
    return false;
  }
}
