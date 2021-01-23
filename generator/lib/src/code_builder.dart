import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as path;
import 'package:objectbox/objectbox.dart';
import 'package:dart_style/dart_style.dart';
import 'entity_resolver.dart';
import 'code_chunks.dart';

/// CodeBuilder collects all '.objectbox.info' files created by EntityResolver and generates objectbox-model.json and
/// objectbox_model.dart
class CodeBuilder extends Builder {
  static final jsonFile = 'objectbox-model.json';
  static final codeFile = 'objectbox.g.dart';

  @override
  final buildExtensions = {r'$lib$': _outputs, r'$test$': _outputs};

  // we can't write `jsonFile` as part of the output because we want it persisted, not removed before each generation
  static final _outputs = [codeFile];

  String dir(BuildStep buildStep) => path.dirname(buildStep.inputId.path);

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    // build() will be called only twice, once for the `lib` directory and once for the `test` directory

    // map from file name to a 'json' representation of entities
    final files = <String, List<dynamic>>{};
    final glob = Glob(dir(buildStep) + '/**' + EntityResolver.suffix);
    await for (final input in buildStep.findAssets(glob)) {
      files[input.path] = json.decode(await buildStep.readAsString(input));
    }
    if (files.isEmpty) return;

    // collect all entities and sort them by name
    final entities = <ModelEntity>[];
    for (final entitiesList in files.values) {
      for (final entityMap in entitiesList) {
        entities.add(ModelEntity.fromMap(entityMap, check: false));
      }
    }
    entities.sort((a, b) => a.name.compareTo(b.name));

    log.info('Package: ${buildStep.inputId.package}');
    log.info('Found ${entities.length} entities in: ${files.keys}');

    // update the model JSON with the read entities
    final model = await updateModel(entities, buildStep);

    // generate binding code
    updateCode(model, files.keys.toList(growable: false), buildStep);
  }

  Future<ModelInfo> updateModel(
      List<ModelEntity> entities, BuildStep buildStep) async {
    {
      // TODO temporary v0.5 -> v0.6 update - check if the model file exists in the old location
      final oldJson =
          AssetId(buildStep.inputId.package, 'objectbox-model.json');
      if (File(oldJson.path).existsSync()) {
        throw StateError(''
            'Found objectbox-model.json in the package root. This is the old behaviour before ObjectBox v0.6\n'
            'Please move objectbox-model.json to lib/objectbox-model.json and run the build_runner again.\n');
      }
    }

    // load an existing model or initialize a new one
    ModelInfo model;
    final jsonId =
        AssetId(buildStep.inputId.package, dir(buildStep) + '/' + jsonFile);
    if (await buildStep.canRead(jsonId)) {
      log.info('Using model: ${jsonId.path}');
      model =
          ModelInfo.fromMap(json.decode(await buildStep.readAsString(jsonId)));
    } else {
      log.warning('Creating model: ${jsonId.path}');
      model = ModelInfo();
    }

    // merge existing model and annotated model that was just read, then write new final model to file
    merge(model, entities);
    model.validate();

    // write model info
    // Can't use output, it's removed before each build, though writing to FS is explicitly forbidden by package:build.
    // await buildStep.writeAsString(jsonId, JsonEncoder.withIndent('  ').convert(model.toMap()));
    await File(jsonId.path).writeAsString(
        JsonEncoder.withIndent('  ').convert(model.toMap(forModelJson: true)));

    return model;
  }

  void updateCode(
      ModelInfo model, List<String> infoFiles, BuildStep buildStep) async {
    // transform '/lib/path/entity.objectbox.info' to 'path/entity.dart'
    final imports = infoFiles
        .map((file) => file
            .replaceFirst(EntityResolver.suffix, '.dart')
            .replaceFirst(dir(buildStep) + '/', ''))
        .toList();

    var code = CodeChunks.objectboxDart(model, imports);
    code = DartFormatter().format(code);

    final codeId =
        AssetId(buildStep.inputId.package, dir(buildStep) + '/' + codeFile);
    log.info('Generating code: ${codeId.path}');
    await buildStep.writeAsString(codeId, code);
  }

  void merge(ModelInfo model, List<ModelEntity> entities) {
    // update existing and add new, while collecting all entity IDs at the end
    final currentEntityIds = <int, bool>{};
    entities.forEach((entity) {
      final id = mergeEntity(model, entity);
      currentEntityIds[id.id] = true;
    });

    // remove ('retire') missing entities
    model.entities
        .where((entity) => !currentEntityIds.containsKey(entity.id.id))
        .forEach((entity) {
      log.warning(
          'Entity ${entity.name}(${entity.id.toString()}) not found in the code, removing from the model');
      model.removeEntity(entity);
    });
  }

  void mergeProperty(ModelEntity entityInModel, ModelProperty prop) {
    var propInModel = entityInModel.findSameProperty(prop);

    if (propInModel == null) {
      log.info('Found new property ${entityInModel.name}.${prop.name}');
      propInModel = entityInModel.createProperty(prop.name, prop.id.uid);
    }

    propInModel.name = prop.name;
    propInModel.type = prop.type;
    propInModel.flags = prop.flags;
    propInModel.dartFieldType = prop.dartFieldType;
    propInModel.relationTarget = prop.relationTarget;

    if (!prop.hasIndexFlag()) {
      propInModel.removeIndex();
    } else {
      propInModel.indexId ??= entityInModel.model.createIndexId();
    }
  }

  void mergeRelation(ModelEntity entityInModel, ModelRelation rel) {
    var relInModel = entityInModel.findSameRelation(rel);

    if (relInModel == null) {
      log.info('Found new relation ${entityInModel.name}.${rel.name}');
      relInModel = entityInModel.createRelation(rel.name, rel.id.uid);
    }

    relInModel.name = rel.name;
    relInModel.targetId =
        entityInModel.model.findEntityByName(rel.targetName).id;
  }

  IdUid mergeEntity(ModelInfo modelInfo, ModelEntity entity) {
    // 'entity' only contains the entity info directly read from the annotations and Dart source (i.e. with missing ID, lastPropertyId etc.)
    // 'entityInModel' is the entity from the model with all correct id/uid, lastPropertyId etc.
    var entityInModel = modelInfo.findSameEntity(entity);

    if (entityInModel == null) {
      log.info('Found new entity ${entity.name}');
      // in case the entity is created (i.e. when its given UID or name that does not yet exist), we are done, as nothing needs to be merged
      entityInModel = modelInfo.createEntity(entity.name, entity.id.uid);
    }

    entityInModel.name = entity.name;
    entityInModel.flags = entity.flags;

    // here, the entity was found already and entityInModel and entity might differ, i.e. conflicts need to be resolved, so merge all properties first
    entity.properties.forEach((p) => mergeProperty(entityInModel, p));
    entity.relations.forEach((r) => mergeRelation(entityInModel, r));

    // then remove all properties not present anymore in entity
    final missingProps = entityInModel.properties
        .where((p) => entity.findSameProperty(p) == null)
        .toList(growable: false);

    missingProps.forEach((p) {
      log.warning(
          'Property ${entity.name}.${p.name}(${p.id.toString()}) not found in the code, removing from the model');
      entityInModel.removeProperty(p);
    });

    // then remove all relations not present anymore in entity
    final missingRels = entityInModel.relations
        .where((p) => entity.findSameRelation(p) == null)
        .toList(growable: false);

    missingRels.forEach((p) {
      log.warning(
          'Relation ${entity.name}.${p.name}(${p.id.toString()}) not found in the code, removing from the model');
      entityInModel.removeRelation(p);
    });

    return entityInModel.id;
  }
}
