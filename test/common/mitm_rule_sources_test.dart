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
  group('MitmRuleSource', () {
    test('a stored entry round-trips its name, address and timestamp', () {
      final source = MitmRuleSource(
        name: 'Weibo',
        url: 'https://example.com/Weibo.conf',
        lastUpdateTime: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      final decoded = MitmRuleSource.decodeList(
        MitmRuleSource.encodeList([source]),
      );

      expect(decoded, hasLength(1));
      expect(decoded.single.name, 'Weibo');
      expect(decoded.single.url, source.url);
      expect(decoded.single.lastUpdateTime, source.lastUpdateTime);
    });

    test('a bare address is read as a rule set named after its file', () {
      final decoded = MitmRuleSource.decodeList([
        'https://raw.githubusercontent.com/user/rules/main/Rewrite/AdBlock/Weibo.conf',
      ]);

      expect(decoded.single.name, 'Weibo');
      expect(decoded.single.lastUpdateTime, isNull);
    });

    test('an address that is not http(s) is dropped', () {
      final decoded = MitmRuleSource.decodeList([
        '',
        'not a url',
        'ftp://example.com/rules.conf',
      ]);

      expect(decoded, isEmpty);
    });

    test('the same address is kept once', () {
      final decoded = MitmRuleSource.decodeList([
        'https://example.com/rules.conf',
        'https://example.com/rules.conf',
      ]);

      expect(decoded, hasLength(1));
    });

    test('a name is derived from the file, not the folder', () {
      expect(
        defaultRuleSourceName('https://example.com/a/b/AdBlock.conf'),
        'AdBlock',
      );
      expect(
        defaultRuleSourceName('https://example.com/a/b.conf?token=1'),
        'b',
      );
      expect(
        defaultRuleSourceName('https://example.com/rewrite/'),
        'example.com',
      );
    });
  });

  group('parseMitmRules', () {
    test('every action a rule set can carry is classified', () {
      final entries = parseMitmRules(r'''
^https?://a\.example/1 url reject
^https?://a\.example/2 url 302 https://b.example/2
^https?://a\.example/3 url request-header "X-A" "1"
^https?://a\.example/4 url response-header "a" response-header "b"
^https?://a\.example/5 url response-body "foo" response-body "bar"
^https?://a\.example/6 url jsonjq-response-body '.data.ads'
^https?://a\.example/7 url script-response-body https://cdn.example.com/a.js
^https?://a\.example/8 url echo-response text/html echo-response answer.html
''');

      expect(entries.map((entry) => entry.kind), [
        MitmRuleKind.reject,
        MitmRuleKind.redirect,
        MitmRuleKind.requestHeader,
        MitmRuleKind.responseHeader,
        MitmRuleKind.responseBody,
        MitmRuleKind.jsonQuery,
        MitmRuleKind.script,
        MitmRuleKind.echo,
      ]);
      expect(entries[0].pattern, r'^https?://a\.example/1');
      expect(entries[1].argument, 'https://b.example/2');
      expect(entries[3].argument, '"a" → "b"');
      expect(entries[4].argument, '"foo" → "bar"');
      expect(entries[5].argument, '.data.ads');
      expect(entries[6].argument, 'https://cdn.example.com/a.js');
      expect(entries[7].argument, 'text/html · answer.html');
      expect(entries.every((entry) => entry.valid), isTrue);
    });

    test('a url-and-header rule keeps the header expression apart', () {
      final entries = parseMitmRules(
        r'^https?://a\.example/i "User-Agent: Foo" url-and-header reject',
      );

      expect(entries, hasLength(1));
      expect(entries.single.kind, MitmRuleKind.reject);
      expect(entries.single.headerPattern, '"User-Agent: Foo"');
    });

    test('comments, section headers and settings are not rules', () {
      final entries = parseMitmRules(r'''
[rewrite_local]
; ^https?://a\.example/1 url reject
# ^https?://a\.example/2 url reject
// ^https?://a\.example/3 url reject
hostname = a.example, b.example,
skip_validating_cert = true

[filter_local]
host, ads.example, reject
''');

      expect(entries, isEmpty);
    });

    test('an action this build cannot run is listed and marked', () {
      final entries = parseMitmRules(
        r'^https?://a\.example/1 url some-future-action x',
      );

      expect(entries.single.kind, MitmRuleKind.other);
      expect(entries.single.valid, isFalse);
    });

    test('a redirect without a target is marked', () {
      expect(
        parseMitmRules(r'^https?://a\.example/1 url 302').single.valid,
        isFalse,
      );
    });
  });

  group('combineRuleSets', () {
    test('local rules come first, blank parts are skipped', () {
      final rules = combineRuleSets(r'^https?://local\.example/ad url reject', [
        '',
        _weiboRuleSet,
      ]);

      expect(
        rules,
        startsWith(
          r'^https?://local\.example/ad url reject'
          '\n',
        ),
      );
      expect(rules, contains('hostname = api.weibo.cn'));
    });

    test('a byte order mark does not survive into the rule text', () {
      final rules = combineRuleSets('', [
        '\uFEFF^https?://example\\.com/a url reject',
      ]);

      expect(rules.startsWith('\uFEFF'), isFalse);
      expect(rules, r'^https?://example\.com/a url reject');
    });

    test('nothing configured means nothing to install', () {
      expect(combineRuleSets('', const []), isEmpty);
    });

    test('a rule set without scripts needs no download', () async {
      const plain = r'^https?://ads\.example/.* url reject';

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

      final result = await fetchRuleSet(
        url,
        fetch: (url) async {
          throw const SocketException('offline');
        },
      );

      expect(result.ok, isFalse);
      expect(result.content, _weiboRuleSet);
    });

    test('a successful download reports the fresh copy', () async {
      const url = 'https://example.com/Weibo.conf';

      final result = await fetchRuleSet(
        url,
        fetch: (url) async => _weiboRuleSet,
      );

      expect(result.ok, isTrue);
      expect(result.content, _weiboRuleSet);
      expect(await loadCachedRuleSet(url), _weiboRuleSet);
    });

    test('an empty answer never replaces the stored copy', () async {
      const url = 'https://example.com/Weibo.conf';
      await refreshRuleSets([url], fetch: (url) async => _weiboRuleSet);

      final result = await fetchRuleSet(url, fetch: (url) async => '');

      expect(result.ok, isFalse);
      expect(result.content, _weiboRuleSet);
    });

    test('the cached copies load without touching the network', () async {
      const stored = 'https://example.com/Weibo.conf';
      const missing = 'https://example.com/Missing.conf';
      await refreshRuleSets([stored], fetch: (url) async => _weiboRuleSet);

      expect(await loadCachedRuleSets([stored, missing]), [_weiboRuleSet]);
    });

    test('a deleted rule set takes its cached copy with it', () async {
      const url = 'https://example.com/Weibo.conf';
      await refreshRuleSets([url], fetch: (url) async => _weiboRuleSet);

      await deleteRuleSetCache(url);

      expect(await loadCachedRuleSet(url), isEmpty);
    });

    test('a script is cached and used again when its cdn is down', () async {
      const rules =
          r'^https?://api\.example/.* url script-response-body https://cdn.example.com/a.js';

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
          r'^https?://api\.example/.* url script-request-header local.js';

      expect(await fetchMitmScripts(rules, fetch: (url) async => ''), isEmpty);
    });
  });
}
