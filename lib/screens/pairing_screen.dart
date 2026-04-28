import 'package:flutter/material.dart';
import '../i18n.dart';
import '../theme/app_theme.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.status,
    required this.qrController,
    required this.topInset,
    required this.bottomInset,
    required this.showBack,
    required this.onScan,
    required this.onPair,
    required this.onPaste,
    required this.onBack,
  });

  final String status;
  final TextEditingController qrController;
  final double topInset;
  final double bottomInset;
  final bool showBack;
  final VoidCallback onScan;
  final VoidCallback onPair;
  final VoidCallback onPaste;
  final VoidCallback onBack;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  bool _showManual = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final prefs = AppPreferences.of(context);
    return Container(
      color: AppColors.bgBase,
      child: Column(
        children: [
          _LargeHeader(
            title: prefs.t('pair.title'),
            subtitle: prefs.t('pair.subheading'),
            topInset: widget.topInset,
            showBack: widget.showBack,
            onBack: widget.onBack,
          ),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                AppSpacing.l,
                AppSpacing.s,
                AppSpacing.l,
                AppSpacing.xl + widget.bottomInset,
              ),
              children: [
                _ScanCard(
                  accent: accent,
                  heading: prefs.t('pair.heading'),
                  hint: prefs.t('pair.tapToScan'),
                  onTap: widget.onScan,
                ),
                const SizedBox(height: AppSpacing.l),
                _ManualToggle(
                  open: _showManual,
                  openLabel: prefs.t('pair.manualToggleOpen'),
                  closeLabel: prefs.t('pair.manualToggleClose'),
                  onTap: () => setState(() => _showManual = !_showManual),
                ),
                if (_showManual) ...[
                  const SizedBox(height: AppSpacing.s),
                  _ManualPanel(
                    controller: widget.qrController,
                    accent: accent,
                    hint: prefs.t('pair.manualHint'),
                    pasteLabel: prefs.t('pair.paste'),
                    submitLabel: prefs.t('pair.submit'),
                    onPair: widget.onPair,
                    onPaste: widget.onPaste,
                  ),
                ],
                if (widget.status.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.l),
                  Center(
                    child: Text(
                      widget.status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                _NetworkHint(text: prefs.t('pair.networkHint')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LargeHeader extends StatelessWidget {
  const _LargeHeader({
    required this.title,
    required this.subtitle,
    required this.topInset,
    required this.showBack,
    required this.onBack,
  });
  final String title;
  final String subtitle;
  final double topInset;
  final bool showBack;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      AppSpacing.s,
      topInset + AppSpacing.s,
      AppSpacing.l,
      AppSpacing.l,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 36,
          child: showBack
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    onPressed: onBack,
                    icon: const Icon(
                      Icons.chevron_left,
                      color: AppColors.textPrimary,
                      size: 28,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                )
              : null,
        ),
        const SizedBox(height: AppSpacing.s),
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.s),
          child: Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.s),
          child: Text(
            subtitle,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ScanCard extends StatelessWidget {
  const _ScanCard({
    required this.accent,
    required this.heading,
    required this.hint,
    required this.onTap,
  });
  final Color accent;
  final String heading;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.bgSurface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: AppColors.border, width: 0.5),
    ),
    clipBehavior: Clip.antiAlias,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.l,
            vertical: AppSpacing.xxl,
          ),
          child: Column(
            children: [
              SizedBox(
                width: 168,
                height: 168,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.bgBase,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Center(
                          child: Icon(Icons.qr_code_2, size: 80, color: accent),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _Corner(top: true, left: true, accent: accent),
                    ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _Corner(top: true, left: false, accent: accent),
                    ),
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: _Corner(top: false, left: true, accent: accent),
                    ),
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: _Corner(top: false, left: false, accent: accent),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.l),
              Text(
                heading,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: AppTextSize.title,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.s),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton.icon(
                  onPressed: onTap,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: Text(
                    hint,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: AppColors.bgBase,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Corner extends StatelessWidget {
  const _Corner({required this.top, required this.left, required this.accent});
  final bool top;
  final bool left;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      border: Border(
        top: top ? BorderSide(color: accent, width: 2) : BorderSide.none,
        bottom: !top ? BorderSide(color: accent, width: 2) : BorderSide.none,
        left: left ? BorderSide(color: accent, width: 2) : BorderSide.none,
        right: !left ? BorderSide(color: accent, width: 2) : BorderSide.none,
      ),
      borderRadius: BorderRadius.only(
        topLeft: top && left
            ? const Radius.circular(AppRadius.sm)
            : Radius.zero,
        topRight: top && !left
            ? const Radius.circular(AppRadius.sm)
            : Radius.zero,
        bottomLeft: !top && left
            ? const Radius.circular(AppRadius.sm)
            : Radius.zero,
        bottomRight: !top && !left
            ? const Radius.circular(AppRadius.sm)
            : Radius.zero,
      ),
    ),
  );
}

class _ManualToggle extends StatelessWidget {
  const _ManualToggle({
    required this.open,
    required this.openLabel,
    required this.closeLabel,
    required this.onTap,
  });
  final bool open;
  final String openLabel;
  final String closeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.bgSurface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: AppColors.border, width: 0.5),
    ),
    clipBehavior: Clip.antiAlias,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.l,
            vertical: AppSpacing.m,
          ),
          child: Row(
            children: [
              const Icon(
                Icons.edit_outlined,
                size: 18,
                color: AppColors.textPrimary,
              ),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: Text(
                  open ? closeLabel : openLabel,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppTextSize.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                open ? Icons.keyboard_arrow_up : Icons.chevron_right,
                size: 20,
                color: AppColors.textSubtle,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ManualPanel extends StatelessWidget {
  const _ManualPanel({
    required this.controller,
    required this.accent,
    required this.hint,
    required this.pasteLabel,
    required this.submitLabel,
    required this.onPair,
    required this.onPaste,
  });
  final TextEditingController controller;
  final Color accent;
  final String hint;
  final String pasteLabel;
  final String submitLabel;
  final VoidCallback onPair;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.bgSurface,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.l,
            vertical: AppSpacing.s,
          ),
          child: TextField(
            controller: controller,
            minLines: 4,
            maxLines: 6,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              height: 1.4,
            ),
            cursorColor: accent,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: AppColors.textSubtle),
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              enabledBorder: InputBorder.none,
              isCollapsed: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.m),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: onPaste,
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: Text(pasteLabel),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    backgroundColor: AppColors.bgSurface,
                    side: const BorderSide(color: AppColors.border, width: 0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.s),
            Expanded(
              child: SizedBox(
                height: 46,
                child: FilledButton.icon(
                  onPressed: onPair,
                  icon: const Icon(Icons.link, size: 16),
                  label: Text(submitLabel),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: AppColors.bgBase,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NetworkHint extends StatelessWidget {
  const _NetworkHint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(Icons.info_outline, size: 14, color: AppColors.textMuted),
      const SizedBox(width: AppSpacing.s),
      Text(
        text,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
    ],
  );
}
