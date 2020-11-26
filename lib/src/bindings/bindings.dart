import 'dart:ffi';
import 'dart:io' show Platform;

import 'objectbox-c.dart';

// let files importing bindings.dart also get all the OBX_* types
export 'objectbox-c.dart';

ObjectBoxC loadObjectBoxLib() {
  DynamicLibrary /*?*/ lib;
  var libName = 'objectbox';
  if (Platform.isWindows) {
    libName += '.dll';
  } else if (Platform.isMacOS) {
    libName = 'lib' + libName + '.dylib';
  } else if (Platform.isIOS) {
    // this works in combination with `'OTHER_LDFLAGS' => '-framework ObjectBox'` in objectbox_flutter_libs.podspec
    lib = DynamicLibrary.process();
    // alternatively, if `DynamicLibrary.process()` wasn't faster (it should be though...)
    // libName = 'ObjectBox.framework/ObjectBox';
  } else if (Platform.isAndroid) {
    libName = 'lib' + libName + '-jni.so';
  } else if (Platform.isLinux) {
    libName = 'lib' + libName + '.so';
  } else {
    throw Exception(
        'unsupported platform detected: ${Platform.operatingSystem}');
  }
  lib ??= DynamicLibrary.open(libName);
  return ObjectBoxC(lib);
}

ObjectBoxC /*?*/ _cachedBindings;

ObjectBoxC get bindings => _cachedBindings ??= loadObjectBoxLib();

/// Init DartAPI in C for async callbacks - only needs to be called once.
/// See the following issue:
/// https://github.com/objectbox/objectbox-dart/issues/143
void initializeDartAPI() {
  if (!_dartAPIinitialized) {
    _dartAPIinitialized = true;
    bindings.obx_dart_init_api(NativeApi.initializeApiDLData);
  }
}

bool _dartAPIinitialized = false;
