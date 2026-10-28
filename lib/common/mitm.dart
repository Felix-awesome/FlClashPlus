import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/request.dart';

/// Extracts script references (URLs or local names) from Quantumult X style
/// MITM rewrite rules and fetches their JavaScript source.
///
/// Rules reference scripts via script-request-header, script-request-body,
/// script-response-header, script-response-body, etc. The script reference
/// is the last whitespace-separated field on each such line and may be a
/// remote URL (fetched here) or a local name (left empty -- the core
/// resolves it against its bundled scripts).
Future<Map<String, String>> fetchMitmScripts(String rules) async {
  final refs = <String>{};
  for (final line in rules.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('#') ||
        trimmed.startsWith('//')) {
      continue;
    }
    final fields = trimmed.split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    // Skip the optional "url" marker.
    var action = fields[1];
    if (action == 'url' && fields.length >= 3) {
      action = fields[2];
    }
    if (action.startsWith('script-request') ||
        action.startsWith('script-response')) {
      // The script reference is the last field.
      final ref = fields.last;
      if (ref.isNotEmpty) refs.add(ref);
    }
  }
  final scripts = <String, String>{};
  for (final ref in refs) {
    if (ref.startsWith('http://') || ref.startsWith('https://')) {
      try {
        final response = await request.getTextResponseForUrl(ref);
        final body = response.data ?? '';
        if (body.isNotEmpty) scripts[ref] = body;
      } catch (error) {
        commonPrint.log('fetch MITM script $ref failed: $error');
      }
    }
  }
  return scripts;
}
