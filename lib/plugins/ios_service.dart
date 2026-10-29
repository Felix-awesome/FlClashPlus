import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final _utf8JsonDecoder = utf8.decoder.fuse(json.decoder);

Object? _decodeUtf8Json(Uint8List data) => _utf8JsonDecoder.convert(data);

Map<String, Object?> _decodeResponseOf((Uint8List, CoreMethod) request) {
  final (data, method) = request;
  final decoded = _decodeUtf8Json(data);
  return withResultModel(method, Map<String, Object?>.from(decoded as Map));
}

Future<Map<String, Object?>> _decodeResponse(
  Uint8List data,
  CoreMethod method,
) async {
  if (data.length < 51200) {
    return _decodeResponseOf((data, method));
  }
  return compute(_decodeResponseOf, (data, method));
}

/// The platform channels are registered while the app is launching, which can
/// land just after the Dart entry point starts running. A call made in that
/// window reports MissingPluginException even though the handler does exist, so
/// such a call is retried briefly instead of failing the very first launch.
const _channelRetryAttempts = 5;
const _channelRetryDelay = Duration(milliseconds: 100);

/// A core call the extension relays answers with nothing when its own core has
/// not finished starting, which the app would surface as "Core did not
/// answer <method>". The extension already waits for setup before replying, so
/// an empty answer usually means the tunnel was still coming up: one more
/// attempt covers that without tripling the worst-case latency.
const _emptyReplyAttempts = 2;
const _emptyReplyDelay = Duration(milliseconds: 300);

/// How many times a transport error from `sendProviderMessage` is retried.
const _sendRetryAttempts = 3;
const _sendRetryDelay = Duration(milliseconds: 200);

/// Retries a channel call that reports [MissingPluginException], which is what
/// a platform answers while its handler has not been installed yet. The result
/// stays nullable because `invokeMethod<T>` itself returns `T?`.
Future<T?> _invokeWithRetry<T>(Future<T?> Function() invoke) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await invoke();
    } on MissingPluginException {
      if (attempt >= _channelRetryAttempts) {
        rethrow;
      }
      await Future<void>.delayed(_channelRetryDelay);
    }
  }
}

/// The iOS counterpart of the Android [Service]: it drives the
/// NetworkExtension tunnel via NETunnelProviderManager (through the AppDelegate
/// method channel) and forwards Core method calls to the Go core running inside
/// the packet-tunnel extension via `sendProviderMessage` (handleAppMessage).
class IOSService {
  static IOSService? _instance;

  late MethodChannel vpnChannel;
  late MethodChannel coreChannel;

  static const _vpnChannelName = '$packageName/ios_vpn';
  static const _coreChannelName = '$packageName/core';

  factory IOSService() {
    _instance ??= IOSService._internal();
    return _instance!;
  }

  IOSService._internal() {
    vpnChannel = const MethodChannel(_vpnChannelName);
    coreChannel = const MethodChannel(_coreChannelName);
  }

  /// Whether the VPN tunnel is currently connected or connecting.
  Future<bool> getStatus() async {
    try {
      final status = await _invokeWithRetry(
        () => vpnChannel.invokeMapMethod<String, Object?>('getStatus'),
      );
      return status?['running'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Saves the NETunnelProviderProtocol config. Returns true on success.
  Future<bool> saveConfig({
    required String homeDir,
    String stack = 'gvisor',
    String address = '198.18.0.1/30',
    String dns = '198.18.0.1',
    Map<String, Object?> options = const {},
  }) async {
    return await _invokeWithRetry(
          () => vpnChannel.invokeMethod<bool>('saveConfig', {
            'homeDir': homeDir,
            'stack': stack,
            'address': address,
            'dns': dns,
            'options': options,
          }),
        ) ??
        false;
  }

  /// Requests the system VPN permission (triggers the NEVPNManager dialog).
  Future<bool> requestPermission() async {
    return await _invokeWithRetry(
          () => vpnChannel.invokeMethod<bool>('requestPermission'),
        ) ??
        false;
  }

  /// Starts the VPN tunnel.
  Future<bool> start() async {
    return await _invokeWithRetry(
          () => vpnChannel.invokeMethod<bool>('start'),
        ) ??
        false;
  }

  /// Stops the VPN tunnel.
  Future<bool> stop() async {
    return await _invokeWithRetry(
          () => vpnChannel.invokeMethod<bool>('stop'),
        ) ??
        false;
  }

  /// Initializes the iOS service. The core lives in the extension process, so
  /// there is nothing to initialize here.
  Future<String> init() async => '';

  /// Best-effort state sync. iOS keeps state in the shared app group, so this
  /// is a no-op for now.
  Future<String> syncState(SharedState state) async => '';

  /// Shuts down: stops the tunnel.
  Future<bool> shutdown() async {
    await stop();
    return true;
  }

  Future<DateTime?> getRunTime() async {
    final ms =
        await _invokeWithRetry(
          () => vpnChannel.invokeMethod<int>('getRunTime'),
        ) ??
        0;
    if (ms == 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Forwards a Core method call to the Go core inside the packet-tunnel
  /// extension. The AppDelegate relays this through `sendProviderMessage`,
  /// whose reply is delivered to the extension's handleAppMessage.
  ///
  /// `startVPNTunnel` only queues the request, and the app issues its first
  /// core call right after it returns, so the session may still refuse provider
  /// messages: a transport error is retried briefly instead of failing a call
  /// that would succeed a moment later. An empty reply is retried once for the
  /// same reason -- the extension answers nothing while its core is starting.
  Future<CoreMethodResponse?> invokeMethod(CoreMethodCall call) async {
    Uint8List? data;
    for (var attempt = 0; ; attempt++) {
      try {
        data = await coreChannel.invokeMethod<Uint8List>(
          'invokeMethod',
          json.encode(call),
        );
      } on PlatformException {
        if (attempt >= _sendRetryAttempts - 1) {
          rethrow;
        }
        await Future<void>.delayed(_sendRetryDelay);
        continue;
      } on MissingPluginException {
        if (attempt >= _channelRetryAttempts - 1) {
          rethrow;
        }
        await Future<void>.delayed(_channelRetryDelay);
        continue;
      }
      if (data != null || attempt >= _emptyReplyAttempts - 1) {
        break;
      }
      await Future<void>.delayed(_emptyReplyDelay);
    }
    if (data == null) {
      return null;
    }
    return resolveSpilledResponse(
      CoreMethodResponse.fromJson(await _decodeResponse(data, call.method)),
      method: call.method,
    );
  }
}

IOSService? get iosService => system.isIOS ? IOSService() : null;
