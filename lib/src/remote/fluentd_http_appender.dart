import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/src/internal/dummy_logger.dart';
import 'package:logging_appenders/src/logrecord_formatter.dart';
import 'package:logging_appenders/src/remote/base_remote_appender.dart';

final _logger = DummyLogger('logging_appenders.loki_appender');

SyslogLevel _defaultToSyslogLevel(Level level) {
  return SyslogLevel.values.firstWhere(
    (element) => level >= element.loggingLevel,
    orElse: () => SyslogLevel.alert,
  );
}

class FluentdHttpAppender extends BaseDioLogSender {
  FluentdHttpAppender({
    required this.endpoint,
    required this.host,
    this.toLogLevel = _defaultToSyslogLevel,
    LogRecordFormatter? formatter,
    int? bufferSize,
  }) : super(
          formatter: formatter,
          bufferSize: bufferSize,
        );

  final String endpoint;

  /// the name of the host, source or application that sent this message;
  /// MUST be set by the client library.
  final String host;

  /// convert log levels of logging package to syslog levels.
  final SyslogLevel Function(Level level) toLogLevel;

  Dio? _clientInstance;

  Dio get _client => _clientInstance ??= Dio();

  @override
  Future<void> sendLogEventsWithDio(List<LogEntry> entries,
      Map<String, String> userProperties, CancelToken cancelToken) {
    final userProps = {
      for (var e in userProperties.entries) '_${e.key}': e.value
    };
    final body = entries
        .map((e) {
          final firstNewLine = e.line.indexOf("\n");
          final (shortMessage, fullMessage) = firstNewLine > -1
              ? (
                  e.line.substring(0, firstNewLine),
                  e.line,
                )
              : (e.line, null);
          final payload = FluentDPayload(
            logLevel: toLogLevel(e.logLevel),
            host: host,
            shortMessage: shortMessage,
            fullMessage: fullMessage,
            timestamp: e.ts,
          );
          return {
            ...payload.toJson(),
            for (final entry in e.lineLabels.entries)
              '_${entry.key}': entry.value,
            ...userProps,
          };
        })
        .map((e) => json.encode(e))
        .join('\n');
    return _client
        .post<dynamic>(
          endpoint,
          cancelToken: cancelToken,
          data: body,
        )
        .then(
          (response) => Future<void>.value(null),
//      _logger.finest('sent logs.');
        )
        .catchError((Object err, StackTrace stackTrace) {
      String? message;
      if (err is DioError) {
        if (err.response != null) {
          message = 'response:${err.response!.data}';
        }
      }
      _logger.warning(
          'Error while sending logs to graylog. $message', err, stackTrace);
      return Future<void>.error(err, stackTrace);
    });
  }
}

/// according to https://en.wikipedia.org/wiki/Syslog
/// unfortuantely doesn't quite match the severity levels of logging package.
enum SyslogLevel {
  emergency(0, Level.SHOUT),
  alert(1, Level.SEVERE),
  critical(2, Level.WARNING),
  error(3, Level.INFO),
  warning(4, Level.CONFIG),
  notice(5, Level.FINE),
  information(6, Level.FINER),
  debug(7, Level.FINEST),
  ;

  const SyslogLevel(
    this.syslogValue,
    this.loggingLevel,
  );

  final int syslogValue;
  final Level loggingLevel;
}

class FluentDPayload {
  FluentDPayload({
    required this.logLevel,
    required this.host,
    required this.shortMessage,
    this.fullMessage,
    required this.timestamp,
  });

  final String version = '1.0';
  final SyslogLevel logLevel;
  final String host;
  final String shortMessage;
  final String? fullMessage;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'level': logLevel.syslogValue,
        'version': version,
        'host': host,
        'short_message': shortMessage,
        if (fullMessage != null) 'full_message': fullMessage,
        // timestamps must be seconds, but can have decimal places.
        'timestamp': (timestamp.millisecondsSinceEpoch / 1000.0),
      };
}
