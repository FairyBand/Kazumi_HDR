import 'dart:io';

import 'package:card_settings_ui/card_settings_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late bool promptOnEnable;
  late int mpvHdrTargetPeak;
  late int rtxHdrMaxLuma;
  bool supportsRtxHdr = false;
  late final ValueNotifier<String> superResolutionType = ValueNotifier<String>(
    GStorage.getSetting(SettingsKeys.defaultSuperResolutionType).toString(),
  );

  @override
  void initState() {
    super.initState();
    final int selectedType = int.tryParse(superResolutionType.value) ?? 1;
    if (_shouldResetInitialType(selectedType)) {
      superResolutionType.value = '1';
      GStorage.putSetting(SettingsKeys.defaultSuperResolutionType, 1);
    }
    promptOnEnable = GStorage.getSetting(SettingsKeys.superResolutionWarn);
    mpvHdrTargetPeak = storedMpvHdrTargetPeak();
    rtxHdrMaxLuma = storedRtxHdrMaxLuma();
    _loadRtxGpuSupport();
  }

  @override
  void dispose() {
    superResolutionType.dispose();
    super.dispose();
  }

  bool isChineseLocale(BuildContext context) {
    return Localizations.localeOf(context).languageCode == 'zh';
  }

  String textFor(BuildContext context, String zh, String en) {
    return isChineseLocale(context) ? zh : en;
  }

  String superResolutionLabel(BuildContext context, int type) {
    final isZh = isChineseLocale(context);
    return switch (type) {
      1 => isZh ? '\u5173\u95ed' : 'OFF',
      2 => isZh ? '\u6548\u7387\u6863' : 'Efficiency',
      3 => isZh ? '\u8d28\u91cf\u6863' : 'Quality',
      4 => 'MPV HDR',
      5 => isZh ? 'MPV HDR + \u6548\u7387\u6863' : 'MPV HDR + Efficiency',
      6 => isZh ? 'MPV HDR + \u8d28\u91cf\u6863' : 'MPV HDR + Quality',
      7 => 'RTX HDR',
      8 => isZh ? 'RTX HDR + \u6548\u7387\u6863' : 'RTX HDR + Efficiency',
      9 => isZh ? 'RTX HDR + \u8d28\u91cf\u6863' : 'RTX HDR + Quality',
      _ => isZh ? '\u672a\u77e5\u9009\u9879' : 'Unknown',
    };
  }

  bool _isMpvHdrType(int type) {
    return type >= 4 && type <= 6;
  }

  bool _isRtxHdrType(int type) {
    return type >= 7 && type <= 9;
  }

  bool _supportsMpvHdrPlatform() {
    return Platform.isWindows || Platform.isAndroid;
  }

  bool _shouldResetInitialType(int type) {
    if (_isMpvHdrType(type)) {
      return !_supportsMpvHdrPlatform();
    }
    if (_isRtxHdrType(type)) {
      return !Platform.isWindows;
    }
    return false;
  }

  Future<void> _loadRtxGpuSupport() async {
    final supported = await PlatformEnvironmentService.hasSupportedRtxGpu();
    if (!mounted) return;
    final int selectedType = int.tryParse(superResolutionType.value) ?? 1;
    if (!supported && _isRtxHdrType(selectedType)) {
      superResolutionType.value = '1';
      await GStorage.putSetting(SettingsKeys.defaultSuperResolutionType, 1);
    }
    if (mounted) {
      setState(() {
        supportsRtxHdr = supported;
      });
    }
  }

  Future<void> updateMpvHdrTargetPeak() async {
    final controller = TextEditingController(text: mpvHdrTargetPeak.toString());
    final int? targetPeak = await showDialog<int>(
      context: context,
      builder: (context) {
        final isZh = isChineseLocale(context);
        return AlertDialog(
          title: Text(isZh ? 'MPV HDR 峰值亮度' : 'MPV HDR peak brightness'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              suffixText: 'nit',
              helperText: isZh
                  ? '仅适用于 MPV HDR，对所有显卡有效。建议填写显示器 HDR 峰值亮度，范围 100 - 10000。'
                  : 'Only applies to MPV HDR and works on all GPUs. Use your display HDR peak brightness, 100 - 10000.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(isZh ? '取消' : 'Cancel'),
            ),
            TextButton(
              onPressed: () {
                final value = int.tryParse(controller.text);
                if (value == null || value < 100 || value > 10000) {
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: Text(isZh ? '确定' : 'OK'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (targetPeak == null) return;
    await GStorage.putSetting(SettingsKeys.mpvHdrTargetPeak, targetPeak);
    if (mounted) {
      setState(() {
        mpvHdrTargetPeak = targetPeak;
      });
    }
  }

  Future<void> updateRtxHdrMaxLuma() async {
    final controller = TextEditingController(text: rtxHdrMaxLuma.toString());
    final int? maxLuma = await showDialog<int>(
      context: context,
      builder: (context) {
        final isZh = isChineseLocale(context);
        return AlertDialog(
          title: Text(isZh ? 'RTX HDR 峰值亮度' : 'RTX HDR peak brightness'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              suffixText: 'nit',
              helperText: isZh
                  ? '仅适用于 RTX HDR，且仅对 NVIDIA RTX 显卡有效。建议与 NVIDIA App 的 RTX HDR 峰值亮度一致，范围 100 - 10000。'
                  : 'Only applies to RTX HDR and only works on NVIDIA RTX GPUs. Match the NVIDIA App RTX HDR peak brightness, 100 - 10000.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(isZh ? '取消' : 'Cancel'),
            ),
            TextButton(
              onPressed: () {
                final value = int.tryParse(controller.text);
                if (value == null || value < 100 || value > 10000) {
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: Text(isZh ? '确定' : 'OK'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (maxLuma == null) return;
    await GStorage.putSetting(SettingsKeys.rtxHdrMaxLuma, maxLuma);
    if (mounted) {
      setState(() {
        rtxHdrMaxLuma = maxLuma;
      });
    }
  }

  int storedMpvHdrTargetPeak() {
    return GStorage.getSetting(SettingsKeys.mpvHdrTargetPeak)
        .clamp(100, 10000)
        .toInt();
  }

  int storedRtxHdrMaxLuma() {
    return GStorage.getSetting(SettingsKeys.rtxHdrMaxLuma)
        .clamp(100, 10000)
        .toInt();
  }

  Future<void> setSuperResolutionType(String value) async {
    await GStorage.putSetting(
      SettingsKeys.defaultSuperResolutionType,
      int.tryParse(value) ?? 1,
    );
    if (mounted) {
      setState(() {
        superResolutionType.value = value;
      });
    }
  }

  SettingsTile<String> superResolutionTile({
    required BuildContext context,
    required String title,
    required String description,
    required String value,
    required String? fontFamily,
  }) {
    return SettingsTile<String>.radioTile(
      title: Text(title, style: TextStyle(fontFamily: fontFamily)),
      description: Text(description, style: TextStyle(fontFamily: fontFamily)),
      radioValue: value,
      groupValue: superResolutionType.value,
      onChanged: (String? nextValue) {
        if (nextValue != null) {
          setSuperResolutionType(nextValue);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final isZh = isChineseLocale(context);
    final bool supportsMpvHdr = _supportsMpvHdrPlatform();
    final bool supportsRtxHdrOptions = Platform.isWindows && supportsRtxHdr;
    return Scaffold(
      appBar: SysAppBar(
        title: Text(isZh ? '超分辨率' : 'Super Resolution'),
      ),
      body: SettingsList(
        maxWidth: 1000,
        sections: [
          SettingsSection(
            title: Text(
              isZh
                  ? '超分辨率需要启用硬件解码；MPV HDR 支持 Windows / Android，RTX HDR 仅支持 Windows NVIDIA RTX'
                  : 'Super resolution requires hardware decoding; MPV HDR supports Windows/Android, RTX HDR requires Windows NVIDIA RTX',
              style: TextStyle(fontFamily: fontFamily),
            ),
            tiles: [
              superResolutionTile(
                context: context,
                title: superResolutionLabel(context, 1),
                description: textFor(
                  context,
                  '\u9ed8\u8ba4\u4f7f\u7528\u5173\u95ed',
                  'Use OFF by default',
                ),
                value: '1',
                fontFamily: fontFamily,
              ),
              superResolutionTile(
                context: context,
                title: superResolutionLabel(context, 2),
                description: textFor(
                  context,
                  '\u9ed8\u8ba4\u4f7f\u7528\u6548\u7387\u6863',
                  'Use Efficiency by default',
                ),
                value: '2',
                fontFamily: fontFamily,
              ),
              superResolutionTile(
                context: context,
                title: superResolutionLabel(context, 3),
                description: textFor(
                  context,
                  '\u9ed8\u8ba4\u4f7f\u7528\u8d28\u91cf\u6863',
                  'Use Quality by default',
                ),
                value: '3',
                fontFamily: fontFamily,
              ),
              if (supportsMpvHdr) ...[
                superResolutionTile(
                  context: context,
                  title: superResolutionLabel(context, 4),
                  description: textFor(
                    context,
                    '\u9ed8\u8ba4\u4f7f\u7528 MPV HDR',
                    'Use MPV HDR by default',
                  ),
                  value: '4',
                  fontFamily: fontFamily,
                ),
                superResolutionTile(
                  context: context,
                  title: superResolutionLabel(context, 5),
                  description: textFor(
                    context,
                    '\u9ed8\u8ba4\u4f7f\u7528 MPV HDR + \u6548\u7387\u6863',
                    'Use MPV HDR + Efficiency by default',
                  ),
                  value: '5',
                  fontFamily: fontFamily,
                ),
                superResolutionTile(
                  context: context,
                  title: superResolutionLabel(context, 6),
                  description: textFor(
                    context,
                    '\u9ed8\u8ba4\u4f7f\u7528 MPV HDR + \u8d28\u91cf\u6863',
                    'Use MPV HDR + Quality by default',
                  ),
                  value: '6',
                  fontFamily: fontFamily,
                ),
                if (supportsRtxHdrOptions) ...[
                  superResolutionTile(
                    context: context,
                    title: superResolutionLabel(context, 7),
                    description: textFor(
                      context,
                      '\u9ed8\u8ba4\u4f7f\u7528 RTX HDR',
                      'Use RTX HDR by default',
                    ),
                    value: '7',
                    fontFamily: fontFamily,
                  ),
                  superResolutionTile(
                    context: context,
                    title: superResolutionLabel(context, 8),
                    description: textFor(
                      context,
                      '\u9ed8\u8ba4\u4f7f\u7528 RTX HDR + \u6548\u7387\u6863',
                      'Use RTX HDR + Efficiency by default',
                    ),
                    value: '8',
                    fontFamily: fontFamily,
                  ),
                  superResolutionTile(
                    context: context,
                    title: superResolutionLabel(context, 9),
                    description: textFor(
                      context,
                      '\u9ed8\u8ba4\u4f7f\u7528 RTX HDR + \u8d28\u91cf\u6863',
                      'Use RTX HDR + Quality by default',
                    ),
                    value: '9',
                    fontFamily: fontFamily,
                  ),
                ],
                if (Platform.isWindows)
                  SettingsTile.navigation(
                    onPressed: (_) async {
                      await updateMpvHdrTargetPeak();
                    },
                    title: Text(
                      isZh ? 'MPV HDR 峰值亮度' : 'MPV HDR peak brightness',
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    description: Text(
                      isZh
                          ? '仅适用于 MPV HDR，对所有显卡均有效。'
                          : 'Only applies to MPV HDR and works on all GPUs.',
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    value: Text(
                      '$mpvHdrTargetPeak nit',
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                  ),
                if (supportsRtxHdrOptions)
                  SettingsTile.navigation(
                    onPressed: (_) async {
                      await updateRtxHdrMaxLuma();
                    },
                    title: Text(
                      isZh ? 'RTX HDR 峰值亮度' : 'RTX HDR peak brightness',
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    description: Text(
                      isZh
                          ? '仅适用于 RTX HDR，且仅对 NVIDIA RTX 显卡有效。'
                          : 'Only applies to RTX HDR and only works on NVIDIA RTX GPUs.',
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    value: Text(
                      '$rtxHdrMaxLuma nit',
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                  ),
              ],
            ],
          ),
          SettingsSection(
            title: Text(
              isZh ? '默认行为' : 'Default Behavior',
              style: TextStyle(fontFamily: fontFamily),
            ),
            tiles: [
              SettingsTile.switchTile(
                title: Text(
                  isZh ? '关闭提示' : 'Disable prompt',
                  style: TextStyle(fontFamily: fontFamily),
                ),
                description: Text(
                  isZh
                      ? '关闭每次启用超分辨率时的提示'
                      : 'Disable the prompt shown when super resolution is enabled',
                  style: TextStyle(fontFamily: fontFamily),
                ),
                initialValue: promptOnEnable,
                onToggle: (value) async {
                  promptOnEnable = value ?? !promptOnEnable;
                  await GStorage.putSetting(
                    SettingsKeys.superResolutionWarn,
                    promptOnEnable,
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
