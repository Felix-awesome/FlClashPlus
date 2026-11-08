import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/mitm.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_paths.dart';
import '../helpers/preferences.dart';

const _sharedState = SharedState(
  stopTip: 'stop',
  startTip: 'start',
  localNetworkTip: 'local',
  currentProfileName: 'profile',
  stopText: 'stopped',
  onlyStatisticsProxy: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences store;

  setUp(() async {
    await mockPreferences();
    store = await SharedPreferences.getInstance();
  });

  group('applied config md5', () {
    test('round-trips a written md5 and forgets a cleared one', () async {
      expect(await preferences.getAppliedConfigMd5(), isNull);

      await preferences.saveAppliedConfigMd5('abc');
      expect(await preferences.getAppliedConfigMd5(), 'abc');

      await preferences.saveAppliedConfigMd5(null);
      expect(store.containsKey(appliedConfigMd5Key), isFalse);
    });
  });

  group('version', () {
    test('defaults to 0 when never written', () async {
      expect(await preferences.getVersion(), 0);
    });

    test('round-trips a written version', () async {
      await preferences.setVersion(7);

      expect(await preferences.getVersion(), 7);
    });
  });

  group('config', () {
    test('getConfig returns null when nothing is stored', () async {
      expect(await preferences.getConfig(), isNull);
    });

    test('saveConfig then getConfig round-trips the model', () async {
      const config = Config(
        themeProps: defaultThemeProps,
        currentProfileId: 42,
        excludeSSIDs: ['home'],
      );

      expect(await preferences.saveConfig(config), isTrue);
      final restored = await preferences.getConfig();

      expect(restored, isNotNull);
      expect(restored!.currentProfileId, 42);
      expect(restored.excludeSSIDs, ['home']);
    });

    test('getConfigMap returns null for malformed JSON', () async {
      await store.setString(configKey, 'not-json');

      expect(await preferences.getConfigMap(), isNull);
    });

    test('getConfigMap returns null when the payload is not a map', () async {
      await store.setString(configKey, '123');

      expect(await preferences.getConfigMap(), isNull);
    });
  });

  group('clash config', () {
    test('getClashConfigMap returns null when nothing is stored', () async {
      expect(await preferences.getClashConfigMap(), isNull);
    });

    test('getClashConfigMap decodes a stored map', () async {
      await store.setString(clashConfigKey, json.encode({'mode': 'rule'}));

      expect(await preferences.getClashConfigMap(), {'mode': 'rule'});
    });

    test('getClashConfigMap returns null for malformed JSON', () async {
      await store.setString(clashConfigKey, '{oops');

      expect(await preferences.getClashConfigMap(), isNull);
    });

    test('clearClashConfig removes only the clash config entry', () async {
      await store.setString(clashConfigKey, json.encode({'mode': 'rule'}));
      await preferences.setVersion(3);

      await preferences.clearClashConfig();

      expect(await preferences.getClashConfigMap(), isNull);
      expect(await preferences.getVersion(), 3);
    });
  });

  test('saveShareState writes the encoded shared state', () async {
    await preferences.saveShareState(_sharedState);

    final raw = store.getString('sharedState');
    expect(raw, isNotNull);
    expect(
      SharedState.fromJson(json.decode(raw!) as Map<String, Object?>),
      _sharedState,
    );
  });

  test('clearPreferences empties every stored key', () async {
    await preferences.setVersion(9);
    await preferences.saveConfig(const Config(themeProps: defaultThemeProps));

    await preferences.clearPreferences();

    expect(await preferences.getVersion(), 0);
    expect(await preferences.getConfig(), isNull);
  });

  test('isInit resolves true once shared preferences are available', () async {
    expect(await preferences.isInit, isTrue);
  });

  group('boot record', () {
    test('getBootRecord returns null when nothing is stored', () async {
      expect(await preferences.getBootRecord(), isNull);
    });

    test('saveBootRecord then getBootRecord round-trips the record', () async {
      const record = BootRecord(
        stage: BootStage.starting,
        profileId: 5,
        startedAt: 111,
        failureCount: 1,
        lastFailedProfileId: 4,
        handledExitAt: 99,
      );

      await preferences.saveBootRecord(record);

      expect(await preferences.getBootRecord(), record);
    });

    test('getBootRecord survives a corrupt entry', () async {
      await store.setString(bootRecordKey, 'not json');

      expect(await preferences.getBootRecord(), isNull);
    });
  });

  group('mitm rule sources', () {
    late Directory root;

    setUp(() async {
      // The refresh writes the downloaded copies to the app's directories, so
      // they have to point at a temporary one rather than the platform's.
      root = await Directory.systemTemp.createTemp('flclash_mitm_sources');
      await useAppPaths(root);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('nothing stored means no rule sets', () async {
      expect(await preferences.getMitmRuleSources(), isEmpty);
    });

    test('saved rule sets keep their name and address', () async {
      await preferences.saveMitmRuleSources(const [
        MitmRuleSource(name: 'Weibo', url: 'https://example.com/Weibo.conf'),
      ]);

      final sources = await preferences.getMitmRuleSources();

      expect(sources.single.name, 'Weibo');
      expect(sources.single.url, 'https://example.com/Weibo.conf');
    });

    test('a bare address stored by an older build still loads', () async {
      await store.setStringList(mitmRuleSourcesKey, [
        'https://example.com/Ads.conf',
      ]);

      final sources = await preferences.getMitmRuleSources();

      expect(sources.single.name, 'Ads');
      expect(sources.single.lastUpdateTime, isNull);
    });

    test('a failed refresh keeps the timestamp it had', () async {
      final time = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await preferences.saveMitmRuleSources([
        MitmRuleSource(
          name: 'Weibo',
          url: 'https://example.com/Weibo.conf',
          lastUpdateTime: time,
        ),
      ]);

      final updated = await preferences.refreshMitmRuleSources(
        fetch: (url) async => throw const SocketException('offline'),
      );

      expect(updated, 0);
      final sources = await preferences.getMitmRuleSources();
      expect(sources.single.lastUpdateTime, time);
    });

    test('a refresh that answers stamps the rule set as current', () async {
      await preferences.saveMitmRuleSources(const [
        MitmRuleSource(name: 'Weibo', url: 'https://example.com/Weibo.conf'),
      ]);

      final updated = await preferences.refreshMitmRuleSources(
        fetch: (url) async => r'^https?://a\.example/1 url reject',
      );

      expect(updated, 1);
      final sources = await preferences.getMitmRuleSources();
      expect(sources.single.lastUpdateTime, isNotNull);
    });
  });
}
