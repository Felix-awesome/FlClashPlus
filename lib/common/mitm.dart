import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/common/string.dart';
import 'package:path/path.dart';

/// The rewrite actions that reference a JavaScript file. Their argument is the
/// script reference, everything else on the line belongs to the rule.
const _scriptActions = {
  'script-request-header',
  'script-request-body',
  'script-response-header',
  'script-response-body',
  'script-echo-response',
  'script-analyze-echo-response',
};

/// Fetches the text of one remote file: a rewrite rule set or a script.
typedef RemoteFetch = Future<String> Function(String url);

/// Extracts script references (URLs or local names) from Quantumult X style
/// MITM rewrite rules and fetches their JavaScript source.
///
/// A rule references a script through one of the script actions above, and the
/// reference is the last field on the line. It may be a remote URL, fetched
/// here, or a local name, left empty so the core resolves it against the
/// scripts it already has.
///
/// A script that cannot be downloaded right now falls back to the copy stored
/// by an earlier download: the CDN these rule sets point at is blocked often
/// enough that a failed fetch must not silently turn every scripted rule off.
Future<Map<String, String>> fetchMitmScripts(
  String rules, {
  RemoteFetch fetch = downloadRemoteFile,
}) async {
  final refs = <String>{};
  for (final line in rules.split('\n')) {
    final ref = _scriptReference(line);
    if (ref != null) refs.add(ref);
  }

  final scripts = <String, String>{};
  for (final ref in refs) {
    if (!ref.startsWith('http://') && !ref.startsWith('https://')) continue;
    var source = '';
    try {
      source = await fetch(ref);
      if (source.isNotEmpty) {
        await _storeCachedFile(_scriptFolder, ref, _scriptExtension, source);
      }
    } catch (error) {
      commonPrint.log('fetch MITM script $ref failed: $error');
    }
    if (source.isEmpty) {
      source = await _readCachedFile(_scriptFolder, ref, _scriptExtension);
    }
    if (source.isNotEmpty) scripts[ref] = source;
  }
  return scripts;
}

/// Returns the script a rule line references, or null when the line is not a
/// script rule.
///
/// The action is looked up by name instead of by field position, because a
/// Quantumult X rule may carry an optional `url` marker and the match half of
/// a header or body rule may itself contain spaces.
String? _scriptReference(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  // Quantumult X comments start with ";", other rule sets use "#" or "//", and
  // a pasted snippet may carry a "[rewrite_local]" section header.
  if (trimmed.startsWith(';') ||
      trimmed.startsWith('#') ||
      trimmed.startsWith('//')) {
    return null;
  }
  if (trimmed.startsWith('[') && trimmed.endsWith(']')) return null;

  final fields = trimmed.split(RegExp(r'\s+'));
  if (fields.length < 3) return null;
  final actionIndex = fields.indexWhere(
    (field) => _scriptActions.contains(field),
    1,
  );
  if (actionIndex < 0 || actionIndex == fields.length - 1) return null;
  final ref = fields.last;
  return ref.isEmpty ? null : ref;
}

/// Splits the remote rule set list the user edits into usable URLs: one entry
/// per line, blanks and comments dropped.
List<String> parseRuleSourceUrls(String text) {
  final urls = <String>[];
  for (final line in text.split('\n')) {
    final url = line.trim();
    if (url.isEmpty || url.startsWith('#')) continue;
    if (!url.startsWith('http://') && !url.startsWith('https://')) continue;
    if (urls.contains(url)) continue;
    urls.add(url);
  }
  return urls;
}

/// Fetches one remote file over the app's proxy chain.
///
/// Going through the proxy is what makes this work: a rule set or script is
/// routinely hosted on a service that is only reachable through a node.
Future<String> downloadRemoteFile(String url) async {
  final response = await request.getTextResponseForUrl(url);
  return _trimBom(response.data ?? '');
}

const _ruleSetFolder = 'rules';
const _ruleSetExtension = 'conf';
const _scriptFolder = 'scripts';
const _scriptExtension = 'js';

/// The directory the downloaded rule sets and scripts are cached in.
///
/// Both have to stay usable while the host serving them is unreachable, so the
/// last copy that was downloaded is kept next to the CA and installed again on
/// the next core start without touching the network.
Future<File> _cacheFile(String folder, String url, String extension) async {
  final homeDirPath = await appPath.homeDirPath;
  return File(join(homeDirPath, 'mitm', folder, '${url.toMd5()}.$extension'));
}

/// The cached copy of a remote file, or an empty string when there is none.
Future<String> _readCachedFile(
  String folder,
  String url,
  String extension,
) async {
  try {
    final file = await _cacheFile(folder, url, extension);
    if (!await file.exists()) return '';
    return _trimBom(await file.readAsString());
  } catch (error) {
    commonPrint.log('read MITM $folder cache for $url failed: $error');
    return '';
  }
}

/// Replaces the cached copy of a remote file, going through a temporary file so
/// a half-written download never becomes the copy the next start installs.
Future<void> _storeCachedFile(
  String folder,
  String url,
  String extension,
  String content,
) async {
  try {
    final file = await _cacheFile(folder, url, extension);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.download');
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(file.path);
  } catch (error) {
    commonPrint.log('store MITM $folder cache for $url failed: $error');
  }
}

/// The cached copy of every rule set, read without touching the network.
Future<List<String>> loadCachedRuleSets(List<String> urls) async {
  final ruleSets = <String>[];
  for (final url in urls) {
    final content = await _readCachedFile(
      _ruleSetFolder,
      url,
      _ruleSetExtension,
    );
    if (content.isNotEmpty) ruleSets.add(content);
  }
  return ruleSets;
}

/// Downloads every rule set and returns the copies that are now current.
///
/// A failed download keeps the cached copy in place, so a subscription that is
/// down never leaves the core with fewer rules than it had.
Future<List<String>> refreshRuleSets(
  List<String> urls, {
  RemoteFetch fetch = downloadRemoteFile,
}) async {
  final ruleSets = <String>[];
  for (final url in urls) {
    var content = '';
    try {
      content = await fetch(url);
      if (content.isNotEmpty) {
        await _storeCachedFile(_ruleSetFolder, url, _ruleSetExtension, content);
      }
    } catch (error) {
      commonPrint.log('fetch MITM rule set $url failed: $error');
    }
    if (content.isEmpty) {
      content = await _readCachedFile(_ruleSetFolder, url, _ruleSetExtension);
    }
    if (content.isNotEmpty) ruleSets.add(content);
  }
  return ruleSets;
}

/// Joins the local rules and the remote ones into the single text the core
/// parses.
///
/// The local rules come first: a rule that answers a request ends the match, so
/// what the user wrote by hand takes precedence over a subscription. Each rule
/// set keeps its own "[mitm]" hostname list, and the core merges those into one
/// set of hosts it is willing to decrypt.
String combineRuleSets(String localRules, List<String> remoteRuleSets) {
  final buffer = StringBuffer();
  for (final text in [localRules, ...remoteRuleSets]) {
    final trimmed = _trimBom(text).trim();
    if (trimmed.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(trimmed);
  }
  return buffer.toString();
}

/// What the core needs to run a rule set: the merged rule text and the source
/// of every script it references.
typedef MitmRuleSet = ({String rules, Map<String, String> scripts});

/// Builds the rule set the core installs from the local rules and the remote
/// copies, downloading the scripts any of them reference.
Future<MitmRuleSet> buildMitmRuleSet(
  String localRules,
  List<String> remoteRuleSets,
) async {
  final rules = combineRuleSets(localRules, remoteRuleSets);
  final scripts = await fetchMitmScripts(rules);
  return (rules: rules, scripts: scripts);
}

/// Rule sets are served with a byte order mark often enough that it has to be
/// stripped: it would otherwise sit in front of the first rule, which then
/// parses as garbage instead of as a URL expression.
String _trimBom(String text) {
  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}
