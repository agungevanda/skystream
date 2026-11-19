import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';

class LogPreferences {
  LogPreferences(this.file);
  final File file;
  bool verbose = false;
  int retentionDays = 7;

  Future<void> load() async {
    if (!await file.exists()) return;
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    verbose = value['verbose'] == true;
    final days = value['retentionDays'];
    retentionDays = days is int && days > 0 ? days : 7;
  }

  Future<void> update({bool? verbose, int? retentionDays}) async {
    if (retentionDays != null && retentionDays < 1) {
      throw ArgumentError.value(retentionDays);
    }
    final nextVerbose = verbose ?? this.verbose;
    final nextDays = retentionDays ?? this.retentionDays;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.new');
    await temp.writeAsString(
      jsonEncode({'verbose': nextVerbose, 'retentionDays': nextDays}),
      flush: true,
    );
    await temp.rename(file.path);
    this.verbose = nextVerbose;
    this.retentionDays = nextDays;
  }
}

class StoredLogRecord {
  StoredLogRecord(this.time, this.message);
  final DateTime time;
  final String message;
}

/// Append-only records, pruned when opened.
class PersistentLog {
  PersistentLog(this.file, {DateTime Function()? now, this.retentionDays = 7})
    : now = now ?? DateTime.now;

  final File file;
  final DateTime Function() now;
  final int retentionDays;
  Future<void> _pending = Future.value();

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> open() => _enqueue(() async {
    if (retentionDays < 1) throw ArgumentError.value(retentionDays);
    await file.parent.create(recursive: true);
    if (!await file.exists()) return;
    final cutoff = now().subtract(Duration(days: retentionDays));
    final kept = <String>[];
    for (final line in await file.readAsLines()) {
      try {
        final record = jsonDecode(line) as Map<String, dynamic>;
        final time = DateTime.parse(record['time'] as String);
        if (!time.isBefore(cutoff)) {
          final message = record['message'];
          if (message is! String) {
            throw const FormatException('Invalid message');
          }
          kept.add(
            jsonEncode({
              'time': time.toUtc().toIso8601String(),
              'message': redactSecrets(message),
            }),
          );
        }
      } on FormatException {
        kept.add(redactSecrets(line));
      } on TypeError {
        kept.add(redactSecrets(line));
      }
    }
    final temporary = File('${file.path}.prune');
    await temporary.writeAsString(
      kept.isEmpty ? '' : '${kept.join('\n')}\n',
      flush: true,
    );
    await temporary.rename(file.path);
  });

  Future<void> add(String message, {DateTime? time}) => _enqueue(() async {
    final line = jsonEncode({
      'time': (time ?? now()).toUtc().toIso8601String(),
      'message': redactSecrets(message),
    });
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  });

  Future<void> flush() => _pending;

  Future<void> clear() => _enqueue(() async {
    await file.parent.create(recursive: true);
    await file.writeAsString('', flush: true);
  });

  Future<String> exportText() async => (await read())
      .map(
        (record) =>
            '${record.time.toLocal().toIso8601String()} | ${record.message}',
      )
      .join('\n');

  Future<List<StoredLogRecord>> read() async {
    await flush();
    if (!await file.exists()) return [];
    final records = <StoredLogRecord>[];
    for (final line in await file.readAsLines()) {
      try {
        final record = jsonDecode(line) as Map<String, dynamic>;
        records.add(
          StoredLogRecord(
            DateTime.parse(record['time'] as String),
            redactSecrets(record['message'] as String),
          ),
        );
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return records;
  }
}
