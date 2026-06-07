import 'dart:convert';

import 'package:codux_flutter/main.dart';
import 'package:codux_flutter/models/remote_models.dart';
import 'package:codux_flutter/services/storage_service.dart';
import 'package:codux_remote_iroh/codux_remote_iroh.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('device home waits for host snapshots after iroh connect', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    expect(session.sent, isNotEmpty);
    expect(find.text('连接中'), findsWidgets);
    expect(find.text('未连接'), findsNothing);
  });

  testWidgets('device home shows direct iroh path when native reports it', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitPath('direct');
    await _pumpUntil(tester, () => find.text('P2P').evaluate().isNotEmpty);

    expect(find.text('P2P'), findsWidgets);
    expect(find.text('Iroh'), findsNothing);
  });

  testWidgets('device home shows relay path as relay status', (tester) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitPath('relay');
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    expect(find.text('中继'), findsWidgets);
    expect(find.text('Iroh'), findsNothing);
  });

  testWidgets('device home treats mixed path as relay status', (tester) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitPath('mixed');
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    expect(find.text('中继'), findsWidgets);
    expect(find.text('P2P'), findsNothing);
  });

  testWidgets('host info updates runtime iroh node address', (tester) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
    final session = bridge.sessions.single;
    session.emitState('connected');
    session.emitEnvelope({
      'type': 'host.info',
      'payload': {
        'name': 'Mac',
        'protocolVersion': 'v2.0',
        'iroh': {
          'nodeId': 'node-1',
          'relayUrl': 'https://relay.iroh.network',
          'directAddresses': ['203.0.113.1:12345'],
        },
      },
    });
    await _pumpUntil(tester, () => bridge.addedNodeAddrs.isNotEmpty);

    expect(bridge.addedNodeAddrs, [
      {
        'nodeId': 'node-1',
        'relayUrl': 'https://relay.iroh.network',
        'directAddresses': ['203.0.113.1:12345'],
      },
    ]);
    final prefs = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(prefs.getString(StorageService.devicesKey)!)
            as List<dynamic>;
    final device = StoredDevice.fromJson(
      Map<String, dynamic>.from(stored.single as Map),
    );
    expect(device.iroh?.relayUrl, 'https://relay.iroh.network');
    expect(device.iroh?.directAddresses, ['203.0.113.1:12345']);

    await tester.pump(const Duration(milliseconds: 200));
    expect(bridge.sessions.length, 1);
  });

  testWidgets('relay path reconnects once when host info adds direct address', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
    final session = bridge.sessions.single;
    session.emitState('connected');
    session.emitPath('relay');
    session.emitEnvelope({
      'type': 'host.info',
      'payload': {
        'name': 'Mac',
        'protocolVersion': 'v2.0',
        'iroh': {
          'nodeId': 'node-1',
          'relayUrl': 'https://relay.iroh.network',
          'directAddresses': ['203.0.113.1:12345'],
        },
      },
    });
    await _pumpUntil(tester, () => bridge.addedNodeAddrs.isNotEmpty);
    await _pumpUntil(tester, () => bridge.sessions.length > 1);

    expect(bridge.sessions.length, 2);
    expect(bridge.sessions.first.closed, isTrue);
    expect(
      bridge.connectConfigs.last['nodeAddr'],
      containsPair('directAddresses', ['203.0.113.1:12345']),
    );
  });

  testWidgets('stored direct addresses are ignored for normal reconnect', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(
      tester,
      bridge,
      devices: [
        _device().copyWith(
          iroh: const IrohNodeAddr(
            nodeId: 'node-1',
            relayUrl: 'https://relay.iroh.network',
            directAddresses: ['198.51.100.1:12345'],
          ),
        ),
      ],
    );
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.connectConfigs.single['nodeAddr'], {
      'nodeId': 'node-1',
      'relayUrl': 'https://relay.iroh.network',
    });
  });

  testWidgets('device can dial with node id only when no address hints exist', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(
      tester,
      bridge,
      devices: [_device().copyWith(iroh: const IrohNodeAddr(nodeId: 'node-1'))],
    );
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.sessions, hasLength(1));
  });

  testWidgets('device home shows reconnecting after iroh close', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitState('closed');
    await _pumpUntil(tester, () => find.text('连接中').evaluate().isNotEmpty);

    expect(find.text('连接中'), findsWidgets);
  });

  testWidgets('transport pong updates latency', (tester) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    await tester.pump(const Duration(milliseconds: 25));
    session.emitEnvelope({'type': 'transport.pong'});
    await _pumpUntil(
      tester,
      () => find.textContaining('ms').evaluate().isNotEmpty,
    );

    expect(find.textContaining('ms'), findsWidgets);
  });

  testWidgets(
    'initial project and terminal list requests retry without reply',
    (tester) async {
      final bridge = _FakeIrohBridge();
      await _pumpApp(tester, bridge);
      final session = await _connectAndEmitHostInfoOnly(tester, bridge);

      await _pumpUntil(tester, () => session.sentTypes.length >= 4);
      final initialCount = session.sentTypes.length;
      await tester.pump(const Duration(milliseconds: 850));

      expect(session.sentTypes.length, greaterThan(initialCount));
    },
  );

  testWidgets(
    'foreground resume refreshes host snapshots without reconnecting iroh',
    (tester) async {
      final bridge = _FakeIrohBridge();
      await _pumpApp(tester, bridge);
      final session = await _connectAndEmitReady(tester, bridge);
      final before = session.sentTypes.length;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      _emitHostReady(session);
      await _pumpUntil(tester, () => session.sentTypes.length > before);

      expect(bridge.sessions.length, 1);
      expect(session.closed, isFalse);
      expect(session.sentTypes.length, greaterThan(before));
    },
  );

  testWidgets('relay path after host info direct address reconnects once', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
    final session = bridge.sessions.single;
    session.emitState('connected');
    session.emitEnvelope({
      'type': 'host.info',
      'payload': {
        'name': 'Mac',
        'protocolVersion': 'v2.0',
        'iroh': {
          'nodeId': 'node-1',
          'relayUrl': 'https://relay.iroh.network',
          'directAddresses': ['203.0.113.1:12345'],
        },
      },
    });
    await _pumpUntil(tester, () => bridge.addedNodeAddrs.isNotEmpty);

    session.emitPath('relay');
    await _pumpUntil(tester, () => bridge.sessions.length > 1);

    expect(bridge.sessions.length, 2);
    expect(bridge.sessions.first.closed, isTrue);
  });

  testWidgets('relay fallback after direct path keeps the current transport', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
    final session = bridge.sessions.single;
    session.emitState('connected');
    session.emitEnvelope({
      'type': 'host.info',
      'payload': {
        'name': 'Mac',
        'protocolVersion': 'v2.0',
        'iroh': {
          'nodeId': 'node-1',
          'relayUrl': 'https://relay.iroh.network',
          'directAddresses': ['203.0.113.1:12345'],
        },
      },
    });
    await _pumpUntil(tester, () => bridge.addedNodeAddrs.isNotEmpty);

    session.emitPath('direct');
    await tester.pump();
    session.emitPath('relay');
    await tester.pump(const Duration(milliseconds: 200));

    expect(bridge.sessions.length, 1);
    expect(session.closed, isFalse);
  });

  testWidgets('iroh close reconnects through iroh', (tester) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitState('closed');
    await _pumpUntil(tester, () => find.text('连接中').evaluate().isNotEmpty);

    expect(find.text('连接中'), findsWidgets);
  });

  testWidgets('host info timeout reconnects through iroh', (tester) async {
    final bridge = _FakeIrohBridge(autoConnected: true);
    await _pumpApp(tester, bridge);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    await tester.pump(const Duration(milliseconds: 6100));
    await tester.pump(const Duration(milliseconds: 850));

    expect(bridge.sessions.length, greaterThan(1));
    expect(find.text('Iroh'), findsNothing);
  });

  testWidgets('incompatible host protocol blocks reconnect for this run', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
    final session = bridge.sessions.single;
    session.emitState('connected');
    session.emitEnvelope({
      'type': 'host.info',
      'payload': {'name': 'Mac', 'protocolVersion': 'v1.0'},
    });
    await _pumpUntil(
      tester,
      () => find.text('协议版本不兼容，请升级应用').evaluate().isNotEmpty,
    );

    expect(find.text('协议版本不兼容，请升级应用'), findsWidgets);
    expect(session.closed, isTrue);

    await tester.pump(const Duration(seconds: 2));
    expect(bridge.sessions.length, 1);

    await tester.tap(find.text('Mac').first);
    await tester.pump();
    expect(bridge.sessions.length, 1);
  });
}

Future<void> _pumpApp(
  WidgetTester tester,
  _FakeIrohBridge bridge, {
  List<StoredDevice>? devices,
}) async {
  await tester.pumpWidget(
    CoduxFlutterApp(irohBridge: bridge, initialDevices: devices ?? [_device()]),
  );
  await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
}

Future<_FakeIrohSession> _connectAndEmitReady(
  WidgetTester tester,
  _FakeIrohBridge bridge,
) async {
  final session = await _connectAndEmitHostInfoOnly(tester, bridge);
  _emitProjectAndTerminalLists(session);
  await _pumpUntil(tester, () => find.text('连接中').evaluate().isNotEmpty);
  return session;
}

Future<_FakeIrohSession> _connectAndEmitHostInfoOnly(
  WidgetTester tester,
  _FakeIrohBridge bridge,
) async {
  await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
  final session = bridge.sessions.single;
  session.emitState('connected');
  session.emitEnvelope({
    'type': 'host.info',
    'payload': {'name': 'Mac', 'protocolVersion': 'v2.0'},
  });
  await tester.pump();
  return session;
}

void _emitHostReady(_FakeIrohSession session) {
  session.emitEnvelope({
    'type': 'host.info',
    'payload': {'name': 'Mac', 'protocolVersion': 'v2.0'},
  });
  _emitProjectAndTerminalLists(session);
}

void _emitProjectAndTerminalLists(_FakeIrohSession session) {
  session.emitEnvelope({
    'type': 'project.list',
    'payload': {
      'projects': [
        {'id': 'project-1', 'name': 'Codux', 'path': '/Volumes/Web/codux'},
      ],
    },
  });
  session.emitEnvelope({
    'type': 'terminal.list',
    'payload': {'terminals': []},
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxPumps = 30,
}) async {
  for (var index = 0; index < maxPumps; index += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (done()) return;
  }
}

StoredDevice _device() {
  return const StoredDevice(
    server: '',
    hostId: 'host-1',
    deviceId: 'device-1',
    token: 'device-token',
    name: 'Phone',
    hostName: 'Mac',
    hostPublicKey: _hostPublicKey,
    devicePrivateKey: _devicePrivateKey,
    devicePublicKey: _devicePublicKey,
    cryptoVersion: 1,
    transport: 'iroh',
    iroh: IrohNodeAddr(
      nodeId: 'node-1',
      relayUrl: 'https://relay.iroh.network',
    ),
  );
}

const _hostPublicKey = 'NKW6MhTW7bzdIKm4s8YJFxtOEh6lGd1dMpSpbgq13nc';
const _devicePrivateKey = 'aKLDwMsHHKv5RI8Fkc-v-MhavdFDhwz4s0vEyedXHGo';
const _devicePublicKey = 'u0-G63Fh0FcwyatxPffyvLPvgqJDwxpNCWpfIqApmCQ';

final class _FakeIrohBridge implements CoduxRemoteIrohBridge {
  _FakeIrohBridge({this.autoConnected = false});

  final bool autoConnected;
  final sessions = <_FakeIrohSession>[];
  final addedNodeAddrs = <Map<String, dynamic>>[];
  final connectConfigs = <Map<String, dynamic>>[];

  @override
  int connect(Map<String, dynamic> config) {
    connectConfigs.add(config);
    final session = _FakeIrohSession(sessions.length + 1);
    sessions.add(session);
    if (autoConnected) {
      session.emitState('connected');
    }
    return session.handle;
  }

  @override
  bool send(int handle, Map<String, dynamic> envelope) {
    final session = sessions.singleWhere((item) => item.handle == handle);
    session.sent.add(envelope);
    return true;
  }

  @override
  bool addNodeAddr(int handle, Map<String, dynamic> nodeAddr) {
    addedNodeAddrs.add(nodeAddr);
    return true;
  }

  @override
  Map<String, dynamic>? pollEvent(int handle) {
    final session = sessions.singleWhere((item) => item.handle == handle);
    if (session.events.isEmpty) return null;
    return session.events.removeAt(0);
  }

  @override
  void close(int handle) {
    for (final session in sessions) {
      if (session.handle == handle) {
        session.closed = true;
        return;
      }
    }
  }
}

final class _FakeIrohSession {
  _FakeIrohSession(this.handle);

  final int handle;
  final events = <Map<String, dynamic>>[];
  final sent = <Map<String, dynamic>>[];
  bool closed = false;

  List<String> get sentTypes => sent.map((item) => '${item['type']}').toList();

  void emitState(String state) {
    events.add({'type': 'state', 'state': state});
  }

  void emitPath(String path) {
    events.add({'type': 'state', 'state': 'path', 'path': path});
  }

  void emitEnvelope(Map<String, dynamic> envelope) {
    events.add({'type': 'envelope', 'envelope': envelope});
  }
}
