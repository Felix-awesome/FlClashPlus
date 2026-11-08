import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;

import '../helpers/app_paths.dart';

const _weiboRuleSet = '''
hostname = api.weibo.cn, mapi.weibo.com,

; a commented out rule
;^https://api.weibo.cn/2/!/client/light_skin url reject

^https?://m?api\\.weibo\\.c(n|om)/2/(cardlist|page) url script-response-body https://cdn.jsdelivr.net/gh/zmqcherish/proxy-script@main/weibo_main.js
''';

void main() {
  group('parseRuleSourceUrls', () {
    test('keeps one http url per line and drops everything else', () {
      final urls = parseRuleSourceUrls('''
# a comment
https://raw.githubusercontent.com/Felix-awesome/Rules-For-Quantumult-X/refs/heads/develop/Rewrite/AdBlock/Weibo.conf

  https://example.com/rules.conf
https://raw.githubusercontent.com/Felix-awesome/Rules-For-Quantumult-X/refs/heads/develop/Rewrite/AdBlock/Weibo.conf
ftp://example.com/rules.conf
''');

      expect(urls, [
        'https://raw.githubusercontent.com/Felix-awesome/Rules-For-Quantumult-X/refs/heads/develop/Rewrite/AdBlock/Weibo.conf',
        'https://example.com/rules.conf',
      ]);
    });

    test('an empty editor means no rule sets', () {
      expect(parseRuleSourceUrls('  \n\n'), isEmpty);
    });
  });

  group('combineRuleSets', () {
    test('local rules come first, blank parts are skipped', () {
      final rules = combineRuleSets('^https?://local\\.example/ad url reject', [
        '',
        _weiboRuleSet,
      ]);

      expect(rules, startsWith('^https?://local\\.example/ad url reject\n'));
      expect(rules, contains('hostname = api.weibo.cn'));
    });

    test('a byte order mark does not survive into the rule text', () {
      final rules = combineRuleSets('', [
        '\uFEFF^https?://example\\.com/a url reject',
      ]);

      expect(rules.startsWith('\uFEFF'), isFalse);
      expect(rules, '^https?://example\\.com/a url reject');
    });

    test('nothing configured means nothing to install', () {
      expect(combineRuleSets('', const []), isEmpty);
    });

    test('a rule set without scripts needs no download', () async {
      const plain = '^https?://ads\\.example/.* url reject';

      final ruleSet = await buildMitmRuleSet('', [plain]);

      expect(ruleSet.rules, plain);
      expect(ruleSet.scripts, isEmpty);
    });
  });

  group('remote rule set cache', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('flclash_mitm_rules');
      await useAppPaths(root);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('a downloaded rule set is stored under its url hash', () async {
      const url = 'https://example.com/Weibo.conf';

      final ruleSets = await refreshRuleSets([
        url,
      ], fetch: (url) async => _weiboRuleSet);

      expect(ruleSets, [_weiboRuleSet]);
      final file = File(
        join(root.path, 'mitm', 'rules', '${url.toMd5()}.conf'),
      );
      expect(await file.readAsString(), _weiboRuleSet);
      expect(await File('${file.path}.download').exists(), isFalse);
    });

    test('a failed download keeps the copy already on disk', () async {
      const url = 'https://example.com/Weibo.conf';
      await refreshRuleSets([url], fetch: (url) async => _weiboRuleSet);

      final ruleSets = await refreshRuleSets(
        [url],
        fetch: (url) async {
          throw const SocketException('offline');
        },
      );

      expect(ruleSets, [_weiboRuleSet]);
    });

    test('an empty answer never replaces the stored copy', () async {
      const url = 'https://example.com/Weibo.conf';
      await refreshRuleSets([url], fetch: (url) async => _weiboRuleSet);

      final ruleSets = await refreshRuleSets([url], fetch: (url) async => '');

      expect(ruleSets, [_weiboRuleSet]);
    });

    test('the cached copies load without touching the network', () async {
      const stored = 'https://example.com/Weibo.conf';
      const missing = 'https://example.com/Missing.conf';
      await refreshRuleSets([stored], fetch: (url) async => _weiboRuleSet);

      expect(await loadCachedRuleSets([stored, missing]), [_weiboRuleSet]);
    });

    test('a script is cached and used again when its cdn is down', () async {
      const rules =
          '^https?://api\\.example/.* url script-response-body https://cdn.example.com/a.js';

      final first = await fetchMitmScripts(
        rules,
        fetch: (url) async => 'var a = 1;',
      );
      expect(first, {'https://cdn.example.com/a.js': 'var a = 1;'});

      final second = await fetchMitmScripts(
        rules,
        fetch: (url) async {
          throw const SocketException('offline');
        },
      );
      expect(second, {'https://cdn.example.com/a.js': 'var a = 1;'});
    });

    test('a local script name is left for the core to resolve', () async {
      const rules =
          '^https?://api\\.example/.* url script-request-header local.js';

      expect(await fetchMitmScripts(rules, fetch: (url) async => ''), isEmpty);
    });
  });
}
