import 'dart:io';

import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:skystream/core/logger/persistent_log.dart';

void main() {
  test(
    'plugin search, episode, server success and failure reach durable logs',
    () async {
      final directory = await Directory.systemTemp.createTemp('playback_log_');
      addTearDown(() async => directory.delete(recursive: true));
      final store = PersistentLog(File('${directory.path}/log.jsonl'));
      talker.cleanHistory();
      await attachPersistentLog(talker, store);
      final provider = CloudStreamProvider(
        plugin: const CsInstalledPlugin(
          info: CsPluginInfo(
            internalName: 'Demo',
            name: 'Demo',
            url: '',
            repositoryUrl: '',
          ),
          filePath: '/plugins/Demo.cs3',
        ),
        pluginKey: 'repo/Demo',
        info: const CsProviderInfo(name: 'Demo'),
        host: _StageHost(),
      );
      final results = await provider.search('Film');
      final details = await provider.getDetails(results.single.url);
      await provider.loadStreams(details.episodes!.single.url);
      await provider.loadStreams(CloudStreamProvider.token('empty'));
      await store.flush();
      final records = (await store.read())
          .where((r) => r.message.contains('plugin: Demo'))
          .toList();
      expect(records, hasLength(4));
      expect(
        records[0].message,
        contains('cari sumber | plugin: Demo | berhasil'),
      );
      expect(
        records[1].message,
        contains('ambil episode | plugin: Demo | berhasil'),
      );
      expect(
        records[2].message,
        contains('ambil server | plugin: Demo | berhasil'),
      );
      expect(
        records[3].message,
        contains('ambil server | plugin: Demo | gagal'),
      );
      expect(
        records.every((r) => RegExp(r'\d+ ms').hasMatch(r.message)),
        isTrue,
      );
    },
  );
}

class _StageHost extends CloudStreamEngineHost {
  int streams = 0;
  @override
  Future<T> run<T>(
    String path,
    Future<T> Function(Cs3Engine engine) call, {
    String kind = 'call',
    String? provider,
    String mainUrl = '',
    String? pluginUrl,
  }) async {
    final Map<String, dynamic> result = switch (kind) {
      'search' => {
        'items': [
          {'name': 'Film', 'url': '/film', 'type': 'Movie'},
        ],
      },
      'load' => {'name': 'Film', 'type': 'Movie', 'dataUrl': '/play'},
      'loadLinks' => {
        'links': streams++ == 0
            ? [
                {'url': 'https://example.test/video', 'name': 'A'},
              ]
            : <Map<String, String>>[],
      },
      _ => throw StateError('unexpected kind $kind'),
    };
    return result as T;
  }
}
