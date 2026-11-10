import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hands the core everything it needs to run the rewrite rules: the local
/// rules plus the cached copy of every remote rule set, and the source of each
/// script those rules reference.
///
/// The core only ever holds the text it was last given, so every view that
/// changes one of those inputs — the switch, the rule set page and the rule
/// browser — ends with this call.
///
/// Everything the widget tree provides is read before the first await: a caller
/// that awaited a download first would otherwise reach for a `ref` whose widget
/// is already gone, and the whole install would be dropped on the floor.
Future<bool> installMitmRules(WidgetRef ref) {
  return installMitmRulesFor(
    ref.read(coreHandlerProvider),
    ref.read(appSettingProvider).mitmRules,
  );
}

/// Installs the rules for a caller that already resolved the core and the local
/// rules, because its widget may be gone by the time the download finishes.
Future<bool> installMitmRulesFor(CoreController core, String localRules) async {
  final sources = await preferences.getMitmRuleSources();
  try {
    final ruleSets = await loadCachedRuleSets([
      for (final source in sources) source.url,
    ]);
    final ruleSet = await buildMitmRuleSet(localRules, ruleSets);
    await core.updateMitmRules(ruleSet.rules, scripts: ruleSet.scripts);
    return true;
  } catch (error) {
    commonPrint.log('install MITM rules failed: $error');
    return false;
  }
}
