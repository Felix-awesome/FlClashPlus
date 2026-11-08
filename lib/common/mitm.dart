import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/request.dart';

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

/// Extracts script references (URLs or local names) from Quantumult X style
/// MITM rewrite rules and fetches their JavaScript source.
///
/// A rule references a script through one of the script actions above, and the
/// reference is the last field on the line. It may be a remote URL, fetched
/// here, or a local name, left empty so the core resolves it against the
/// scripts it already has.
Future<Map<String, String>> fetchMitmScripts(String rules) async {
  final refs = <String>{};
  for (final line in rules.split('\n')) {
    final ref = _scriptReference(line);
    if (ref != null) refs.add(ref);
  }

  final scripts = <String, String>{};
  for (final ref in refs) {
    if (!ref.startsWith('http://') && !ref.startsWith('https://')) continue;
    try {
      final response = await request.getTextResponseForUrl(ref);
      final body = response.data ?? '';
      if (body.isNotEmpty) scripts[ref] = body;
    } catch (error) {
      commonPrint.log('fetch MITM script $ref failed: $error');
    }
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
