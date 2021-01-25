import 'dart:io';
import 'entity.dart';
import 'objectbox.g.dart';

class TestEnv {
  final Directory dir;
  final Store store;

  factory TestEnv(String name) {
    final dir = Directory('testdata-' + name);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    return TestEnv._(dir, Store(getObjectBoxModel(), directory: dir.path));
  }

  TestEnv._(this.dir, this.store);

  Box<TestEntity> get box => store.box();

  void close() {
    store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
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
