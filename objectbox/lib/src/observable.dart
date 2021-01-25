import 'dart:async';
import 'dart:ffi';

import 'bindings/bindings.dart';
import 'query/query.dart';
import 'store.dart';
import 'util.dart';

// ignore_for_file: non_constant_identifier_names

// dart callback signature
typedef Any = void Function(Pointer<Void>, Pointer<Uint32>, int);

class _Observable {
  static final _anyObserver = <int, Pointer<OBX_observer>>{};
  static final _any = <int, Map<int, Any>>{};

  // sync:true -> ObjectBoxException: 10001 TX is not active anymore: #101
  static final controller = StreamController<int>.broadcast();

  // The user_data is used to pass the store ptr address
  // in case there is no consensus on the entity id between stores
  static void _anyCallback(
      Pointer<Void> user_data, Pointer<Uint32> mutated_ids, int mutated_count) {
    final storeAddress = user_data.address;
    // call schema's callback
    final storeCallbacks = _any[storeAddress];
    if (storeCallbacks != null) {
      for (var i = 0; i < mutated_count; i++) {
        storeCallbacks[mutated_ids[i]]
            ?.call(user_data, mutated_ids, mutated_count);
      }
    }
  }

  static void subscribe(Store store) {
    syncOrObserversExclusive.mark(store);

    final callback = Pointer.fromFunction<obx_observer>(_anyCallback);
    final storePtr = store.ptr;
    _anyObserver[storePtr.address] =
        C.observe(storePtr, callback, storePtr.cast<Void>());
    StoreCloseObserver.addListener(store, _anyObserver[storePtr.address], () {
      unsubscribe(store);
    });
  }

  // #53 ffi:Pointer finalizer
  static void unsubscribe(Store store) {
    final storeAddress = store.ptr.address;
    if (!_anyObserver.containsKey(storeAddress)) {
      return;
    }
    StoreCloseObserver.removeListener(store, _anyObserver[storeAddress]);
    C.observer_close(_anyObserver[storeAddress]);
    _anyObserver.remove(storeAddress);
    syncOrObserversExclusive.unmark(store);
  }

  static bool isSubscribed(Store store) =>
      _Observable._anyObserver.containsKey(store.ptr.address);
}

extension Streamable<T> on Query<T> {
  void _setup() {
    if (!_Observable.isSubscribed(store)) {
      _Observable.subscribe(store);
    }
    final storeAddress = store.ptr.address;

    _Observable._any[storeAddress] ??= <int, Any>{};
    _Observable._any[storeAddress] /*!*/ [entityId] ??= (u, _, __) {
      // dummy value to trigger an event
      _Observable.controller.add(entityId);
    };
  }

  Stream<List<T>> findStream(
      {@Deprecated('Use offset() instead') int offset = 0,
      @Deprecated('Use limit() instead') int limit = 0}) {
    _setup();
    return _Observable.controller.stream.where((e) => e == entityId).map((_) {
      if (offset != 0) this.offset(offset);
      if (limit != 0) this.limit(limit);
      return find();
    });
  }

  /// Use this for Query Property
  Stream<Query<T>> get stream {
    _setup();
    return _Observable.controller.stream
        .where((e) => e == entityId)
        .map((_) => this);
  }
}
