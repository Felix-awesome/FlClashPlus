import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/battery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

import 'app.dart';
import 'config.dart';

part 'generated/on_demand.g.dart';

@Riverpod(keepAlive: true)
class LocationPermissions extends _$LocationPermissions {
  bool _requesting = false;
  bool _autoRequested = false;

  @override
  WifiSsidPermission build() => WifiSsidPermission.denied;

  /// Whether this platform can report the Wi-Fi SSID at all.
  ///
  /// The wifi_ssid plugin ships no iOS implementation: the system exposes the
  /// SSID only through NEHotspotNetwork, and reaching that needs an entitlement
  /// a sideloaded build does not carry. The channel answers
  /// MissingPluginException, and logging one every refresh buries the messages
  /// that actually explain a failure.
  bool get _supportsSsidLookup => !system.isIOS;

  /// Only a request can tell a permanent denial apart, so a check leaves that
  /// answer in place until it sees the grant.
  Future<void> refresh() async {
    if (ref.read(safeModeProvider) || !_supportsSsidLookup) {
      return;
    }
    final WifiSsidPermission permission;
    try {
      permission = await wifiSsidManager.checkPermission();
    } catch (error) {
      commonPrint.log(
        'checkPermission error $error',
        logLevel: LogLevel.warning,
      );
      return;
    }
    if (permission == WifiSsidPermission.granted ||
        state != WifiSsidPermission.permanentlyDenied) {
      state = permission;
    }
    if (ref.read(excludeSSIDsProvider).isEmpty) {
      _autoRequested = false;
      return;
    }
    if (permission != WifiSsidPermission.denied || _autoRequested) {
      return;
    }
    try {
      _autoRequested = await request() != null;
    } on PlatformException catch (error) {
      commonPrint.log(
        'requestPermission error $error',
        logLevel: LogLevel.warning,
      );
    }
  }

  /// Null while another request is showing, so only the caller that raised
  /// the prompt follows up on the answer.
  Future<WifiSsidPermission?> request() async {
    if (_requesting || !_supportsSsidLookup) {
      return null;
    }
    _requesting = true;
    try {
      final permission = await wifiSsidManager.requestPermission();
      state = permission;
      return permission;
    } finally {
      _requesting = false;
    }
  }
}

@riverpod
class BatteryOptimizationIgnored extends _$BatteryOptimizationIgnored {
  bool _requesting = false;

  @protected
  BatteryOptimization? get plugin => batteryOptimization;

  @override
  Stream<bool> build() => plugin?.onChanged ?? Stream.value(true);

  Future<void> request() async {
    final plugin = this.plugin;
    if (plugin == null || _requesting) {
      return;
    }
    _requesting = true;
    try {
      await plugin.requestIgnore();
    } on PlatformException catch (error) {
      commonPrint.log(
        'requestIgnoreOptimizations error $error',
        logLevel: LogLevel.warning,
      );
    } finally {
      _requesting = false;
    }
  }
}
