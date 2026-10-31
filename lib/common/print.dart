import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:material_ui/material_ui.dart';

/// One readable line for a failure, keeping what it actually failed on.
///
/// The type alone never says enough: a lookup that found nothing, a refused
/// connection and a reset all arrive as `connectionError`, and the difference is
/// the whole diagnosis. The cause and the host are kept for that reason, and the
/// path is not: a subscription URL carries its token there, and these lines end
/// up in bug reports.
String compactError(Object error) {
  if (error is DioException) {
    final statusCode = error.response?.statusCode;
    final host = error.requestOptions.uri.host;
    final kind = [
      'DioException(${error.type.name}',
      if (statusCode != null) ', HTTP $statusCode',
      if (host.isNotEmpty) ', ${error.requestOptions.method} $host',
      ')',
    ].join();
    final cause = _dioCause(error);
    return cause.isEmpty ? kind : '$kind: $cause';
  }
  return error.toString();
}

String _dioCause(DioException error) {
  final text = switch (error.error) {
    SocketException(:final message, :final osError) =>
      osError == null ? message : '$message (${osError.message})',
    null => error.message ?? '',
    final cause => cause.toString(),
  };
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class CommonPrint {
  static CommonPrint? _instance;

  CommonPrint._internal();

  factory CommonPrint() {
    _instance ??= CommonPrint._internal();
    return _instance!;
  }

  void log(String? text, {LogLevel logLevel = LogLevel.info}) {
    final payload = '[APP] $text';
    debugPrint(payload);
    if (!globalState.isAttach) {
      return;
    }
    globalState.container
        .read(logsProvider.notifier)
        .add(Log.app(payload).copyWith(logLevel: logLevel));
  }
}

final commonPrint = CommonPrint();
