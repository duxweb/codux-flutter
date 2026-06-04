import 'package:flutter/material.dart';
import '../i18n.dart';
import '../models/remote_models.dart';
import '../theme/app_theme.dart';

class ProjectTabBar extends StatelessWidget {
  const ProjectTabBar({
    super.key,
    required this.projects,
    required this.selectedId,
    required this.loading,
    required this.terminals,
    required this.activeTerminalId,
    required this.onSelect,
    required this.onSelectTerminal,
    required this.onRefresh,
    required this.onCreateTerminal,
    required this.onCloseTerminal,
    required this.onRebuild,
  });

  final List<ProjectInfo> projects;
  final String? selectedId;
  final bool loading;
  final List<TerminalInfo> terminals;
  final String? activeTerminalId;
  final ValueChanged<ProjectInfo> onSelect;
  final ValueChanged<TerminalInfo> onSelectTerminal;
  final VoidCallback onRefresh;
  final VoidCallback onCreateTerminal;
  final VoidCallback? onCloseTerminal;
  final VoidCallback onRebuild;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final prefs = AppPreferences.of(context);
    final splitTerminals = terminals
        .where((terminal) => _isSplitTerminal(terminal))
        .toList();
    final tabTerminals = terminals
        .where((terminal) => !_isSplitTerminal(terminal))
        .toList();
    return Material(
      color: AppColors.bgSurface,
      child: Container(
        height: AppLayout.tabBarHeight,
        decoration: const BoxDecoration(color: AppColors.bgSurface),
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.l,
                  vertical: AppSpacing.s,
                ),
                children: [
                  if (projects.isEmpty && !loading)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              prefs.t('app.noProjects'),
                              style: const TextStyle(
                                color: AppColors.textSubtle,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  for (final project in projects)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.s),
                      child: _ProjectTab(
                        project: project,
                        active: project.id == selectedId,
                        accent: accent,
                        onTap: () => onSelect(project),
                      ),
                    ),
                ],
              ),
            ),
            Container(width: 0.5, height: 24, color: AppColors.border),
            const SizedBox(width: AppSpacing.s),
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.s),
              child: SizedBox(
                width: 36,
                height: 32,
                child: PopupMenuButton<String>(
                  tooltip: '',
                  padding: EdgeInsets.zero,
                  position: PopupMenuPosition.under,
                  offset: const Offset(0, 4),
                  color: AppColors.bgSurface,
                  elevation: 12,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    side: const BorderSide(color: AppColors.border, width: 0.5),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.bgElevated,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Center(
                      child: loading
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : Icon(Icons.tune_rounded, color: accent, size: 16),
                    ),
                  ),
                  onSelected: (value) {
                    if (value == 'refresh') {
                      onRefresh();
                      return;
                    }
                    if (value == 'create-terminal') {
                      onCreateTerminal();
                      return;
                    }
                    if (value == 'close-terminal') {
                      onCloseTerminal?.call();
                      return;
                    }
                    if (value == 'rebuild') {
                      onRebuild();
                      return;
                    }
                    if (value.startsWith('terminal:')) {
                      final id = value.substring('terminal:'.length);
                      final matches = terminals.where((item) => item.id == id);
                      if (matches.isNotEmpty) onSelectTerminal(matches.first);
                    }
                  },
                  itemBuilder: (context) => [
                    ..._terminalMenuSection(
                      title: prefs.t('app.splits'),
                      terminals: splitTerminals,
                      activeTerminalId: activeTerminalId,
                      terminalLabel: prefs.t('app.terminal'),
                    ),
                    if (splitTerminals.isNotEmpty && tabTerminals.isNotEmpty)
                      const PopupMenuItem<String>(
                        enabled: false,
                        height: 10,
                        padding: EdgeInsets.zero,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.m,
                          ),
                          child: SizedBox(
                            height: 1,
                            child: ColoredBox(color: AppColors.textSubtle),
                          ),
                        ),
                      ),
                    ..._terminalMenuSection(
                      title: prefs.t('app.tabs'),
                      terminals: tabTerminals,
                      activeTerminalId: activeTerminalId,
                      terminalLabel: prefs.t('app.terminal'),
                    ),
                    if (terminals.isNotEmpty)
                      const PopupMenuItem<String>(
                        enabled: false,
                        height: 10,
                        padding: EdgeInsets.zero,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.m,
                          ),
                          child: SizedBox(
                            height: 1,
                            child: ColoredBox(color: AppColors.textSubtle),
                          ),
                        ),
                      ),
                    PopupMenuItem(
                      value: 'create-terminal',
                      height: 40,
                      child: _ProjectMenuItem(
                        icon: Icons.add_rounded,
                        label: prefs.t('app.newTerminal'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'close-terminal',
                      enabled: onCloseTerminal != null,
                      height: 40,
                      child: _ProjectMenuItem(
                        icon: Icons.close_rounded,
                        label: prefs.t('app.closeSplit'),
                        muted: onCloseTerminal == null,
                      ),
                    ),
                    const PopupMenuItem<String>(
                      enabled: false,
                      height: 10,
                      padding: EdgeInsets.zero,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.m),
                        child: SizedBox(
                          height: 1,
                          child: ColoredBox(color: AppColors.textSubtle),
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'refresh',
                      height: 40,
                      child: _ProjectMenuItem(
                        icon: Icons.refresh_rounded,
                        label: prefs.t('app.refresh'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'rebuild',
                      height: 40,
                      child: _ProjectMenuItem(
                        icon: Icons.restart_alt_rounded,
                        label: prefs.t('project.rebuildTerminal'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isSplitTerminal(TerminalInfo terminal) {
  return terminal.id.isNotEmpty && terminal.projectId.isNotEmpty;
}

List<PopupMenuEntry<String>> _terminalMenuSection({
  required String title,
  required List<TerminalInfo> terminals,
  required String? activeTerminalId,
  required String terminalLabel,
}) {
  if (terminals.isEmpty) return const [];
  return [
    PopupMenuItem<String>(
      enabled: false,
      height: 30,
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
      ),
    ),
    for (var i = 0; i < terminals.length; i += 1)
      PopupMenuItem(
        value: 'terminal:${terminals[i].id}',
        height: 42,
        child: _TerminalMenuItem(
          index: i + 1,
          active: terminals[i].id == activeTerminalId,
          terminalLabel: terminalLabel,
        ),
      ),
  ];
}

class _ProjectMenuItem extends StatelessWidget {
  const _ProjectMenuItem({
    required this.icon,
    required this.label,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        icon,
        size: 18,
        color: muted ? AppColors.textSubtle : AppColors.textPrimary,
      ),
      const SizedBox(width: AppSpacing.s),
      Text(
        label,
        style: TextStyle(
          color: muted ? AppColors.textSubtle : AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
}

class _TerminalMenuItem extends StatelessWidget {
  const _TerminalMenuItem({
    required this.index,
    required this.active,
    required this.terminalLabel,
  });

  final int index;
  final bool active;
  final String terminalLabel;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Row(
      children: [
        Expanded(
          child: Text(
            '$terminalLabel $index',
            style: TextStyle(
              color: active ? accent : AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        if (active)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.s),
            child: Icon(Icons.check_rounded, size: 18, color: accent),
          ),
      ],
    );
  }
}

class _ProjectTab extends StatelessWidget {
  const _ProjectTab({
    required this.project,
    required this.active,
    required this.accent,
    required this.onTap,
  });
  final ProjectInfo project;
  final bool active;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? accent.withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? accent : AppColors.textMuted,
                fontSize: 14,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
