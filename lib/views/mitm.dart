import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The file name offered when the MITM root CA is exported. A .crt extension
/// is what both iOS and Android recognise as an installable certificate.
const mitmCertificateFileName = 'FlClash-MITM-CA.crt';

/// MITM 重写（Quantumult X 式）设置视图。
///
/// 开启后，Core 会拦截 HTTPS 连接、以本地 CA 签发证书解密流量，并按
/// 下方规则逐条匹配 URL，执行 reject / 302 重定向 / header 改写等动作。
///
/// 规则有两个来源：这里手写的本地规则，以及一排远端规则集地址。两者在
/// 安装前拼成同一份文本交给 Core 解析，本地规则排在前面，因此手写的规则
/// 总是先匹配。
class MitmView extends ConsumerStatefulWidget {
  const MitmView({super.key});

  @override
  ConsumerState<MitmView> createState() => _MitmViewState();
}

class _MitmViewState extends ConsumerState<MitmView> {
  /// The remote rule sets, kept in memory so the section can show how many are
  /// configured without waiting for storage on every rebuild.
  List<String> _ruleSources = const [];

  @override
  void initState() {
    super.initState();
    _loadRuleSources();
  }

  Future<void> _loadRuleSources() async {
    final sources = await preferences.getMitmRuleSources();
    if (!mounted) return;
    setState(() => _ruleSources = sources);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final enableMitm = ref.watch(
      appSettingProvider.select((state) => state.enableMitm),
    );
    final mitmRules = ref.watch(
      appSettingProvider.select((state) => state.mitmRules),
    );

    return BaseScaffold(
      title: appLocalizations.mitmRewrite,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            items: [
              ConfigToggleItem(
                title: (l) => l.mitmEnable,
                selector: appSettingProvider.select(
                  (state) => state.enableMitm,
                ),
                onChanged: (ref, value) async {
                  ref
                      .read(appSettingProvider.notifier)
                      .update((state) => state.copyWith(enableMitm: value));
                  // The core only holds the rule set it was handed, and a core
                  // that started with interception off was handed none, so the
                  // current one is pushed before interception turns on.
                  if (value) {
                    await _installRules(await loadCachedRuleSets(_ruleSources));
                  }
                  await ref
                      .read(coreHandlerProvider)
                      .setMitm(SetMitmParams(enable: value));
                },
              ),
              ListItem.open(
                leading: const GlyphIcon(AppGlyphs.code),
                title: Text(appLocalizations.mitmRules),
                subtitle: Text(
                  _rulesSummary(appLocalizations, mitmRules),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                widget: _MitmRulesEditor(
                  initialContent: mitmRules,
                  onSave: (content) => _saveRules(content),
                ),
              ),
              ListItem.open(
                leading: const GlyphIcon(AppGlyphs.cloudSync),
                title: Text(appLocalizations.mitmRuleSources),
                subtitle: Text(
                  _sourcesSummary(appLocalizations, _ruleSources),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                widget: _MitmRuleSourcesEditor(
                  initialContent: _ruleSources.join('\n'),
                  onSave: (content) => _saveRuleSources(content),
                ),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.lock),
                title: Text(appLocalizations.mitmCertificate),
                subtitle: Text(appLocalizations.mitmCertificateDesc),
                onTap: () => _exportCertificate(context),
              ),
            ],
          ),
          if (enableMitm)
            generateSection(
              footer: appLocalizations.mitmCaInstallHint,
              items: const [],
            ),
        ],
      ),
    );
  }

  Future<void> _saveRules(String content) async {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(mitmRules: content));
    // The remote copies are already on disk, so saving the local rules does not
    // have to wait on the network.
    await _installRules(await loadCachedRuleSets(_ruleSources));
  }

  Future<void> _saveRuleSources(String content) async {
    final appLocalizations = context.appLocalizations;
    final sources = parseRuleSourceUrls(content);
    await preferences.saveMitmRuleSources(sources);
    if (mounted) {
      setState(() => _ruleSources = sources);
    }
    // Downloading is what tells the user the address actually works, so it
    // happens here rather than on the next start.
    final ruleSets = await refreshRuleSets(sources);
    await _installRules(ruleSets);
    if (!mounted) return;
    await dialogs.showMessage(
      message: TextSpan(
        text: appLocalizations.mitmRuleSourcesSaved(ruleSets.length),
      ),
      context: context,
    );
  }

  /// Installs the local rules plus [ruleSets] in the core.
  ///
  /// The core may well be gone here: the rule set is stored locally either way
  /// and pushed again the next time it starts.
  Future<void> _installRules(List<String> ruleSets) async {
    final localRules = ref.read(appSettingProvider).mitmRules;
    try {
      final ruleSet = await buildMitmRuleSet(localRules, ruleSets);
      await ref
          .read(coreHandlerProvider)
          .updateMitmRules(ruleSet.rules, scripts: ruleSet.scripts);
    } catch (error) {
      commonPrint.log('install MITM rules failed: $error');
    }
  }

  String _rulesSummary(AppLocalizations l, String rules) {
    if (rules.trim().isEmpty) {
      return l.mitmRulesEmpty;
    }
    final count = rules
        .split('\n')
        .where((line) => line.trim().isNotEmpty && !line.trim().startsWith('#'))
        .length;
    return l.mitmRulesCount(count);
  }

  String _sourcesSummary(AppLocalizations l, List<String> sources) {
    if (sources.isEmpty) {
      return l.mitmRuleSourcesEmpty;
    }
    return l.mitmRuleSourcesCount(sources.length);
  }

  Future<void> _exportCertificate(BuildContext context) async {
    final appLocalizations = context.appLocalizations;
    try {
      final cert = await ref.read(coreHandlerProvider).getMitmCertificate();
      // Save a real file rather than only copying the PEM text: neither iOS
      // nor Android can install a certificate straight from the clipboard.
      final uri = await picker.saveFile(
        mitmCertificateFileName,
        Uint8List.fromList(utf8.encode(cert)),
      );
      if (!context.mounted) {
        return;
      }
      if (uri == null) {
        // The picker was dismissed: keep the PEM on the clipboard so the copy
        // is still reachable for a manual install.
        await Clipboard.setData(ClipboardData(text: cert));
        if (!context.mounted) {
          return;
        }
        await dialogs.showMessage(
          message: TextSpan(text: appLocalizations.mitmCertCopied),
          context: context,
        );
        return;
      }
      await dialogs.showMessage(
        message: TextSpan(text: appLocalizations.exportSuccess),
        context: context,
      );
    } catch (_) {
      if (context.mounted) {
        await dialogs.showMessage(
          message: TextSpan(text: appLocalizations.mitmCertError),
          context: context,
        );
      }
    }
  }
}

class _MitmRulesEditor extends StatelessWidget {
  const _MitmRulesEditor({required this.initialContent, required this.onSave});

  final String initialContent;
  final ValueChanged<String> onSave;

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      title: context.appLocalizations.mitmRules,
      content: initialContent,
      language: Language.javaScript,
      onSave: (context, _, content) async {
        onSave(await content.readText());
      },
    );
  }
}

/// The editor for the remote rule set addresses: one URL per line, blank lines
/// and `#` comments ignored.
class _MitmRuleSourcesEditor extends StatelessWidget {
  const _MitmRuleSourcesEditor({
    required this.initialContent,
    required this.onSave,
  });

  final String initialContent;
  final ValueChanged<String> onSave;

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      title: context.appLocalizations.mitmRuleSources,
      content: initialContent,
      language: Language.yaml,
      onSave: (context, _, content) async {
        onSave(await content.readText());
      },
    );
  }
}
