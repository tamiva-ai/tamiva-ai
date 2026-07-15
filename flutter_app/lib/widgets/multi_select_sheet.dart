import 'package:flutter/material.dart';
import '../theme/tamiva_theme.dart';

/// Full-height searchable multi-select sheet.
/// Returns the selected values when closed.
///
/// Pass [selected] to set the current selection (the widget is
/// reactive - the parent can update selection after open).
/// Pass [maxSelection] to cap the number of choices - if the user
/// hits the cap, further taps flash a hint and don't select.
class MultiSelectSheet extends StatefulWidget {
  final String title;
  final String searchHint;
  final List<String> options;
  final List<String> selected;
  final int? maxSelection;

  /// Optional leading widget per option (e.g. colour swatches for a
  /// palette picker). Rendered between the checkbox and the label.
  final Widget Function(String option)? optionLeadingBuilder;

  /// Optional text style per option (e.g. the actual font family for a
  /// typography picker). Merged onto the base label style.
  final TextStyle? Function(String option)? optionTextStyleBuilder;

  const MultiSelectSheet({
    super.key,
    required this.title,
    required this.options,
    this.selected = const [],
    this.searchHint = 'Search…',
    this.maxSelection,
    this.optionLeadingBuilder,
    this.optionTextStyleBuilder,
  });

  @override
  State<MultiSelectSheet> createState() => _MultiSelectSheetState();
}

class _MultiSelectSheetState extends State<MultiSelectSheet> {
  late final Set<String> _selected;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected = _hydrateSelection(widget.selected);
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
      });
    });
  }

  /// For single-select pickers, returning users may have multiple
  /// comma-separated values from a prior schema (e.g. industry was
  /// previously a multi-select). Keep the first one as a sensible
  /// default so the UI shows a single radio checked; the user can
  /// then change it via the new radio behavior.
  Set<String> _hydrateSelection(List<String> incoming) {
    if (widget.maxSelection == 1 && incoming.length > 1) {
      return {incoming.first};
    }
    return incoming.toSet();
  }

  @override
  void didUpdateWidget(covariant MultiSelectSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the internal selection in sync if the parent updates
    // widget.selected while the sheet is open.
    if (!_setsEqual(_selected, widget.selected.toSet())) {
      final next = _hydrateSelection(widget.selected);
      _selected
        ..clear()
        ..addAll(next);
    }
  }

  bool _setsEqual(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final s in a) {
      if (!b.contains(s)) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<String> get _filteredOptions {
    if (_query.isEmpty) return widget.options;
    return widget.options
        .where((o) => o.toLowerCase().contains(_query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: TamivaColors.surfaceRaised,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(TamivaRadii.lg),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: TamivaColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: textTheme.titleLarge,
                      ),
                    ),
                    if (widget.maxSelection != null)
                      Text(
                        "${_selected.length}/${widget.maxSelection}",
                        style: textTheme.labelMedium?.copyWith(
                          color: _selected.length == widget.maxSelection
                              ? TamivaColors.gold
                              : TamivaColors.textFaint,
                        ),
                      )
                    else if (_selected.isNotEmpty)
                      Text(
                        "${_selected.length} selected",
                        style: textTheme.labelMedium?.copyWith(
                          color: TamivaColors.gold,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: widget.searchHint,
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 20,
                      color: TamivaColors.textFaint,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _filteredOptions.isEmpty
                    ? Center(
                        child: Text(
                          "No matches",
                          style: textTheme.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _filteredOptions.length,
                        itemBuilder: (context, index) {
                          final option = _filteredOptions[index];
                          final checked = _selected.contains(option);
                          final leading =
                              widget.optionLeadingBuilder?.call(option);
                          final customStyle =
                              widget.optionTextStyleBuilder?.call(option);
                          final baseStyle = textTheme.bodyLarge?.copyWith(
                            color: checked
                                ? TamivaColors.textPrimary
                                : TamivaColors.textSecondary,
                            fontWeight:
                                checked ? FontWeight.w600 : FontWeight.w400,
                          );
                          return InkWell(
                            onTap: () {
                              setState(() {
                                if (checked) {
                                  _selected.remove(option);
                                  return;
                                }
                                // v37.1: maxSelection == 1 is single-select
                                // (radio behavior) - tapping any unchecked
                                // option replaces the existing one instead
                                // of being blocked with a SnackBar.
                                if (widget.maxSelection == 1) {
                                  _selected
                                    ..clear()
                                    ..add(option);
                                  return;
                                }
                                if (widget.maxSelection != null &&
                                    _selected.length >= widget.maxSelection!) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        "Pick up to ${widget.maxSelection} only",
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                _selected.add(option);
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    // v37.1: radio affordance for
                                    // single-select pickers (maxSelection
                                    // == 1) so the user reads the list as
                                    // "pick one" rather than "tick several".
                                    checked
                                        ? (widget.maxSelection == 1
                                            ? Icons.radio_button_checked
                                            : Icons.check_box)
                                        : (widget.maxSelection == 1
                                            ? Icons.radio_button_unchecked
                                            : Icons.check_box_outline_blank),
                                    color: checked
                                        ? TamivaColors.gold
                                        : TamivaColors.textFaint,
                                  ),
                                  const SizedBox(width: 14),
                                  if (leading != null) ...[
                                    leading,
                                    const SizedBox(width: 14),
                                  ],
                                  Expanded(
                                    child: Text(
                                      option,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: customStyle == null
                                          ? baseStyle
                                          : baseStyle?.merge(customStyle),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: GradientCtaButton(
                    onPressed: () {
                      Navigator.pop(context, _selected.toList());
                    },
                    child: Text(
                      _selected.isEmpty
                          ? "Done"
                          : "Use ${_selected.length} →",
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
