// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// A pure Dart client for Sentry.io crash reporting.
library sentry;

import 'dart:async';

import 'package:app_intelligence/app_intelligence_browser.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:usage/uuid/uuid.dart';
import 'package:w_transport/browser.dart' show browserTransportPlatform;
import 'package:w_transport/w_transport.dart';

import 'src/stack_trace.dart';
import 'src/utils.dart';
import 'src/version.dart';

export 'src/version.dart';

/// Logs crash reports and events to the Sentry.io service.
class SentryClient {
  /// Sentry.io client identifier for _this_ client.
  @visibleForTesting
  static const String sentryClient = '$sdkName/$sdkVersion';

  /// Instantiates a client using [dsn] issued to your project by Sentry.io as
  /// the endpoint for submitting events.
  ///
  /// [environmentAttributes] contain event attributes that do not change over
  /// the course of a program's lifecycle. These attributes will be added to
  /// all events captured via this client. The following attributes often fall
  /// under this category: [SentryEvent.loggerName], [SentryEvent.serverName],
  /// [SentryEvent.release], [SentryEvent.environment].
  ///
  /// If [httpClient] is provided, it is used instead of the default client to
  /// make HTTP calls to Sentry.io. This is useful in tests.
  ///
  /// If [uuidGenerator] is provided, it is used to generate the "event_id"
  /// field instead of the built-in random UUID v4 generator. This is useful in
  /// tests.
  factory SentryClient({
    @required String dsn,
    SentryEvent environmentAttributes,
    JsonRequest httpClient,
    UuidGenerator uuidGenerator,
    Logger logger,
  }) {
    httpClient ??= browserTransportPlatform.newJsonRequest();
    uuidGenerator ??= _generateUuidV4WithoutDashes;
    logger ??= new Logger('');

    final Uri uri = Uri.parse(dsn);
    final List<String> userInfo = uri.userInfo.split(':');

    assert(() {
      if (userInfo.length != 2)
        throw new ArgumentError(
            'Colon-separated publicKey:secretKey pair not found in the user info field of the DSN URI: $dsn');

      if (uri.pathSegments.isEmpty)
        throw new ArgumentError('Project ID not found in the URI path of the DSN URI: $dsn');

      return true;
    }());

    final String publicKey = userInfo.first;
    final String secretKey = userInfo.last;
    final String projectId = uri.pathSegments.last;

    return new SentryClient._(
      httpClient: httpClient,
      uuidGenerator: uuidGenerator,
      logger: logger,
      environmentAttributes: environmentAttributes,
      dsnUri: uri,
      publicKey: publicKey,
      secretKey: secretKey,
      projectId: projectId,
    );
  }

  SentryClient._({
    @required JsonRequest httpClient,
    @required UuidGenerator uuidGenerator,
    @required Logger logger,
    @required this.environmentAttributes,
    @required this.dsnUri,
    @required this.publicKey,
    @required this.secretKey,
    @required this.projectId,
  })
      : _httpClient = httpClient,
        _uuidGenerator = uuidGenerator,
        _logger = logger;

  final JsonRequest _httpClient;
  final UuidGenerator _uuidGenerator;
  final Logger _logger;

  SentryEvent _sentryEvent = new SentryEvent();
  SentryEvent get sentryEvent => _sentryEvent;

  /// Contains [SentryEvent] attributes that are automatically mixed into all events
  /// captured through this client.
  ///
  /// This event is designed to contain static values that do not change from
  /// event to event, such as local operating system version, the version of
  /// Dart/Flutter SDK, etc. These attributes have lower precedence than those
  /// supplied in the even passed to [capture].
  final SentryEvent environmentAttributes;

  /// The DSN URI.
  @visibleForTesting
  final Uri dsnUri;

  /// The Sentry.io public key for the project.
  @visibleForTesting
  final String publicKey;

  /// The Sentry.io secret key for the project.
  @visibleForTesting
  final String secretKey;

  /// The ID issued by Sentry.io to your project.
  ///
  /// Attached to the event payload.
  final String projectId;

  @visibleForTesting
  String get postUri => '${dsnUri.scheme}://${dsnUri.host}/api/$projectId/store/';

  String _getAuthHeader() =>
      'Sentry sentry_version=7,' +
      'sentry_timestamp=${new DateTime.now().toUtc().millisecondsSinceEpoch},' +
      'sentry_key=${publicKey}';

  /// Reports an [event] to Sentry.io.
  Future<SentryResponse> capture({@required SentryEvent event}) async {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Sentry-Auth': _getAuthHeader(),
    };

    final Map<String, dynamic> body = <String, dynamic>{
      'project': projectId,
      'event_id': _uuidGenerator(),
      'timestamp': formatDateAsIso8601WithSecondPrecision(
          new DateTime.now().toUtc()),
      'logger': event.loggerName,
    };

    if (environmentAttributes != null) mergeAttributes(
        environmentAttributes.toJson(), into: body);

    mergeAttributes(event.toJson(), into: body);

    _httpClient.uri = Uri.parse(postUri);
    _httpClient.headers = headers;
    _httpClient.body = body;
    final Response response = await _httpClient.post();

    if (response.status != 200) {
      String errorMessage = 'Sentry.io responded with HTTP ${response.status}';
      if (response.headers['x-sentry-error'] != null) {
        errorMessage += ': ${response.headers['x-sentry-error']}';
        return new SentryResponse.failure(errorMessage);
      }
    }

    final String eventId = response.body.asJson()['id'];
    return new SentryResponse.success(eventId: eventId);
  }


  /// Reports the [exception] and optionally its [stackTrace] to Sentry.io.
  Future<SentryResponse> captureException({
    @required dynamic exception,
    dynamic stackTrace,
    String message,
  }) {
    final SentryEvent event = new SentryEvent(
      message: message,
      exception: exception,
      stackTrace: stackTrace,
      loggerName: _logger.fullName,
      tags: sentryEvent.tags,
    );
    return capture(event: event);
  }

  void init(List<Interceptor> interceptors) {
    Map tags = {};
    for (Interceptor interceptor in interceptors) {
      switch (interceptor.name) {
        case 'AppInterceptor':
          tags.addAll({
            'appId': (interceptor as AppInterceptor).appId,
            'appName': (interceptor as AppInterceptor).appName,
            'appVersion': (interceptor as AppInterceptor).appVersion
          });
          break;
        case 'BrowserInterceptor':
          tags.addAll({
            'browserSource': (interceptor as BrowserInterceptor).browserSource,
            'browserString': (interceptor as BrowserInterceptor).browserString,
            'flashVersion': (interceptor as BrowserInterceptor).flashVersion,
            'screenOrientation': (interceptor as BrowserInterceptor).screenOrientation,
            'screenResolution': (interceptor as BrowserInterceptor).screenResolution,
            'tabId': (interceptor as BrowserInterceptor).tabId,
            'viewport': (interceptor as BrowserInterceptor).viewport,
            'windowId': (interceptor as BrowserInterceptor).windowId
          });
          break;
      }
    }
    _sentryEvent = new SentryEvent(tags: tags);
  }

  Future<Null> close() async {
    _httpClient.done;
  }

  @override
  String toString() => '$SentryClient("$postUri")';
}

/// A response from Sentry.io.
///
/// If [isSuccessful] the [eventId] field will contain the ID assigned to the
/// captured event by the Sentry.io backend. Otherwise, the [error] field will
/// contain the description of the error.
@immutable
class SentryResponse {
  const SentryResponse.success({@required this.eventId})
      : isSuccessful = true,
        error = null;

  const SentryResponse.failure(this.error)
      : isSuccessful = false,
        eventId = null;

  /// Whether event was submitted successfully.
  final bool isSuccessful;

  /// The ID Sentry.io assigned to the submitted event for future reference.
  final String eventId;

  /// Error message, if the response is not successful.
  final String error;
}

typedef UuidGenerator = String Function();

String _generateUuidV4WithoutDashes() => new Uuid().generateV4().replaceAll('-', '');

/// Severity of the logged [SentryEvent].
@immutable
class SeverityLevel {
  static const fatal = const SeverityLevel._('fatal');
  static const error = const SeverityLevel._('error');
  static const warning = const SeverityLevel._('warning');
  static const info = const SeverityLevel._('info');
  static const debug = const SeverityLevel._('debug');

  const SeverityLevel._(this.name);

  /// API name of the level as it is encoded in the JSON protocol.
  final String name;
}

/// An event to be reported to Sentry.io.
@immutable
class SentryEvent {
  /// Refers to the default fingerprinting algorithm.
  ///
  /// You do not need to specify this value unless you supplement the default
  /// fingerprint with custom fingerprints.
  static const String defaultFingerprint = '{{ default }}';

  /// Creates an event.
  const SentryEvent({
    this.loggerName,
    this.serverName,
    this.release,
    this.environment,
    this.message,
    this.exception,
    this.stackTrace,
    this.level,
    this.culprit,
    this.tags,
    this.extra,
    this.fingerprint,
  });

  /// The logger that logged the event.
  final String loggerName;

  /// Identifies the server that logged this event.
  final String serverName;

  /// The version of the application that logged the event.
  final String release;

  /// The environment that logged the event, e.g. "production", "staging".
  final String environment;

  /// SentryEvent message.
  ///
  /// Generally an event either contains a [message] or an [exception].
  final String message;

  /// An object that was thrown.
  ///
  /// It's `runtimeType` and `toString()` are logged. If this behavior is
  /// undesirable, consider using a custom formatted [message] instead.
  final dynamic exception;

  /// The stack trace corresponding to the thrown [exception].
  ///
  /// Can be `null`, a [String], or a [StackTrace].
  final dynamic stackTrace;

  /// How important this event is.
  final SeverityLevel level;

  /// What caused this event to be logged.
  final String culprit;

  /// Name/value pairs that events can be searched by.
  final Map<String, String> tags;

  /// Arbitrary name/value pairs attached to the event.
  ///
  /// Sentry.io docs do not talk about restrictions on the values, other than
  /// they must be JSON-serializable.
  final Map<String, dynamic> extra;

  /// Used to deduplicate events by grouping ones with the same fingerprint
  /// together.
  ///
  /// If not specified a default deduplication fingerprint is used. The default
  /// fingerprint may be supplemented by additional fingerprints by specifying
  /// multiple values. The default fingerprint can be specified by adding
  /// [defaultFingerprint] to the list in addition to your custom values.
  ///
  /// Examples:
  ///
  ///     // A completely custom fingerprint:
  ///     var custom = ['foo', 'bar', 'baz'];
  ///     // A fingerprint that supplements the default one with value 'foo':
  ///     var supplemented = [SentryEvent.defaultFingerprint, 'foo'];
  final List<String> fingerprint;

  /// Serializes this event to JSON.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> json = <String, dynamic>{
      'platform': sdkPlatform,
      'sdk': {
        'version': sdkVersion,
        'name': sdkName,
      },
    };

    if (loggerName != null) json['logger'] = loggerName;

    if (serverName != null) json['server_name'] = serverName;

    if (release != null) json['release'] = release;

    if (environment != null) json['environment'] = environment;

    if (message != null) json['message'] = message;

    if (exception != null) {
      json['exception'] = [
        <String, dynamic>{
          'type': '${exception.runtimeType}',
          'value': '$exception',
        }
      ];
    }

    if (stackTrace != null) {
      json['stacktrace'] = <String, dynamic>{
        'frames': encodeStackTrace(stackTrace),
      };
    }

    if (level != null) json['level'] = level.name;

    if (culprit != null) json['culprit'] = culprit;

    if (tags != null && tags.isNotEmpty) json['tags'] = tags;

    if (extra != null && extra.isNotEmpty) json['extra'] = extra;

    if (fingerprint != null && fingerprint.isNotEmpty) json['fingerprint'] = fingerprint;

    return json;
  }
}
