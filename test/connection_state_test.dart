import 'package:codux_flutter/main.dart';
import 'package:codux_flutter/models/remote_models.dart';
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
    expect(find.text('Iroh'), findsWidgets);
    expect(find.text('未连接'), findsNothing);
  });

  testWidgets('device home shows direct iroh path when native reports it', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitPath('direct');
    await _pumpUntil(tester, () => find.text('直连').evaluate().isNotEmpty);

    expect(find.text('直连'), findsWidgets);
    expect(find.text('Iroh'), findsNothing);
  });

  testWidgets('device home shows reconnecting after iroh close', (
    tester,
  ) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitState('closed');
    await _pumpUntil(tester, () => find.text('重连中').evaluate().isNotEmpty);

    expect(find.text('重连中'), findsWidgets);
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
    'foreground resume refreshes host snapshots on existing iroh link',
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
      await _pumpUntil(tester, () => bridge.sessions.length > 1);

      expect(bridge.sessions.length, greaterThan(1));
      expect(session.sentTypes.length, before);
      expect(find.text('QUIC'), findsWidgets);
    },
  );

  testWidgets('iroh close reconnects through iroh', (tester) async {
    final bridge = _FakeIrohBridge();
    await _pumpApp(tester, bridge);
    final session = await _connectAndEmitReady(tester, bridge);

    session.emitState('closed');
    await _pumpUntil(tester, () => find.text('重连中').evaluate().isNotEmpty);

    expect(find.text('重连中'), findsWidgets);
  });

  testWidgets('host info timeout reconnects through iroh', (tester) async {
    final bridge = _FakeIrohBridge(autoConnected: true);
    await _pumpApp(tester, bridge);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    await tester.pump(const Duration(milliseconds: 6100));
    expect(find.text('连接失败，后台重试中'), findsWidgets);
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

Future<void> _pumpApp(WidgetTester tester, _FakeIrohBridge bridge) async {
  await tester.pumpWidget(
    CoduxFlutterApp(irohBridge: bridge, initialDevices: [_device()]),
  );
  await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
}

Future<_FakeIrohSession> _connectAndEmitReady(
  WidgetTester tester,
  _FakeIrohBridge bridge,
) async {
  final session = await _connectAndEmitHostInfoOnly(tester, bridge);
  _emitProjectAndTerminalLists(session);
  await _pumpUntil(tester, () => find.text('Iroh').evaluate().isNotEmpty);
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
    iroh: IrohNodeAddr(nodeId: 'node-1'),
  );
}

const _hostPublicKey = 'NKW6MhTW7bzdIKm4s8YJFxtOEh6lGd1dMpSpbgq13nc';
const _devicePrivateKey = 'aKLDwMsHHKv5RI8Fkc-v-MhavdFDhwz4s0vEyedXHGo';
const _devicePublicKey = 'u0-G63Fh0FcwyatxPffyvLPvgqJDwxpNCWpfIqApmCQ';

final class _FakeIrohBridge implements CoduxRemoteIrohBridge {
  _FakeIrohBridge({this.autoConnected = false});

  final bool autoConnected;
  final sessions = <_FakeIrohSession>[];

  @override
  int connect(Map<String, dynamic> config) {
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
