import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/utils/storage.dart';
import 'package:card_settings_ui/card_settings_ui.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late final Box setting = GStorage.setting;
  late bool promptOnEnable;
  late int mpvHdrTargetPeak;
  late final ValueNotifier<String> superResolutionType = ValueNotifier<String>(
    setting
        .get(SettingBoxKey.defaultSuperResolutionType, defaultValue: 1)
        .toString(),
  );

  @override
  void initState() {
    super.initState();
    final int selectedType = int.tryParse(superResolutionType.value) ?? 1;
    if (!Platform.isWindows && selectedType >= 4) {
      superResolutionType.value = '1';
      setting.put(SettingBoxKey.defaultSuperResolutionType, 1);
    }
    promptOnEnable =
        setting.get(SettingBoxKey.superResolutionWarn, defaultValue: false);
    mpvHdrTargetPeak = storedMpvHdrTargetPeak();
  }

  @override
  void dispose() {
    superResolutionType.dispose();
    super.dispose();
  }

  Future<void> updateMpvHdrTargetPeak() async {
    final controller = TextEditingController(text: mpvHdrTargetPeak.toString());
    final int? targetPeak = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('HDR 峰值亮度'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              suffixText: 'nit',
              helperText: '填写显示器 HDR 最大峰值亮度，建议 100 - 10000',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final value = int.tryParse(controller.text);
                if (value == null || value < 100 || value > 10000) {
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (targetPeak == null) return;
    await setting.put(SettingBoxKey.mpvHdrTargetPeak, targetPeak);
    if (mounted) {
      setState(() {
        mpvHdrTargetPeak = targetPeak;
      });
    }
  }

  int storedMpvHdrTargetPeak() {
    final peak = setting.get(SettingBoxKey.mpvHdrTargetPeak, defaultValue: 410);
    if (peak is int) {
      return peak.clamp(100, 10000);
    }
    if (peak is double) {
      return peak.round().clamp(100, 10000);
    }
    return int.tryParse(peak.toString())?.clamp(100, 10000) ?? 410;
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
              title: Text('超分辨率需要启用硬件解码；HDR 增强选项仅在 Windows HDR 环境下可用',
                  style: TextStyle(fontFamily: fontFamily)),
              tiles: [
                SettingsTile<String>.radioTile(
                  title: Text("OFF", style: TextStyle(fontFamily: fontFamily)),
                  description: Text("默认禁用超分辨率",
                      style: TextStyle(fontFamily: fontFamily)),
                  radioValue: "1",
                  groupValue: superResolutionType.value,
                  onChanged: (String? value) {
                    if (value != null) {
                      setting.put(SettingBoxKey.defaultSuperResolutionType,
                          int.tryParse(value) ?? 1);
                      setState(() {
                        superResolutionType.value = value;
                      });
                    }
                  },
                ),
                SettingsTile<String>.radioTile(
                  title: Text("Efficiency",
                      style: TextStyle(fontFamily: fontFamily)),
                  description: Text("默认启用基于Anime4K的超分辨率 (效率优先)",
                      style: TextStyle(fontFamily: fontFamily)),
                  radioValue: "2",
                  groupValue: superResolutionType.value,
                  onChanged: (String? value) {
                    if (value != null) {
                      setting.put(SettingBoxKey.defaultSuperResolutionType,
                          int.tryParse(value) ?? 1);
                      setState(() {
                        superResolutionType.value = value;
                      });
                    }
                  },
                ),
                SettingsTile<String>.radioTile(
                  title:
                      Text("Quality", style: TextStyle(fontFamily: fontFamily)),
                  description: Text("默认启用基于Anime4K的超分辨率 (质量优先)",
                      style: TextStyle(fontFamily: fontFamily)),
                  radioValue: "3",
                  groupValue: superResolutionType.value,
                  onChanged: (String? value) {
                    if (value != null) {
                      setting.put(SettingBoxKey.defaultSuperResolutionType,
                          int.tryParse(value) ?? 1);
                      setState(() {
                        superResolutionType.value = value;
                      });
                    }
                  },
                ),
                if (Platform.isWindows) ...[
                  SettingsTile<String>.radioTile(
                    title: Text("MPV SDR->HDR",
                        style: TextStyle(fontFamily: fontFamily)),
                    description: Text("使用 mpv 逆色调映射输出 HDR",
                        style: TextStyle(fontFamily: fontFamily)),
                    radioValue: "4",
                    groupValue: superResolutionType.value,
                    onChanged: (String? value) {
                      if (value != null) {
                        setting.put(SettingBoxKey.defaultSuperResolutionType,
                            int.tryParse(value) ?? 1);
                        setState(() {
                          superResolutionType.value = value;
                        });
                      }
                    },
                  ),
                  SettingsTile<String>.radioTile(
                    title: Text("Anime4K Efficiency + HDR",
                        style: TextStyle(fontFamily: fontFamily)),
                    description: Text("Anime4K 效率档 + mpv SDR->HDR",
                        style: TextStyle(fontFamily: fontFamily)),
                    radioValue: "5",
                    groupValue: superResolutionType.value,
                    onChanged: (String? value) {
                      if (value != null) {
                        setting.put(SettingBoxKey.defaultSuperResolutionType,
                            int.tryParse(value) ?? 1);
                        setState(() {
                          superResolutionType.value = value;
                        });
                      }
                    },
                  ),
                  SettingsTile<String>.radioTile(
                    title: Text("Anime4K Quality + HDR",
                        style: TextStyle(fontFamily: fontFamily)),
                    description: Text("Anime4K 质量档 + mpv SDR->HDR",
                        style: TextStyle(fontFamily: fontFamily)),
                    radioValue: "6",
                    groupValue: superResolutionType.value,
                    onChanged: (String? value) {
                      if (value != null) {
                        setting.put(SettingBoxKey.defaultSuperResolutionType,
                            int.tryParse(value) ?? 1);
                        setState(() {
                          superResolutionType.value = value;
                        });
                      }
                    },
                  ),
                  SettingsTile.navigation(
                    onPressed: (_) async {
                      await updateMpvHdrTargetPeak();
                    },
                    title: Text('HDR 峰值亮度',
                        style: TextStyle(fontFamily: fontFamily)),
                    description: Text('mpv target-peak，单位 nit',
                        style: TextStyle(fontFamily: fontFamily)),
                    value: Text('$mpvHdrTargetPeak nit',
                        style: TextStyle(fontFamily: fontFamily)),
                  ),
                ],
              ]),
          SettingsSection(
            title: Text('默认行为', style: TextStyle(fontFamily: fontFamily)),
            tiles: [
              SettingsTile.switchTile(
                title: Text('关闭提示', style: TextStyle(fontFamily: fontFamily)),
                description: Text('关闭每次启用超分辨率时的提示',
                    style: TextStyle(fontFamily: fontFamily)),
                initialValue: promptOnEnable,
                onToggle: (value) async {
                  promptOnEnable = value ?? !promptOnEnable;
                  await setting.put(
                      SettingBoxKey.superResolutionWarn, promptOnEnable);
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
