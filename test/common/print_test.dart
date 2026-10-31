import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/print.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compactError compacts DioException to type and status code', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 403,
      ),
    );
    expect(compactError(error), 'DioException(badResponse, HTTP 403)');
  });

  test('compactError omits the status code when the response is missing', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionError,
    );
    expect(compactError(error), 'DioException(connectionError)');
  });

  test('compactError keeps what the connection actually failed on', () {
    final error = DioException(
      requestOptions: RequestOptions(
        path: 'https://www.example.com/sub?token=secret',
      ),
      type: DioExceptionType.connectionError,
      error: const SocketException("Failed host lookup: 'www.example.com'"),
    );

    expect(
      compactError(error),
      'DioException(connectionError, GET www.example.com): '
      "Failed host lookup: 'www.example.com'",
    );
  });

  test('compactError never writes the token of a subscription into a log', () {
    final error = DioException(
      requestOptions: RequestOptions(
        path: 'https://sub.example.com/api/v1/client/subscribe?token=secret',
      ),
      type: DioExceptionType.connectionTimeout,
    );

    expect(compactError(error), isNot(contains('secret')));
    expect(compactError(error), isNot(contains('/api/')));
  });

  test('compactError keeps other exception messages', () {
    expect(compactError(StateError('boom')), contains('boom'));
  });
}
