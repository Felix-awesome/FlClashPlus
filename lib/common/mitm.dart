import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/file.dart';
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
      if (source.isNotEmpty && _looksLikeMarkup(source)) {
        commonPrint.log('fetch MITM script $ref answered with a web page');
        source = '';
      }
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

  final fields = trimmed.split(_whitespace);
  if (fields.length < 3) return null;
  final actionIndex = fields.indexWhere(
    (field) => _scriptActions.contains(field),
    1,
  );
  if (actionIndex < 0 || actionIndex == fields.length - 1) return null;
  final ref = fields.last;
  return ref.isEmpty ? null : ref;
}

/// A remote rewrite rule set: a name to recognise it by, the address its rules
/// are fetched from, and when that last succeeded.
///
/// The name is what the rule browser groups the rules under; the address is
/// what the fetched copy is cached by, so editing the name alone never causes
/// another download and editing the address never mistakes the old copy for
/// the new one.
class MitmRuleSource {
  const MitmRuleSource({
    required this.name,
    required this.url,
    this.lastUpdateTime,
  });

  final String name;
  final String url;

  /// When the stored copy was last replaced, or null when the address has not
  /// answered yet.
  final DateTime? lastUpdateTime;

  /// A rule set is identified by its address: adding the same one twice is
  /// meaningless, and the cached copy is keyed by it.
  String get id => url;

  MitmRuleSource copyWith({
    String? name,
    String? url,
    DateTime? lastUpdateTime,
  }) {
    return MitmRuleSource(
      name: name ?? this.name,
      url: url ?? this.url,
      lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'url': url,
      if (lastUpdateTime != null)
        'lastUpdateTime': lastUpdateTime!.millisecondsSinceEpoch,
    };
  }

  /// Reads one stored entry.
  ///
  /// Builds that only kept addresses stored a bare URL per entry, so anything
  /// that is not a JSON object is read as one rather than dropped.
  static MitmRuleSource? decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('{')) {
      final source = _decodeJson(text);
      if (source != null) return source;
    }
    if (!_isHttpUrl(text)) return null;
    return MitmRuleSource(name: defaultRuleSourceName(text), url: text);
  }

  static MitmRuleSource? _decodeJson(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final url = (json['url'] as String?)?.trim() ?? '';
      if (!_isHttpUrl(url)) return null;
      final name = (json['name'] as String?)?.trim() ?? '';
      final time = json['lastUpdateTime'];
      return MitmRuleSource(
        name: name.isEmpty ? defaultRuleSourceName(url) : name,
        url: url,
        lastUpdateTime: time is int
            ? DateTime.fromMillisecondsSinceEpoch(time)
            : null,
      );
    } catch (error) {
      commonPrint.log('decode MITM rule source failed: $error');
      return null;
    }
  }

  static List<MitmRuleSource> decodeList(List<String> raw) {
    final sources = <MitmRuleSource>[];
    for (final entry in raw) {
      final source = decode(entry);
      if (source == null) continue;
      if (sources.any((item) => item.url == source.url)) continue;
      sources.add(source);
    }
    return sources;
  }

  static List<String> encodeList(List<MitmRuleSource> sources) {
    return [for (final source in sources) jsonEncode(source.toJson())];
  }
}

/// Only a plain http(s) address can be fetched. Anything else that reached the
/// list is dropped rather than kept as a source that never loads.
bool _isHttpUrl(String text) {
  final uri = text.webUri;
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

/// The rule count a source's rules are listed under.
///
/// A rule set is usually named after its file, which is the only part of a
/// subscription address a user recognises; the host is the fallback for an
/// address that ends at a directory.
String defaultRuleSourceName(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final segments = uri.pathSegments.where((it) => it.isNotEmpty).toList();
  // An address that ends at a directory names no file, so the host is the only
  // thing left to call it.
  var stem = uri.path.endsWith('/') || segments.isEmpty ? '' : segments.last;
  for (final extension in const ['.conf', '.txt', '.list']) {
    if (stem.toLowerCase().endsWith(extension)) {
      stem = stem.substring(0, stem.length - extension.length);
      break;
    }
  }
  if (stem.isNotEmpty) return stem;
  return uri.host.isEmpty ? url : uri.host;
}

/// What kind of change a rewrite rule makes, in the order a rule browser
/// lists them: the rules that answer a request themselves come first.
enum MitmRuleKind {
  reject,
  redirect,
  echo,
  requestHeader,
  responseHeader,
  requestBody,
  responseBody,
  jsonQuery,
  script,
  other,
}

/// One rewrite rule, split into the parts the rule browser shows.
class MitmRuleEntry {
  const MitmRuleEntry({
    required this.kind,
    required this.pattern,
    required this.action,
    this.argument = '',
    this.headerPattern,
    this.valid = true,
    required this.line,
  });

  final MitmRuleKind kind;

  /// The URL expression a request is matched against, exactly as written.
  final String pattern;

  /// The action keyword as written, which is also what a user searches for.
  final String action;

  /// The action's payload, formatted for display: a redirect target, a script
  /// reference, a header expression, or a "match → replacement" pair.
  final String argument;

  /// The header block expression of a `url-and-header` rule, when it has one.
  final String? headerPattern;

  /// Whether the line is a rewrite rule the core can run. A rule set shipping
  /// a line this build does not implement is still listed, marked, so the
  /// missing rules are visible instead of silently absent.
  final bool valid;

  /// The line exactly as it was written.
  final String line;
}

/// Every rewrite rule [text] carries, in file order.
///
/// The core owns the authoritative parser; this one mirrors it closely enough
/// to show what a rule set contains. Lines it cannot classify are returned
/// with [MitmRuleEntry.valid] false rather than dropped.
List<MitmRuleEntry> parseMitmRules(String text) {
  final entries = <MitmRuleEntry>[];
  var section = '';
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final header = _sectionName(line);
    if (header != null) {
      section = header;
      continue;
    }
    if (_isComment(line)) continue;
    // A plain "hostname = ..." line is a rule set setting, not a rule.
    if (_isMitmSetting(line)) continue;
    // Other sections of a Quantumult X configuration carry hostnames and
    // filters rather than rewrite rules.
    if (!_rewriteSections.contains(section)) continue;
    final entry = _parseRuleLine(line);
    if (entry != null) entries.add(entry);
  }
  return entries;
}

/// The groups of a Quantumult X configuration that hold rewrite rules.
const _rewriteSections = {'', 'rewrite', 'rewrite_local', 'rewrite_remote'};

const _mitmSettingKeys = {
  'hostname',
  'skip_validating_cert',
  'skip_src_ip',
  'skip_dst_ip',
  'p12',
  'passphrase',
};

final _whitespace = RegExp(r'\s+');
final _urlAndHeaderMarker = RegExp(r'(?:^|\s)url-and-header(?:\s|$)');

MitmRuleEntry? _parseRuleLine(String line) {
  final (pattern, afterPattern) = _cutToken(line);
  if (pattern.isEmpty) return null;
  var rest = afterPattern;
  final (marker, afterMarker) = _cutToken(rest);
  // Quantumult X writes "<url> url <action>", the plain form omits the marker.
  if (marker == 'url') rest = afterMarker;

  String? headerPattern;
  final headerMarker = _urlAndHeaderMarker.firstMatch(rest);
  if (headerMarker != null) {
    final header = rest.substring(0, headerMarker.start).trim();
    if (header.isNotEmpty) headerPattern = header;
    rest = rest.substring(headerMarker.end);
  }

  final (action, args) = _cutToken(rest);
  final argument = args.trim();

  MitmRuleEntry entry(MitmRuleKind kind, {String? detail, bool valid = true}) {
    return MitmRuleEntry(
      kind: kind,
      pattern: pattern,
      action: action,
      argument: detail ?? '',
      headerPattern: headerPattern,
      valid: valid,
      line: line,
    );
  }

  switch (action) {
    case '':
      return entry(MitmRuleKind.other, valid: false);
    case 'reject':
    case 'reject-200':
    case 'reject-img':
    case 'reject-dict':
    case 'reject-array':
      // Only reject-dict carries a payload of its own.
      return entry(
        MitmRuleKind.reject,
        detail: action == 'reject-dict' ? argument : '',
      );
    case '302':
    case '307':
      return entry(
        MitmRuleKind.redirect,
        detail: argument,
        valid: argument.isNotEmpty,
      );
    case 'request-header':
    case 'response-header':
      final kind = action == 'request-header'
          ? MitmRuleKind.requestHeader
          : MitmRuleKind.responseHeader;
      final halves = _splitRepeated(argument, action);
      if (halves != null) {
        return entry(kind, detail: '${halves.$1} → ${halves.$2}');
      }
      final fields = argument
          .split(_whitespace)
          .where((it) => it.isNotEmpty)
          .length;
      // "<name> <value>" is the name/value form this app wrote first; a
      // single token cannot say which header it addresses.
      return entry(kind, detail: argument, valid: fields >= 2);
    case 'request-body':
    case 'response-body':
      final kind = action == 'request-body'
          ? MitmRuleKind.requestBody
          : MitmRuleKind.responseBody;
      final halves = _splitRepeated(argument, action);
      if (halves == null) return entry(kind, valid: false);
      return entry(kind, detail: '${halves.$1} → ${halves.$2}');
    case 'jsonjq-request-body':
    case 'jsonjq-response-body':
      final query = _unquote(argument);
      return entry(
        MitmRuleKind.jsonQuery,
        detail: query,
        valid: query.isNotEmpty,
      );
    case 'echo-response':
      final halves = _splitRepeated(argument, action);
      if (halves == null) return entry(MitmRuleKind.echo, valid: false);
      return entry(MitmRuleKind.echo, detail: '${halves.$1} · ${halves.$2}');
    default:
      if (_scriptActions.contains(action)) {
        return entry(
          MitmRuleKind.script,
          detail: argument,
          valid: argument.isNotEmpty,
        );
      }
      return entry(MitmRuleKind.other, detail: argument, valid: false);
  }
}

/// Splits `<match> <action> <replacement>` on the second occurrence of the
/// action keyword, which Quantumult X repeats because either half may contain
/// spaces.
(String, String)? _splitRepeated(String args, String action) {
  final marker = RegExp(r'\s+' + RegExp.escape(action) + r'\s+');
  final match = marker.firstMatch(args);
  if (match == null) return null;
  return (
    args.substring(0, match.start).trim(),
    args.substring(match.end).trim(),
  );
}

(String, String) _cutToken(String text) {
  final value = text.trimLeft();
  if (value.isEmpty) return ('', '');
  final match = _whitespace.firstMatch(value);
  if (match == null) return (value, '');
  return (value.substring(0, match.start), value.substring(match.end));
}

String? _sectionName(String line) {
  if (line.length < 2 || !line.startsWith('[') || !line.endsWith(']')) {
    return null;
  }
  return line.substring(1, line.length - 1).trim().toLowerCase();
}

bool _isComment(String line) {
  return line.startsWith(';') || line.startsWith('#') || line.startsWith('//');
}

bool _isMitmSetting(String line) {
  final index = line.indexOf('=');
  if (index < 0) return false;
  final key = line.substring(0, index).trim().toLowerCase();
  return _mitmSettingKeys.contains(key);
}

/// Strips the matching quotes a rule set wraps a jq expression in.
String _unquote(String text) {
  if (text.length >= 2) {
    final first = text[0];
    final last = text[text.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return text.substring(1, text.length - 1);
    }
  }
  return text;
}

/// Fetches one remote file over the app's proxy chain.
///
/// Going through the proxy is what makes this work: a rule set or script is
/// routinely hosted on a service that is only reachable through a node.
Future<String> downloadRemoteFile(String url) async {
  String? served;
  try {
    served = await _fetchRemoteText(url, _ruleSetUserAgent);
    if (!_looksLikeMarkup(served)) return _trimBom(served);
  } catch (error) {
    commonPrint.log('fetch $url as a Quantumult X client failed: $error');
  }
  // Some hosts serve the file only to a client they recognise and answer
  // everyone else with their landing page or a refusal. A proxy client agent is
  // the one these rule sets are written for, and the browser agent is the other
  // half of the same gate, so it is worth one retry before calling the address
  // broken.
  final fallback = await _fetchRemoteText(url, null);
  return _trimBom(fallback.isEmpty ? served ?? '' : fallback);
}

/// The user agent a rewrite rule set is fetched with.
///
/// Addressing a rule set with the app's own agent is what makes a host answer
/// with its web page instead: the body is a 200 and looks downloaded, but it
/// carries no rules at all, which reads to the user as "this address cannot be
/// recognised". A rule set is written for Quantumult X, so the download says
/// so, and the hosts that gate on the client serve the file.
const _ruleSetUserAgent = 'Quantumult X/1.4.1 (iPhone; iOS 17.5; Scale/3.00)';

Future<String> _fetchRemoteText(String url, String? userAgent) async {
  final response = await request.getTextResponseForUrl(
    url,
    headers: userAgent == null
        ? null
        : {HttpHeaders.userAgentHeader: userAgent},
  );
  return response.data ?? '';
}

/// Whether [text] is a web page rather than a rule set or a script.
///
/// A host that answers with its landing page still answers 200, so the only
/// way to tell a download that failed from one that worked is that a rule set
/// never starts with markup. Keeping such a body out of the cache is what stops
/// a landing page from replacing rules that do work.
bool _looksLikeMarkup(String text) {
  final head = text.trimLeft().toLowerCase();
  return head.startsWith('<!doctype') || head.startsWith('<html');
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

/// What one download attempt produced: whether the address answered, and the
/// text to use — the fresh copy when it did, the stored one when it did not.
typedef MitmRuleSetFetch = ({bool ok, String content});

/// Downloads one rule set and caches it.
///
/// A failed or empty answer never replaces the stored copy: a subscription that
/// is down must not empty the rules it delivered before. The stored copy is
/// returned with `ok` false so the caller can tell the user the address did not
/// answer.
Future<MitmRuleSetFetch> fetchRuleSet(
  String url, {
  RemoteFetch fetch = downloadRemoteFile,
}) async {
  var content = '';
  var ok = false;
  try {
    content = await fetch(url);
    if (_looksLikeMarkup(content)) {
      // The address answered, but with its own web page: it carries no rules,
      // so it counts as a failed download and the stored copy stays in place.
      commonPrint.log('fetch MITM rule set $url answered with a web page');
      content = '';
    }
    if (content.isNotEmpty) {
      await _storeCachedFile(_ruleSetFolder, url, _ruleSetExtension, content);
      ok = true;
    }
  } catch (error) {
    commonPrint.log('fetch MITM rule set $url failed: $error');
  }
  if (ok) return (ok: true, content: content);
  return (
    ok: false,
    content: await _readCachedFile(_ruleSetFolder, url, _ruleSetExtension),
  );
}

/// The cached copy of one rule set, read without touching the network.
Future<String> loadCachedRuleSet(String url) {
  return _readCachedFile(_ruleSetFolder, url, _ruleSetExtension);
}

/// The cached copy of every rule set, read without touching the network.
Future<List<String>> loadCachedRuleSets(List<String> urls) async {
  final ruleSets = <String>[];
  for (final url in urls) {
    final content = await loadCachedRuleSet(url);
    if (content.isNotEmpty) ruleSets.add(content);
  }
  return ruleSets;
}

/// Forgets the cached copy of a rule set that is no longer configured.
Future<void> deleteRuleSetCache(String url) async {
  try {
    final file = await _cacheFile(_ruleSetFolder, url, _ruleSetExtension);
    await file.safeDelete();
  } catch (error) {
    commonPrint.log('delete MITM rule set cache for $url failed: $error');
  }
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
    final result = await fetchRuleSet(url, fetch: fetch);
    if (result.content.isNotEmpty) ruleSets.add(result.content);
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
