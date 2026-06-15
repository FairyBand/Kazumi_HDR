import 'dart:io';

import 'package:flutter/services.dart';

class WindowsTitleBarService {
  static const MethodChannel _channel =
      MethodChannel('com.predidit.kazumi/windows_title_bar');

  static Future<void> setBrightness(Brightness brightness) async {
    if (!Platform.isWindows) return;

    await _channel.invokeMethod<void>('setBrightness', {
      'brightness': brightness.name,
    });
  }
}
