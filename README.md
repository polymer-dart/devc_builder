# Polymerize - Polymer 2.0 Dart-DDC

[![Join the chat at https://gitter.im/dart-polymer/Lobby](https://badges.gitter.im/dart-polymer/Lobby.svg)](https://gitter.im/dart-polymer/Lobby?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

This package is a community effort to bring support for **Polymer 2** and latest HTML standards to Dart (DDC).

It features :
 - support for `polymer 2.0.0` (web components 1.0)
 - using DDC to generate `ES6` output code
 - leverages [html5](https://github.com/polymer-dart/html5), a new html lib for Dart based on js interoperability only,
 - ~~using [bazel](http://bazel.io) as build system (see also [rules](https://github.com/polymer-dart/bazel_polymerize_rules) )~~
 - **NOW** working with dart 1.24 + pub (ddc)
 - **dynamic load** of polymer components definitions through `imd` (require js implementation using html imports)
 - **interoperability** with other JS frameworks
 - **Incremental** build (dependencies are built only once, thanks to DDC modularity system and bazel build)
 - possibility to distribute **ONLY** the build result to thirdy party users and devs
 - simplified API
   - automatic getter and setter (no explicit notify for first level properties)
   - **NO** Annotations required to expose properties
   - **NO** Annotations required to expose methods
 - seamless integration with widely used js tools like `bower`

## Disclaimer

`Polymerize` works on every platforms where `DDC` runs that's MacOS and Linux for now.

The upcoming version of `pub` will support `DDC` build and `polymerize` will support it too thus extending the platform where you can use it.

### Browser compatibility

`Polymerize` uses `DDC` and `Polymer-2`, this means that it will only work on modern browsers. So far only `chrome` and `firefox` have been tested but `Safari` should work too along with latest IE11 builds.

Eventually some "transpiling" support can be added along with some optimizing post processing (like vulcanize or similar) could be added to the build chain to broaden the compatibility range.  

** UPDATE ** : after moving to ** PUB+DDC ** there's something broken with firefox , will fix soon. But I wanted to publish this release quickly after 1.24 was officially released.


## Usage

### Prepare a project

In order to build a project with polymerize you have to add the following transformer and dev dependencies to your pubspec:

    dev_dependencies:
      - polymerize: ^0.9.0
    transformers:
      - polymerize:
         entry-point: web/index.dart


The entry point is the main dart file. Your html file should look as this:

    <html>
     <head>
         <script src="bower_components/webcomponentsjs/webcomponents-loader.js"></script>
         <script type="application/dart" src="index.dart"></script>
         <script src="polymerize_require/start.js"></script>
     </head>
     ...
    </html>


See the demo todo project for more details.

### Build a project

 1. `pub build --web-compiler dartdevc` (or add the necessary entries in the pubspec as well) 

** DISCLAIMER ** : When using `dartdevc` for production build you will loose al the optimizations that `dart2js` normally makes to your code. This means that you will have bigger fat code even if modular and loaded only on demand.


# Developing with polymerize

## Sample project

A sample project illustrating how to build `polymer-2` components using `polymerize` can be found here :
 - [Sample mini todo APP for Polymer2-Dart-DDC Project](https://github.com/dam0vm3nt/todo_ddc)

See the [README](https://github.com/dam0vm3nt/polymer_dcc/blob/master/README.md) for more information.

## Component definition

This is a sample component definition:

    import 'package:polymer_element/polymer_element.dart';
    import 'package:my_component/other_component.dart';

    @PolymerRegister('my-tag',template:'my-tag.html')
    abstract class MyTag extends PolymerElement {

      int count = 0;  // <- no need to annotate this !!!

      onClickIt(Event ev,details) {  // <- NO need to annotate this!!!!
        count = count + 1;    // <- no need to call `set` API , magical setter in action here
      }

      @Observe('count')
      void countChanged(val) {
        print("Count has changed : ${count}");
      }

      MyTag() { // <- Use a simple constructor for created callback !!!
        print("HELLO THERE !")
      }

      factory MyTag.tag() => Element.tag('my-tag'); // <- If you want to create it programmatically use this

      connectedCallback() {
        super.connectedCallback(); // <- super MUST BE CALLED if you override this callback (needed by webcomponents v1) !!!!
      }
    }

The Html template is just the usual `dom-module`  template **without** any JS code. The import dependencies will generate the appropriate html imports so there is no need to add them to
the template. 

The `index.html` should preload `imd`, `webcomponents` polyfill and `polymer.html` (see the demo).

## Importing a Bower component

To import a bower component and use it in your project simply create a stub (that can created automatically, see below) for it and use the `@BowerImport` annotation along with `@PolymerRegister` with `native=true`, for instance:

    @PolymerRegister('paper-button',native:true)
    @BowerImport(ref:'PolymerElements/paper-button#2.0-preview',import:"paper-button/paper-button.html",name:'paper-button')
    abstract class PaperButton extends PolymerElement implements imp0.PaperButtonBehavior {
      /**
       * If true, the button should be styled with a shadow.
       */
      external bool get raised;
      external set raised(bool value);

    }

During the build phase `polymerize` will check any `@BowerImport` annotation on classes of dependencies, generate a `bower.json` file (using `resolutions` if you need to override something) and then
runs `bower install`.

You can also automatically generate a stub from the HTML `polymer` component using `polymerize generate_wrapper`, for instance:

    pub run polymerize:polymerize generate-wrapper --component-refs comps.yaml --dest-path out -p polymer_elements --bower-needs-map Polymer.IronFormElementBehavior=package:polymer_elements/iron_form_element_behavior.dart

(You have to add `polymerize` as a dev dependency of your project).

The generator uses a yaml file describing the components to analyze passed through the `component-refs` options (see `gen/comps.yam` in this repo for an example).

The project [polymerize_elements](https://github.com/dam0vm3nt/polymerize_elements) is an example of wrappers generated using this tool for the `polymer-elements` components.

## Output

After complilation everything will be found in the bazel output folder (`bazel-bin`), ready to be used.

## TODO:

 - more polymer APIs
 - ~~support for mixins~~
 - ~~annotations for properties (computed props, etc.)~~
 - ~~support for external element wrappers~~
 - ~~support for auto gen HTML imports~~
