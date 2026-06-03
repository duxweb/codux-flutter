import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codux_flutter/main.dart';
import 'package:codux_flutter/models/remote_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('device home waits for host snapshots after relay hello', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);
    expect(relay.channels.length, 1);

    relay.channels.single.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();

    expect(find.text('连接中...'), findsWidgets);
    expect(find.text('同步中'), findsNothing);
    _emitHostReady(relay.channels.single);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    expect(find.text('中继'), findsWidgets);
    expect(find.text('未连接'), findsNothing);
  });

  testWidgets('old socket close does not clear a newer connected socket', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);
    final first = relay.channels.single;

    await tester.tap(find.text('Mac').first);
    await tester.pump();
    expect(relay.channels.length, 2);
    final second = relay.channels.last;

    second.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();
    _emitHostReady(second);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);
    expect(find.text('中继'), findsWidgets);

    first.closeFromServer();
    await tester.pump();

    expect(find.text('中继'), findsWidgets);
    expect(find.text('未连接'), findsNothing);
  });

  testWidgets('active socket close keeps last transport visible during grace', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);
    final channel = relay.channels.single;

    channel.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();
    _emitHostReady(channel);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    channel.closeFromServer();
    await tester.pump();

    expect(find.text('中继'), findsWidgets);
    expect(find.text('未连接'), findsNothing);
  });

  testWidgets('reconnect refresh keeps existing host snapshot visible', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);
    final first = relay.channels.single;

    first.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();
    _emitHostReady(first);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    first.closeFromServer();
    await tester.pump(const Duration(milliseconds: 850));
    await _pumpUntil(tester, () => relay.channels.length == 2);
    final second = relay.channels.last;

    second.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();
    _emitHostReady(second);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    expect(find.text('中继'), findsWidgets);
    expect(find.text('同步中'), findsNothing);
  });

  testWidgets(
    'opening terminal before project list does not show history loading',
    (tester) async {
      final relay = _FakeRelayFactory();

      await tester.pumpWidget(
        CoduxFlutterApp(
          relaySocketFactory: relay.call,
          initialDevices: [_device()],
        ),
      );
      await _pumpUntil(tester, () => relay.channels.isNotEmpty);

      relay.channels.single.emit({
        'type': 'hello',
        'payload': {'role': 'client'},
      });
      await tester.pump();

      await tester.tap(find.text('Mac').first);
      await tester.pump();

      expect(find.text('正在加载终端历史...'), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('正在加载终端历史...'), findsNothing);
    },
  );

  testWidgets(
    'initial project and terminal list requests retry without reply',
    (tester) async {
      final relay = _FakeRelayFactory();

      await tester.pumpWidget(
        CoduxFlutterApp(
          relaySocketFactory: relay.call,
          initialDevices: [_device()],
        ),
      );
      await _pumpUntil(tester, () => relay.channels.isNotEmpty);

      relay.channels.single.emit({
        'type': 'hello',
        'payload': {'role': 'client'},
      });
      relay.channels.single.emit({
        'type': 'host.info',
        'payload': {'name': 'Mac', 'protocolVersion': 'v1.0'},
      });
      await _pumpUntil(
        tester,
        () => relay.channels.single.sink.sent.length >= 4,
      );

      final initialCount = relay.channels.single.sink.sent.length;
      await tester.pump(const Duration(milliseconds: 850));

      expect(relay.channels.single.sink.sent.length, greaterThan(initialCount));
    },
  );

  testWidgets('foreground resume refreshes host snapshots on existing socket', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);
    final channel = relay.channels.single;

    channel.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();
    _emitHostReady(channel);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    final before = channel.sink.sent.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('连接中...'), findsWidgets);
    _emitHostReady(channel);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    expect(channel.sink.sent.length, greaterThan(before));
    expect(find.text('中继'), findsWidgets);
    expect(find.text('未连接'), findsNothing);
  });

  testWidgets('foreground resume reconnects when existing socket is stale', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);
    final channel = relay.channels.single;

    channel.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();
    _emitHostReady(channel);
    await _pumpUntil(tester, () => find.text('中继').evaluate().isNotEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 6100));
    expect(find.text('连接失败，后台重试中'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 850));

    expect(relay.channels.length, 2);
    expect(find.text('中继'), findsNothing);
  });

  testWidgets('relay hello without host response becomes connection failed', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);

    relay.channels.single.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();

    expect(find.text('连接中...'), findsWidgets);
    expect(find.text('同步中'), findsNothing);
    expect(find.text('中继'), findsNothing);

    await tester.pump(const Duration(milliseconds: 6100));

    expect(find.text('连接失败，后台重试中'), findsWidgets);
    expect(find.text('同步中'), findsNothing);
    expect(find.text('中继'), findsNothing);
  });

  testWidgets('incompatible host protocol blocks reconnect for this run', (
    tester,
  ) async {
    final relay = _FakeRelayFactory();

    await tester.pumpWidget(
      CoduxFlutterApp(
        relaySocketFactory: relay.call,
        initialDevices: [_device()],
      ),
    );
    await _pumpUntil(tester, () => relay.channels.isNotEmpty);
    final channel = relay.channels.single;

    channel.emit({
      'type': 'hello',
      'payload': {'role': 'client'},
    });
    await tester.pump();
    channel.emit({
      'type': 'host.info',
      'payload': {'name': 'Mac', 'protocolVersion': 'v2.0'},
    });
    await _pumpUntil(
      tester,
      () => find.text('协议版本不兼容，请升级应用').evaluate().isNotEmpty,
    );

    expect(find.text('协议版本不兼容，请升级应用'), findsWidgets);
    expect(channel.sink.closed, isTrue);

    await tester.pump(const Duration(seconds: 2));
    expect(relay.channels.length, 1);

    await tester.tap(find.text('Mac').first);
    await tester.pump();
    expect(relay.channels.length, 1);
  });
}

void _emitHostReady(_FakeRelayChannel channel) {
  channel.emit({
    'type': 'host.info',
    'payload': {'name': 'Mac', 'protocolVersion': 'v1.0'},
  });
  channel.emit({
    'type': 'project.list',
    'payload': {
      'projects': [
        {'id': 'project-1', 'name': 'Codux', 'path': '/Volumes/Web/codux'},
      ],
    },
  });
  channel.emit({
    'type': 'terminal.list',
    'payload': {'terminals': []},
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxPumps = 20,
}) async {
  for (var index = 0; index < maxPumps; index += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (done()) return;
  }
}

StoredDevice _device() {
  return const StoredDevice(
    server: 'http://127.0.0.1:8088',
    hostId: 'host-1',
    deviceId: 'device-1',
    token: 'device-token',
    name: 'Phone',
    hostName: 'Mac',
    hostPublicKey: _hostPublicKey,
    devicePrivateKey: _devicePrivateKey,
    devicePublicKey: _devicePublicKey,
    cryptoVersion: 1,
  );
}

const _hostPublicKey = 'NKW6MhTW7bzdIKm4s8YJFxtOEh6lGd1dMpSpbgq13nc';
const _devicePrivateKey = 'aKLDwMsHHKv5RI8Fkc-v-MhavdFDhwz4s0vEyedXHGo';
const _devicePublicKey = 'u0-G63Fh0FcwyatxPffyvLPvgqJDwxpNCWpfIqApmCQ';

final class _FakeRelayFactory {
  final channels = <_FakeRelayChannel>[];

  _FakeRelayChannel call(StoredDevice device) {
    final channel = _FakeRelayChannel();
    channels.add(channel);
    return channel;
  }
}

final class _FakeRelayChannel {
  _FakeRelayChannel() : sink = _FakeRelaySink();

  final _controller = StreamController<String>();
  final _FakeRelaySink sink;
  Future<void> get ready => Future<void>.value();
  Stream<String> get stream => _controller.stream;

  void emit(Map<String, Object?> message) {
    _controller.add(jsonEncode(message));
  }

  void closeFromServer() {
    _controller.close();
  }
}

final class _FakeRelaySink {
  final sent = <String>[];
  bool closed = false;

  void add(String data) {
    sent.add(data);
  }

  void close() {
    closed = true;
  }
}
