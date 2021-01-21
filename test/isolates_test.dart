import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:objectbox/src/bindings/bindings.dart';
import 'package:test/test.dart';
import 'package:objectbox/observable.dart';

import 'entity.dart';
import 'test_env.dart';

// We want to have types explicit - verifying the return types of functions.
// ignore_for_file: omit_local_variable_types
void main() {
  /// Set up a simple echo isolate with request-response communication.
  /// This isn't really a test, just an example of how isolates can communicate.
  test('isolates two-way communication example', () async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(echoIsolate, receivePort.sendPort);

    Completer sendPortCompleter = Completer<SendPort>();
    Completer responseCompleter;
    receivePort.listen((data) {
      if (data is SendPort) {
        sendPortCompleter.complete(data);
      } else {
        print('Main received: $data');
        responseCompleter.complete(data);
      }
    });

    // Receive the SendPort from the Isolate
    SendPort sendPort = await sendPortCompleter.future;

    final call = (message) {
      responseCompleter = Completer<String>();
      sendPort.send(message);
      return responseCompleter.future;
    };

    // Send a message to the isolate
    expect(await call('hello'), equals('re:hello'));
    expect(await call('foo'), equals('re:foo'));

    isolate.kill(priority: Isolate.immediate);
    receivePort.close();
  });

  /// Work with a single store accross multiple isolates
  test('single store in multiple isolates', () async {
    final receivePort = ReceivePort();
    final isolate =
        await Isolate.spawn(createDataIsolate, receivePort.sendPort);

    final sendPortCompleter = Completer<SendPort>();
    Completer<dynamic> responseCompleter;
    receivePort.listen((data) {
      if (data is SendPort) {
        sendPortCompleter.complete(data);
      } else {
        print('Main received: $data');
        responseCompleter.complete(data);
      }
    });

    // Receive the SendPort from the Isolate
    SendPort sendPort = await sendPortCompleter.future;

    final call = (message) {
      responseCompleter = Completer<dynamic>();
      sendPort.send(message);
      return responseCompleter.future;
    };

    // Pass the store to the isolate
    final env = TestEnv('isolates');
    expect(await call(env.store.ptr.address), equals('store set'));

    {
      // check simple box operations
      expect(env.box.isEmpty(), isTrue);
      expect(await call(['put', 'Foo']), equals(1)); // returns inserted id = 1
      expect(env.box.get(1).tString, equals('Foo'));
    }

    {
      // verify that query streams (using observers) work fine across isolates
      final query = env.box.query().build();
      final futureFirst = query.findStream().first; // starts a subscription
      expect(await call(['put', 'Bar']), equals(2));
      List<TestEntity> found = await futureFirst.timeout(Duration(seconds: 1));
      expect(found.length, equals(2));
      expect(found.last.tString, equals('Bar'));
      query.close();
    }

    isolate.kill(priority: Isolate.immediate);
    receivePort.close();
    env.close();
  });
}

// Echoes back any received message.
void echoIsolate(SendPort sendPort) async {
  // Open the ReceivePort to listen for incoming messages
  final port = ReceivePort();

  // Send the port where the main isolate can contact us
  sendPort.send(port.sendPort);

  // Listen for messages
  await for (final data in port) {
    // `data` is the message received.
    print('Isolate received: $data');
    sendPort.send('re:$data');
  }
}

// Creates data in the background, in the [Store] received as the first message.
void createDataIsolate(SendPort sendPort) async {
  // Open the ReceivePort to listen for incoming messages
  final port = ReceivePort();

  // Send the port where the main isolate can contact us
  sendPort.send(port.sendPort);

  TestEnv env;
  // Listen for messages
  await for (final data in port) {
    if (env == null) {
      // first message data is Store's C pointer address
      env = TestEnv.fromPtr(Pointer<OBX_store>.fromAddress(data));
      sendPort.send('store set');
    } else {
      print('Isolate received: $data');
      if (data is! List) {
        sendPort.send('unknown message type, list expected');
      } else {
        switch (data[0]) {
          case 'put':
            final id = env.box.put(TestEntity(tString: data[1]));
            sendPort.send(id);
        }
      }
    }
  }
}
