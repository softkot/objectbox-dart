import 'dart:math';
import 'dart:typed_data';

import 'package:objectbox/src/bindings/bindings.dart';
import 'package:objectbox/objectbox.dart';
import 'package:objectbox/observable.dart';
import 'package:test/test.dart';

import 'entity.dart';
import 'objectbox.g.dart';
import 'test_env.dart';

// We want to have types explicit - verifying the return types of functions.
// ignore_for_file: omit_local_variable_types

void main() {
  /*late final*/ TestEnv env;
  /*late final*/ Store store;

  setUp(() {
    env = TestEnv('sync');
    store = env.store;
  });

  tearDown(() {
    if (env != null) env.close();
  });

  // lambda to easily create clients in the test below
  SyncClient createClient(Store s) =>
      Sync.client(s, 'ws://127.0.0.1:9999', SyncCredentials.none());

  // lambda to easily create clients in the test below
  SyncClient loggedInClient(Store s) {
    final client = createClient(s);
    client.start();
    expect(waitUntil(() => client.state() == SyncState.loggedIn), isTrue);
    return client;
  }

  test('Model Entity has sync enabled', () {
    final model = getObjectBoxModel().model;
    final entity =
        model.entities.firstWhere((ModelEntity e) => e.name == 'TestEntity');
    expect(entity.hasFlag(OBXEntityFlags.SYNC_ENABLED), isTrue);
  });

  test('SyncCredentials string encoding', () {
    // Let's check some special characters and verify the data is how it would
    // look like if the same shared secret was provided to the sync-server via
    // an utf-8 encoded json file (i.e. the usual way).
    final str = 'uũú';
    expect(SyncCredentials.sharedSecretString(str).data,
        equals(Uint8List.fromList([117, 197, 169, 195, 186])));
  });

  if (Sync.isAvailable()) {
    // TESTS to run when SYNC is available

    group('Circumvent issue #142 - async callbacks error', () {
      final error = throwsA(predicate((Exception e) => e.toString().contains(
          'Using observers/query streams in combination with SyncClient is currently not supported')));

      test('Must not start an Observer when SyncClient is active', () {
        createClient(store);
        expect(() => env.box.query().build().findStream(), error);
      });

      test('Must not start SyncClient when an Observer is active', () {
        final error = throwsA(predicate((Exception e) => e.toString().contains(
            'Using observers/query streams in combination with SyncClient is currently not supported')));

        createClient(store);
        expect(() => env.box.query().build().findStream(), error);
      });
    });

    test('SyncClient lifecycle', () {
      expect(store.syncClient(), isNull);

      SyncClient c1 = createClient(store);

      // Store now has the client available in cache.
      expect(store.syncClient(), equals(c1));

      // Can't have two clients on the same store.
      expect(
          () => createClient(store),
          throwsA(predicate(
              (Exception e) => e.toString().contains('one sync client'))));

      // But we can have another one after the previous is closed or destroyed.
      expect(c1.isClosed(), isFalse);
      c1.close();
      expect(c1.isClosed(), isTrue);
      expect(store.syncClient(), isNull);
    });

    test('SyncClient instance caching', () {
      {
        // Just losing the variable scope doesn't close the client automatically.
        // Store holds onto the same instance.
        final client = createClient(store);
        expect(client.isClosed(), isFalse);
      }

      // But we can still get a handle of the client in the store - we're never
      // completely without an option to close it.
      SyncClient /*?*/ client = store.syncClient();
      expect(client, isNotNull);
      expect(client /*!*/ .isClosed(), isFalse);
      client.close();
      expect(store.syncClient(), isNull);
    });

    test('SyncClient is closed when a store is closed', () {
      final env2 = TestEnv('sync2');
      final client = createClient(env2.store);
      env2.close();
      expect(client.isClosed(), isTrue);
    });

    test('different Store => different SyncClient', () {
      SyncClient c1 = createClient(store);

      final env2 = TestEnv('sync2');
      SyncClient c2 = createClient(env2.store);
      expect(c1, isNot(equals(c2)));
      env2.close();
    });

    test('SyncClient states (no server available)', () {
      SyncClient client = createClient(store);
      expect(client.state(), equals(SyncState.created));
      client.start();
      expect(client.state(), equals(SyncState.started));
      client.stop();
      expect(client.state(), equals(SyncState.stopped));
    });

    test('SyncClient access after closing must throw', () {
      SyncClient c = createClient(store);
      c.close();
      expect(c.isClosed(), isTrue);

      final error = throwsA(predicate(
          (Exception e) => e.toString().contains('SyncClient already closed')));
      expect(() => c.start(), error);
      expect(() => c.stop(), error);
      expect(() => c.state(), error);
      expect(() => c.cancelUpdates(), error);
      expect(() => c.requestUpdates(true), error);
      expect(() => c.outgoingMessageCount(), error);
      expect(() => c.setCredentials(SyncCredentials.none()), error);
      expect(() => c.setRequestUpdatesMode(SyncRequestUpdatesMode.auto), error);
    });

    test('SyncClient simple coverage (no server available)', () {
      SyncClient c = createClient(store);
      expect(c.isClosed(), isFalse);
      c.setCredentials(SyncCredentials.none());
      c.setCredentials(SyncCredentials.googleAuthString('secret'));
      c.setCredentials(SyncCredentials.sharedSecretString('secret'));
      c.setCredentials(
          SyncCredentials.googleAuthUint8List(Uint8List.fromList([13, 0, 25])));
      c.setCredentials(SyncCredentials.sharedSecretUint8List(
          Uint8List.fromList([13, 0, 25])));
      c.setCredentials(SyncCredentials.none());
      c.setRequestUpdatesMode(SyncRequestUpdatesMode.manual);
      c.start();
      expect(c.requestUpdates(true), isFalse); // false because not connected
      expect(c.requestUpdates(false), isFalse); // false because not connected
      expect(c.outgoingMessageCount(), isZero);
      c.stop();
      expect(c.state(), equals(SyncState.stopped));
    });

    test('SyncClient - data test (requires manual server setup)', () {
      final env2 = TestEnv('sync2');

      loggedInClient(env.store);
      loggedInClient(env2.store);

      int id = env.box.put(TestEntity(tLong: Random().nextInt(1 << 32)));
      expect(waitUntil(() => env2.box.get(id) != null), isTrue);

      TestEntity /*?*/ read1 = env.box.get(id);
      TestEntity /*?*/ read2 = env2.box.get(id);
      expect(read1, isNotNull);
      expect(read2, isNotNull);
      expect(read1 /*!*/ .id, equals(read2 /*!*/ .id));
      expect(read1 /*!*/ .tLong, equals(read2 /*!*/ .tLong));
    },
        // Note: only available when you start a sync server manually.
        // Comment out the `skip: ` argument in tthe test-case definition.
        // run sync-server --unsecured-no-authentication --model=/path/objectbox-dart/test/objectbox-model.json
        skip: 'Data sync test is disabled, Enable after running sync-server.' //
        );
  } else {
    // TESTS to run when SYNC isn't available

    test('SyncClient cannot be created when running with non-sync library', () {
      expect(
          () => createClient(store),
          throwsA(predicate((Exception e) => e.toString().contains(
              'Sync is not available in the loaded ObjectBox runtime library'))));
    });
  }
}
