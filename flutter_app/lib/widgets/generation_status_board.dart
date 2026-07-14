import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../theme/tamiva_theme.dart';

/// A live status board showing each artifact (logo / carousel / film /
/// website) as a row with a state-specific icon, elapsed time, and a
/// short status message.
///
/// Polls [apiClient.getBusinessProfileProjects] every [pollInterval] and
/// rebuilds the rows. When every "real" row (logo, carousel, video) is
/// either ready or failed, polling stops and [onAllReachedTerminalState]
/// is fired so the parent can swap to the brand-kit reveal view.
///
/// v37: Brand Colors and Typography rows were removed (the surfaces
/// behind them no longer exist in the brand kit). Website is a locked
/// Pro feature so its row is always `notStarted` — no backend project
/// is created until the user upgrades.
class GenerationStatusBoard extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;
  final Duration pollInterval;

  /// Called once every row reaches a terminal state (ready/failed/
  /// not-started). Useful for swapping to a different view.
  final VoidCallback? onAllReachedTerminalState;

  /// Called when the user taps any row. The [artifactKey] is a
  /// stable identifier ('logo' | 'carousel' | 'film' | 'website').
  /// The [project] is null for rows that haven't been started yet,
  /// otherwise it's the current snapshot from the backend.
  ///
  /// The parent decides what to do - usually:
  ///   * Static artifacts (colors, typography) -> open static preview.
  ///   * Generated artifacts at ready state -> openProjectPreview().
  ///   * Generated artifacts at notStarted/failed -> start a new
  ///     generation (show cost-estimate confirmation first).
  ///   * Generated artifacts at inProgress -> do nothing (just wait).
  ///
  /// If null, rows remain static (still show status + elapsed time,
  /// but tapping does nothing).
  final void Function(String artifactKey, Project? project)? onRowTap;

  const GenerationStatusBoard({
    super.key,
    required this.apiClient,
    required this.businessProfileId,
    this.pollInterval = const Duration(seconds: 3),
    this.onAllReachedTerminalState,
    this.onRowTap,
  });

  @override
  State<GenerationStatusBoard> createState() => _GenerationStatusBoardState();
}

class _GenerationStatusBoardState extends State<GenerationStatusBoard> {
  BusinessProfileProjects? _snapshot;
  Timer? _pollTimer;
  DateTime? _firstStartedAt;
  bool _notifiedTerminal = false;

  @override
  void initState() {
    super.initState();
    _firstStartedAt = DateTime.now();
    _poll();
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final snap = await widget.apiClient.getBusinessProfileProjects(
        widget.businessProfileId,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
      });
      if (_allTerminal(snap)) {
        _pollTimer?.cancel();
        if (!_notifiedTerminal && widget.onAllReachedTerminalState != null) {
          _notifiedTerminal = true;
          widget.onAllReachedTerminalState!();
        }
      }
    } catch (e) {
      // Transient poll failure - just keep retrying on the next tick.
      // We don't reset state; the user still sees the last-known status.
    }
  }

  /// Considered terminal when every row has either succeeded, failed,
  /// or is a placeholder (colors/typography). We don't wait on those
  /// two because they're not driven by a backend generation in v7.
  bool _allTerminal(BusinessProfileProjects snap) {
    bool terminal(Project? p) =>
        p == null || p.isReady || p.isFailed;
    return terminal(snap.logo) &&
        terminal(snap.carousel) &&
        terminal(snap.video);
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snapshot;

    if (snap == null) {
      // First poll hasn't returned yet. Show a small placeholder so the
      // screen isn't a hard empty box for the initial 0-3s.
      return _BoardScaffold(
        elapsed: _elapsed(),
        children: const [
          _StatusRow.shimmer(label: 'Logo'),
          _StatusRow.shimmer(label: 'Social carousel'),
          _StatusRow.shimmer(label: '10-sec brand film'),
          _StatusRow.shimmer(label: 'Website'),
        ],
      );
    }

    return _BoardScaffold(
      elapsed: _elapsed(),
      children: [
        _StatusRow.fromProject(
          label: 'Logo',
          project: snap.logo,
          onTap: () => widget.onRowTap?.call('logo', snap.logo),
        ),
        _StatusRow.fromProject(
          label: 'Social carousel',
          project: snap.carousel,
          onTap: () => widget.onRowTap?.call('carousel', snap.carousel),
        ),
        _StatusRow.fromProject(
          label: '10-sec brand film',
          project: snap.video,
          onTap: () => widget.onRowTap?.call('film', snap.video),
        ),
        _StatusRow.fromProject(
          label: 'Website',
          project: null,
          onTap: () => widget.onRowTap?.call('website', null),
        ),
      ],
    );
  }

  Duration _elapsed() {
    if (_firstStartedAt == null) return Duration.zero;
    return DateTime.now().difference(_firstStartedAt!);
  }
}

class _BoardScaffold extends StatelessWidget {
  final Duration elapsed;
  final List<_StatusRow> children;

  const _BoardScaffold({
    required this.elapsed,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final totalSeconds = elapsed.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final elapsedLabel = minutes > 0
        ? '${minutes}m ${seconds}s elapsed'
        : '${seconds}s elapsed';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('YOUR BRAND KIT', style: textTheme.labelMedium),
              const Spacer(),
              Text(
                elapsedLabel,
                style: textTheme.bodyMedium?.copyWith(
                  color: TamivaColors.gold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "Here's everything being generated for your brand. Tap any ready tile to view it.",
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final _RowState state;
  final String? message;
  final Duration? elapsed;
  final VoidCallback? onTap;

  const _StatusRow({
    required this.label,
    required this.state,
    this.message,
    this.elapsed,
    this.onTap,
  });

  /// Placeholder-style row for Colors and Typography which don't have
  /// backend generation wired up yet.
  const _StatusRow.placeholder({required String label})
      : this(
          label: label,
          state: _RowState.placeholder,
          message: 'Included in Tamiva Pro',
          elapsed: null,
        );

  /// First-load shimmer before we have any snapshot back.
  const _StatusRow.shimmer({required String label})
      : this(
          label: label,
          state: _RowState.loading,
          message: 'Connecting…',
          elapsed: null,
        );

  factory _StatusRow.fromProject({
    required String label,
    required Project? project,
    /// Single callback fired for every tap regardless of state. The
    /// parent decides whether to actually start generation, open a
    /// preview, or do nothing. If null the row is static (no tap).
    VoidCallback? onTap,
  }) {
    if (project == null) {
      return _StatusRow(
        label: label,
        state: _RowState.notStarted,
        message: 'Tap to generate',
        elapsed: null,
        onTap: onTap,
      );
    }

    final elapsed = project.elapsedSinceCreation(DateTime.now());

    if (project.isReady) {
      return _StatusRow(
        label: label,
        state: _RowState.ready,
        message: 'Ready · ${_formatElapsed(elapsed)}',
        elapsed: elapsed,
        onTap: onTap,
      );
    }
    if (project.isFailed) {
      return _StatusRow(
        label: label,
        state: _RowState.failed,
        message: 'Failed · tap to retry',
        elapsed: elapsed,
        onTap: onTap,
      );
    }

    // In progress - queued or generating.
    final statusLabel = project.status == 'queued' ? 'Queued' : 'Generating';
    return _StatusRow(
      label: label,
      state: _RowState.inProgress,
      message: '$statusLabel · ${_formatElapsed(elapsed)}',
      elapsed: elapsed,
      onTap: null, // disabled mid-flight - parent should ignore taps here
    );
  }

  static String _formatElapsed(Duration d) {
    if (d.inSeconds < 1) return '<1s';
    final seconds = d.inSeconds;
    final minutes = seconds ~/ 60;
    final remSeconds = seconds % 60;
    if (minutes == 0) return '${seconds}s';
    return '${minutes}m ${remSeconds.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final icon = switch (state) {
      _RowState.loading =>
        const Icon(Icons.refresh, size: 18, color: TamivaColors.textFaint),
      _RowState.placeholder =>
        const Icon(Icons.auto_awesome_outlined, size: 18, color: TamivaColors.textFaint),
      _RowState.notStarted =>
        const Icon(Icons.circle_outlined, size: 18, color: TamivaColors.textFaint),
      _RowState.inProgress =>
        const Icon(Icons.refresh, size: 18, color: TamivaColors.gold),
      _RowState.ready =>
        const Icon(Icons.check_circle, size: 18, color: TamivaColors.success),
      _RowState.failed =>
        const Icon(Icons.error_outline, size: 18, color: TamivaColors.error),
    };

    // Animated spinner for in-progress rows; static icons otherwise.
    final leadingIcon = state == _RowState.inProgress
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(TamivaColors.gold),
            ),
          )
        : icon;

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          leadingIcon,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: textTheme.titleMedium?.copyWith(
                    color: TamivaColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message ?? '',
                  style: textTheme.bodyMedium?.copyWith(
                    color: state == _RowState.failed
                        ? TamivaColors.error
                        : TamivaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Show a chevron on tap-able rows so the user knows they're
          // interactive. The chevron itself is non-functional.
          if (onTap != null)
            const Icon(Icons.chevron_right,
                color: TamivaColors.gold, size: 18),
        ],
      ),
    );

    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(TamivaRadii.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(TamivaRadii.sm),
        onTap: onTap,
        child: row,
      ),
    );
  }
}

enum _RowState { loading, placeholder, notStarted, inProgress, ready, failed }
              