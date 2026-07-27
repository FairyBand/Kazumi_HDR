import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:card_settings_ui/card_settings_ui.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late bool disableWarning;
  late SuperResolutionMode superResolutionMode;
  late int mpvHdrTargetPeak;

  @override
  void initState() {
    super.initState();
    disableWarning = GStorage.getSetting<bool>(
      SettingsKeys.disableSuperResolutionWarning,
    );
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.defaultSuperResolutionMode),
    );
    if (!_isModeSupported(superResolutionMode)) {
      superResolutionMode = SuperResolutionMode.off;
    }
    mpvHdrTargetPeak = GStorage.getSetting<int>(SettingsKeys.mpvHdrTargetPeak)
        .clamp(100, 10000)
        .toInt();
  }

  bool _isModeSupported(SuperResolutionMode mode) {
    return switch (mode) {
      SuperResolutionMode.mpvHdr ||
      SuperResolutionMode.mpvHdrEfficiency ||
      SuperResolutionMode.mpvHdrQuality =>
        Platform.isWindows || Platform.isAndroid,
      _ => true,
    };
  }

  Future<void> _editMpvHdrTargetPeak() async {
    final controller = TextEditingController(text: mpvHdrTargetPeak.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('MPV HDR 峰值亮度'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            suffixText: 'nit',
            helperText: '显示器 HDR 峰值亮度，范围 100–10000 nit',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value != null && value >= 100 && value <= 10000) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await GStorage.putSetting<int>(SettingsKeys.mpvHdrTargetPeak, result);
    if (mounted) setState(() => mpvHdrTargetPeak = result);
  }

  @override
  Widget build(BuildContext context) {
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return Scaffold(
      appBar: const SysAppBar(
        title: Text('超分辨率'),
      ),
      body: SettingsList(
        maxWidth: 1000,
        sections: [
          SettingsSection(
              title: Text('超分辨率需要启用硬件解码, 若启用硬件解码后仍然不生效, 尝试切换视频渲染器为 gpu',
                  style: TextStyle(fontFamily: fontFamily)),
              tiles: [
                for (final mode
                    in SuperResolutionMode.values.where(_isModeSupported))
                  SettingsTile<SuperResolutionMode>.radioTile(
                    title: Text(
                      mode.label,
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    description: Text(
                      mode.description,
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    radioValue: mode,
                    groupValue: superResolutionMode,
                    onChanged: (SuperResolutionMode? value) {
                      if (value == null) return;
                      GStorage.putSetting<int>(
                        SettingsKeys.defaultSuperResolutionMode,
                        value.storageValue,
                      );
                      setState(() {
                        superResolutionMode = value;
                      });
                    },
                  ),
              ]),
          if (Platform.isWindows || Platform.isAndroid)
            SettingsSection(
              title: Text('HDR 映射', style: TextStyle(fontFamily: fontFamily)),
              tiles: [
                SettingsTile.navigation(
                  onPressed: (_) => _editMpvHdrTargetPeak(),
                  title: Text(
                    'MPV HDR 峰值亮度',
                    style: TextStyle(fontFamily: fontFamily),
                  ),
                  description: Text(
                    'Windows 使用此值；Android 优先使用系统报告的显示器亮度。',
                    style: TextStyle(fontFamily: fontFamily),
                  ),
                  value: Text(
                    '$mpvHdrTargetPeak nit',
                    style: TextStyle(fontFamily: fontFamily),
                  ),
                ),
              ],
            ),
          SettingsSection(
            title: Text('默认行为', style: TextStyle(fontFamily: fontFamily)),
            tiles: [
              SettingsTile.switchTile(
                title: Text('关闭提示', style: TextStyle(fontFamily: fontFamily)),
                description: Text('关闭每次启用超分辨率时的提示',
                    style: TextStyle(fontFamily: fontFamily)),
                initialValue: disableWarning,
                onToggle: (value) async {
                  disableWarning = value ?? !disableWarning;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.disableSuperResolutionWarning,
                    disableWarning,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
