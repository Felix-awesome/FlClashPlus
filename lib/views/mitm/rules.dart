import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'install.dart';

/// Every rewrite rule currently installed, grouped by where it came from and
/// then by what it does.
///
/// The list is read from the local rules and from the cached copy of each
/// remote rule set, so it shows exactly what the core was handed — including a
/// rule set that is only on disk because its host is unreachable right now.
class MitmRulesView extends ConsumerStatefulWidget {
  const MitmRulesView({super.key});

  @override
  ConsumerState<MitmRulesView> createState() => _MitmRulesViewState();
}

class _MitmRulesViewState extends ConsumerState<MitmRulesView> {
  var _groups = const <_RuleGroup>[];
  var _query = SearchQuery('');
  var _loading = true;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final appLocalizations = context.appLocalizations;
    final localRules = ref.read(appSettingProvider).mitmRules;
    final sources = await preferences.getMitmRuleSources();
    final groups = <_RuleGroup>[];
    groups.add(
      _RuleGroup(
        title: appLocalizations.mitmRulesLocal,
        entries: parseMitmRules(localRules),
        hasContent: localRules.trim().isNotEmpty,
      ),
    );
    for (final source in sources) {
      final content = await loadCachedRuleSet(source.url);
      groups.add(
        _RuleGroup(
          title: source.name,
          subtitle: source.url,
          entries: parseMitmRules(content),
          hasContent: content.trim().isNotEmpty,
          source: source,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  String _kindLabel(MitmRuleKind kind) {
    final appLocalizations = context.appLocalizations;
    return switch (kind) {
      MitmRuleKind.reject => appLocalizations.mitmRuleTypeReject,
      MitmRuleKind.redirect => appLocalizations.mitmRuleTypeRedirect,
      MitmRuleKind.echo => appLocalizations.mitmRuleTypeEcho,
      MitmRuleKind.requestHeader => appLocalizations.mitmRuleTypeRequestHeader,
      MitmRuleKind.responseHeader =>
        appLocalizations.mitmRuleTypeResponseHeader,
      MitmRuleKind.requestBody => appLocalizations.mitmRuleTypeRequestBody,
      MitmRuleKind.responseBody => appLocalizations.mitmRuleTypeResponseBody,
      MitmRuleKind.jsonQuery => appLocalizations.mitmRuleTypeJson,
      MitmRuleKind.script => appLocalizations.mitmRuleTypeScript,
      MitmRuleKind.other => appLocalizations.mitmRuleTypeOther,
    };
  }

  bool _matches(MitmRuleEntry entry, _RuleGroup group) {
    if (_query.isEmpty) return true;
    return _query.matches([
      entry.pattern,
      entry.action,
      entry.argument,
      entry.headerPattern,
      _kindLabel(entry.kind),
      group.title,
    ]);
  }

  /// The rows to scroll through: a header per source, then one block per kind
  /// of rule that source carries.
  List<_Block> _blocks() {
    final blocks = <_Block>[];
    for (final group in _groups) {
      final entries = group.entries
          .where((entry) => _matches(entry, group))
          .toList();
      if (entries.isEmpty) {
        // A rule set that was downloaded but carries no rewrite rules is worth
        // saying so; one that was never downloaded is not listed at all. The
        // local rules are reached through the editor in the bar, so an empty
        // local set keeps a page that says there is nothing to show.
        if (_query.isEmpty && group.source != null && group.hasContent) {
          blocks.add(_GroupBlock(group: group, count: 0));
          blocks.add(_EmptyBlock(context.appLocalizations.mitmRuleSourceEmpty));
        }
        continue;
      }
      blocks.add(_GroupBlock(group: group, count: entries.length));
      for (final kind in MitmRuleKind.values) {
        final ofKind = entries.where((entry) => entry.kind == kind).toList();
        if (ofKind.isEmpty) continue;
        blocks.add(_KindBlock(kind: kind, entries: ofKind));
      }
    }
    return blocks;
  }

  void _handleSearch(String query) {
    setState(() => _query = SearchQuery(query));
  }

  void _handleEditLocalRules() {
    unawaited(
      BaseNavigator.push(
        context,
        EditorPage(
          title: context.appLocalizations.mitmRules,
          content: ref.read(appSettingProvider).mitmRules,
          language: Language.javaScript,
          onSave: (context, _, content) async {
            final rules = await content.readText();
            ref
                .read(appSettingProvider.notifier)
                .update((state) => state.copyWith(mitmRules: rules));
            if (context.mounted) {
              Navigator.of(context).pop();
            }
            unawaited(installMitmRules(ref));
            unawaited(_load());
          },
        ),
      ),
    );
  }

  Future<void> _handleRefresh() async {
    final appLocalizations = context.appLocalizations;
    final total = _groups.where((group) => group.source != null).length;
    setState(() => _busy = true);
    final updated = await preferences.refreshMitmRuleSources();
    if (!mounted) return;
    await installMitmRules(ref);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    await dialogs.showMessage(
      context: context,
      message: TextSpan(
        text: updated == total
            ? appLocalizations.mitmRuleSourcesSaved(updated)
            : appLocalizations.mitmRuleSourcesFailed(total - updated),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final blocks = _blocks();
    final hasRemote = _groups.any((group) => group.source != null);
    return CommonScaffold(
      title: appLocalizations.mitmRules,
      isLoading: _busy,
      searchState: AppBarSearchState(onSearch: _handleSearch),
      actions: [
        IconButton(
          tooltip: appLocalizations.edit,
          onPressed: _busy ? null : _handleEditLocalRules,
          icon: const GlyphIcon(AppGlyphs.edit),
        ),
        if (hasRemote)
          IconButton(
            tooltip: appLocalizations.sync,
            onPressed: _busy ? null : _handleRefresh,
            icon: const GlyphIcon(AppGlyphs.sync),
          ),
      ],
      body: NullStatusSwitcher(
        isLoading: _loading,
        isEmpty: blocks.isEmpty,
        isSearching: _query.isNotEmpty,
        nullStatus: NullStatus(
          label: appLocalizations.mitmRulesEmpty,
          illustration: NullStatusIllustration.rules,
        ),
        child: Builder(
          // The inset below is read here, inside the scaffold, so the end of
          // the list clears the room its docked search adds on a phone.
          builder: (context) => ListView.builder(
            padding: EdgeInsets.fromLTRB(
              16,
              context.contentTopPadding,
              16,
              16 + context.bottomInset,
            ),
            itemCount: blocks.length,
            itemBuilder: (_, index) => switch (blocks[index]) {
              final _GroupBlock block => _GroupHeader(
                block: block,
                onEdit: block.group.source == null
                    ? _handleEditLocalRules
                    : null,
              ),
              final _KindBlock block => _KindSection(
                block: block,
                label: _kindLabel(block.kind),
              ),
              final _EmptyBlock block => ListFooter(text: block.text),
            },
          ),
        ),
      ),
    );
  }
}

/// One source of rewrite rules and the rules it carried.
class _RuleGroup {
  const _RuleGroup({
    required this.title,
    this.subtitle,
    required this.entries,
    required this.hasContent,
    this.source,
  });

  final String title;

  /// The address a remote rule set was read from; null for the local rules.
  final String? subtitle;
  final List<MitmRuleEntry> entries;

  /// Whether the source delivered anything at all, even if none of it parsed
  /// as a rewrite rule.
  final bool hasContent;

  /// The remote rule set this group came from, null for the local rules.
  final MitmRuleSource? source;
}

sealed class _Block {
  const _Block();
}

class _GroupBlock extends _Block {
  const _GroupBlock({required this.group, required this.count});

  final _RuleGroup group;
  final int count;
}

class _KindBlock extends _Block {
  const _KindBlock({required this.kind, required this.entries});

  final MitmRuleKind kind;
  final List<MitmRuleEntry> entries;
}

class _EmptyBlock extends _Block {
  const _EmptyBlock(this.text);

  final String text;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.block, this.onEdit});

  final _GroupBlock block;

  /// Set for the local rules, the one group that can be edited in place; a
  /// remote group is edited through its rule set.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final group = block.group;
    final subtitle = group.subtitle;
    final onEdit = this.onEdit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListHeader(
          title: group.title,
          trailing: Text(
            appLocalizations.mitmRulesCount(block.count),
            style: context.listCaptionStyle,
          ),
          actions: [
            if (onEdit != null)
              IconButtonData(
                glyph: AppGlyphs.edit,
                tooltip: appLocalizations.edit,
                onPressed: onEdit,
              ),
          ],
        ),
        if (subtitle != null) ListFooter(text: subtitle),
      ],
    );
  }
}

class _KindSection extends StatelessWidget {
  const _KindSection({required this.block, required this.label});

  final _KindBlock block;
  final String label;

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyle.footnote
        .of(context, emphasized: true)
        .copyWith(color: context.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              Text(block.entries.length.compact, style: style),
            ],
          ),
        ),
        generateGroup([
          for (final entry in block.entries) _RuleTile(entry: entry),
        ]),
      ],
    );
  }
}

/// One rule line: the URL expression it matches, and what it does with a
/// request that matches.
class _RuleTile extends StatelessWidget {
  const _RuleTile({required this.entry});

  final MitmRuleEntry entry;

  @override
  Widget build(BuildContext context) {
    final detail = [
      if (entry.headerPattern != null) entry.headerPattern!,
      if (entry.argument.isNotEmpty) entry.argument,
    ].join(' · ');
    return DecorationListItem(
      contentPadding: const EdgeInsets.only(left: 16, right: 16),
      minVerticalPadding: 8,
      title: Text(
        entry.pattern,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: context.listSubtitleStyle.toJetBrainsMono,
      ),
      subtitle: detail.isEmpty
          ? null
          : Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.listCaptionStyle,
            ),
      trailing: entry.valid
          ? null
          : Tooltip(
              message: context.appLocalizations.mitmRuleInvalid,
              child: GlyphIcon(
                AppGlyphs.warning,
                size: 16,
                color: context.colorScheme.error,
              ),
            ),
    );
  }
}
