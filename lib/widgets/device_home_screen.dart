import 'package:flutter/material.dart';
import '../i18n.dart';
import '../models/remote_models.dart';
import '../theme/app_theme.dart';
import 'more_menu.dart';

class DeviceHomeScreen extends StatelessWidget {
  const DeviceHomeScreen({
    super.key,
    required this.devices,
    required this.activeDeviceId,
    required this.connected,
    required this.status,
    required this.topInset,
    required this.bottomInset,
    required this.onOpen,
    required this.onConnect,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    required this.onSettings,
    required this.onCheckUpdate,
    required this.onAbout,
  });

  final List<StoredDevice> devices;
  final String? activeDeviceId;
  final bool connected;
  final String status;
  final double topInset;
  final double bottomInset;
  final ValueChanged<StoredDevice> onOpen;
  final ValueChanged<StoredDevice> onConnect;
  final VoidCallback onAdd;
  final ValueChanged<StoredDevice> onEdit;
  final ValueChanged<StoredDevice> onDelete;
  final VoidCallback onSettings;
  final VoidCallback onCheckUpdate;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final prefs = AppPreferences.of(context);
    return Container(
      color: AppColors.bgBase,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.l,
        topInset + AppSpacing.l,
        AppSpacing.l,
        bottomInset + AppSpacing.l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Codux',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      prefs.t('device.homeHint'),
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
              _CircleButton(icon: Icons.settings_outlined, onTap: onSettings),
              const SizedBox(width: AppSpacing.s),
              MoreMenu(
                onAddDevice: onAdd,
                onCheckUpdate: onCheckUpdate,
                onAbout: onAbout,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Expanded(
            child: devices.isEmpty
                ? _EmptyDeviceState(accent: accent, onAdd: onAdd)
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: devices.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.s),
                    itemBuilder: (context, index) {
                      final device = devices[index];
                      final isActive = device.deviceId == activeDeviceId;
                      final isConnected = isActive && connected;
                      final state = isActive
                          ? status
                          : prefs.t('app.notConnected');
                      return _SwipeDeviceTile(
                        device: device,
                        connected: isConnected,
                        status: state,
                        accent: accent,
                        onOpen: () => onOpen(device),
                        onConnect: () => onConnect(device),
                        onEdit: () => onEdit(device),
                        onDelete: () => onDelete(device),
                      );
                    },
                  ),
          ),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: accent.withValues(alpha: 0.16),
                foregroundColor: accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: Text(prefs.t('device.addByScan')),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.bgElevated,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(
        width: 42,
        height: 42,
        child: Icon(icon, size: 20, color: AppColors.textPrimary),
      ),
    ),
  );
}

class _EmptyDeviceState extends StatelessWidget {
  const _EmptyDeviceState({required this.accent, required this.onAdd});
  final Color accent;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final prefs = AppPreferences.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_other_outlined, size: 48, color: accent),
          const SizedBox(height: AppSpacing.m),
          Text(
            prefs.t('device.emptyTitle'),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: AppTextSize.title,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          Text(
            prefs.t('device.emptySubtitle'),
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: AppTextSize.small,
            ),
          ),
          const SizedBox(height: AppSpacing.l),
          FilledButton(
            onPressed: onAdd,
            child: Text(prefs.t('device.scanAdd')),
          ),
        ],
      ),
    );
  }
}

class _SwipeDeviceTile extends StatefulWidget {
  const _SwipeDeviceTile({
    required this.device,
    required this.connected,
    required this.status,
    required this.accent,
    required this.onOpen,
    required this.onConnect,
    required this.onEdit,
    required this.onDelete,
  });

  final StoredDevice device;
  final bool connected;
  final String status;
  final Color accent;
  final VoidCallback onOpen;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_SwipeDeviceTile> createState() => _SwipeDeviceTileState();
}

class _SwipeDeviceTileState extends State<_SwipeDeviceTile> {
  double _offset = 0;
  static const _actionWidth = 132.0;

  void _settle() {
    setState(() => _offset = _offset.abs() > 54 ? -_actionWidth : 0);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = AppPreferences.of(context);
    final title = widget.device.hostName?.isNotEmpty == true
        ? widget.device.hostName!
        : widget.device.name;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: SizedBox(
        height: 74,
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _actionWidth,
                  child: Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: prefs.t('device.edit'),
                          color: widget.accent.withValues(alpha: 0.16),
                          textColor: widget.accent,
                          onTap: widget.onEdit,
                        ),
                      ),
                      Expanded(
                        child: _ActionButton(
                          label: prefs.t('device.delete'),
                          color: AppColors.danger.withValues(alpha: 0.16),
                          textColor: AppColors.danger,
                          onTap: widget.onDelete,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              left: _offset,
              right: -_offset,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _offset = (_offset + details.delta.dx).clamp(
                      -_actionWidth,
                      0,
                    );
                  });
                },
                onHorizontalDragEnd: (_) => _settle(),
                child: Material(
                  color: AppColors.bgSurface,
                  child: InkWell(
                    onTap: widget.connected ? widget.onOpen : widget.onConnect,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.m,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: widget.connected
                                  ? widget.accent.withValues(alpha: 0.14)
                                  : AppColors.bgElevated,
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Icon(
                              Icons.desktop_mac_outlined,
                              color: widget.connected
                                  ? widget.accent
                                  : AppColors.textMuted,
                              size: 21,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.m),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: widget.connected
                                        ? AppColors.textPrimary
                                        : AppColors.textSecondary,
                                    fontSize: AppTextSize.body,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.device.server,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textSubtle,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpacing.s),
                          _StatusPill(
                            connected: widget.connected,
                            status: widget.status,
                            accent: widget.accent,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.onTap,
  });
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    child: InkWell(
      onTap: onTap,
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: AppTextSize.small,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.connected,
    required this.status,
    required this.accent,
  });
  final bool connected;
  final String status;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: connected
            ? AppColors.success.withValues(alpha: 0.14)
            : AppColors.bgElevated,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: connected ? AppColors.success : AppColors.textMuted,
          fontSize: AppTextSize.small,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
