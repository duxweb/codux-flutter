import 'package:codux_flutter/models/remote_models.dart';
import 'package:codux_flutter/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('project list cache is scoped by host', () async {
    final storage = StorageService();
    const device = StoredDevice(
      server: 'https://codux-service.dux.plus',
      hostId: 'host-1',
      deviceId: 'device-1',
      token: 'token',
      name: 'Phone',
    );

    await storage.saveCachedProjects(device, const [
      ProjectInfo(id: 'project-1', name: 'Codux', path: '/Volumes/Web/codux'),
    ]);

    final cached = await storage.loadCachedProjects(device);

    expect(cached, hasLength(1));
    expect(cached.single.id, 'project-1');
    expect(cached.single.name, 'Codux');
    expect(cached.single.path, '/Volumes/Web/codux');
  });
}
