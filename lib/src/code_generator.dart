import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:code_builder/code_builder.dart' as code_builder;
import 'package:polymerize/src/dep_analyzer.dart';
import 'package:polymerize/src/utils.dart';

String toLibraryName(String uri) {
  Uri u = Uri.parse(uri);
  return u.pathSegments.map((x) => x.replaceAll('.', "_")).join("_") + "_G";
}

typedef Future CodeGenerator(GeneratorContext ctx, CompilationUnit cu, code_builder.LibraryBuilder libBuilder, code_builder.MethodBuilder initModuleBuilder, IOSink htmlHeader);

List<CodeGenerator> _codeGenerators = [_generateInitMethods, _addHtmlImport];

class GeneratorContext {
  InternalContext ctx;
  String inputUri;

  GeneratorContext(this.ctx, this.inputUri);
}

Future generateCode(String inputUri, String genPath, String htmlTemp) async {
  InternalContext ctx = await InternalContext.create('.');

  CompilationUnit cu = ctx.getCompilationUnit(inputUri);

  GeneratorContext getctx = new GeneratorContext(ctx, inputUri);

  code_builder.LibraryBuilder libBuilder = new code_builder.LibraryBuilder(toLibraryName(inputUri));
  libBuilder.addDirective(new code_builder.ImportBuilder(inputUri, prefix: "_lib"));
  code_builder.MethodBuilder initModuleBuilder = new code_builder.MethodBuilder("initModule");
  libBuilder.addMember(initModuleBuilder);

  IOSink htmlTempSink = new File(htmlTemp).openWrite();

  await Future.wait(_codeGenerators.map((gen) => gen(getctx, cu, libBuilder, initModuleBuilder, htmlTempSink)));

  await htmlTempSink.close();

  initModuleBuilder
    ..addStatements([
      new code_builder.StatementBuilder.raw((scope) {
        return "return;";
      })
    ]);

  return new File(genPath).writeAsString(code_builder.prettyToSource(libBuilder.buildAst()));
}

/**
 * Look for INIT METHODS
 */

Future _generateInitMethods(
    GeneratorContext ctx, CompilationUnit cu, code_builder.LibraryBuilder libBuilder, code_builder.MethodBuilder initModuleBuilder, IOSink htmlHeader) async {
  for (CompilationUnitMember m in cu.declarations) {
    if (m.element?.kind == ElementKind.FUNCTION) {
      FunctionElement functionElement = m.element;
      DartObject init = getAnnotation(m.element.metadata, isInit);
      if (init != null && functionElement.parameters.isEmpty) {
        code_builder.ReferenceBuilder ref = code_builder.reference("_lib.${functionElement.name}");
        initModuleBuilder.addStatement(ref.call([]));
      }
    }
  }
}

Future _addHtmlImport(GeneratorContext ctx, CompilationUnit cu, code_builder.LibraryBuilder libBuilder, code_builder.MethodBuilder initModuleBuilder, IOSink htmlHeader) async {
  for (AstNode m in cu.sortedDirectivesAndDeclarations) {
    List<ElementAnnotation> anno;
    if (m is Declaration) {
      anno = m.element?.metadata;
    } else if (m is Directive) {
      anno = m.element?.metadata;
    }
    if (anno==null) {
      continue;
    }
    DartObject html = getAnnotation(anno, isHtmlImport);
    if (html != null) {
      String relPath = html.getField('path').toStringValue();

      htmlHeader.writeln("<link rel='import' href='${relPath}'>");
    }
  }
}
