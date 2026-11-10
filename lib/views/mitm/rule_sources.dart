import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'install.dart';

/// The remote rewrite rule sets the MITM rewrite reads its rules from.
///
/// A rule set is a name and an address. The address is what gets fetched and
/// cached; the name is what its rules are grouped under in the rule browser.
/// Nothing is replaced until the address answers, so a subscription that is
/// down keeps the rules it last delivered instead of leaving the core with
/// fewer rules than it had.
class MitmRuleSourcesView extends ConsumerStatefulWidget {
  const MitmRuleSourcesView({super.key});

  @override
  ConsumerState<MitmRuleSourcesView> createState() =>
      _MitmRuleSourcesViewState();
}

class _MitmRuleSourcesViewState extends ConsumerState<MitmRuleSourcesView> {
  var _sources = const <MitmRuleSource>[];
  var _counts = const <String, int>{};
  var _loading = true;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final sources = await preferences.getMitmRuleSources();
    final counts = <String, int>{};
    for (final source in sources) {
      final content = await loadCachedRuleSet(source.url);
      counts[source.url] = parseMitmRules(content).length;
    }
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _counts = counts;
      _loading = false;
    });
  }

  /// Stores [next] and pushes the resulting rules into the core.
  Future<void> _save(List<MitmRuleSource> next) async {
    // Resolved before the write: a download that finished after this page was
    // closed must still reach the core, so the ref is not used past the await.
    final core = ref.read(coreHandlerProvider);
    final localRules = ref.read(appSettingProvider).mitmRules;
    await preferences.saveMitmRuleSources(next);
    if (mounted) {
      setState(() => _sources = next);
    }
    await installMitmRulesFor(core, localRules);
    await _load();
  }

  String? _validateName(String? value, {MitmRuleSource? source}) {
    final appLocalizations = context.appLocalizations;
    final name = value?.trim() ?? '';
    if (name.isEmpty) return null;
    final taken = _sources.any(
      (item) => item.url != source?.url && item.name == name,
    );
    return taken ? appLocalizations.existsTip(appLocalizations.name) : null;
  }

  String? _validateUrl(String? value, {MitmRuleSource? source}) {
    final appLocalizations = context.appLocalizations;
    final url = value?.trim() ?? '';
    if (url.isEmpty) return appLocalizations.emptyTip(appLocalizations.url);
    if (!url.isUrl) return appLocalizations.urlTip(appLocalizations.url);
    final taken = _sources.any(
      (item) => item.url != source?.url && item.url == url,
    );
    return taken ? appLocalizations.existsTip(appLocalizations.url) : null;
  }

  Future<void> _handleAdd() async {
    final appLocalizations = context.appLocalizations;
    final res = await showNamedUrlForm(
      context,
      title: appLocalizations.mitmRuleSources,
      labelValidator: (value) => _validateName(value),
      urlValidator: (value) => _validateUrl(value),
    );
    if (res == null || !mounted) return;
    final url = res.url.trim();
    final name = res.label.trim().isEmpty
        ? defaultRuleSourceName(url)
        : res.label.trim();
    // The first download is what tells the user the address works, so it runs
    // before the entry is reported as added.
    setState(() => _busy = true);
    final result = await fetchRuleSet(url);
    await _save([
      ..._sources,
      MitmRuleSource(
        name: name,
        url: url,
        lastUpdateTime: result.ok ? DateTime.now() : null,
      ),
    ]);
    if (!mounted) return;
    setState(() => _busy = false);
    await dialogs.showMessage(
      context: context,
      message: TextSpan(
        text: result.ok
            ? appLocalizations.mitmRuleSourceAdded(name)
            : appLocalizations.mitmRuleSourceFetchFailed(name),
      ),
    );
  }

  Future<void> _handleEdit(MitmRuleSource source) async {
    final appLocalizations = context.appLocalizations;
    final res = await showNamedUrlForm(
      context,
      title: appLocalizations.edit,
      label: source.name,
      url: source.url,
      labelValidator: (value) => _validateName(value, source: source),
      urlValidator: (value) => _validateUrl(value, source: source),
    );
    if (res == null || !mounted) return;
    final url = res.url.trim();
    final name = res.label.trim().isEmpty
        ? defaultRuleSourceName(url)
        : res.label.trim();
    if (url == source.url) {
      await _save([
        for (final item in _sources)
          item.url == source.url ? item.copyWith(name: name) : item,
      ]);
      return;
    }
    // A new address is only worth storing once it answers: keeping a renamed
    // entry that never loads, while the copy of the old address is dropped,
    // would lose the rules without saying so.
    setState(() => _busy = true);
    final result = await fetchRuleSet(url);
    if (!result.ok) {
      if (!mounted) return;
      setState(() => _busy = false);
      await dialogs.showMessage(
        context: context,
        message: TextSpan(
          text: appLocalizations.mitmRuleSourceFetchFailed(name),
        ),
      );
      return;
    }
    await deleteRuleSetCache(source.url);
    await _save([
      for (final item in _sources)
        item.url == source.url
            ? MitmRuleSource(
                name: name,
                url: url,
                lastUpdateTime: DateTime.now(),
              )
            : item,
    ]);
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _handleRefresh(MitmRuleSource source) async {
    final appLocalizations = context.appLocalizations;
    setState(() => _busy = true);
    final result = await fetchRuleSet(source.url);
    if (result.ok) {
      await _save([
        for (final item in _sources)
          item.url == source.url
              ? item.copyWith(lastUpdateTime: DateTime.now())
              : item,
      ]);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      await dialogs.showMessage(
        context: context,
        message: TextSpan(
          text: appLocalizations.mitmRuleSourceFetchFailed(source.name),
        ),
      );
    }
  }

  Future<void> _handleRefreshAll() async {
    final appLocalizations = context.appLocalizations;
    final total = _sources.length;
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

  Future<void> _handleDelete(MitmRuleSource source) async {
    final appLocalizations = context.appLocalizations;
    final res = await dialogs.showMessage(
      context: context,
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.deleteTip(source.name)),
      destructive: true,
      confirmText: appLocalizations.delete,
    );
    if (res != true || !mounted) return;
    await deleteRuleSetCache(source.url);
    await _save([
      for (final item in _sources)
        if (item.url != source.url) item,
    ]);
  }

  List<CommonPopupMenuItem> _buildMenuItems(MitmRuleSource source) {
    final appLocalizations = context.appLocalizations;
    return [
      CommonPopupMenuItem(
        glyph: AppGlyphs.edit,
        label: appLocalizations.edit,
        onPressed: () => _handleEdit(source),
      ),
      CommonPopupMenuItem(
        glyph: AppGlyphs.sync,
        label: appLocalizations.sync,
        onPressed: () => _handleRefresh(source),
      ),
      CommonPopupMenuItem(
        danger: true,
        glyph: AppGlyphs.delete,
        label: appLocalizations.delete,
        onPressed: () => _handleDelete(source),
      ),
    ];
  }

  Widget _buildItem(MitmRuleSource source) {
    final count = _counts[source.url];
    return ContextMenuRegion(
      menuItems: _buildMenuItems(source),
      child: DecorationListItem(
        contentPadding: const EdgeInsets.only(left: 16, right: 16),
        title: ChipTitle(
          title: source.name,
          chip: count == null || count == 0 ? null : count.compact,
        ),
        subtitle: Text(
          source.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.listCaptionStyle,
        ),
        trailing: _SourceTrailing(source: source),
        onPressed: () => _handleEdit(source),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      title: appLocalizations.mitmRuleSources,
      isLoading: _busy,
      actions: [
        if (_sources.isNotEmpty)
          IconButton(
            tooltip: appLocalizations.sync,
            onPressed: _busy ? null : _handleRefreshAll,
            icon: const GlyphIcon(AppGlyphs.sync),
          ),
        IconButton(
          tooltip: appLocalizations.add,
          onPressed: _busy ? null : _handleAdd,
          icon: const GlyphIcon(AppGlyphs.addCircle),
        ),
      ],
      body: NullStatusSwitcher(
        isLoading: _loading,
        isEmpty: _sources.isEmpty,
        nullStatus: NullStatus(
          label: appLocalizations.mitmRuleSourcesEmpty,
          illustration: NullStatusIllustration.rules,
        ),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
            top: context.contentTopPadding,
            bottom: 16 + context.bottomInset,
          ),
          children: [
            generateSection(
              items: [for (final source in _sources) _buildItem(source)],
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceTrailing extends StatelessWidget {
  const _SourceTrailing({required this.source});

  final MitmRuleSource source;

  @override
  Widget build(BuildContext context) {
    final lastUpdateTime = source.lastUpdateTime;
    if (lastUpdateTime == null) {
      return Text(
        context.appLocalizations.mitmRuleSourceNeverFetched,
        style: context.listCaptionStyle,
      );
    }
    return LastUpdateTimeText(
      lastUpdateDate: lastUpdateTime,
      compact: true,
      style: context.listCaptionStyle,
    );
  }
}
