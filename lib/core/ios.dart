import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
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

/// How long a core call waits for the tunnel before it is sent.
///
/// On iOS "connected" means two things in sequence: the system builds the
/// tunnel, and the extension boots the core inside it. On a first launch that
/// takes tens of seconds on an older device -- far past the shared 10s gate.
/// A call therefore gave up a moment before the tunnel came up, and the app
/// reported "Core did not answer setupConfig" no matter how long the extension
/// itself was willing to wait for its core: the request was never sent at all.
const _iosConnectionWaitDuration = Duration(seconds: 60);

/// How long a call waits for the system to finish starting a session the app
/// did not start itself, after the status still reads "not running".
const _iosStatusProbeDuration = Duration(seconds: 2);

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
    // A failed save has to abort here: starting the tunnel without its provider
    // configuration leaves the extension with no home dir to read, and the
    // user would instead get a core-call timeout that says nothing about the
    // real cause.
    final homeDir = await appPath.homeDirPath;
    final saved = await _service?.saveConfig(homeDir: homeDir) ?? false;
    if (!saved) {
      throw StateError('iOS VPN configuration was not saved');
    }
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

  // On iOS the core runs inside the packet-tunnel extension, and the Go core's
  // StartTun/StopTun already open/close the inbound listener automatically
  // (see core/lib.go). So unlike Android there is no separate listener command
  // to send: starting/stopping the tunnel IS starting/stopping the listener.
  @override
  Future<bool> startListener() async {
    // start() already issued startVPNTunnel when the core booted, so the
    // tunnel is usually connecting/connected here; re-issuing startVPNTunnel
    // throws in that state. Treat an already-running tunnel as success.
    if (await _service?.getStatus() ?? false) {
      // A tunnel that is already up was started outside start() (the system
      // brought it back after a relaunch, for example). Core calls wait on this
      // completer, so it has to be completed here too -- otherwise every call
      // sits out the full connection timeout and fails as unanswered.
      if (!_connectedCompleter.isCompleted) {
        _connectedCompleter.complete(true);
      }
      return true;
    }
    final started = await _service?.start() ?? false;
    if (started && !_connectedCompleter.isCompleted) {
      _connectedCompleter.complete(true);
    }
    return started;
  }

  /// Checks a profile with the core, when there is a core to check it.
  ///
  /// On iOS the core only ever exists inside the tunnel extension, so with the
  /// VPN off there is nothing anywhere that could read the file. Failing the
  /// call there made adding a subscription impossible in exactly the situation
  /// it is usually added -- before the first connection -- and the message it
  /// produced ("Core did not answer validateConfig") describes an absence, not
  /// a bad config, so it sent the reader looking in the wrong place.
  ///
  /// The config is still checked for real later, by the same core: setupConfig
  /// hands it over when the tunnel comes up, and a rejection is reported there
  /// with the core's own text. An accepted-but-unvalidated profile is a
  /// deferred check, not a skipped one.
  @override
  Future<String> validateConfig(String path) async {
    if (!await _waitForConnection(CoreMethod.validateConfig)) {
      commonPrint.log(
        'Skipping validation of $path: no core is running to validate it',
        logLevel: LogLevel.warning,
      );
      return '';
    }
    return super.validateConfig(path);
  }

  /// Explains a silent core in words the dialog can show.
  ///
  /// "Core did not answer setupConfig" is only true: it says nothing about
  /// which half of the connection failed. The extension writes its startup
  /// steps into the shared container, so the reply names the step it stopped
  /// at instead of leaving the reader to guess.
  @override
  Future<String> coreDiagnostics() async {
    final running = await _service?.getStatus() ?? false;
    // These come from the app's own channel, so they answer even when the
    // extension cannot be reached at all -- which is exactly the case where
    // the extension's own log file explains nothing.
    final diagnostics = await _service?.getDiagnostics() ?? const {};
    final appGroup = diagnostics['appGroupAvailable'] == true;
    final embedded = diagnostics['extensionEmbedded'] == true;
    final homeDir = diagnostics['appGroupPath'] as String? ?? '';
    final boot = (await _service?.getBootLog() ?? '').trim();
    const missingGroup =
        'App Group 不可用：主 App 与扩展不共享数据目录，因此扩展的启动日志也读不到。'
        '重签时描述文件缺少 App Groups 能力会这样。';
    final lines = <String>[
      running ? 'VPN 隧道：已连接' : 'VPN 隧道：未连接',
      'App Group 共享目录：${appGroup ? '可用（$homeDir）' : '不可用'}',
      '隧道扩展 FlClashService.appex：${embedded ? '已打包' : '未打包'}',
      if (!appGroup) missingGroup,
      if (!embedded) '安装包里没有扩展，系统不会启动它，任何核心调用都不可能有人回应。',
      if (boot.isEmpty && embedded) '扩展没有写入启动日志：它没有执行到 startTunnel，或被系统在启动时拒绝。',
      if (boot.isNotEmpty) '扩展启动日志（最新在最后）：',
      if (boot.isNotEmpty) boot,
    ];
    return lines.where((line) => line.isNotEmpty).join('\n');
  }

  @override
  Future<bool> stopListener() async {
    return await _service?.stop() ?? false;
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
    if (!await _waitForConnection(method)) {
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

  /// Whether a core call should be sent now.
  ///
  /// "Not connected" has two very different causes on iOS, and only one of
  /// them is worth waiting out:
  ///
  /// - A tunnel exists and its extension is still booting the core -- the
  ///   system restarted it, or on-demand brought it back. That boot compiles
  ///   the whole rule set on a first launch, so the wait is generous.
  /// - No tunnel exists. Nothing is booting, so the call would be answered by
  ///   nobody however long it waited; answering it now keeps the caller's own
  ///   fallback (an unvalidated profile, a skipped query) from arriving a
  ///   minute late, which from the outside is indistinguishable from a hang.
  Future<bool> _waitForConnection(CoreMethod method) async {
    // Nothing to wait for: this is the path every call takes while the tunnel
    // is up, so it must not cost a channel round trip.
    if (_connectedCompleter.isCompleted) {
      return true;
    }
    if (!await (_service?.getStatus() ?? false)) {
      // A tunnel the app did not start itself has no completer anyone is
      // waiting on yet. The status can also read "disconnected" for a moment
      // while the system finishes starting a session, so one short probe
      // covers that without turning every call made with the VPN off into a
      // stall.
      if (await _awaitConnected(_iosStatusProbeDuration)) {
        return true;
      }
      commonPrint.log(
        'Invoke method ${method.name} skipped: no tunnel is running',
        logLevel: LogLevel.warning,
      );
      return false;
    }
    if (await _awaitConnected(_iosConnectionWaitDuration)) {
      return true;
    }
    commonPrint.log(
      'Invoke method ${method.name} timed out waiting for the tunnel',
      logLevel: LogLevel.warning,
    );
    return false;
  }

  /// Waits up to [timeout] for the tunnel to report itself connected.
  Future<bool> _awaitConnected(Duration timeout) async {
    final completer = _connectedCompleter;
    if (completer.isCompleted) {
      return true;
    }
    try {
      await completer.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

final coreIOS = system.isIOS ? CoreIOS() : null;
