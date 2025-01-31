// Copyright 2017 The Chromium Authors. All rights reserved. Use of this source
// code is governed by a BSD-style license that can be found in the LICENSE file.

// @dart = 2.12

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:git/git.dart';
import 'package:path/path.dart' as p;

import 'build_spec.dart';
import 'edit.dart';
import 'globals.dart';
import 'lint.dart';
import 'runner.dart';
import 'util.dart';

Future<int> main(List<String> args) async {
  var runner = BuildCommandRunner();

  runner.addCommand(LintCommand(runner));
  runner.addCommand(AntBuildCommand(runner));
  runner.addCommand(GradleBuildCommand(runner));
  runner.addCommand(TestCommand(runner));
  runner.addCommand(DeployCommand(runner));
  runner.addCommand(GenerateCommand(runner));
  runner.addCommand(SetupCommand(runner));

  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    print('$e');
    return 1;
  }
}

void addProductFlags(ArgParser argParser, String verb) {
  argParser.addFlag('ij', help: '$verb the IntelliJ plugin', defaultsTo: true);
  argParser.addFlag('as',
      help: '$verb the Android Studio plugin', defaultsTo: true);
}

void copyResources({required String from, required String to}) {
  log('copying resources from $from to $to');
  _copyResources(Directory(from), Directory(to));
}

List<BuildSpec> createBuildSpecs(ProductCommand command) {
  var specs = <BuildSpec>[];
  var input = readProductMatrix();
  for (var json in input) {
    specs.add(BuildSpec.fromJson(json, command.release));
  }
  return specs;
}

Future<int> deleteBuildContents() async {
  final dir = Directory(p.join(rootPath, 'build'));
  if (!dir.existsSync()) throw 'No build directory found';
  var args = <String>[];
  args.add('-rf');
  args.add(p.join(rootPath, 'build', '*'));
  return await exec('rm', args);
}

List<File> findJars(String path) {
  final dir = Directory(path);
  return dir
      .listSync(recursive: true, followLinks: false)
      .where((e) => e is File && e.path.endsWith('.jar'))
      .toList()
      .cast<File>();
}

List<String> findJavaFiles(String path) {
  final dir = Directory(path);
  return dir
      .listSync(recursive: true, followLinks: false)
      .where((e) => e.path.endsWith('.java'))
      .map((f) => f.path)
      .toList();
}

Future<bool> genPluginFiles(BuildSpec spec, String destDir) async {
  await genPluginXml(spec, destDir, 'META-INF/plugin.xml');
  await genPluginXml(spec, destDir, 'META-INF/studio-contribs.xml');
  return true;
}

Future<File> genPluginXml(BuildSpec spec, String destDir, String path) async {
  var templatePath =
      '${path.substring(0, path.length - '.xml'.length)}_template.xml';
  var file =
      await File(p.join(rootPath, destDir, path)).create(recursive: true);
  log('writing ${p.relative(file.path)}');
  var dest = file.openWrite();
  dest.writeln(
      "<!-- Do not edit; instead, modify ${p.basename(templatePath)}, and run './bin/plugin generate'. -->");
  dest.writeln();
  await utf8.decoder
      .bind(File(p.join(rootPath, 'resources', templatePath)).openRead())
      .transform(LineSplitter())
      .forEach((l) => dest.writeln(substituteTemplateVariables(l, spec)));
  await dest.close();
  return await dest.done;
}

void genPresubmitYaml(List<BuildSpec> specs) {
  var file = File(p.join(rootPath, '.github', 'workflows', 'presubmit.yaml'));
  var versions = [];
  for (var spec in specs) {
    if (spec.channel == 'stable' && !spec.untilBuild.contains('SNAPSHOT')) {
      versions.add(spec.version);
    }
  }

  var templateFile =
      File(p.join(rootPath, '.github', 'workflows', 'presubmit.yaml.template'));
  var templateContents = templateFile.readAsStringSync();
  // If we need to make many changes consider something like genPluginXml().
  templateContents =
      templateContents.replaceFirst('@VERSIONS@', versions.join(', '));
  var header =
      "# Do not edit; instead, modify ${p.basename(templateFile.path)},"
      " and run './bin/plugin generate'.\n\n";
  var contents = header + templateContents;
  log('writing ${p.relative(file.path)}');
  file.writeAsStringSync(contents, flush: true);
}

bool isTravisFileValid() {
  var travisPath = p.join(rootPath, '.github/workflows/presubmit.yaml');
  var travisFile = File(travisPath);
  if (!travisFile.existsSync()) {
    return false;
  }
  var matrixPath = p.join(rootPath, 'product-matrix.json');
  var matrixFile = File(matrixPath);
  if (!matrixFile.existsSync()) {
    throw 'product-matrix.json is missing';
  }
  return isNewer(travisFile, matrixFile);
}

Future<int> jar(String directory, String outFile) async {
  var args = ['cf', p.absolute(outFile)];
  args.addAll(Directory(directory)
      .listSync(followLinks: false)
      .map((f) => p.basename(f.path)));
  args.remove('.DS_Store');
  return await exec('jar', args, cwd: directory);
}

Future<int> moveToArtifacts(ProductCommand cmd, BuildSpec spec) async {
  final dir = Directory(p.join(rootPath, 'artifacts'));
  if (!dir.existsSync()) throw 'No artifacts directory found';
  var file = pluginRegistryIds[spec.pluginId];
  var args = <String>[];
  args.add(p.join(rootPath, 'build', file));
  args.add(cmd.releasesFilePath(spec));
  return await exec('mv', args);
}

Future<bool> performReleaseChecks(ProductCommand cmd) async {
  // git must have a release_NN branch where NN is the value of --release
  // git must have no uncommitted changes
  var isGitDir = await GitDir.isGitDir(rootPath);
  if (isGitDir) {
    if (cmd.isTestMode) {
      return true;
    }
    if (cmd.isDevChannel) {
      log('release mode is incompatible with the dev channel');
      return false;
    }
    if (!cmd.isReleaseValid) {
      log('the release identifier ("${cmd.release}") must be of the form xx.x (major.minor)');
      return false;
    }
    var gitDir = await GitDir.fromExisting(rootPath);
    var isClean = await gitDir.isWorkingTreeClean();
    if (isClean) {
      var branch = await gitDir.currentBranch();
      var name = branch.branchName;
      var expectedName =
          cmd.isDevChannel ? 'master' : "release_${cmd.releaseMajor}";
      var result = name == expectedName;
      if (!result) {
        result = name.startsWith("release_${cmd.releaseMajor}") &&
            name.lastIndexOf(RegExp(r"\.[0-9]")) == name.length - 2;
      }
      if (result) {
        if (isTravisFileValid()) {
          return result;
        } else {
          log('the presubmit.yaml file needs updating: plugin generate');
        }
      } else {
        log('the current git branch must be named "$expectedName"');
      }
    } else {
      log('the current git branch has uncommitted changes');
    }
  } else {
    log('the current working directory is not managed by git: $rootPath');
  }
  return false;
}

List readProductMatrix() {
  var contents =
      File(p.join(rootPath, 'product-matrix.json')).readAsStringSync();
  var map = json.decode(contents);
  return map['list'];
}

String substituteTemplateVariables(String line, BuildSpec spec) {
  String valueOf(String name) {
    switch (name) {
      case 'PLUGINID':
        return spec.pluginId;
      case 'SINCE':
        return spec.sinceBuild;
      case 'UNTIL':
        return spec.untilBuild;
      case 'VERSION':
        var releaseNo = buildVersionNumber(spec);
        return '<version>$releaseNo</version>';
      case 'CHANGELOG':
        return spec.changeLog;
      case 'DEPEND':
        // If found, this is the module that triggers loading the Android Studio
        // support. The public sources and the installable plugin use different ones.
        return spec.isSynthetic
            ? 'com.intellij.modules.androidstudio'
            : 'com.android.tools.apk';
      default:
        throw 'unknown template variable: $name';
    }
  }

  var start = line.indexOf('@');
  while (start >= 0 && start < line.length) {
    var end = line.indexOf('@', start + 1);
    if (end > 0) {
      var name = line.substring(start + 1, end);
      line = line.replaceRange(start, end + 1, valueOf(name));
      if (end < line.length - 1) {
        start = line.indexOf('@', end + 1);
      }
    } else {
      break; // Some commit message has a '@' in it.
    }
  }
  return line;
}

Future<int> zip(String directory, String outFile) async {
  var dest = p.absolute(outFile);
  createDir(p.dirname(dest));
  var args = ['-r', dest, p.basename(directory)];
  return await exec('zip', args, cwd: p.dirname(directory));
}

void _copyFile(File file, Directory to, {String filename = ''}) {
  if (!file.existsSync()) {
    throw "${file.path} does not exist";
  }
  if (!to.existsSync()) {
    to.createSync(recursive: true);
  }
  if (filename == '') filename = p.basename(file.path);
  final target = File(p.join(to.path, filename));
  target.writeAsBytesSync(file.readAsBytesSync());
}

void _copyResources(Directory from, Directory to) {
  for (var entity in from.listSync(followLinks: false)) {
    final basename = p.basename(entity.path);
    if (basename.endsWith('.java') ||
        basename.endsWith('.kt') ||
        basename.endsWith('.form') ||
        basename == 'plugin.xml.template') {
      continue;
    }

    if (entity is File) {
      _copyFile(entity, to);
    } else if (entity is Directory) {
      _copyResources(entity, Directory(p.join(to.path, basename)));
    }
  }
}

class AntBuildCommand extends BuildCommand {
  AntBuildCommand(BuildCommandRunner runner) : super(runner, 'build');

  @override
  Future<int> doit() async {
    return GradleBuildCommand(runner).doit();
  }

  @override
  Future<int> externalBuildCommand(BuildSpec spec) async {
    // Not used
    return 0;
  }

  @override
  Future<int> savePluginArtifact(BuildSpec spec) async {
    // Not used
    return 0;
  }
}

class GradleBuildCommand extends BuildCommand {
  GradleBuildCommand(BuildCommandRunner runner) : super(runner, 'make');

  @override
  Future<int> externalBuildCommand(BuildSpec spec) async {
    var pluginFile = File('resources/META-INF/plugin.xml');
    var studioFile = File('resources/META-INF/studio-contribs.xml');
    var pluginSrc = pluginFile.readAsStringSync();
    var studioSrc = studioFile.readAsStringSync();
    try {
      await genPluginFiles(spec, 'resources');
      return await runner.buildPlugin(spec, buildVersionNumber(spec));
    } finally {
      pluginFile.writeAsStringSync(pluginSrc);
      studioFile.writeAsStringSync(studioSrc);
    }
  }

  @override
  Future<int> savePluginArtifact(BuildSpec spec) async {
    final file = File(releasesFilePath(spec));
    final version = buildVersionNumber(spec);
    var source = File('build/distributions/flutter-intellij-$version.zip');
    if (!source.existsSync()) {
      // Setting the plugin name in Gradle should eliminate the need for this,
      // but it does not.
      // TODO(messick) Find a way to make the Kokoro file name: flutter-intellij-DEV.zip
      source = File('build/distributions/flutter-intellij-kokoro-$version.zip');
    }
    _copyFile(
      source,
      file.parent,
      filename: p.basename(file.path),
    );
    await _stopDaemon();
    return 0;
  }

  Future<int> _stopDaemon() async {
    if (Platform.isWindows) {
      return await exec('.\\third_party\\gradlew.bat', ['--stop']);
    } else {
      return await exec('./third_party/gradlew', ['--stop']);
    }
  }
}

/// Build deployable plugin files. If the --release argument is given
/// then perform additional checks to verify that the release environment
/// is in good order.
abstract class BuildCommand extends ProductCommand {
  @override
  final BuildCommandRunner runner;

  BuildCommand(this.runner, String commandName) : super(commandName) {
    argParser.addOption('only-version',
        abbr: 'o',
        help: 'Only build the specified IntelliJ version; useful for sharding '
            'builds on CI systems.');
    argParser.addFlag('unpack',
        abbr: 'u',
        help: 'Unpack the artifact files during provisioning, '
            'even if the cache appears fresh.\n'
            'This flag is ignored if --release is given.',
        defaultsTo: false);
    argParser.addOption('minor',
        abbr: 'm', help: 'Set the minor version number.');
    argParser.addFlag('setup', abbr: 's', defaultsTo: true);
  }

  @override
  String get description => 'Build a deployable version of the Flutter plugin, '
      'compiled against the specified artifacts.';

  Future<int> externalBuildCommand(BuildSpec spec);

  Future<int> savePluginArtifact(BuildSpec spec);

  @override
  Future<int> doit() async {
    try {
      if (isReleaseMode) {
        if (argResults!['unpack']) {
          separator('Release mode (--release) implies --unpack');
        }
        if (!await performReleaseChecks(this)) {
          return 1;
        }
      }

      // Check to see if we should only be building a specific version.
      String? onlyVersion = argResults!['only-version'];

      var buildSpecs = specs;
      if (onlyVersion != null && onlyVersion.isNotEmpty) {
        buildSpecs =
            specs.where((spec) => spec.version == onlyVersion).toList();
        if (buildSpecs.isEmpty) {
          log("No spec found for version '$onlyVersion'");
          return 1;
        }
      }

      String? minorNumber = argResults!['minor'];
      if (minorNumber != null) {
        pluginCount = int.parse(minorNumber) - 1;
      }

      var result = 0;
      for (var spec in buildSpecs) {
        if (spec.channel != channel) {
          continue;
        }
        if (!(isForIntelliJ && isForAndroidStudio)) {
          // This is a little more complicated than I'd like because the default
          // is to always do both.
          if (isForAndroidStudio && !spec.isAndroidStudio) continue;
          if (isForIntelliJ && spec.isAndroidStudio) continue;
        }

        pluginCount++;
        if (spec.isDevChannel && !isDevChannel) {
          spec.buildForMaster();
        }

        result = await spec.artifacts.provision(
          rebuildCache:
              isReleaseMode || argResults!['unpack'] || buildSpecs.length > 1,
        );
        if (result != 0) {
          return result;
        }
        if (channel == 'setup') {
          return 0;
        }

        separator('Building flutter-intellij.jar');
        await removeAll('build');

        log('spec.version: ${spec.version}');

        result = await applyEdits(spec, () async {
          return await externalBuildCommand(spec);
        });
        if (result != 0) {
          log('applyEdits() returned ${result.toString()}');
          return result;
        }

        try {
          result = await savePluginArtifact(spec);
          if (result != 0) {
            return result;
          }
        } catch (ex) {
          log("$ex");
          return 1;
        }

        separator('Built artifact');
        log(releasesFilePath(spec));
      }
      if (argResults!['only-version'] == null) {
        checkAndClearAppliedEditCommands();
      }

      return 0;
    } finally {
      if (argResults!['setup']) {
        await SetupCommand(runner).run();
      }
    }
  }
}

/// Either the --release or --channel options must be provided.
/// The permanent token is read from the file specified by Kokoro.
class DeployCommand extends ProductCommand {
  @override
  final BuildCommandRunner runner;

  DeployCommand(this.runner) : super('deploy');

  @override
  String get description => 'Upload the Flutter plugin to the JetBrains site.';

  @override
  Future<int> doit() async {
    if (isReleaseMode) {
      if (!await performReleaseChecks(this)) {
        return 1;
      }
    } else if (!isDevChannel) {
      log('Deploy must have a --release or --channel=dev argument');
      return 1;
    }

    var token = readTokenFromKeystore('FLUTTER_KEYSTORE_NAME');
    var value = 0;
    var originalDir = Directory.current;
    for (var spec in specs) {
      if (spec.channel != channel) continue;
      var filePath = releasesFilePath(spec);
      log("uploading $filePath");
      var file = File(filePath);
      changeDirectory(file.parent);
      var pluginNumber = pluginRegistryIds[spec.pluginId];
      value = await upload(
          p.basename(file.path), pluginNumber!, token, spec.channel);
      if (value != 0) {
        return value;
      }
    }
    changeDirectory(originalDir);
    return value;
  }

  void changeDirectory(Directory dir) {
    Directory.current = dir.path;
  }

  Future<int> upload(String filePath, String pluginNumber, String token,
      String channel) async {
    if (!File(filePath).existsSync()) {
      throw 'File not found: $filePath';
    }
    // See https://plugins.jetbrains.com/docs/marketplace/plugin-upload.html#PluginUploadAPI-POST
    // Trying to run curl directly doesn't work; something odd happens to the quotes.
    var cmd = '''
curl
-i
--header "Authorization: Bearer $token"
-F pluginId=$pluginNumber
-F file=@$filePath
-F channel=$channel
https://plugins.jetbrains.com/plugin/uploadPlugin
''';

    var args = ['-c', cmd.split('\n').join(' ')];
    final processResult = await Process.run('sh', args);
    if (processResult.exitCode != 0) {
      log('Upload failed: ${processResult.stderr} for file: $filePath');
    }
    String out = processResult.stdout;
    var message = out.trim().split('\n').last.trim();
    log(message);
    return processResult.exitCode;
  }
}

/// Generate the plugin.xml from the plugin.xml.template file. If the --release
/// argument is given, create a git branch and commit the new file to it,
/// assuming the release checks pass.
///
/// Note: The product-matrix.json file includes a build spec for the EAP version
/// at the end. When the EAP version is released that needs to be updated.
class GenerateCommand extends ProductCommand {
  @override
  final BuildCommandRunner runner;

  GenerateCommand(this.runner) : super('generate');

  @override
  String get description =>
      'Generate plugin.xml, .github/workflows/presubmit.yaml, '
      'and resources/liveTemplates/flutter_miscellaneous.xml files for the '
      'Flutter plugin.\nThe plugin.xml.template and product-matrix.json are '
      'used as input.';

  @override
  Future<int> doit() async {
    var json = readProductMatrix();
    var spec = SyntheticBuildSpec.fromJson(json.first, release, specs);
    await genPluginFiles(spec, 'resources');
    genPresubmitYaml(specs);
    generateLiveTemplates();
    if (isReleaseMode) {
      if (!await performReleaseChecks(this)) {
        return 1;
      }
    }
    return 0;
  }

  SyntheticBuildSpec makeSyntheticSpec(List specs) =>
      SyntheticBuildSpec.fromJson(specs[0], release, specs[2]);

  void generateLiveTemplates() {
    // Find all the live templates.
    final templateFragments = Directory(p.join('resources', 'liveTemplates'))
        .listSync()
        .whereType<File>()
        .where((file) => p.extension(file.path) == '.txt')
        .cast<File>()
        .toList();
    final templateFile =
        File(p.join('resources', 'liveTemplates', 'flutter_miscellaneous.xml'));
    var contents = templateFile.readAsStringSync();

    log('writing ${p.relative(templateFile.path)}');

    for (var file in templateFragments) {
      final name = p.basenameWithoutExtension(file.path);

      var replaceContents = file.readAsStringSync();
      replaceContents = replaceContents
          .replaceAll('\n', '&#10;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');

      // look for '<template name="$name" value="..."'
      final regexp = RegExp('<template name="$name" value="([^"]+)"');
      final match = regexp.firstMatch(contents);
      if (match == null) {
        throw 'No entry found for "$name" live template in ${templateFile.path}';
      }

      // Replace the existing content in the xml live template file with the
      // content from the template $name.txt file.
      final matchString = match.group(1);
      final matchStart = contents.indexOf(matchString!);
      contents = contents.substring(0, matchStart) +
          replaceContents +
          contents.substring(matchStart + matchString.length);
    }

    templateFile.writeAsStringSync(contents);
  }
}

abstract class ProductCommand extends Command {
  @override
  final String name;
  late List<BuildSpec> specs;

  ProductCommand(this.name) {
    addProductFlags(argParser, name[0].toUpperCase() + name.substring(1));
    argParser.addOption('channel',
        abbr: 'c',
        help: 'Select the channel to build: stable or dev',
        defaultsTo: 'stable');
  }

  String get channel => argResults!['channel'];

  bool get isDevChannel => channel == 'dev';

  /// Returns true when running in the context of a unit test.
  bool get isTesting => false;

  bool get isForAndroidStudio => argResults!['as'];

  bool get isForIntelliJ => argResults!['ij'];

  DateTime get releaseDate => lastReleaseDate;

  bool get isReleaseMode => release != null;

  bool get isReleaseValid {
    var rel = release;
    if (rel == null) {
      return false;
    }
    // Validate for '00.0' with optional '-dev.0'
    return rel == RegExp(r'^\d+\.\d(?:-dev.\d)?$').stringMatch(rel);
  }

  bool get isTestMode => globalResults!['cwd'] != null;

  String? get release {
    String? rel = globalResults!['release'];

    if (rel != null) {
      if (rel.startsWith('=')) {
        rel = rel.substring(1);
      }
      if (!rel.contains('.')) {
        rel = '$rel.0';
      }
    }

    return rel;
  }

  String? get releaseMajor {
    var rel = release;
    if (rel != null) {
      var idx = rel.indexOf('.');
      if (idx > 0) {
        rel = rel.substring(0, idx);
      }
    }
    return rel;
  }

  String releasesFilePath(BuildSpec spec) {
    var subDir = isReleaseMode
        ? 'release_$releaseMajor'
        : (spec.channel == "stable" ? 'release_master' : 'release_dev');
    var filePath = p.join(
        rootPath, 'releases', subDir, spec.version, 'flutter-intellij.zip');
    return filePath;
  }

  String testTargetPath(BuildSpec spec) {
    var subDir = 'release_master';
    var filePath = p.join(rootPath, 'releases', subDir, 'test_target');
    return filePath;
  }

  String ijVersionPath(BuildSpec spec) {
    var subDir = 'release_master';
    var filePath = p.join(rootPath, 'releases', subDir, spec.ijVersion);
    return filePath;
  }

  Future<int> doit();

  @override
  Future<int> run() async {
    await _initGlobals();
    await _initSpecs();
    try {
      return await doit();
    } catch (ex, stack) {
      log(ex.toString());
      log(stack.toString());
      return 1;
    }
  }

  Future<void> _initGlobals() async {
    // Initialization constraint: rootPath depends on arg parsing, and
    // lastReleaseName and lastReleaseDate depend on rootPath.
    rootPath = Directory.current.path;
    var rel = globalResults!['cwd'];
    if (rel != null) {
      rootPath = p.normalize(p.join(rootPath, rel));
    }
    if (isDevChannel) {
      lastReleaseName = await lastRelease();
      lastReleaseDate = await dateOfLastRelease();
    }
  }

  Future<int> _initSpecs() async {
    specs = createBuildSpecs(this);
    for (var i = 0; i < specs.length; i++) {
      if (isDevChannel) {
        specs[i].buildForDev();
      }
      await specs[i].initChangeLog();
    }
    return specs.length;
  }
}

/// A crude rename utility. The IntelliJ feature does not work on the case
/// needed. This just substitutes package names and assumes all are FQN-form.
/// It does not update forms; they use paths instead of packages.
/// It would be easy to do forms but it isn't worth the trouble. Only one
/// had to be edited.
class RenamePackageCommand extends ProductCommand {
  @override
  final BuildCommandRunner runner;
  String baseDir = Directory.current.path; // Run from flutter-intellij dir.
  late String oldName;
  late String newName;

  RenamePackageCommand(this.runner) : super('rename') {
    argParser.addOption('package',
        defaultsTo: 'com.android.tools.idea.npw',
        help: 'Package to be renamed');
    argParser.addOption('append',
        defaultsTo: 'Old', help: 'Suffix to be appended to package name');
    argParser.addOption('new-name', help: 'Name of package after renaming');
    argParser.addFlag('studio',
        negatable: true, help: 'The package is in the flutter-studio module');
  }

  @override
  String get description => 'Rename a package in the plugin sources';

  @override
  Future<int> doit() async {
    if (argResults!['studio']) baseDir = p.join(baseDir, 'flutter-studio/src');
    oldName = argResults!['package'];
    newName = argResults!.wasParsed('new-name')
        ? argResults!['new-name']
        : oldName + argResults!['append'];
    if (oldName == newName) {
      log('Nothing to do; new name is same as old name');
      return 1;
    }
    // TODO(messick) If the package is not in flutter-studio then we need to edit it too
    moveFiles();
    editReferences();
    await deleteDir();
    return 0;
  }

  void moveFiles() {
    final srcDir = Directory(p.join(baseDir, oldName.replaceAll('.', '/')));
    final destDir = Directory(p.join(baseDir, newName.replaceAll('.', '/')));
    _editAndMoveAll(srcDir, destDir);
  }

  void editReferences() {
    final srcDir = Directory(p.join(baseDir, oldName.replaceAll('.', '/')));
    final destDir = Directory(p.join(baseDir, newName.replaceAll('.', '/')));
    _editAll(Directory(baseDir), skipOld: srcDir, skipNew: destDir);
  }

  Future<int> deleteDir() async {
    final dir = Directory(p.join(baseDir, oldName.replaceAll('.', '/')));
    await dir.delete(recursive: true);
    return 0;
  }

  void _editAndMoveFile(File file, Directory to) {
    if (!to.existsSync()) {
      to.createSync(recursive: true);
    }
    final filename = p.basename(file.path);
    if (filename.startsWith('.')) return;
    final target = File(p.join(to.path, filename));
    var source = file.readAsStringSync();
    source = source.replaceAll(oldName, newName);
    target.writeAsStringSync(source);
    if (to.path != file.parent.path) file.deleteSync();
  }

  void _editAndMoveAll(Directory from, Directory to) {
    for (var entity in from.listSync(followLinks: false)) {
      final basename = p.basename(entity.path);

      if (entity is File) {
        _editAndMoveFile(entity, to);
      } else if (entity is Directory) {
        _editAndMoveAll(entity, Directory(p.join(to.path, basename)));
      }
    }
  }

  void _editAll(Directory src,
      {required Directory skipOld, required Directory skipNew}) {
    if (src.path == skipOld.path || src.path == skipNew.path) return;
    for (var entity in src.listSync(followLinks: false)) {
      if (entity is File) {
        _editAndMoveFile(entity, src);
      } else if (entity is Directory) {
        _editAll(entity, skipOld: skipOld, skipNew: skipNew);
      }
    }
  }
}

class SetupCommand extends Command {
  @override
  BuildCommandRunner runner;

  SetupCommand(this.runner) : super();

  @override
  Future<int> run() async {
    return await runner.run(['make', '-osetup', '-csetup', '-u', '--no-setup']);
  }

  @override
  String get description =>
      'Unpack the artifacts required to debug the plugin in IntelliJ';

  @override
  String get name => 'setup';
}

/// Build the tests if necessary then run them and return any failure code.
class TestCommand extends ProductCommand {
  @override
  final BuildCommandRunner runner;

  TestCommand(this.runner) : super('test') {
    argParser.addFlag('unit', negatable: false, help: 'Run unit tests');
    argParser.addFlag('integration',
        negatable: false, help: 'Run integration tests');
    argParser.addFlag('skip',
        negatable: false,
        help: 'Do not run tests, just unpack artifaccts',
        abbr: 's');
    argParser.addFlag('setup', abbr: 'p', defaultsTo: true);
  }

  @override
  String get description => 'Run the tests for the Flutter plugin.';

  @override
  Future<int> doit() async {
    try {
      final javaHome = Platform.environment['JAVA_HOME'];
      if (javaHome == null) {
        log('JAVA_HOME environment variable not set - this is needed by gradle.');
        return 1;
      }

      log('JAVA_HOME=$javaHome');

      final spec = specs.firstWhere((s) => s.isUnitTestTarget);
      await spec.artifacts.provision(rebuildCache: true);
      if (!argResults!['skip']) {
        if (argResults!['integration']) {
          return _runIntegrationTests();
        } else {
          return _runUnitTests(spec);
        }
      }
      return 0;
    } finally {
      if (argResults!['setup']) {
        await SetupCommand(runner).run();
      }
    }
  }

  Future<int> _runUnitTests(BuildSpec spec) async {
    // run './gradlew test'
    return await applyEdits(spec, () async {
      return await runner.runGradleCommand(['test'], spec, '1', 'true');
    });
  }

  Future<int> _runIntegrationTests() async {
    throw 'integration test execution not yet implemented';
  }
}
