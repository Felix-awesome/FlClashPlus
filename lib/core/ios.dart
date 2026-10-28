import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/ios_service.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'desktop/model.dart';
import 'interface.dart';
import 'method.dart';
import 'spill.dart';

/// The iOS core transport. On iOS the Go core runs inside the
/// NetworkExtension packet-tunnel process, so this controller only:
///  - saves + starts / stops the tunnel via NEVPNManager (through the
///    AppDelegate method channel), and
///  - forwards Core method calls to the core via `sendProviderMessage`
///    (the extension's handleAppMessage).
///
/// The actual core boot (QuickSetup + StartTun) happens inside the extension's
/// PacketTunnelProvider, not here.
class CoreIOS extends CoreHandlerInterface {
  static CoreIOS? _instance;

  final IOSService? _service;

  Completer<bool> _connectedCompleter = Completer<bool>();
  Future<CoreLifecycleResult>? _closeOperation;
  int _lifecycleRevision = 0;
  int _methodCallId = 0;
  bool _closed = false;

  CoreIOS._internal() : _service = iosService;

  @visibleForTesting
  CoreIOS.scoped(IOSService this._service);

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  factory CoreIOS() {
    _instance ??= CoreIOS._internal();
    return _instance!;
  }

  @override
  Future<CoreLifecycleResult> start() async {
    if (_closed) {
      throw StateError('Core lifecycle is closed');
    }
    final revision = ++_lifecycleRevision;
    if (_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    // Save the tunnel config (home dir etc.) then start the tunnel. The
    // extension boots the core and opens its listener as part of startTunnel.
    final homeDir = await appPath.homeDirPath;
    await _service?.saveConfig(homeDir: homeDir);
    final started = await _service?.start() ?? false;
    if (!started) {
      throw StateError('iOS VPN tunnel failed to start');
    }
    _connectedCompleter.complete(true);
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> restart() async {
    await stop();
    return start();
  }

  @override
  Future<CoreLifecycleResult> stop() => _stop();

  Future<CoreLifecycleResult> _stop({bool allowClosed = false}) async {
    if (_closed && !allowClosed) {
      throw StateError('Core lifecycle is closed');
    }
    final revision = ++_lifecycleRevision;
    if (!_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    _connectedCompleter = Completer<bool>();
    final stopped = await _service?.shutdown() ?? true;
    if (!stopped) {
      throw StateError('iOS VPN tunnel shutdown failed');
    }
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> close() {
    return _closeOperation ??= _close();
  }

  Future<CoreLifecycleResult> _close() async {
    _closed = true;
    return _stop(allowClosed: true);
  }

  // The extension's PacketTunnelProvider opens/closes the core listener when
  // the tunnel starts/stops, so these mirror the VPN lifecycle.
  @override
  Future<bool> startListener() async {
    await super.startListener();
    return await _service?.start() ?? false;
  }

  @override
  Future<bool> stopListener() async {
    final serviceStopped = await _service?.stop() ?? false;
    await super.stopListener();
    return serviceStopped;
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) {
    final call = _invokeMethod<T>(method: method, arguments: arguments);
    return call.withTimeout(
      timeout: timeout,
      onTimeout: () {
        unawaited(call.then(discardSpilledFile, onError: (_) {}));
        return null;
      },
    );
  }

  Future<T?> _invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
  }) async {
    try {
      await _connectedCompleter.future.timeout(coreConnectionWaitDuration);
    } catch (error) {
      commonPrint.log(
        'Invoke method ${method.name} before connection timed out: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
    final id = '${++_methodCallId}';
    final response = await _service?.invokeMethod(
      CoreMethodCall(id: id, method: method, arguments: arguments),
    );
    if (response == null) {
      return null;
    }
    return response.unwrap<T>();
  }
}

CoreIOS? get coreIOS => system.isIOS ? CoreIOS() : null;
