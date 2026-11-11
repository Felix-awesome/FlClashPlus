part of '../action.dart';

@Riverpod(keepAlive: true)
class CoreAction extends _$CoreAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  int _requestedRestartRevision = 0;
  Future<bool>? _restartOperation;

  /// How long a start or a restart may take before the app stops waiting.
  ///
  /// The extension waits 45s for its core to come up and gives an acknowledged
  /// call another 150s, so a transition that outlives this is not going to
  /// finish. Without a bound, one that never completes leaves the badge
  /// spinning for the rest of the session with nothing said about what it is
  /// waiting for -- which reads exactly like a core that is still starting.
  static const _lifecycleTimeout = Duration(minutes: 4);

  @override
  void build() {}

  Future<void> initCore() async {
    final isInit = await _core.isInit;

    final version = ref.read(versionProvider);
    if (!isInit) {
      final res = await _core.init(version);
      commonPrint.log('init result: $res');
    } else {
      await ref.read(proxiesActionProvider.notifier).updateGroups();
      await ref.read(providersProvider.notifier).syncProviders();
    }
  }

  Future<void> startCore() async {
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    try {
      await _runLifecycle(startLifecycle);
    } on TimeoutException {
      await _reportStuckLifecycle('start');
    } catch (error) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      dialogs.showNotifier(error.toString(), level: MessageLevel.error);
    }
  }

  /// Runs one transition and the init that follows it, bounded by
  /// [_lifecycleTimeout].
  Future<bool> _runLifecycle(
    Future<CoreLifecycleResult> Function() lifecycle, {
    bool statusFirst = false,
  }) {
    return (() async {
      final result = await lifecycle();
      return _applyLifecycleResult(result, statusFirst: statusFirst);
    })().timeout(_lifecycleTimeout);
  }

  /// Reports a transition that did not finish, naming the step the extension
  /// stopped at when it can say.
  Future<void> _reportStuckLifecycle(String action) async {
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    var detail = 'Core did not finish starting';
    try {
      final described = await _core.coreDiagnostics();
      if (described.isNotEmpty) {
        detail = described;
      }
    } catch (error) {
      commonPrint.log(
        'core diagnostics failed: $error',
        logLevel: LogLevel.warning,
      );
    }
    commonPrint.log(
      'core $action timed out: $detail',
      logLevel: LogLevel.error,
    );
    dialogs.showNotifier(detail, level: MessageLevel.error);
  }

  @protected
  Future<CoreLifecycleResult> startLifecycle() {
    return _core.start();
  }

  @protected
  Future<CoreLifecycleResult> restartLifecycle() {
    return _core.restart();
  }

  // Nothing in lib/ calls CoreController.stop(); only close() (app exit)
  // supersedes a start/restart. statusFirst lets onCrash catch a crash
  // during initCore itself (it early-returns unless status is connected).
  Future<bool> _applyLifecycleResult(
    CoreLifecycleResult result, {
    bool statusFirst = false,
  }) async {
    if (result.outcome == CoreLifecycleOutcome.superseded) {
      return false;
    }
    if (statusFirst) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await initCore();
    } else {
      await initCore();
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    }
    return true;
  }

  Future<void> closeConnection(String id) async {
    await _core.closeConnection(id);
  }

  Future<void> closeConnections() async {
    await _core.closeConnections();
  }

  Future<void> clearDnsCacheOnNetworkChange() async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    try {
      await _core.clearDnsCache();
    } catch (error) {
      commonPrint.log(
        'clearDnsCache error: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  Future<void> requestGc() async {
    await _core.requestGc();
  }

  Future<void> crash() async {
    await _core.crash();
  }

  Future<bool> restartCore() {
    _requestedRestartRevision++;
    final activeOperation = _restartOperation;
    if (activeOperation != null) {
      return activeOperation;
    }

    final operation = _runRestartWorker();
    _restartOperation = operation;
    return operation;
  }

  Future<bool> _runRestartWorker() async {
    try {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      if (!await _runLifecycle(restartLifecycle, statusFirst: true)) {
        return false;
      }

      var appliedRevision = 0;
      var applied = true;
      while (appliedRevision < _requestedRestartRevision) {
        final revision = _requestedRestartRevision;
        if (ref.read(isStartProvider)) {
          applied = await ref
              .read(setupActionProvider.notifier)
              .setRunning(true, initialize: true);
        } else {
          applied = await ref
              .read(setupActionProvider.notifier)
              .applyProfile(force: true);
        }
        appliedRevision = revision;
      }
      return applied;
    } on TimeoutException {
      await _reportStuckLifecycle('restart');
      return false;
    } catch (_) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      rethrow;
    } finally {
      _restartOperation = null;
    }
  }
}
