import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/remote_models.dart';

class StorageService {
  static const devicesKey = 'codux.mobile.devices';
  static const legacyDeviceKey = 'codux.mobile.device';
  static const settingsKey = 'codux.mobile.settings';

  Future<List<StoredDevice>> loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(devicesKey);
    if (value != null && value.isNotEmpty) {
      final list = jsonDecode(value) as List<dynamic>;
      return list
          .map((item) => StoredDevice.fromJson(item as Map<String, dynamic>))
          .toList();
    }
    final legacy = prefs.getString(legacyDeviceKey);
    if (legacy != null && legacy.isNotEmpty) {
      final migrated = [
        StoredDevice.fromJson(jsonDecode(legacy) as Map<String, dynamic>),
      ];
      await saveDevices(migrated);
      return migrated;
    }
    return [];
  }

  Future<void> saveDevices(List<StoredDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      devicesKey,
      jsonEncode(devices.map((item) => item.toJson()).toList()),
    );
  }

  Future<MobileSettings?> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(settingsKey);
    if (value == null || value.isEmpty) return null;
    return MobileSettings.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> saveSettings(MobileSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(settingsKey, jsonEncode(settings.toJson()));
  }
}
