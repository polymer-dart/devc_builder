import 'dart:async';
import 'dart:convert';

import 'dart:io';
import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:barback/barback.dart';
import 'package:code_transformers/resolver.dart';
import 'package:glob/glob.dart';
import 'package:polymerize/src/code_generator.dart';
import 'package:polymerize/src/dart_file_command.dart';
import 'package:polymerize/src/dep_analyzer.dart';

import 'package:path/path.dart' as p;
import 'package:polymerize/src/utils.dart';

class ResolversInternalContext implements InternalContext {
  Resolver _resolver;

  static AssetId toAssetId(String uriString) {
    Uri uri = Uri.parse(uriString);
    if (uri.scheme == 'package') {
      AssetId assetId = new AssetId(uri.pathSegments[0], "lib/${uri.pathSegments.sublist(1).join("/")}");
      return assetId;
    }
    throw "Unknown URI ${uriString}";
  }

  ResolversInternalContext(Resolver resolver) : _resolver = resolver;

  @override
  CompilationUnit getCompilationUnit(String inputUri) => getLibraryElement(inputUri).unit;

  @override
  LibraryElement getLibraryElement(String inputUri) => _resolver.getLibrary(toAssetId(inputUri));

  @override
  void invalidateUri(String inputUri) {
    // Nothing to do here
  }
}

const String ORIG_EXT = "_orig.dart";

class PrepareTransformer extends Transformer with ResolverTransformer {
  PrepareTransformer({bool releaseMode, this.settings}) {
    resolvers = new Resolvers(dartSdkDirectory);
  }
  BarbackSettings settings;

  PrepareTransformer.asPlugin(BarbackSettings settings) : this(releaseMode: settings.mode == BarbackMode.RELEASE, settings: settings);

  Future<bool> isPrimary(id) async {
    return id.extension == '.dart' && id.path.startsWith("lib/");
  }

  @override
  applyResolver(Transform transform, Resolver resolver) async {
    if (!resolver.isLibrary(transform.primaryInput.id) || !_needsHtmlImport(resolver.getLibrary(transform.primaryInput.id))) {
      transform.logger.fine("${transform.primaryInput.id} is NOT a library, skipping");
      return;
    }
    AssetId origId = transform.primaryInput.id.changeExtension(ORIG_EXT);
    Stream<List<int>> content = transform.primaryInput.read();
    Asset orig = new Asset.fromStream(origId, content);
    transform.addOutput(orig);
    transform.consumePrimary();
    transform.logger.fine("COPY ${transform.primaryInput.id} INTO ${origId} WITH CONTENT : ${content}", asset: origId);
    transform.logger.fine("ADDED : ${orig}", asset: origId);
  }

  @override
  Future<bool> shouldApplyResolver(Asset asset) async {
    return asset.id.extension == ".dart";
  }
}

class InoculateTransformer extends Transformer with ResolverTransformer implements DeclaringTransformer {
  InoculateTransformer({bool releaseMode, this.settings}) {
    resolvers = new Resolvers(dartSdkDirectory);
  }
  BarbackSettings settings;

  InoculateTransformer.asPlugin(BarbackSettings settings) : this(releaseMode: settings.mode == BarbackMode.RELEASE, settings: settings);

  Future<bool> isPrimary(id) async {
    return id.path.endsWith(ORIG_EXT) && id.path.startsWith("lib/");
  }

  AssetId toDest(AssetId orig) => new AssetId(orig.package, orig.path.substring(0, orig.path.length - ORIG_EXT.length) + ".dart");
  AssetId toHtmlDest(AssetId orig) => toDest(orig).changeExtension('.mod.html');

  @override
  declareOutputs(DeclaringTransform transform) {
    // for each dart file produce a '.g.dart'

    transform.declareOutput(toDest(transform.primaryId));
    transform.declareOutput(toHtmlDest(transform.primaryId));
  }

  @override
  applyResolver(Transform transform, Resolver resolver) async {
    Buffer outputBuffer = new Buffer();
    Buffer htmlBuffer = new Buffer();

    AssetId origId = transform.primaryInput.id;
    AssetId dest = toDest(origId);
    transform.logger.fine("DEST ID : ${dest}");

    String basePath = p.joinAll(p.split(origId.path).sublist(1));
    String uri; // = "package:${origId.package}/${basePath}";

    uri = resolver.getImportUri(resolver.getLibrary(origId), from: dest).toString();
    transform.logger.fine("My URI : :${uri}");

    GeneratorContext generatorContext = new GeneratorContext(new ResolversInternalContext(resolver), uri, htmlBuffer.createSink(), outputBuffer.createSink());
    await generatorContext.generateCode();
    Asset gen = new Asset.fromStream(dest, outputBuffer.binaryStream);
    transform.addOutput(gen);
    //transform.logger.info("GEN ${dest}: ${await gen.readAsString()}");

    AssetId htmlId = toHtmlDest(transform.primaryInput.id);

    Asset html = new Asset.fromStream(htmlId, _generateHtml(htmlBuffer, transform, resolver, dest).transform(UTF8.encoder));
    await html.readAsString();
    transform.addOutput(html);
    transform.logger.fine("HTML : ${htmlId}");

    // generate bower.json
    if (!settings.configuration.containsKey('entry-point')) {
      return;
    }

    transform.logger.info("GENERATING BOWER.JSON WITH ${settings.configuration}",asset: transform.primaryInput.id);

    await _generateBowerJson(transform, resolver);
  }

  Future _generateBowerJson(Transform t, Resolver r) async {
    // Check if current lib matches
    if(!new  Glob(settings.configuration['entry-point']).matches(t.primaryInput.id.path)) {
      t.logger.warning("${t.primaryInput.id.path} doesn't marches with ${settings.configuration['entry-point']}");
      return;
    }
    t.logger.info("PRODUCING BOWER.JSON FOR ${t.primaryInput.id}");


    Map<String, String> deps = new Map.fromIterable(_flatten(_libraryTree(r.getLibrary(t.primaryInput.id)).map((l) => allFirstLevelAnnotation(l.unit, isBowerImport))),
        key: (DartObject o) => o.getField('name').toStringValue(), value: (DartObject o) => o.getField('ref').toStringValue());

    t.logger.info("DEPS ARE :${deps}");
    if (deps.isEmpty) {
      return;
    }

    AssetId bowerId = new AssetId(t.primaryInput.id.package, 'web/bower.json');
    Asset bowerJson = new Asset.fromString(bowerId, JSON.encode({'name':t.primaryInput.id.package,'dependencies': deps}));
    t.addOutput(bowerJson);
  }

  Iterable<X> _flatten<X>(Iterable<Iterable<X>> x) sync* {
    for (Iterable<X> i in x) {
      yield* i;
    }
  }

  Iterable<Uri> _findDependencies(Transform t, Resolver r) => _findDependenciesFor(t, r, r.getLibrary(t.primaryInput.id));

  Iterable<LibraryElement> _libraryTree(LibraryElement from, [Set<LibraryElement> traversed]) sync* {
    if (traversed == null) {
      traversed = new Set<LibraryElement>();
    }

    if (traversed.contains(from)) {
      return;
    }
    traversed.add(from);
    yield from;
    for (LibraryElement lib in _referencedLibs(from)) {
      yield* _libraryTree(lib, traversed);
    }
  }

  bool _anyDepNeedsHtmlImport(LibraryElement lib) => _libraryTree(lib).any(_needsHtmlImport);

  Iterable<LibraryElement> _referencedLibs(LibraryElement lib) sync* {
    yield* lib.imports.map((i) => i.importedLibrary);
    yield* lib.exports.map((e) => e.exportedLibrary);
  }

  Iterable<Uri> _findDependenciesFor(Transform t, Resolver r, LibraryElement lib) =>
      _referencedLibs(lib).where(_anyDepNeedsHtmlImport).map((lib) => r.getImportUri(lib, from: t.primaryInput.id));

  Stream<String> _generateHtml(Buffer htmlBuffer, Transform t, Resolver r, AssetId destId) async* {
    t.logger.fine("IMPORTED: ${r.getLibrary(t.primaryInput.id).imports.map((i)=>i.importedLibrary).where(_needsHtmlImport).map((l) => l.source.uri).join(",")}");
    String locName = "${p.split(p.withoutExtension(destId.path)).join('__')}";
    String relName = "${p.split(p.withoutExtension(destId.path)).sublist(1).join('__')}";
    String modName = "packages/${destId.package}/${locName}";

    String modPseudoDir = p.dirname(modName);

    yield* htmlBuffer.stream;

    yield* new Stream.fromIterable(_findDependencies(t, r).map(_packageUriToModuleName).map((u) => "<link rel='import' href='${p.relative(u,from:modPseudoDir)}'>\n"));

    yield* new Stream.fromIterable(
        _dedupe(allFirstLevelAnnotation(r.getLibrary(t.primaryInput.id).unit, isBowerImport).map((o) => "bower_components/${o.getField('import').toStringValue()}"))
            .map((i) => "<link rel='import' href='${p.relative(i,from:modPseudoDir)}'>\n"));

    yield "<script>require(['${modName}'],(module) =>  module.${relName}.initModule());</script>\n";
  }

  @override
  Future<bool> shouldApplyResolver(Asset asset) async {
    return asset.id.path.endsWith('.dart');
  }
}

Iterable<X> _dedupe<X>(Iterable<X> from) => new Set()..addAll(from);

bool _needsHtmlImport(LibraryElement importedLib) => hasAnyFirstLevelAnnotation(importedLib.unit, anyOf([isHtmlImport, isInit, isPolymerRegister, isBowerImport]));

String _packageUriToModuleName(Uri packageUri) => "packages/${packageUri.pathSegments[0]}/${p.withoutExtension(p.joinAll(packageUri.pathSegments.sublist(1)))}.mod.html";
