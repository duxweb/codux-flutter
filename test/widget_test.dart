import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codux_flutter/main.dart';
import 'package:codux_flutter/i18n.dart';
import 'package:codux_flutter/models/remote_models.dart';
import 'package:codux_flutter/services/e2e_crypto.dart';
import 'package:codux_flutter/services/log_service.dart';
import 'package:codux_flutter/services/remote_protocol_service.dart';
import 'package:codux_flutter/services/remote_transport.dart';

void main() {
  testWidgets('Codux app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const CoduxFlutterApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets(
    'opening terminal after list sync asks host to bind missing project terminal',
    (WidgetTester tester) async {
      CoduxLog.setLevelName('debug');
      CoduxLog.clear();
      final device = await _fakeDevice();
      final fake = _FakeRemoteTransport(
        device: device,
        onSent: (transport, envelope) {
          final type = '${envelope['type'] ?? ''}';
          if (type == 'host.info') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'project.list',
                payload: {
                  'projects': [
                    {'id': 'project-1', 'name': 'Project 1', 'path': '/tmp/p1'},
                  ],
                },
              ),
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.list',
                payload: {'terminals': []},
              ),
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'host.info',
                payload: {'protocolVersion': remoteProtocolVersion},
              ),
            );
            return;
          }
          if (type == 'project.select') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.list',
                payload: {
                  'terminals': [
                    {
                      'id': 'session-1',
                      'title': 'Terminal',
                      'projectId': 'project-1',
                      'layoutKind': 'split',
                    },
                  ],
                },
              ),
            );
            return;
          }
          if (type == 'terminal.buffer') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.output',
                sessionId: 'session-1',
                payload: {
                  'data': 'ready',
                  'buffer': true,
                  'offset': 0,
                  'bufferLength': 5,
                  'outputSeq': 1,
                },
              ),
            );
          }
        },
      );

      await tester.pumpWidget(
        CoduxFlutterApp(
          initialDevices: [device],
          transportFactory: (_) => fake,
        ),
      );
      await tester.pumpAndSettle();

      expect(CoduxLog.snapshotText(), contains('terminal.list count=0'));
      await tester.tap(find.text('Mac'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final log = CoduxLog.snapshotText();
      expect(
        log,
        contains(
          'send project.select reason=missing-terminal project=project-1',
        ),
      );
      expect(log, contains('bind session=session-1 project=project-1'));
      expect(log, contains('request terminal.buffer session=session-1'));
    },
  );

  testWidgets(
    'opening terminal binds the host selected project terminal immediately',
    (WidgetTester tester) async {
      CoduxLog.setLevelName('debug');
      CoduxLog.clear();
      final sentTypes = <String>[];
      final device = await _fakeDevice();
      final fake = _FakeRemoteTransport(
        device: device,
        onSent: (transport, envelope) {
          final type = '${envelope['type'] ?? ''}';
          sentTypes.add(type);
          if (type == 'host.info') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'project.list',
                payload: {
                  'selectedProjectId': 'project-2',
                  'projects': [
                    {'id': 'project-1', 'name': 'Project 1', 'path': '/tmp/p1'},
                    {'id': 'project-2', 'name': 'Project 2', 'path': '/tmp/p2'},
                  ],
                },
              ),
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.list',
                payload: {
                  'terminals': [
                    {
                      'id': 'session-2',
                      'title': 'Terminal',
                      'projectId': 'project-2',
                      'layoutKind': 'split',
                    },
                  ],
                },
              ),
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'host.info',
                payload: {'protocolVersion': remoteProtocolVersion},
              ),
            );
            return;
          }
          if (type == 'terminal.buffer') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.output',
                sessionId: 'session-2',
                payload: {
                  'data': 'ready',
                  'buffer': true,
                  'offset': 0,
                  'bufferLength': 5,
                  'outputSeq': 1,
                },
              ),
            );
          }
        },
      );

      await tester.pumpWidget(
        CoduxFlutterApp(
          initialDevices: [device],
          transportFactory: (_) => fake,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mac'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final log = CoduxLog.snapshotText();
      expect(log, contains('project.list count=2 selected=project-2'));
      expect(log, contains('bind session=session-2 project=project-2'));
      expect(log, contains('request terminal.buffer session=session-2'));
      expect(sentTypes.where((type) => type == 'project.select'), isEmpty);
    },
  );

  testWidgets(
    'switching projects sends one project select and waits for terminal list',
    (WidgetTester tester) async {
      CoduxLog.setLevelName('debug');
      CoduxLog.clear();
      final sentTypes = <String>[];
      final device = await _fakeDevice();
      final fake = _FakeRemoteTransport(
        device: device,
        onSent: (transport, envelope) {
          final type = '${envelope['type'] ?? ''}';
          sentTypes.add(type);
          if (type == 'host.info') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'project.list',
                payload: {
                  'selectedProjectId': 'project-1',
                  'projects': [
                    {'id': 'project-1', 'name': 'Project 1', 'path': '/tmp/p1'},
                    {'id': 'project-2', 'name': 'Project 2', 'path': '/tmp/p2'},
                  ],
                },
              ),
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.list',
                payload: {
                  'terminals': [
                    {
                      'id': 'session-1',
                      'title': 'Terminal 1',
                      'projectId': 'project-1',
                      'layoutKind': 'split',
                    },
                  ],
                },
              ),
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'host.info',
                payload: {'protocolVersion': remoteProtocolVersion},
              ),
            );
            return;
          }
          if (type == 'project.select') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'project.list',
                payload: {
                  'selectedProjectId': 'project-2',
                  'projects': [
                    {'id': 'project-1', 'name': 'Project 1', 'path': '/tmp/p1'},
                    {'id': 'project-2', 'name': 'Project 2', 'path': '/tmp/p2'},
                  ],
                },
              ),
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.list',
                payload: {
                  'terminals': [
                    {
                      'id': 'session-1',
                      'title': 'Terminal 1',
                      'projectId': 'project-1',
                      'layoutKind': 'split',
                    },
                    {
                      'id': 'session-2',
                      'title': 'Terminal 2',
                      'projectId': 'project-2',
                      'layoutKind': 'split',
                    },
                  ],
                },
              ),
            );
            return;
          }
          if (type == 'terminal.buffer') {
            transport.emitEncrypted(
              RelayEnvelope(
                type: 'terminal.output',
                sessionId: '${envelope['sessionId'] ?? ''}',
                payload: {
                  'data': 'ready',
                  'buffer': true,
                  'offset': 0,
                  'bufferLength': 5,
                  'outputSeq': 1,
                },
              ),
            );
          }
        },
      );

      await tester.pumpWidget(
        CoduxFlutterApp(
          initialDevices: [device],
          transportFactory: (_) => fake,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mac'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.tap(find.text('Project 2'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final projectSelectCount = sentTypes
          .where((type) => type == 'project.select')
          .length;
      final log = CoduxLog.snapshotText();
      expect(projectSelectCount, 1);
      expect(
        log,
        contains('send project.select reason=user-select project=project-2'),
      );
      expect(
        log,
        isNot(
          contains(
            'send project.select reason=missing-terminal project=project-2',
          ),
        ),
      );
      expect(log, contains('bind session=session-2 project=project-2'));
      expect(log, contains('request terminal.buffer session=session-2'));
    },
  );

  testWidgets(
    'accepts out of order encrypted project and terminal list messages',
    (WidgetTester tester) async {
      CoduxLog.setLevelName('debug');
      CoduxLog.clear();
      final device = await _fakeDevice();
      final fake = _FakeRemoteTransport(
        device: device,
        onSent: (transport, envelope) {
          final type = '${envelope['type'] ?? ''}';
          if (type == 'host.info') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.list',
                payload: {
                  'terminals': [
                    {
                      'id': 'session-1',
                      'title': 'Terminal',
                      'projectId': 'project-1',
                      'layoutKind': 'split',
                    },
                  ],
                },
              ),
              seq: 34,
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'project.list',
                payload: {
                  'selectedProjectId': 'project-1',
                  'projects': [
                    {'id': 'project-1', 'name': 'Project 1', 'path': '/tmp/p1'},
                  ],
                },
              ),
              seq: 33,
            );
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'host.info',
                payload: {'protocolVersion': remoteProtocolVersion},
              ),
              seq: 35,
            );
            return;
          }
          if (type == 'terminal.buffer') {
            transport.emitEncrypted(
              const RelayEnvelope(
                type: 'terminal.output',
                sessionId: 'session-1',
                payload: {
                  'data': 'ready',
                  'buffer': true,
                  'offset': 0,
                  'bufferLength': 5,
                  'outputSeq': 1,
                },
              ),
              seq: 36,
            );
          }
        },
      );

      await tester.pumpWidget(
        CoduxFlutterApp(
          initialDevices: [device],
          transportFactory: (_) => fake,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mac'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final log = CoduxLog.snapshotText();
      expect(log, contains('project.list count=1 selected=project-1'));
      expect(log, contains('terminal.list count=1'));
      expect(log, contains('bind session=session-1 project=project-1'));
    },
  );

  test('mobile languages match Mac language count', () {
    expect(LocaleChoices.all.length, 11);
    expect(LocaleChoices.byId('zh-CN').id, 'simplifiedChinese');
    expect(LocaleChoices.byId('en-US').id, 'english');
    expect(tr('settings.title', 'traditionalChinese'), '設定');
    expect(tr('settings.title', 'japanese'), '設定');
  });

  test('visible strings resolve through i18n fallback', () {
    const keys = [
      'app.connected',
      'app.notConnected',
      'app.about',
      'app.removeDevice',
      'toolbar.upload',
      'toolbar.enter',
      'toolbar.keyboard',
      'project.edit',
      'project.add',
      'project.rebuildTerminal',
      'terminal.loadingHistory',
      'device.homeHint',
      'pair.confirmTitle',
      'update.checking',
      'stats.aiTitle',
      'remote.qrInvalid',
    ];

    for (final locale in LocaleChoices.all.where(
      (item) => item.id != 'system',
    )) {
      for (final key in keys) {
        expect(tr(key, locale.id), isNot(key));
      }
    }
  });
}

typedef _FakeEnvelopeHandler =
    void Function(
      _FakeRemoteTransport transport,
      Map<String, dynamic> envelope,
    );

Future<StoredDevice> _fakeDevice() async {
  final keyPair = await RemoteE2ECrypto.newDeviceKeyPair();
  final hostKeyPair = await RemoteE2ECrypto.newDeviceKeyPair();
  return StoredDevice(
    server: 'https://codux-service.dux.plus/v3',
    hostId: 'host-1',
    deviceId: 'device-1',
    token: 'token-1',
    name: 'Mac',
    hostPublicKey: hostKeyPair.publicKey,
    devicePrivateKey: keyPair.privateKey,
    devicePublicKey: keyPair.publicKey,
    cryptoVersion: 1,
    transports: const [
      RemoteTransportCandidate(
        kind: RemoteTransportKind.websocketRelay,
        url: 'https://codux-service.dux.plus/v3',
      ),
    ],
  );
}

final class _FakeRemoteTransport implements RemoteTransport {
  _FakeRemoteTransport({required this.device, required this.onSent});

  final StoredDevice device;
  final _FakeEnvelopeHandler onSent;
  RemoteTransportStateHandler? _onState;
  RemoteTransportEnvelopeHandler? _onEnvelope;

  @override
  String get kind => RemoteTransportKind.websocketRelay;

  @override
  set onState(RemoteTransportStateHandler? handler) => _onState = handler;

  @override
  set onEnvelope(RemoteTransportEnvelopeHandler? handler) =>
      _onEnvelope = handler;

  @override
  Future<void> connect(StoredDevice device) async {
    _onState?.call('connecting');
    _onState?.call('connected:path=relay');
    emit(const RelayEnvelope(type: 'hello'));
  }

  @override
  Future<bool> send(Map<String, dynamic> envelope) async {
    final decoded = await _decode(envelope);
    onSent(this, decoded.toJson());
    return true;
  }

  @override
  Future<void> close() async {}

  void emit(RelayEnvelope envelope) {
    _onEnvelope?.call(envelope.toJson());
  }

  void emitEncrypted(RelayEnvelope envelope, {int? seq}) {
    RemoteE2ECrypto.encryptEnvelope(
      inner: envelope,
      device: device,
      seq: seq ?? DateTime.now().microsecondsSinceEpoch,
    ).then((encrypted) => emit(encrypted));
  }

  Future<RelayEnvelope> _decode(Map<String, dynamic> envelope) async {
    final outer = RelayEnvelope.fromJson(envelope);
    if (outer.type != 'secure.message') return outer;
    return RemoteE2ECrypto.decryptEnvelope(outer: outer, device: device);
  }
}
