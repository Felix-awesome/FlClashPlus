import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hands the core everything it needs to run the rewrite rules: the local
/// rules plus the cached copy of every remote rule set, and the source of each
/// script those rules reference.
///
/// The core only ever holds the text it was last given, so every view that
/// changes one of those inputs — the switch, the rule set page and the rule
/// browser — ends with this call.
Future<void> installMitmRules(WidgetRef ref) async {
  final localRules = ref.read(appSettingProvider).mitmRules;
  final sources = await preferences.getMitmRuleSources();
  try {
    final ruleSets = await loadCachedRuleSets([
      for (final source in sources) source.url,
    ]);
    final ruleSet = await buildMitmRuleSet(localRules, ruleSets);
    await ref
        .read(coreHandlerProvider)
        .updateMitmRules(ruleSet.rules, scripts: ruleSet.scripts);
  } catch (error) {
    commonPrint.log('install MITM rules failed: $error');
  }
}
