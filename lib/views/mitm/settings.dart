import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'install.dart';
import 'rule_sources.dart';
import 'rules.dart';

/// The file name offered when the MITM root CA is exported. A .crt extension
/// is what both iOS and Android recognise as an installable certificate.
const mitmCertificateFileName = 'FlClash-MITM-CA.crt';

/// MITM 重写（Quantumult X 式）设置视图。
///
/// 开启后，Core 会拦截 HTTPS 连接、以本地 CA 签发证书解密流量，并按规则
/// 逐条匹配 URL，执行 reject / 302 重定向 / header 改写等动作。
///
/// 规则有两个来源：手写的本地规则，以及远端规则集。两者在安装前拼成同一
/// 份文本交给 Core 解析，本地规则排在前面，因此手写的规则总是先匹配。两份
/// 来源各有自己的页面：一个浏览已生效的规则，一个管理远端规则集。
class MitmView extends ConsumerStatefulWidget {
  const MitmView({super.key});

  @override
  ConsumerState<MitmView> createState() => _MitmViewState();
}

class _MitmViewState extends ConsumerState<MitmView> {
  var _sources = const <MitmRuleSource>[];
  var _ruleCount = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final localRules = ref.read(appSettingProvider).mitmRules;
    final sources = await preferences.getMitmRuleSources();
    var count = parseMitmRules(localRules).length;
    for (final source in sources) {
      count += parseMitmRules(await loadCachedRuleSet(source.url)).length;
    }
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _ruleCount = count;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final enableMitm = ref.watch(
      appSettingProvider.select((state) => state.enableMitm),
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
                  // Taken now: the switch rebuilds as soon as the setting
                  // changes, and a ref read after that await belongs to a
                  // widget that is already gone.
                  final core = ref.read(coreHandlerProvider);
                  ref
                      .read(appSettingProvider.notifier)
                      .update((state) => state.copyWith(enableMitm: value));
                  // The core only holds the rule set it was handed, and a core
                  // that started with interception off was handed none, so the
                  // current one is pushed before interception turns on.
                  if (value) {
                    await installMitmRules(ref);
                  }
                  try {
                    await core.setMitm(SetMitmParams(enable: value));
                  } catch (error) {
                    commonPrint.log('set MITM failed: $error');
                  }
                },
              ),
              ListItem.open(
                leading: const GlyphIcon(AppGlyphs.rules),
                title: Text(appLocalizations.mitmRules),
                subtitle: Text(
                  _rulesSummary(appLocalizations),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                widget: const MitmRulesView(),
                onChanged: (_) => _load(),
              ),
              ListItem.open(
                leading: const GlyphIcon(AppGlyphs.cloudSync),
                title: Text(appLocalizations.mitmRuleSources),
                subtitle: Text(
                  _sourcesSummary(appLocalizations),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                widget: const MitmRuleSourcesView(),
                onChanged: (_) => _load(),
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

  String _rulesSummary(AppLocalizations l) {
    if (_ruleCount == 0) return l.mitmRulesEmpty;
    return l.mitmRulesCount(_ruleCount);
  }

  String _sourcesSummary(AppLocalizations l) {
    if (_sources.isEmpty) return l.mitmRuleSourcesEmpty;
    return l.mitmRuleSourcesCount(_sources.length);
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
