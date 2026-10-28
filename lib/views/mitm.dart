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

/// MITM 重写（Quantumult X 式）设置视图。
///
/// 开启后，Core 会拦截 HTTPS 连接、以本地 CA 签发证书解密流量，并按
/// 下方规则逐条匹配 URL，执行 reject / 302 重定向 / header 改写等动作。
class MitmView extends ConsumerWidget {
  const MitmView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                onChanged: (ref, value) {
                  ref
                      .read(appSettingProvider.notifier)
                      .update((state) => state.copyWith(enableMitm: value));
                  ref
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
                  onSave: (content) => _saveRules(context, ref, content),
                ),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.lock),
                title: Text(appLocalizations.mitmCertificate),
                subtitle: Text(appLocalizations.mitmCertificateDesc),
                onTap: () => _exportCertificate(context, ref),
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

  Future<void> _saveRules(
    BuildContext context,
    WidgetRef ref,
    String content,
  ) async {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(mitmRules: content));
    // Pull remote scripts referenced by script-request/script-response rules
    // so the core can run them (Quantumult X style remote rewriting).
    final scripts = await _fetchScripts(content);
    await ref
        .read(coreHandlerProvider)
        .updateMitmRules(content, scripts: scripts);
  }

  /// Extracts script references (URLs or local names) from script-* rules and
  /// fetches their JavaScript source. Non-URL references are left empty.
  Future<Map<String, String>> _fetchScripts(String rules) async {
    final refs = <String>{};
    for (final line in rules.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('//')) {
        continue;
      }
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length < 3) continue;
      // Skip the optional "url" marker.
      var action = fields[1];
      if (action == 'url' && fields.length >= 3) {
        action = fields[2];
      }
      if (action.startsWith('script-request') ||
          action.startsWith('script-response')) {
        // The script reference is the last field.
        final ref = fields.last;
        if (ref.isNotEmpty) refs.add(ref);
      }
    }
    final scripts = <String, String>{};
    for (final ref in refs) {
      if (ref.startsWith('http://') || ref.startsWith('https://')) {
        try {
          final response = await request.getTextResponseForUrl(ref);
          final body = response.data ?? '';
          if (body.isNotEmpty) scripts[ref] = body;
        } catch (error) {
          commonPrint.log('fetch MITM script $ref failed: $error');
        }
      }
    }
    return scripts;
  }

  String _rulesSummary(AppLocalizations l, String rules) {
    if (rules.trim().isEmpty) {
      return l.mitmRulesEmpty;
    }
    final count = rules
        .split('\n')
        .where((line) =>
            line.trim().isNotEmpty && !line.trim().startsWith('#'))
        .length;
    return l.mitmRulesCount(count);
  }

  Future<void> _exportCertificate(BuildContext context, WidgetRef ref) async {
    try {
      final cert = await ref.read(coreHandlerProvider).getMitmCertificate();
      await Clipboard.setData(ClipboardData(text: cert));
      if (context.mounted) {
        await dialogs.showMessage(
          message: TextSpan(text: context.appLocalizations.mitmCertCopied),
          context: context,
        );
      }
    } catch (_) {
      if (context.mounted) {
        await dialogs.showMessage(
          message: TextSpan(text: context.appLocalizations.mitmCertError),
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
