import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:yaml/yaml.dart';

import '../helpers/app_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('path_test');
    await useAppPaths(root);
  });

  tearDownAll(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('provider directories match the paths handed to the core', () async {
    const proxiesUrl = 'https://example.com/a.yaml';
    const rulesUrl = 'https://example.com/b.yaml';
    final proxiesDir = await appPath.getProviderDirPath(
      7,
      proxiesProviderDirectoryName,
    );
    final rulesDir = await appPath.getProviderDirPath(
      7,
      rulesProviderDirectoryName,
    );

    final result = await makeRealProfileTask(
      MakeRealProfileState(
        profilesPath: await appPath.profilesPath,
        profileId: 7,
        rawConfig: {
          'proxy-providers': {
            'a': {'type': 'http', 'url': proxiesUrl},
          },
          'rule-providers': {
            'b': {'type': 'http', 'url': rulesUrl},
          },
        },
        realPatchConfig: const PatchClashConfig(),
        appendSystemDns: false,
        proxyGroups: const [],
        rules: const [],
        addedRules: const [],
        defaultUA: 'FlClash',
      ),
    );
    final config = loadYaml(result.yaml) as YamlMap;

    expect(
      config['proxy-providers']['a']['path'],
      join(proxiesDir, 'a@$proxiesUrl'.toMd5()),
    );
    expect(
      config['rule-providers']['b']['path'],
      join(rulesDir, 'b@$rulesUrl'.toMd5()),
    );
  });

  test('confines a provider path the profile tried to choose', () async {
    final proxiesDir = await appPath.getProviderDirPath(
      7,
      proxiesProviderDirectoryName,
    );
    final rulesDir = await appPath.getProviderDirPath(
      7,
      rulesProviderDirectoryName,
    );

    final result = await makeRealProfileTask(
      MakeRealProfileState(
        profilesPath: await appPath.profilesPath,
        profileId: 7,
        rawConfig: {
          'proxy-providers': {
            'escape': {'type': 'file', 'path': '../../../../config.yaml'},
            'urlless': {'type': 'http', 'path': 'cache.db'},
            'literal': {
              'type': 'inline',
              'payload': ['DIRECT'],
            },
          },
          'rule-providers': {
            'sneak': {'type': 'file', 'path': '/etc/hosts'},
          },
        },
        realPatchConfig: const PatchClashConfig(),
        appendSystemDns: false,
        proxyGroups: const [],
        rules: const [],
        addedRules: const [],
        defaultUA: 'FlClash',
      ),
    );
    final config = loadYaml(result.yaml) as YamlMap;

    expect(
      config['proxy-providers']['escape']['path'],
      join(proxiesDir, 'proxy-providers/escape'.toMd5()),
    );
    expect(
      config['proxy-providers']['urlless']['path'],
      join(proxiesDir, 'proxy-providers/urlless'.toMd5()),
    );
    expect(config['proxy-providers']['literal']['path'], isNull);
    expect(
      config['rule-providers']['sneak']['path'],
      join(rulesDir, 'rule-providers/sneak'.toMd5()),
    );
  });

  test('survives a provider section that is not a map', () async {
    final result = await makeRealProfileTask(
      MakeRealProfileState(
        profilesPath: await appPath.profilesPath,
        profileId: 7,
        rawConfig: {
          'proxy-providers': ['not-a-map'],
          'rule-providers': {
            'broken': ['also-not-a-map'],
          },
        },
        realPatchConfig: const PatchClashConfig(),
        appendSystemDns: false,
        proxyGroups: const [],
        rules: const [],
        addedRules: const [],
        defaultUA: 'FlClash',
      ),
    );

    expect(result.yaml, isNotEmpty);
  });

  test('ensureProviderDirs creates both provider directories', () async {
    await appPath.ensureProviderDirs(9);

    for (final type in const [
      proxiesProviderDirectoryName,
      rulesProviderDirectoryName,
    ]) {
      expect(
        Directory(await appPath.getProviderDirPath(9, type)).existsSync(),
        isTrue,
      );
    }

    await expectLater(appPath.ensureProviderDirs(9), completes);
  });

  group('support directory', () {
    late Directory fallback;
    late Directory group;

    setUp(() {
      fallback = Directory.systemTemp.createTempSync('path_fallback');
      group = Directory.systemTemp.createTempSync('path_group');
      // The resolver has to create it, so start from a path that does not exist.
      group.deleteSync(recursive: true);
    });

    tearDown(() {
      for (final directory in [fallback, group]) {
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      }
    });

    test(
      'off iOS the app container is used and the group is never asked',
      () async {
        var groupAsked = false;

        final resolved = await AppPath.resolveSupportDirectory(
          isIOS: false,
          fallback: () async => fallback,
          appGroupHomeDir: () async {
            groupAsked = true;
            return group.path;
          },
        );

        expect(resolved.path, fallback.path);
        expect(groupAsked, isFalse);
      },
    );

    test('on iOS the App Group container wins and is created', () async {
      final resolved = await AppPath.resolveSupportDirectory(
        isIOS: true,
        fallback: () async => fallback,
        appGroupHomeDir: () async => group.path,
      );

      expect(resolved.path, group.path);
      expect(group.existsSync(), isTrue);
    });

    test(
      'a missing or empty group path falls back to the app container',
      () async {
        for (final groupPath in <String?>[null, '']) {
          final resolved = await AppPath.resolveSupportDirectory(
            isIOS: true,
            fallback: () async => fallback,
            appGroupHomeDir: () async => groupPath,
          );

          expect(resolved.path, fallback.path);
        }
      },
    );
  });

  group('temporary directory', () {
    late Directory fallback;
    late Directory group;

    setUp(() {
      fallback = Directory.systemTemp.createTempSync('tmp_fallback');
      group = Directory.systemTemp.createTempSync('tmp_group');
    });

    tearDown(() {
      for (final directory in [fallback, group]) {
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      }
    });

    test('off iOS the system temp directory is kept', () async {
      var groupAsked = false;

      final resolved = await AppPath.resolveTemporaryDirectory(
        isIOS: false,
        fallback: () async => fallback,
        appGroupHomeDir: () async {
          groupAsked = true;
          return group.path;
        },
      );

      expect(resolved.path, fallback.path);
      expect(groupAsked, isFalse);
    });

    test('on iOS scratch files move into the shared container', () async {
      final resolved = await AppPath.resolveTemporaryDirectory(
        isIOS: true,
        fallback: () async => fallback,
        appGroupHomeDir: () async => group.path,
      );

      expect(resolved.path, join(group.path, 'tmp'));
      expect(resolved.existsSync(), isTrue);
    });

    test('a missing group path keeps the system temp directory', () async {
      for (final groupPath in <String?>[null, '']) {
        final resolved = await AppPath.resolveTemporaryDirectory(
          isIOS: true,
          fallback: () async => fallback,
          appGroupHomeDir: () async => groupPath,
        );

        expect(resolved.path, fallback.path);
      }
    });
  });
}
