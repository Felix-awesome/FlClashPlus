import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// The channel the iOS host app exposes its tunnel controls on. It also answers
/// `getHomeDir` with the App Group container the extension can read.
const _iosVpnChannelName = '$packageName/ios_vpn';

Future<String?> _requestAppGroupHomeDirPath() async {
  const channel = MethodChannel(_iosVpnChannelName);
  try {
    return await channel.invokeMethod<String>('getHomeDir');
  } catch (_) {
    return null;
  }
}

class AppPath {
  static AppPath? _instance;
  late ResolveOnce<Directory> _dataDir;
  late ResolveOnce<Directory?> _downloadDir;
  late ResolveOnce<Directory> _tempDir;
  Completer<Directory> cacheDir = Completer();

  @visibleForTesting
  static Future<Directory> Function() supportDirectory =
      _defaultSupportDirectory;

  /// The App Group container as reported by the iOS host app, or null when the
  /// build has no App Group entitlement.
  @visibleForTesting
  static Future<String?> Function() appGroupHomeDirPath =
      _requestAppGroupHomeDirPath;

  @visibleForTesting
  static Future<Directory> Function() temporaryDirectory =
      _defaultTemporaryDirectory;

  @visibleForTesting
  static Future<Directory> Function() cacheDirectory =
      getApplicationCacheDirectory;

  @visibleForTesting
  static Future<Directory?> Function() downloadDirectory =
      getDownloadsDirectory;

  AppPath._internal() {
    _bind();
  }

  @visibleForTesting
  Future<void> rebind() async {
    cacheDir = Completer();
    _bind();
    await Future.wait([_dataDir.value, _downloadDir.value, _tempDir.value]);
  }

  void _bind() {
    _dataDir = ResolveOnce(supportDirectory);
    _downloadDir = ResolveOnce(downloadDirectory);
    _tempDir = ResolveOnce(temporaryDirectory);
    cacheDirectory().then(cacheDir.complete);
  }

  factory AppPath() {
    _instance ??= AppPath._internal();
    return _instance!;
  }

  /// Resolves the directory the app keeps its data in.
  ///
  /// On iOS that has to be the App Group container: the core runs inside the
  /// packet-tunnel extension, whose sandbox cannot read the app's own
  /// container, so `config.yaml`, the profiles and the geo files are only
  /// reachable from there. [fallback] still applies off iOS, and on a build
  /// that dropped the App Group entitlement.
  @visibleForTesting
  static Future<Directory> resolveSupportDirectory({
    required bool isIOS,
    required Future<Directory> Function() fallback,
    required Future<String?> Function() appGroupHomeDir,
  }) async {
    final directory = await fallback();
    if (!isIOS) {
      return directory;
    }
    final groupPath = await appGroupHomeDir();
    if (groupPath == null || groupPath.isEmpty) {
      commonPrint.log(
        'App Group container unavailable, the VPN extension cannot read '
        '${directory.path}',
        logLevel: LogLevel.warning,
      );
      return directory;
    }
    final groupDirectory = Directory(groupPath);
    if (!await groupDirectory.exists()) {
      await groupDirectory.create(recursive: true);
    }
    return groupDirectory;
  }

  static Future<Directory> _defaultSupportDirectory() {
    return resolveSupportDirectory(
      isIOS: Platform.isIOS,
      fallback: getApplicationSupportDirectory,
      appGroupHomeDir: () => appGroupHomeDirPath(),
    );
  }

  /// Resolves the directory temporary files go to.
  ///
  /// iOS hands several of them to the core for validation, and the core runs in
  /// the extension's sandbox, which cannot read the app's own tmp directory.
  /// Keeping scratch files in the shared container is what lets a config that is
  /// still being edited be validated at all.
  @visibleForTesting
  static Future<Directory> resolveTemporaryDirectory({
    required bool isIOS,
    required Future<Directory> Function() fallback,
    required Future<String?> Function() appGroupHomeDir,
  }) async {
    final directory = await fallback();
    if (!isIOS) {
      return directory;
    }
    final groupPath = await appGroupHomeDir();
    if (groupPath == null || groupPath.isEmpty) {
      return directory;
    }
    final shared = Directory(join(groupPath, 'tmp'));
    if (!await shared.exists()) {
      await shared.create(recursive: true);
    }
    return shared;
  }

  static Future<Directory> _defaultTemporaryDirectory() {
    return resolveTemporaryDirectory(
      isIOS: Platform.isIOS,
      fallback: getTemporaryDirectory,
      appGroupHomeDir: () => appGroupHomeDirPath(),
    );
  }

  String get executableExtension {
    return system.isWindows ? '.exe' : '';
  }

  String get executableDirPath {
    final currentExecutablePath = Platform.resolvedExecutable;
    return dirname(currentExecutablePath);
  }

  String get corePath {
    return join(executableDirPath, 'FlClashCore$executableExtension');
  }

  String get helperPath {
    return join(executableDirPath, '$appHelperService$executableExtension');
  }

  Future<String> get downloadDirPath async {
    final directory = await _downloadDir.value;
    return directory?.path ?? await homeDirPath;
  }

  Future<String> get homeDirPath async {
    final directory = await _dataDir.value;
    return directory.path;
  }

  Future<String> get databasePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'database.sqlite');
  }

  Future<String> get tempFilePath async {
    final mTempDir = await _tempDir.value;
    return join(mTempDir.path, 'temp$uniqueId');
  }

  Future<String> get lockFilePath async {
    final homeDirPath = await appPath.homeDirPath;
    return join(homeDirPath, 'FlClash.lock');
  }

  Future<String> get configFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'config.yaml');
  }

  Future<String> get sharedPreferencesPath async {
    final directory = await _dataDir.value;
    return join(directory.path, 'shared_preferences.json');
  }

  Future<String> get profilesPath async {
    final directory = await _dataDir.value;
    return join(directory.path, profilesDirectoryName);
  }

  Future<String> getProfilePath(String fileName) async {
    return join(await profilesPath, '$fileName.yaml');
  }

  Future<String> get scriptsDirPath async {
    final path = await homeDirPath;
    return join(path, 'scripts');
  }

  Future<String> getScriptPath(String fileName) async {
    final path = await scriptsDirPath;
    return join(path, '$fileName.js');
  }

  Future<String> get providerCacheRootPath async {
    final directory = await homeDirPath;
    return join(directory, providersDirectoryName);
  }

  Future<String> getProviderCachePath(String fileName) async {
    return join(
      await providerCacheRootPath,
      rulesProviderDirectoryName,
      fileName,
    );
  }

  Future<String> getProvidersRootPath() async {
    final directory = await profilesPath;
    return join(directory, providersDirectoryName);
  }

  Future<String> getProviderDirPath(int profileId, String type) async {
    final directory = await getProvidersRootPath();
    return join(directory, profileId.toString(), type);
  }

  Future<void> ensureProviderDirs(int profileId) async {
    for (final type in const [
      proxiesProviderDirectoryName,
      rulesProviderDirectoryName,
    ]) {
      final directory = Directory(await getProviderDirPath(profileId, type));
      if (await directory.exists()) {
        continue;
      }
      await directory.create(recursive: true);
    }
  }

  Future<String> get tempPath async {
    final directory = await _tempDir.value;
    return directory.path;
  }
}

final appPath = AppPath();

String getBackupFileName() {
  return '${appName}_backup_${DateTime.now().show}.zip';
}

String get logFileName {
  return '${appName}_${DateTime.now().show}.log';
}
