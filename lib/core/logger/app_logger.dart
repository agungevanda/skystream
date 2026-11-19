import 'dart:developer' as developer;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'persistent_log.dart';

/// How many entries the in-memory log ring buffer keeps.
///
/// The buffer has to survive into release builds - it is the only diagnostic
/// the app ships (`/logs` renders `talker.history`, and its share/copy actions
/// export the same list). That makes an unbounded buffer a memory leak with a
/// six-hour lower bound, so the ring is small enough that a long session can
/// never grow it and long enough to hold the run-up to a crash.
const int kAppLogHistoryLimit = 300;

/// Longest single log message the buffer will store.
///
/// Bounding the count is not enough on its own: one log line carrying a whole
/// JSON response would blow the budget by itself. 300 x 4 KB is a hard ceiling
/// of about 1.2 MB of message text.
const int kAppLogMessageLimit = 4000;

/// Marker substituted for anything that looks like a credential.
const String kRedactedPlaceholder = '<redacted>';

const String _truncationSuffix = '... [truncated]';

/// `name=value` pairs whose name looks like a credential, in a URL query, a
/// header dump, a JSON body or a `toString()`. The value stops at the first
/// character that cannot be part of one.
///
/// The `{0,40}` bounds on the name's prefix and suffix are not cosmetic. An
/// unbounded `*` there backtracks quadratically over a long line with no
/// keyword in it - measured at 8.3 s for one 20 KB log message, on the UI
/// thread - against 43 ms bounded.
final RegExp _secretAssignment = RegExp(
  r'''([A-Za-z0-9_.\-]{0,40}(?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|authorization|password|passwd|token|secret|signature)[A-Za-z0-9_.\-]{0,40})(["']?\s*[:=]\s*)(["']?)([^\s"'&,;}\)\]]+)\3''',
  caseSensitive: false,
);

final RegExp _quotedSecretAssignment = RegExp(
  r'''([A-Za-z0-9_.\-]{0,40}(?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|authorization|password|passwd|token|secret|signature)[A-Za-z0-9_.\-]{0,40}["']?\s*[:=]\s*)(["'])(?:\\.|(?!\2)[^\x0d\x0a])*?(?:\2|$)''',
  caseSensitive: false,
  multiLine: true,
);

/// `Authorization: Bearer *** style credentials, where the name is gone by the
/// time the value is printed.
final RegExp _bearerToken = RegExp(
  r'\b(Bearer|Basic|Token)\s+([A-Za-z0-9._\-+/=]+)',
  caseSensitive: false,
);

final RegExp _emailAddress = RegExp(
  r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b',
);

/// A JWT anywhere in the text, named or not.
final RegExp _jsonWebToken = RegExp(
  r'\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*',
);

/// Strips anything that looks like a credential out of [input].
///
/// Applied to every entry on its way into the log buffer, because that buffer
/// is exported verbatim when a user attaches logs to a bug report. It is a
/// belt on top of the braces of not logging secrets in the first place: a
/// caller that logs a whole request URL (`.../3/movie/1?api_key=...`) or an
/// exception whose `toString()` embeds one must not be able to leak it.
String redactSecrets(String input) {
  if (input.isEmpty) return input;
  // Bearer first: `Authorization: Bearer xxx` would otherwise have its value
  // read as the single word `Bearer`, leaving the token itself in the clear.
  return input
      .replaceAllMapped(
        _quotedSecretAssignment,
        (Match m) => '${m[1]}${m[2]}$kRedactedPlaceholder${m[2]}',
      )
      .replaceAllMapped(
        _bearerToken,
        (Match m) => '${m[1]} $kRedactedPlaceholder',
      )
      .replaceAllMapped(
        _secretAssignment,
        (Match m) => '${m[1]}${m[2]}${m[3]}$kRedactedPlaceholder${m[3]}',
      )
      .replaceAll(_jsonWebToken, kRedactedPlaceholder)
      .replaceAll(_emailAddress, kRedactedPlaceholder);
}

/// Redacts and truncates [data], returning [data] itself when neither applies.
///
/// Returning the original object matters: keeping the concrete [TalkerError] /
/// [TalkerException] subclass preserves how `/logs` renders and filters it, so
/// only the rare entry that actually carried a secret is rewritten.
@visibleForTesting
TalkerData sanitizeLogEntry(TalkerData data) {
  final String? message = data.message;
  final String? cleanMessage = message == null ? null : _clean(message);

  final Object? thrown = data.exception ?? data.error;
  final String? thrownText = thrown?.toString();
  final String? cleanThrown = thrownText == null ? null : _clean(thrownText);
  final title = data.title;
  final cleanTitle = title == null ? null : _clean(title);
  final stack = data.stackTrace?.toString();
  final cleanStack = stack == null ? null : _clean(stack);

  if (cleanMessage == message &&
      cleanThrown == thrownText &&
      cleanTitle == title &&
      cleanStack == stack) {
    return data;
  }

  return TalkerLog(
    cleanMessage,
    key: data.key,
    title: cleanTitle,
    logLevel: data.logLevel,
    stackTrace: cleanStack == null ? null : StackTrace.fromString(cleanStack),
    time: data.time,
    pen: data.pen,
    exception: cleanThrown,
  );
}

/// Truncate first, redact second: it bounds the work the regexes have to do,
/// and a credential can only survive the cut by sitting in the part that is
/// thrown away anyway.
String _clean(String value) {
  final String bounded = value.length <= kAppLogMessageLimit
      ? value
      : value.substring(0, kAppLogMessageLimit) + _truncationSuffix;
  return redactSecrets(bounded);
}

/// [TalkerHistory] that sanitizes every entry before it is stored.
///
/// Bounding is delegated to [DefaultTalkerHistory], which already honours
/// [TalkerSettings.maxHistoryItems] as a ring buffer.
class RedactingTalkerHistory implements TalkerHistory {
  RedactingTalkerHistory(TalkerSettings settings)
    : _inner = DefaultTalkerHistory(settings);

  final DefaultTalkerHistory _inner;
  PersistentLog? persistent;
  LogPreferences? preferences;

  @override
  List<TalkerData> get history => _inner.history;

  @override
  void clean() => _inner.clean();

  @override
  void write(TalkerData data) {
    final clean = sanitizeLogEntry(data);
    if (preferences != null &&
        (clean.logLevel == LogLevel.debug ||
            clean.logLevel == LogLevel.verbose) &&
        preferences?.verbose != true) {
      return;
    }
    _inner.write(clean);
    final store = persistent;
    if (store != null) {
      final message = [
        clean.message,
        clean.exception,
        clean.error,
      ].whereType<Object>().join(' ');
      unawaited(
        store.add(message, time: clean.time).catchError((Object error) {
          debugPrint(
            'Log persistence failed: ${redactSecrets(error.toString())}',
          );
        }),
      );
    }
  }
}

final Expando<RedactingTalkerHistory> _histories = Expando();

Future<void> attachPersistentLog(
  Talker logger,
  PersistentLog store, {
  LogPreferences? preferences,
}) async {
  final history = _histories[logger];
  if (history == null) throw ArgumentError('Unsupported Talker history');
  history.preferences = preferences;
  await store.open();
  final records = await store.read();
  final startup = List<TalkerData>.of(history.history);
  history.clean();
  for (final record in records) {
    history.write(TalkerLog(record.message, time: record.time));
  }
  final pending = <Future<void>>[];
  for (final entry in startup) {
    if (preferences != null &&
        !preferences.verbose &&
        (entry.logLevel == LogLevel.debug ||
            entry.logLevel == LogLevel.verbose)) {
      continue;
    }
    history.write(entry);
    pending.add(
      store.add(
        [
          entry.message,
          entry.exception,
          entry.error,
        ].whereType<Object>().join(' '),
        time: entry.time,
      ),
    );
  }
  history.persistent = store;
  await Future.wait(pending);
}

/// Builds the app's logger.
///
/// [releaseMode] is a parameter rather than a read of [kReleaseMode] so the
/// release configuration is reachable from a test - the whole point of this
/// object is what it does in a shipped build, and `kReleaseMode` is a
/// compile-time `false` everywhere a test can run.
///
/// In release the logger stays **enabled** (so `/logs` and its export have
/// something to show when a user reports a crash) but writes nothing to the
/// console, which is a no-op there anyway since `main` silences [debugPrint].
Talker createAppTalker({
  required bool releaseMode,
  void Function(String)? output,
}) {
  final TalkerSettings settings = TalkerSettings(
    enabled: true,
    useHistory: true,
    useConsoleLogs: !releaseMode,
    maxHistoryItems: kAppLogHistoryLimit,
  );
  final void Function(String) sink = output ?? _consoleOutput;
  final history = RedactingTalkerHistory(settings);
  final logger = Talker(
    // Talker formats for the console straight off the raw entry, bypassing the
    // history, so the redaction has to be repeated here or a debug console
    // would still print the credential the buffer just stripped.
    logger: TalkerLogger(output: (String line) => sink(redactSecrets(line))),
    settings: settings,
    history: history,
  );
  _histories[logger] = history;
  return logger;
}

/// Mirrors `TalkerFlutter.init`'s default output, which is not reachable when
/// building a [Talker] directly (that helper takes no custom history).
void _consoleOutput(String message) {
  if (kIsWeb) {
    debugPrint(message);
    return;
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      developer.log(message, name: 'Talker');
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      debugPrint(message);
  }
}

/// Global Talker instance for logging across the app.
final Talker talker = createAppTalker(releaseMode: kReleaseMode);
LogPreferences? appLogPreferences;
PersistentLog? appPersistentLog;

void logPlaybackStage(
  Talker logger, {
  required String stage,
  required String plugin,
  required bool success,
  required Duration elapsed,
}) {
  logger.info(
    '$stage | plugin: $plugin | ${success ? 'berhasil' : 'gagal'} | ${elapsed.inMilliseconds} ms',
  );
}

Future<T> tracePlaybackStage<T>(
  Talker logger, {
  required String stage,
  required String plugin,
  required Future<T> Function() action,
  bool Function(T result)? successful,
}) async {
  final watch = Stopwatch()..start();
  try {
    final result = await action();
    logPlaybackStage(
      logger,
      stage: stage,
      plugin: plugin,
      success: successful?.call(result) ?? true,
      elapsed: watch.elapsed,
    );
    return result;
  } catch (_) {
    logPlaybackStage(
      logger,
      stage: stage,
      plugin: plugin,
      success: false,
      elapsed: watch.elapsed,
    );
    rethrow;
  }
}
