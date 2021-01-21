import 'dart:ffi';
import 'dart:io';
import 'package:objectbox/src/bindings/bindings.dart';

import 'entity.dart';
import 'objectbox.g.dart';

class TestEnv {
  final Directory dir;
  /*late final*/ Store store;
  /*late final*/ Box<TestEntity> box;

  TestEnv(String name) : dir = Directory('testdata-' + name) {
    if (dir.existsSync()) dir.deleteSync(recursive: true);

    store = Store(getObjectBoxModel(), directory: dir.path);
    box = Box<TestEntity>(store);
  }

  TestEnv.fromPtr(Pointer<OBX_store> cStore) : dir = null {
    store = Store.fromPtr(getObjectBoxModel(), cStore);
    box = Box<TestEntity>(store);
  }

  void close() {
    store.close();
    if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// "Busy-waits" until the predicate returns true.
bool waitUntil(bool Function() predicate, {int timeoutMs = 1000}) {
  var success = false;
  final until = DateTime.now().millisecondsSinceEpoch + timeoutMs;

  while (!(success = predicate()) &&
      until > DateTime.now().millisecondsSinceEpoch) {
    sleep(Duration(milliseconds: 1));
  }
  return success;
}
