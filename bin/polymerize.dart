import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:dev_compiler/src/analyzer/context.dart';
import 'package:dev_compiler/src/compiler/compiler.dart';
import 'package:analyzer/src/summary/package_bundle_reader.dart';
import 'package:dev_compiler/src/compiler/module_builder.dart';
import 'package:path/path.dart' as path;
import 'package:analyzer/src/generated/source.dart';
import 'package:polymerize/package_graph.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:stack_trace/stack_trace.dart';
import 'package:resource/resource.dart' as res;
import 'package:args/args.dart';
import 'package:homedir/homedir.dart' as user;
import 'package:logging/logging.dart' as log;

const Map<ModuleFormat, String> _formatToString = const {
  ModuleFormat.amd: 'amd',
  ModuleFormat.es6: 'es6',
  ModuleFormat.common: 'common',
  ModuleFormat.legacy: 'legacy'
};

const Map<String, ModuleFormat> _stringToFormat = const {
  'amd': ModuleFormat.amd,
  'es6': ModuleFormat.es6,
  'common': ModuleFormat.common,
  'legacy': ModuleFormat.legacy
};

log.Logger logger = new log.Logger("polymerize");

Future _buildAll(String rootPath, Directory dest, ModuleFormat format,
    String repoPath) async {
  /*if (await dest.exists()) {
    await dest.delete(recursive:true);
  }*/

  if (dest != null && !await dest.exists()) await dest.create(recursive: true);

  repoPath = path.join(repoPath, _formatToString[format]);

  PackageGraph packageGraph = new PackageGraph.forPath(rootPath);

  // Build Packages in referse order

  Map summaries = {};
  await _buildPackage(
      rootPath, packageGraph.root, summaries, dest, repoPath, format);

  if (dest == null) {
    return;
  }

  // The order is irrelevant ---
  if (format == ModuleFormat.legacy) {
    await _copyResource("package:dev_compiler/js/legacy/dart_sdk.js",
        path.join(dest.path, "dart_sdk.js"));
    await _copyResource("package:dev_compiler/js/legacy/dart_library.js",
        path.join(dest.path, "dart_library.js"));
  } else if (format == ModuleFormat.es6) {
    await _copyResource("package:dev_compiler/js/es6/dart_sdk.js",
        path.join(dest.path, "dart_sdk.js"));
  } else if (format == ModuleFormat.amd) {
    await _copyResource("package:dev_compiler/js/amd/dart_sdk.js",
        path.join(dest.path, "dart_sdk.js"));

    await _copyResource(
        "package:polymerize/require.js", path.join(dest.path, "require.js"));
  }

  // If an index.html template exists use it

  // Copy everything
  Directory webDir = new Directory(path.join(rootPath, "web"));
  if (webDir.existsSync()) {
    _copyDir(webDir, dest);
  }
}

Future _copyResource(String resx, String dest) async {
  res.Resource rsx = new res.Resource(resx);
  String content = await rsx.readAsString();
  return new File(dest).writeAsString(content);
}

Future<List<String>> _buildPackage(
    String rootPath,
    PackageNode node,
    Map<PackageNode, List<String>> summaries,
    Directory dest,
    String summaryRepoPath,
    ModuleFormat format) async {
  List<String> result;

  result = summaries[node];
  if (result != null) {
    return result;
  }

  // Build this package

  Set deps = new Set();
  for (PackageNode dep in node.dependencies) {
    deps.addAll(await _buildPackage(
        rootPath, dep, summaries, dest, summaryRepoPath, format));
  }

  /*
  (await Future.wait(node.dependencies.map((PackageNode dep) => _buildPackage(
          rootPath, dep, summaries, dest, summaryRepoPath, format))))
      .forEach((List<String> sum) => deps.addAll(sum));
*/

  logger.fine("Building ${node.name}");

  result = new List.from(deps);
  result.add(await _buildOne(
      rootPath,
      node.name,
      new Directory.fromUri(node.location),
      dest,
      new Directory(path.joinAll([
        summaryRepoPath,
        node.name,
        node.version != null ? node.version : ""
      ])),
      result,
      node.dependencyType == PackageDependencyType.pub,
      format));

  summaries[node] = result;

  return result;
}

Future<String> _buildOne(
    String rootPath,
    String packageName,
    Directory location,
    Directory dest,
    Directory summaryDest,
    List<String> summaries,
    bool useRepo,
    ModuleFormat format) async {
  File repo_smap =
      new File(path.join(summaryDest.path, "${packageName}.js.map"));
  File sum = new File(path.join(summaryDest.path, "${packageName}.sum"));
  File repo_js = new File(path.join(summaryDest.path, "${packageName}.js"));

  if (!await summaryDest.exists()) {
    await summaryDest.create(recursive: true);
  }
  String libPath = path.join(location.path, "lib");

  // If use repo (after collect and copy)
  // TODO : Spostare questa logica sotto
  // 1) buildare sempre dentro il repo
  // 2) a poi copiare sempre dal repo verso la dest
  Directory assetDir = new Directory(path.join(summaryDest.path, "assets"));

  if (!useRepo || !(repo_js.existsSync()) || !repo_smap.existsSync()) {
    // Collect sources from filesystem
    List<String> sources = [];
    if (!assetDir.existsSync()) {
      assetDir.createSync();
    }
    await _collectSourcesAndCopyResources(
        packageName, new Directory(libPath), sources, assetDir);
    // print("  Collected : ${sources}");
    // print("  Summaries : ${summaries}");

    ModuleCompiler moduleCompiler = new ModuleCompiler(new AnalyzerOptions(
        packageRoot: path.join(rootPath, "packages"), summaryPaths: summaries));
    CompilerOptions compilerOptions = new CompilerOptions();

    BuildUnit bu = new BuildUnit(
        packageName, ".", sources, (source) => _moduleForLibrary(source));

    JSModuleFile res = moduleCompiler.compile(bu, compilerOptions);
    if (!res.isValid) {
      throw new BuildError(res.errors);
    }

    // Analizzo il modulo

    moduleCompiler.context.librarySources.forEach((Source src) {
      if (src.isInSystemLibrary) {
        return;
      }
      if (src.uri.scheme != 'package') {
        return;
      }
      if (src.uri.pathSegments.first != packageName) {
        return;
      }

      LibraryElement le = moduleCompiler.context.getLibraryElement(src);

      le?.units?.forEach((CompilationUnitElement e) async {
        //print("Unit : ${e.name}");
        e.types.forEach((ClassElement ce) {
          DartObject reg = getAnnotation(ce.metadata, isPolymerRegister);
          if (reg == null) {
            return;
          }

          Map config = collectConfig(moduleCompiler.context, ce);

          String name = path.basenameWithoutExtension(e.name);

          bool native = reg.getField('native').toBoolValue();

          String tag = reg.getField('tagName').toStringValue();
          String template = reg.getField('template').toStringValue();
          //print("${ce.name} -> Found Tag  : ${tag} [${template}]");

          // Trovo il file relativo all'element
          String templatePath =
              path.join(path.dirname(e.source.fullName), template);

          String rel = path.relative(templatePath, from: libPath);

          String destTemplate = path.join(assetDir.path, rel);
          String renameTo =
              "${destTemplate.substring(0,destTemplate.length-5)}_orig.html";

          if (new File(templatePath).existsSync()) {
            //print("found ${templatePath} -> ${destTemplate}");

            new File(templatePath).copySync(renameTo);
            new File(destTemplate).writeAsStringSync(htmlImportTemplate(
                template: template,
                packageName: packageName,
                name: name,
                className: ce.name,
                tagName: tag,
                config: config,native: native));
          }
        });
      });
    });

    // Write outputs
    JSModuleCode code = res.getCode(format, false, "${packageName}.js", "");
    await repo_js.writeAsString(code.code);

    // Write source map
    await repo_smap.writeAsString(JSON.encode(code.sourceMap));

    // Write summary

    //File sum = new File(path.join(summaryDest.path, "${packageName}.sum"));
    await sum.writeAsBytes(res.summaryBytes);

    logger.info(" - ${sum.path}");
  } else {
    // print("CACHED :  ${sum.path}");
  }

  if (dest != null) {
    File smap =
        new File(path.join(dest.path, packageName, "${packageName}.js.map"));
    File js = new File(path.join(dest.path, packageName, "${packageName}.js"));

    await new Directory(path.join(dest.path, packageName)).create();

    // Copy From Build Repo
    await repo_js.copy(js.path);
    await repo_smap.copy(smap.path);
    await _copyDir(assetDir, new Directory(path.join(dest.path, packageName)));
  }
  return sum.path;
}

Map collectConfig(AnalysisContext context, ClassElement ce) {
  List<String> observers = [];
  Map<String, Map> properties = {};

  ce.methods.forEach((MethodElement me) {
    DartObject obs = getAnnotation(me.metadata, isObserve);
    if (obs == null) {
      return;
    }

    String params = obs.getField('observed').toStringValue();

    observers.add("${me.name}(${params})");
  });

  ce.fields.forEach((FieldElement fe) {
    DartObject not = getAnnotation(fe.metadata, isNotify);
    properties[fe.name] = {'notify': not != null};
  });

  return {'observers': observers, 'properties': properties};
}

final Uri POLYMER_REGISTER_URI =
    Uri.parse('package:polymer_element/polymer_element.dart');

bool isPolymerRegister(DartObject o) =>
    (o.type.element.librarySource.uri == POLYMER_REGISTER_URI) &&
    (o.type.name == 'PolymerRegister');

bool isObserve(DartObject o) =>
    (o.type.element.librarySource.uri == POLYMER_REGISTER_URI) &&
    (o.type.name == 'Observe');

bool isNotify(DartObject o) =>
    (o.type.element.librarySource.uri == POLYMER_REGISTER_URI) &&
    (o.type.name == 'Notify');

DartObject getAnnotation(
        Iterable<ElementAnnotation> metadata, //
        bool matches(DartObject)) =>
    metadata
        .map((ElementAnnotation an) => an.constantValue)
        .firstWhere(matches, orElse: () => null);

String htmlImportTemplate(
        {String template,
        String packageName,
        String name,
        String className,
        String tagName,
        Map config,bool native}) =>
    """
<link href='${path.basenameWithoutExtension(template)}_orig.html' rel='import'>

<script>
  require(['${packageName}/${packageName}','polymer_element/polymerize'],function(pkg,polymerize) {
  polymerize(pkg.${name}.${className},'${tagName}',${configTemplate(config)},${native});
});
</script>
""";

String configTemplate(Map config) => (config == null || config.isEmpty)
    ? "null"
    : """
  {
    observers:[${config['observers'].map((x) => '"${x}"').join(',')}],
    properties: {
      ${configPropsTemplate(config['properties'])}
    }
  }""";

String configPropsTemplate(Map properties) => properties.keys
    .map((String propName) =>
        "${propName} : { notify: ${properties[propName]['notify']}}")
    .join(',\n      ');

DartType metadataType(ElementAnnotation meta) {
  if (meta is ConstructorElement) {
    return (meta as ConstructorElement).returnType;
  }
  return null;
}

class BuildError {
  List messages;

  BuildError(this.messages);

  toString() => messages.join("\n");
}

Future _collectSourcesAndCopyResources(String packageName, Directory dir,
    List<String> sources, Directory dest) async {
  if (!await dir.exists()) {
    return [];
  }
  //dest = new Directory(path.join(dest.path, packageName));
  await for (FileSystemEntity e in dir.list(recursive: true)) {
    String rel = path.relative(e.path, from: dir.path);

    if (e is File) {
      if (path.extension(e.path) == '.dart' &&
          !path.basename(e.path).startsWith('.')) {
        sources.add("package:${packageName}/${rel}");
      } else {
        String destPath = path.join(dest.path, rel);
        Directory p = new Directory(path.dirname(destPath));
        if (!await p.exists()) {
          await p.create(recursive: true);
        }
        e.copy(destPath);
      }
    }
  }
}

Future _copyDir(Directory srcDir, Directory dest) async {
  await for (FileSystemEntity e in srcDir.list(recursive: true)) {
    String rel = path.relative(e.path, from: srcDir.path);

    if (e is File) {
      String destPath = path.join(dest.path, rel);
      Directory p = new Directory(path.dirname(destPath));
      if (!await p.exists()) {
        await p.create(recursive: true);
      }
      e.copy(destPath);
    }
  }
}

String _moduleForLibrary(Source source) {
  if (source is InSummarySource) {
    //print ("SOURCES : ${source.summaryPath} , ${source.fullName} , ${moduleRoot}");

    RegExp re = new RegExp(r"^package:([^/]+).*$");
    Match m = re.matchAsPrefix(source.fullName);
    if (m == null) {
      throw "Source should be in package format :${source.fullName}";
    }

    return "${m.group(1)}/${m.group(1)}";
  }

  throw 'Imported file "${source.uri}" was not found as a summary or source '
      'file. Please pass in either the summary or the source file '
      'for this import.';
}

main(List<String> args) {
  ArgParser parser = new ArgParser()
    ..addFlag('emit-output',
        abbr: 'e',
        negatable: true,
        defaultsTo: true,
        help: 'Should emit output')
    ..addOption('output',
        abbr: 'o', defaultsTo: 'out', help: 'output directory')
    ..addOption('repo',
        defaultsTo: path.join(user.homeDirPath, '.polymerize'),
        help: 'Repository path (defaults to "\$HOME/.polymerize")')
    ..addOption('source',
        abbr: 's',
        defaultsTo: Directory.current.path,
        help: 'source package path')
    ..addOption('module-format',
        abbr: 'm',
        allowed:
            ModuleFormat.values.map((ModuleFormat x) => _formatToString[x]),
        defaultsTo: _formatToString[ModuleFormat.amd],
        help: 'module format')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'showHelp');

  // Configure logger
  log.Logger.root.onRecord.listen((log.LogRecord rec) {
    print("${rec.message}");
  });
  log.Logger.root.level =log.Level.INFO;

  var results = parser.parse(args);

  if (results['help']) {
    print(parser.usage);
    return;
  }

  String sourcePath = results['source'];

  String destPath = results['output'];

  if (false == results['emit-output']) {
    destPath = null;
  }

  String repoPath = results['repo'];

  ModuleFormat fmt = _stringToFormat[results['module-format']];

  Chain.capture(() {
    _buildAll(sourcePath, destPath == null ? null : new Directory(destPath),
        fmt, repoPath);
  }, onError: (error, Chain chain) {
    if (error is BuildError) {
      logger.severe("BUILD ERROR : \n${error}",error);
    } else {
      logger.severe("ERROR: ${error}\n AT: ${chain.terse}",error);
    }
  });
}
