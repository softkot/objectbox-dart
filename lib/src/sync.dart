import 'dart:ffi';
import 'dart:typed_data' show Uint8List;
import 'dart:convert' show utf8;

import 'package:ffi/ffi.dart';

import 'store.dart';
import 'util.dart';
import 'bindings/bindings.dart';
import 'bindings/helpers.dart';
import 'bindings/structs.dart';

/// Credentials used to authenticate a sync client against a server.
class SyncCredentials {
  final int _type;
  final Uint8List _data;

  Uint8List get data => _data;

  SyncCredentials(this._type, this._data);

  SyncCredentials._(this._type, String data)
      : _data = Uint8List.fromList(utf8.encode(data));

  SyncCredentials.none()
      : _type = OBXSyncCredentialsType.NONE,
        _data = Uint8List(0);

  SyncCredentials.sharedSecretUint8List(this._data)
      : _type = OBXSyncCredentialsType.SHARED_SECRET;

  SyncCredentials.sharedSecretString(String data)
      : this._(OBXSyncCredentialsType.SHARED_SECRET, data);

  SyncCredentials.googleAuthUint8List(this._data)
      : _type = OBXSyncCredentialsType.GOOGLE_AUTH;

  SyncCredentials.googleAuthString(String data)
      : this._(OBXSyncCredentialsType.GOOGLE_AUTH, data);
}

enum SyncState {
  unknown,
  created,
  started,
  connected,
  loggedIn,
  disconnected,
  stopped,
  dead
}

enum SyncRequestUpdatesMode {
  /// no updates by default, [SyncClient.requestUpdates()] must be called manually
  manual,

  /// same as calling [SyncClient.requestUpdates(true)]
  /// default mode unless overridden by [SyncClient.setRequestUpdatesMode()]
  auto,

  /// same as calling [SyncClient.requestUpdates(false)]
  autoNoPushes
}

/// Sync client is used to provide ObjectBox Sync client capabilities to your application.
class SyncClient {
  final Store _store;
  /*late final*/ Pointer<OBX_sync> _cSync;

  /// The low-level pointer to this box.
  Pointer<OBX_sync> get ptr => (_cSync.address != 0)
      ? _cSync
      : throw Exception('SyncClient already closed');

  /// Creates a sync client associated with the given store and options.
  /// This does not initiate any connection attempts yet: call start() to do so.
  SyncClient(this._store, String serverUri, SyncCredentials creds) {
    if (!Sync.isAvailable()) {
      throw Exception(
          'Sync is not available in the loaded ObjectBox runtime library. '
          'Please visit https://objectbox.io/sync/ for options.');
    }

    final cServerUri = Utf8.toUtf8(serverUri).cast<Int8>();
    try {
      _cSync = checkObxPtr(bindings.obx_sync(_store.ptr, cServerUri),
          'failed to create sync client');
    } finally {
      free(cServerUri);
    }

    setCredentials(creds);
  }

  /// Closes and cleans up all resources used by this sync client.
  /// It can no longer be used afterwards, make a new sync client instead.
  /// Does nothing if this sync client has already been closed.
  void close() {
    final err = bindings.obx_sync_close(_cSync);
    _cSync = nullptr;
    syncClientsStorage.remove(_store);
    StoreCloseObserver.removeListener(_store, this);
    checkObx(err);
  }

  /// Returns if this sync client is closed and can no longer be used.
  bool isClosed() {
    return _cSync.address == 0;
  }

  /// Gets the current sync client state.
  SyncState state() {
    final state = bindings.obx_sync_state(ptr);
    switch (state) {
      case OBXSyncState.CREATED:
        return SyncState.created;
      case OBXSyncState.STARTED:
        return SyncState.started;
      case OBXSyncState.CONNECTED:
        return SyncState.connected;
      case OBXSyncState.LOGGED_IN:
        return SyncState.loggedIn;
      case OBXSyncState.DISCONNECTED:
        return SyncState.disconnected;
      case OBXSyncState.STOPPED:
        return SyncState.stopped;
      case OBXSyncState.DEAD:
        return SyncState.dead;
      default:
        return SyncState.unknown;
    }
  }

  /// Configure authentication credentials.
  /// The accepted [SyncCredentials] type depends on your sync-server configuration.
  void setCredentials(SyncCredentials creds) {
    final cCreds = OBX_bytes_wrapper.managedCopyOf(creds._data, align: false);
    try {
      checkObx(bindings.obx_sync_credentials(
          ptr,
          creds._type,
          creds._type == OBXSyncCredentialsType.NONE ? nullptr : cCreds.ptr,
          cCreds.size));
    } finally {
      cCreds.freeManaged();
    }
  }

  /// Configures how sync updates are received from the server.
  /// If automatic sync updates are turned off, they will need to be requested manually.
  void setRequestUpdatesMode(SyncRequestUpdatesMode mode) {
    int cMode;
    switch (mode) {
      case SyncRequestUpdatesMode.manual:
        cMode = OBXRequestUpdatesMode.MANUAL;
        break;
      case SyncRequestUpdatesMode.auto:
        cMode = OBXRequestUpdatesMode.AUTO;
        break;
      case SyncRequestUpdatesMode.autoNoPushes:
        cMode = OBXRequestUpdatesMode.AUTO_NO_PUSHES;
        break;
      default:
        throw Exception('Unknown mode argument: ' + mode.toString());
    }
    checkObx(bindings.obx_sync_request_updates_mode(ptr, cMode));
  }

  /// Once the sync client is configured, you can "start" it to initiate synchronization.
  /// This method triggers communication in the background and will return immediately.
  /// If the synchronization destination is reachable, this background thread will connect to the server,
  /// log in (authenticate) and, depending on "update request mode", start syncing data.
  /// If the device, network or server is currently offline, connection attempts will be retried later using
  /// increasing backoff intervals.
  /// If you haven't set the credentials in the options during construction, call [setCredentials()] before start().
  void start() {
    checkObx(bindings.obx_sync_start(ptr));
  }

  /// Stops this sync client. Does nothing if it is already stopped.
  void stop() {
    checkObx(bindings.obx_sync_stop(ptr));
  }

  /// Request updates since we last synchronized our database.
  /// Additionally, you can subscribe for future pushes from the server, to let
  /// it send us future updates as they come in.
  /// Call [cancelUpdates()] to stop the updates.
  bool requestUpdates(bool subscribeForFuturePushes) {
    return checkObxSuccess(
        bindings.obx_sync_updates_request(ptr, subscribeForFuturePushes));
  }

  /// Cancel updates from the server so that it will stop sending updates.
  /// See also [requestUpdates()].
  bool cancelUpdates() {
    return checkObxSuccess(bindings.obx_sync_updates_cancel(ptr));
  }

  /// Count the number of messages in the outgoing queue, i.e. those waiting to be sent to the server.
  /// Note: This calls uses a (read) transaction internally: 1) it's not just a "cheap" return of a single number.
  ///       While this will still be fast, avoid calling this function excessively.
  ///       2) the result follows transaction view semantics, thus it may not always match the actual value.
  int outgoingMessageCount({int limit = 0}) {
    final count = allocate<Uint64>();
    try {
      checkObx(bindings.obx_sync_outgoing_message_count(ptr, limit, count));
      return count.value;
    } finally {
      free(count);
    }
  }
}

/// [ObjectBox Sync](https://objectbox.io/sync/) makes data available on other devices.
///
/// Start building a sync client using [Sync.client()] and connect to a remote server.
class Sync {
  /// Sync() annotation enables synchronization for an entity.
  const Sync();

  static /*late final*/ bool _syncAvailable;

  /// Returns true if the loaded ObjectBox native library supports Sync.
  static bool isAvailable() {
    // TODO remove try-catch after upgrading to objectbox-c v0.11 where obx_sync_available() exists.
    try {
      _syncAvailable ??= bindings.obx_sync_available();
    } catch (_) {
      _syncAvailable = false;
    }
    return _syncAvailable;
  }

  /// Creates a sync client associated with the given store and configures it with the given options.
  /// This does not initiate any connection attempts yet: call [SyncClient.start()] to do so.
  /// Before start(), you can still configure some aspects of the sync client, e.g. its "request update" mode.
  /// Note: While you may not interact with SyncClient directly after start(), you need to hold on to the object.
  ///       Make sure the SyncClient is not destroyed and thus synchronization can keep running in the background.
  static SyncClient client(
      Store store, String serverUri, SyncCredentials creds) {
    if (syncClientsStorage.containsKey(store)) {
      throw Exception('Only one sync client can be active for a store');
    }
    final client = SyncClient(store, serverUri, creds);
    syncClientsStorage[store] = client;
    StoreCloseObserver.addListener(store, client, client.close);
    return client;
  }
}
