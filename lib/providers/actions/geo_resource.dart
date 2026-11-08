part of '../action.dart';

/// The file the Core reads this database from, inside the shared home folder.
String geoFileName(GeoResource geoResource) {
  return switch (geoResource) {
    GeoResource.MMDB => MMDB,
    GeoResource.ASN => ASN,
    GeoResource.GEOIP => GEOIP,
    GeoResource.GEOSITE => GEOSITE,
  };
}

/// Whether a response can be handed to the Core as one of its databases.
///
/// Without a Core there is nothing that can parse the file, so the app checks
/// what is checkable here: a real database is megabytes long, and an MMDB file
/// carries the MaxMind marker at its end. This guard exists because replacing a
/// database with something else is not a failed update -- the Core refuses to
/// start with an unreadable one, which on iOS means the tunnel never comes up
/// again.
bool looksLikeGeoDatabase(GeoResource geoResource, List<int> bytes) {
  const minimumSize = 256 * 1024;
  if (bytes.length < minimumSize) {
    return false;
  }
  if (geoResource != GeoResource.MMDB && geoResource != GeoResource.ASN) {
    return true;
  }
  const marker = 'MaxMind.com';
  final tail = bytes.length > 128 * 1024
      ? bytes.sublist(bytes.length - 128 * 1024)
      : bytes;
  return String.fromCharCodes(tail).contains(marker);
}

/// Writes a downloaded database where the Core reads it from.
///
/// Written beside the target and renamed over it: a Core that is reading the
/// old file keeps doing so until it reloads, and no reader ever sees a partial
/// database.
Future<File> storeGeoDatabase(GeoResource geoResource, List<int> bytes) async {
  if (!looksLikeGeoDatabase(geoResource, bytes)) {
    throw MessageException(
      '${geoResource.name}: the download is not a usable database',
    );
  }
  final homePath = await appPath.homeDirPath;
  final file = File(join(homePath, geoFileName(geoResource)));
  final temporary = File('${file.path}.download');
  await temporary.writeAsBytes(bytes, flush: true);
  return temporary.rename(file.path);
}

@Riverpod(keepAlive: true)
class GeoResourceAction extends _$GeoResourceAction {
  /// Whether each manual update announces a success; a failure always shows.
  final _manualUpdates = <GeoResource, bool>{};
  final _operations = <GeoResource, int>{};

  CoreController get _core => ref.read(coreHandlerProvider);

  @override
  void build() {
    ref.listen(coreStatusProvider, (_, next) {
      if (next != CoreStatus.connected) {
        _manualUpdates.clear();
        _operations.clear();
      }
    });
  }

  int _startUpdating(GeoResource geoResource) {
    return _operations.putIfAbsent(
      geoResource,
      () => ref
          .read(updatingKeysProvider.notifier)
          .start(geoResource.updatingKey, scope: UpdatingScope.core),
    );
  }

  void _stopUpdating(GeoResource geoResource, [int? operation]) {
    final current = _operations[geoResource];
    if (current == null || (operation != null && current != operation)) {
      return;
    }
    _operations.remove(geoResource);
    ref
        .read(updatingKeysProvider.notifier)
        .stop(geoResource.updatingKey, current);
  }

  /// Puts the database in place, with or without a tunnel to do it.
  ///
  /// With a Core running it fetches the file itself -- outside the tunnel, so an
  /// update never depends on a working node -- and completion arrives as a
  /// geo-update event through [handleCoreUpdate].
  ///
  /// With no Core there is nothing to fetch it: on iOS the Core lives inside the
  /// tunnel extension, so with the VPN off the request used to be skipped as
  /// "no tunnel is running". The app downloads the file itself instead and
  /// writes it where the Core reads it from on its next start, which needs
  /// nothing to be running at all.
  Future<void> updateGeoResource(
    GeoResource geoResource, {
    bool announceSuccess = true,
  }) async {
    final running = _operations.containsKey(geoResource);
    final previous = _manualUpdates[geoResource];
    _manualUpdates[geoResource] = announceSuccess;
    final operation = _startUpdating(geoResource);
    try {
      if (await _updateWithCore(geoResource)) {
        return;
      }
      await _downloadInTheApp(geoResource);
      _manualUpdates.remove(geoResource);
      _stopUpdating(geoResource, operation);
      if (announceSuccess) {
        dialogs.showNotifier(
          currentAppLocalizations.geoUpdated(geoResource.name),
        );
      }
    } catch (_) {
      if (previous != null) {
        _manualUpdates[geoResource] = previous;
      } else {
        _manualUpdates.remove(geoResource);
      }
      if (!running) {
        _stopUpdating(geoResource, operation);
      }
      rethrow;
    }
  }

  /// True when the Core took over; false when there is no Core to ask.
  Future<bool> _updateWithCore(GeoResource geoResource) async {
    try {
      final message = await _core.updateGeoData(geoResource.name);
      if (message.isNotEmpty) {
        throw MessageException(message);
      }
      return true;
    } on CoreMethodException catch (error) {
      // Only a Core that cannot be reached falls back: one that answered with a
      // refusal named a real reason and the caller has to see it.
      if (!_isCoreGone(error) || !system.isIOS) {
        rethrow;
      }
    }
    commonPrint.log(
      'No Core is running to fetch ${geoResource.name}, '
      'downloading it in the app instead',
      logLevel: LogLevel.warning,
    );
    return false;
  }

  bool _isCoreGone(CoreMethodException error) {
    return error.code == 'no_response' || error.isCoreUnavailable;
  }

  Future<void> _downloadInTheApp(GeoResource geoResource) async {
    final link = ref.read(patchClashConfigProvider).geoXUrl[geoResource];
    if (link == null || link.isEmpty) {
      throw MessageException(
        '${geoResource.name} has no download link configured',
      );
    }
    final response = await request.getFileResponseForUrl(link);
    final bytes = response.data;
    if (bytes == null) {
      throw MessageException('${geoResource.name}: the download was empty');
    }
    await storeGeoDatabase(geoResource, bytes);
  }

  void handleCoreUpdate(
    String geoType,
    bool updating,
    bool skipped,
    String? error,
  ) {
    final geoResource = GeoResource.fromJson(geoType.toLowerCase());
    final announceSuccess = updating
        ? null
        : _manualUpdates.remove(geoResource);
    if (announceSuccess != null && error != null && error.isNotEmpty) {
      dialogs.showNotifier(error, level: MessageLevel.error);
    } else if (announceSuccess == true) {
      final l10n = currentAppLocalizations;
      final message = skipped
          ? l10n.geoSkipped(geoResource.name)
          : l10n.geoUpdated(geoResource.name);
      dialogs.showNotifier(message);
    }
    if (updating) {
      _startUpdating(geoResource);
    } else {
      _stopUpdating(geoResource);
    }
  }

  void updateGeoResourceUrl(GeoResource geoResource, String newUrl) {
    if (!newUrl.isUrl) {
      throw ArgumentError.value(newUrl, 'newUrl', 'Not a valid URL');
    }
    ref.read(patchClashConfigProvider.notifier).update((state) {
      return state.copyWith(geoXUrl: {...state.geoXUrl, geoResource: newUrl});
    });
  }
}
