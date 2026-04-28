import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../i18n.dart';
import '../theme/app_theme.dart';

class ScannerScreen extends StatelessWidget {
  const ScannerScreen({
    super.key,
    required this.bottomInset,
    required this.onDetected,
    required this.onClose,
  });

  final double bottomInset;
  final ValueChanged<String> onDetected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final prefs = AppPreferences.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            MobileScanner(
              onDetect: (capture) {
                final value = capture.barcodes.firstOrNull?.rawValue;
                if (value != null) onDetected(value);
              },
            ),
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: accent, width: 2),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
              ),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 36 + bottomInset,
              child: Column(
                children: [
                  Text(
                    prefs.t('pair.scanTitle'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: AppTextSize.title,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s),
                  Text(
                    prefs.t('pair.scanHint'),
                    style: const TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.l),
                  Material(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: onClose,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.l,
                          vertical: AppSpacing.m,
                        ),
                        child: Text(
                          prefs.t('pair.close'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
