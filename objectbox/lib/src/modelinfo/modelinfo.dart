import 'dart:math';

import '../util.dart';
import 'modelentity.dart';
import 'iduid.dart';

const _minModelVersion = 5;
const _maxModelVersion = 5;

/// In order to represent the model stored in `objectbox-model.json` in Dart, several classes have been introduced.
/// Conceptually, these classes are comparable to how models are handled in ObjectBox Java and ObjectBox Go; eventually,
/// ObjectBox Dart models will be fully compatible to them. This is also why for explanations on most concepts related
/// to ObjectBox models, you can refer to the [existing documentation](https://docs.objectbox.io/advanced).
class ModelInfo {
  static const notes = [
    'KEEP THIS FILE! Check it into a version control system (VCS) like git.',
    'ObjectBox manages crucial IDs for your object model. See docs for details.',
    'If you have VCS merge conflicts, you must resolve them according to ObjectBox docs.',
  ];

  List<ModelEntity> entities;
  IdUid lastEntityId, lastIndexId, lastRelationId, lastSequenceId;
  List<int> retiredEntityUids,
      retiredIndexUids,
      retiredPropertyUids,
      retiredRelationUids;
  int modelVersion, modelVersionParserMinimum, version;

  ModelInfo()
      : entities = [],
        lastEntityId = IdUid.empty(),
        lastIndexId = IdUid.empty(),
        lastRelationId = IdUid.empty(),
        lastSequenceId = IdUid.empty(),
        retiredEntityUids = [],
        retiredIndexUids = [],
        retiredPropertyUids = [],
        retiredRelationUids = [],
        modelVersion = _maxModelVersion,
        modelVersionParserMinimum = _maxModelVersion,
        version = 1;

  ModelInfo.fromMap(Map<String, dynamic> data, {bool check = true})
      : entities = [],
        lastEntityId = IdUid.fromString(data['lastEntityId']),
        lastIndexId = IdUid.fromString(data['lastIndexId']),
        lastRelationId = IdUid.fromString(data['lastRelationId']),
        lastSequenceId = IdUid.fromString(data['lastSequenceId']),
        retiredEntityUids = List<int>.from(data['retiredEntityUids'] ?? []),
        retiredIndexUids = List<int>.from(data['retiredIndexUids'] ?? []),
        retiredPropertyUids = List<int>.from(data['retiredPropertyUids'] ?? []),
        retiredRelationUids = List<int>.from(data['retiredRelationUids'] ?? []),
        modelVersion = data['modelVersion'] ?? 0,
        modelVersionParserMinimum =
            data['modelVersionParserMinimum'] ?? _maxModelVersion,
        version = data['version'] ?? 1 {
    if (data['entities'] == null) throw Exception('entities is null');
    for (final e in data['entities']) {
      entities.add(ModelEntity.fromMap(e, model: this, check: check));
    }
    if (check) validate();
  }

  void validate() {
    if (modelVersion < _minModelVersion) {
      throw Exception(
          'the loaded model is too old: version $modelVersion while the minimum supported is $_minModelVersion, consider upgrading with an older generator or manually');
    }
    if (modelVersion > _maxModelVersion) {
      throw Exception(
          'the loaded model has been created with a newer generator version $modelVersion, while the maximimum supported version is $_maxModelVersion. Please upgrade your toolchain/generator');
    }

    var lastEntityIdFound = false;
    for (final e in entities) {
      if (e.model != this) {
        throw Exception(
            "entity '${e.name}' with id ${e.id.toString()} has incorrect parent model reference");
      }
      e.validate();
      if (lastEntityId.id < e.id.id) {
        throw Exception(
            "lastEntityId ${lastEntityId.toString()} is lower than the one of entity '${e.name}' with id ${e.id.toString()}");
      }
      if (lastEntityId.id == e.id.id) {
        if (lastEntityId.uid != e.id.uid) {
          throw Exception(
              "lastEntityId ${lastEntityId.toString()} does not match entity '${e.name}' with id ${e.id.toString()}");
        }
        lastEntityIdFound = true;
      }
    }

    if (!lastEntityIdFound &&
        !listContains(retiredEntityUids, lastEntityId.uid)) {
      throw Exception(
          'lastEntityId ${lastEntityId.toString()} does not match any entity');
    }

    if (!lastRelationId.isEmpty || hasRelations()) {
      var lastRelationIdFound = false;
      for (final e in entities) {
        for (final r in e.relations) {
          if (lastRelationId /*!*/ .id < r.id.id) {
            throw Exception(
                "lastRelationId ${lastRelationId.toString()} is lower than the one of relation '${r.name}' with id ${r.id.toString()}");
          }
          if (lastRelationId /*!*/ .id == r.id.id) {
            if (lastRelationId /*!*/ .uid != r.id.uid) {
              throw Exception(
                  "lastRelationId ${lastRelationId.toString()} does not match relation '${r.name}' with id ${r.id.toString()}");
            }
            lastRelationIdFound = true;
          }
        }
      }

      if (!lastRelationIdFound &&
          !listContains(retiredRelationUids, lastRelationId.uid)) {
        throw Exception(
            'lastRelationId ${lastRelationId.toString()} does not match any standalone relation');
      }
    }
  }

  // Note: this function is used when generting objectbox-model.json as well as
  // for model persistence in build_runner cache files.
  Map<String, dynamic> toMap({bool forModelJson = false}) {
    final ret = <String, dynamic>{};
    if (forModelJson) {
      ret['_note1'] = notes[0];
      ret['_note2'] = notes[1];
      ret['_note3'] = notes[2];
    }
    ret['entities'] =
        entities.map((e) => e.toMap(forModelJson: forModelJson)).toList();
    ret['lastEntityId'] = lastEntityId.toString();
    ret['lastIndexId'] = lastIndexId.toString();
    ret['lastRelationId'] = lastRelationId.toString();
    ret['lastSequenceId'] = lastSequenceId.toString();
    ret['modelVersion'] = modelVersion;
    if (forModelJson) {
      ret['modelVersionParserMinimum'] = modelVersionParserMinimum;
      ret['retiredEntityUids'] = retiredEntityUids;
      ret['retiredIndexUids'] = retiredIndexUids;
      ret['retiredPropertyUids'] = retiredPropertyUids;
      ret['retiredRelationUids'] = retiredRelationUids;
      ret['version'] = version;
    }
    return ret;
  }

  ModelEntity getEntityByUid(int uid) {
    final entity = findEntityByUid(uid);
    if (entity == null) throw Exception('entity uid=$uid not found');
    return entity;
  }

  ModelEntity /*?*/ findEntityByUid(int uid) {
    final idx = entities.indexWhere((e) => e.id.uid == uid);
    return idx < 0 ? null : entities[idx];
  }

  ModelEntity /*?*/ findEntityByName(String name) {
    final found = entities
        .where((e) => e.name.toLowerCase() == name.toLowerCase())
        .toList();
    if (found.isEmpty) return null;
    if (found.length >= 2) {
      throw Exception(
          'ambiguous entity name: $name; please specify a UID in its annotation');
    }
    return found[0];
  }

  ModelEntity /*?*/ findSameEntity(ModelEntity other) {
    ModelEntity /*?*/ ret;
    if (other.id.uid != 0) ret = findEntityByUid(other.id.uid);
    ret ??= findEntityByName(other.name);
    return ret;
  }

  ModelEntity createEntity(String name, [int uid = 0]) {
    var id = 1;
    if (entities.isNotEmpty) id = lastEntityId.id + 1;
    if (uid != 0 && containsUid(uid)) {
      throw Exception('uid already exists: $uid');
    }
    final uniqueUid = uid == 0 ? generateUid() : uid;

    var entity = ModelEntity(IdUid(id, uniqueUid), name, this);
    entities.add(entity);
    lastEntityId = entity.id;
    return entity;
  }

  void removeEntity(ModelEntity entity) {
    final foundEntity = findSameEntity(entity);
    if (foundEntity == null) {
      throw Exception(
          "cannot remove entity '${entity.name}' with id ${entity.id.toString()}: not found");
    }
    entities = entities.where((p) => p != foundEntity).toList();
    retiredEntityUids.add(entity.id.uid);
    entity.properties.forEach((prop) => retiredPropertyUids.add(prop.id.uid));
  }

  int generateUid() {
    var rng = Random();
    for (var i = 0; i < 1000; ++i) {
      // Dart can only generate random numbers up to 1 << 32, so concat two of them and remove the upper bit to make the number non-negative
      var uid = rng.nextInt(1 << 32);
      uid |= rng.nextInt(1 << 32) << 32;
      uid &= ~(1 << 63);
      if (uid != 0 && !containsUid(uid)) return uid;
    }

    throw Exception('internal error: could not generate a unique UID');
  }

  bool containsUid(int uid) {
    if (lastEntityId.uid == uid) return true;
    if (lastIndexId.uid == uid) return true;
    if (lastRelationId.uid == uid) return true;
    if (lastSequenceId.uid == uid) return true;
    if (entities.indexWhere((e) => e.containsUid(uid)) != -1) return true;
    if (listContains(retiredEntityUids, uid)) return true;
    if (listContains(retiredIndexUids, uid)) return true;
    if (listContains(retiredPropertyUids, uid)) return true;
    if (listContains(retiredRelationUids, uid)) return true;
    return false;
  }

  IdUid createIndexId() {
    var id = lastIndexId.isEmpty ? 1 : lastIndexId.id + 1;
    lastIndexId = IdUid(id, generateUid());
    return lastIndexId;
  }

  bool hasRelations() =>
      entities.indexWhere((e) => e.relations.isNotEmpty) != -1;
}
