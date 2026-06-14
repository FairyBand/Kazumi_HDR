import 'dart:io';

import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:kazumi/services/logging/logger.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class ShaderAssetService {
  late Directory shadersDirectory;

  Future<void> copyShadersToExternalDirectory() async {
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = assetManifest.listAssets();
    final directory = await getApplicationSupportDirectory();
    shadersDirectory = Directory(path.join(directory.path, 'anime_shaders'));

    if (!await shadersDirectory.exists()) {
      await shadersDirectory.create(recursive: true);
      KazumiLogger()
          .i('ShaderManager: Create GLSL Shader: ${shadersDirectory.path}');
    }

    final shaderFiles = assets.where((String asset) =>
        asset.startsWith('assets/shaders/') && asset.endsWith('.glsl'));

    int copiedFilesCount = 0;

    for (var filePath in shaderFiles) {
      final fileName = filePath.split('/').last;
      final targetFile = File(path.join(shadersDirectory.path, fileName));
      try {
        final data = await rootBundle.load(filePath);
        final List<int> bytes = data.buffer.asUint8List();
        if (await targetFile.exists()) {
          final existingBytes = await targetFile.readAsBytes();
          if (_listEquals(existingBytes, bytes)) {
            KazumiLogger().i(
                'ShaderManager: GLSL Shader exists, skip: ${targetFile.path}');
            continue;
          }
        }
        await targetFile.writeAsBytes(bytes);
        copiedFilesCount++;
        KazumiLogger().i('ShaderManager: Copy: ${targetFile.path}');
      } catch (e) {
        KazumiLogger().e('ShaderManager: Copy: ($filePath)', error: e);
      }
    }

    KazumiLogger().i(
        'ShaderManager: $copiedFilesCount GLSL files copied to ${shadersDirectory.path}');
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
