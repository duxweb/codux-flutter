import 'package:flutter/material.dart';
import '../i18n.dart';
import '../models/remote_models.dart';
import '../theme/app_theme.dart';

class ProjectTabBar extends StatelessWidget {
  const ProjectTabBar({
    super.key,
    required this.projects,
    required this.selectedId,
    required this.onSelect,
    required this.onRefresh,
    required this.onRebuild,
  });

  final List<ProjectInfo> projects;
  final String? selectedId;
  final ValueChanged<ProjectInfo> onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onRebuild;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final prefs = AppPreferences.of(context);
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
                  if (projects.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s,
                        ),
                        child: Text(
                          prefs.t('app.noProjects'),
                          style: const TextStyle(
                            color: AppColors.textSubtle,
                            fontSize: 12,
                          ),
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
                    child: Icon(Icons.tune_rounded, color: accent, size: 16),
                  ),
                  onSelected: (value) {
                    if (value == 'refresh') {
                      onRefresh();
                      return;
                    }
                    if (value == 'rebuild') {
                      onRebuild();
                    }
                  },
                  itemBuilder: (context) => [
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

class _ProjectMenuItem extends StatelessWidget {
  const _ProjectMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: AppColors.textPrimary),
      const SizedBox(width: AppSpacing.s),
      Text(
        label,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
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
