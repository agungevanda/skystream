import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/logger/persistent_log.dart';
import 'package:skystream/core/logger/app_logger.dart';

void main() {
  late Directory directory;
  setUp(
    () async => directory = await Directory.systemTemp.createTemp('log_test_'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test(
    'persists sanitized entries and removes expired entries at startup',
    () async {
      final file = File('${directory.path}/events.log');
      final now = DateTime.utc(2026, 1, 10);
      final old = PersistentLog(
        file,
        now: () => now.subtract(const Duration(days: 8)),
      );
      await old.open();
      await old.add('old user@example.com');
      final current = PersistentLog(file, now: () => now);
      await current.open();
      await current.add('Bearer abc');
      final text = await file.readAsString();
      expect(text, isNot(contains('old')));
      expect(text, isNot(contains('abc')));
      expect(text, contains('<redacted>'));
    },
  );

  test('pruning keeps valid records with quoted secrets readable', () async {
    final file = File('${directory.path}/quoted.log');
    final now = DateTime.utc(2026, 1, 10);
    final store = PersistentLog(file, now: () => now);
    await store.open();
    await store.add('password="alpha beta"');
    await PersistentLog(file, now: () => now).open();
    final records = await store.read();
    expect(records, hasLength(1));
    expect(records.single.message, contains('<redacted>'));
    expect(records.single.message, isNot(contains('alpha')));
  });

  test('storage errors are reported to callers', () async {
    final log = PersistentLog(File(directory.path));
    await expectLater(log.add('entry'), throwsA(isA<FileSystemException>()));
  });

  test('clear removes persisted records', () async {
    final log = PersistentLog(File('${directory.path}/clear.log'));
    await log.open();
    await log.add('one');
    await log.clear();
    expect(await log.read(), isEmpty);
  });

  test('export text contains readable persisted records', () async {
    final log = PersistentLog(File('${directory.path}/export.log'));
    await log.open();
    await log.add('playback started');
    expect(await log.exportText(), contains('playback started'));
  });

  test('pruning sanitizes retained records', () async {
    final file = File('${directory.path}/previous.log');
    await file.writeAsString(
      '{"time":"2026-01-10T00:00:00.000Z","message":"user@example.com"}\n',
    );
    await PersistentLog(file, now: () => DateTime.utc(2026, 1, 11)).open();
    expect(await file.readAsString(), isNot(contains('user@example.com')));
  });

  test('concurrent appends retain every entry', () async {
    final file = File('${directory.path}/concurrent.log');
    final log = PersistentLog(file);
    await log.open();
    await Future.wait(List.generate(40, (i) => log.add('entry-$i')));
    final lines = await file.readAsLines();
    expect(lines, hasLength(40));
    for (var i = 0; i < 40; i++) {
      expect(lines.where((line) => line.contains('"entry-$i"')), hasLength(1));
    }
  });

  test('preserves malformed lines for recovery during retention', () async {
    final file = File('${directory.path}/damaged.log');
    await file.writeAsString('damaged-but-recoverable\n');
    await PersistentLog(file).open();
    expect(await file.readAsString(), contains('damaged-but-recoverable'));
  });

  test('startup messages retain event timestamp', () async {
    final logger = createAppTalker(releaseMode: true);
    logger.info('before startup');
    final time = logger.history.single.time;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final store = PersistentLog(File('${directory.path}/time.log'));
    await attachPersistentLog(logger, store);
    expect((await store.read()).single.time, time.toUtc());
  });

  test('verbose and retention settings persist', () async {
    final prefs = LogPreferences(File('${directory.path}/settings.json'));
    await prefs.load();
    expect(prefs.verbose, isFalse);
    expect(prefs.retentionDays, 7);
    await prefs.update(verbose: true, retentionDays: 3);
    final next = LogPreferences(prefs.file);
    await next.load();
    expect(next.verbose, isTrue);
    expect(next.retentionDays, 3);
  });

  test('retention uses saved days on next open', () async {
    final file = File('${directory.path}/days.log');
    final now = DateTime.utc(2026, 1, 10);
    final old = PersistentLog(
      file,
      now: () => now.subtract(const Duration(days: 4)),
    );
    await old.open();
    await old.add('expired');
    final prefs = LogPreferences(File('${directory.path}/config.json'));
    await prefs.update(retentionDays: 3);
    await PersistentLog(
      file,
      now: () => now,
      retentionDays: prefs.retentionDays,
    ).open();
    expect(await file.readAsString(), isNot(contains('expired')));
  });

  test('verbose mode controls debug persistence', () async {
    final prefs = LogPreferences(File('${directory.path}/config.json'));
    final log = PersistentLog(File('${directory.path}/events.log'));
    final logger = createAppTalker(releaseMode: true);
    await attachPersistentLog(logger, log, preferences: prefs);
    logger.debug('hidden diagnostic');
    logger.info('important event');
    await log.flush();
    expect(await log.file.readAsString(), isNot(contains('hidden diagnostic')));
    expect(await log.file.readAsString(), contains('important event'));
    await prefs.update(verbose: true);
    logger.debug('visible diagnostic');
    await log.flush();
    expect(await log.file.readAsString(), contains('visible diagnostic'));
  });

  test(
    'debug startup events are not persisted with verbose disabled',
    () async {
      final logger = createAppTalker(releaseMode: true);
      logger.debug('startup diagnostic');
      logger.info('startup important');
      final log = PersistentLog(File('${directory.path}/startup.log'));
      final prefs = LogPreferences(File('${directory.path}/prefs.json'));
      await attachPersistentLog(logger, log, preferences: prefs);
      final text = await log.file.readAsString();
      expect(text, isNot(contains('startup diagnostic')));
      expect(text, contains('startup important'));
    },
  );

  test(
    'connects Talker history to disk and restores it after restart',
    () async {
      final file = File('${directory.path}/history.log');
      final history = PersistentLog(file);
      final logger = createAppTalker(releaseMode: true);
      await attachPersistentLog(logger, history);
      logger.info('saved message user@example.com');
      await history.flush();
      final restored = createAppTalker(releaseMode: true);
      await attachPersistentLog(restored, PersistentLog(file));
      expect(
        restored.history.map((e) => e.message).join(),
        contains('saved message'),
      );
      expect(await file.readAsString(), isNot(contains('user@example.com')));
    },
  );
}
