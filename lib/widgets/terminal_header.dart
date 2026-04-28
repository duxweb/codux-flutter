import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'project_action_menu.dart';

class TerminalHeader extends StatelessWidget {
  const TerminalHeader({
    super.key,
    required this.topInset,
    required this.onBack,
    required this.onEditProject,
    required this.onAddProject,
    required this.onRemoveProject,
    required this.activeMode,
    required this.onTerminal,
    required this.onStats,
    required this.onFiles,
  });

  final double topInset;
  final VoidCallback onBack;
  final VoidCallback onEditProject;
  final VoidCallback onAddProject;
  final VoidCallback onRemoveProject;
  final String activeMode;
  final VoidCallback onTerminal;
  final VoidCallback onStats;
  final VoidCallback onFiles;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Material(
      color: AppColors.bgBase,
      child: Container(
        height: AppLayout.topBarHeight + topInset,
        padding: EdgeInsets.only(top: topInset),
        decoration: const BoxDecoration(color: AppColors.bgBase),
        child: Row(
          children: [
            const SizedBox(width: AppSpacing.s),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                color: AppColors.textPrimary,
              ),
            ),
            Expanded(
              child: Center(
                child: _ModeCapsule(
                  accent: accent,
                  activeMode: activeMode,
                  onTerminal: onTerminal,
                  onStats: onStats,
                  onFiles: onFiles,
                ),
              ),
            ),
            ProjectActionMenu(
              onEditProject: onEditProject,
              onAddProject: onAddProject,
              onRemoveProject: onRemoveProject,
            ),
            const SizedBox(width: AppSpacing.s),
          ],
        ),
      ),
    );
  }
}

class _ModeCapsule extends StatelessWidget {
  const _ModeCapsule({
    required this.accent,
    required this.activeMode,
    required this.onTerminal,
    required this.onStats,
    required this.onFiles,
  });
  final Color accent;
  final String activeMode;
  final VoidCallback onTerminal;
  final VoidCallback onStats;
  final VoidCallback onFiles;

  @override
  Widget build(BuildContext context) => Container(
    height: 38,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: AppColors.bgSurface,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CapsuleItem(
          icon: Icons.terminal,
          active: activeMode == 'terminal',
          accent: accent,
          onTap: onTerminal,
        ),
        _CapsuleItem(
          icon: Icons.bar_chart_rounded,
          active: activeMode == 'stats',
          accent: accent,
          onTap: onStats,
        ),
        _CapsuleItem(
          icon: Icons.folder_open_rounded,
          active: activeMode == 'files',
          accent: accent,
          onTap: onFiles,
        ),
      ],
    ),
  );
}

class _CapsuleItem extends StatelessWidget {
  const _CapsuleItem({
    required this.icon,
    required this.active,
    required this.accent,
    this.onTap,
  });
  final IconData icon;
  final bool active;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(999),
    onTap: onTap,
    child: Container(
      width: 46,
      height: 32,
      decoration: BoxDecoration(
        color: active ? accent.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Icon(
        icon,
        color: active ? accent : AppColors.textMuted,
        size: active ? 19 : 18,
      ),
    ),
  );
}
