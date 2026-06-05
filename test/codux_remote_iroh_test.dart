import 'package:flutter_test/flutter_test.dart';
import 'package:codux_remote_iroh/codux_remote_iroh.dart';

void main() {
  test('transport bridge is lazy and dispatches native events', () async {
    final bridge = _FakeIrohBridge();
    final transport = CoduxRemoteIroh(bridge: bridge);
    final states = <String>[];
    final envelopes = <Map<String, dynamic>>[];
    transport.onState = states.add;
    transport.onEnvelope = envelopes.add;

    expect(bridge.connectCalls, 0);

    await transport.connect(nodeAddr: {'nodeId': 'node-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(bridge.connectCalls, 1);
    expect(states, contains('connected'));
    expect(envelopes.single['type'], 'host.info');

    expect(await transport.send({'type': 'project.list'}), isTrue);
    expect(bridge.sent.single['type'], 'project.list');

    await transport.close();
    expect(bridge.closedHandles, contains(1));
  });

  test('transport drains queued envelopes after native close state', () async {
    final bridge = _FakeIrohBridge(
      events: [
        {'type': 'state', 'state': 'closed'},
        {
          'type': 'envelope',
          'envelope': {'type': 'pairing.confirmed'},
        },
      ],
    );
    final transport = CoduxRemoteIroh(bridge: bridge);
    final states = <String>[];
    final envelopes = <Map<String, dynamic>>[];
    transport.onState = states.add;
    transport.onEnvelope = envelopes.add;

    await transport.connect(nodeAddr: {'nodeId': 'node-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(states, contains('closed'));
    expect(envelopes.single['type'], 'pairing.confirmed');
  });

  test('transport forwards native path state detail', () async {
    final bridge = _FakeIrohBridge(
      events: [
        {
          'type': 'state',
          'state': 'path',
          'path': 'direct',
          'detail': '192.168.1.2:12345',
        },
      ],
    );
    final transport = CoduxRemoteIroh(bridge: bridge);
    final states = <String>[];
    transport.onState = states.add;

    await transport.connect(nodeAddr: {'nodeId': 'node-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(states, contains('path:path=direct;detail=192.168.1.2:12345'));
  });
}

final class _FakeIrohBridge implements CoduxRemoteIrohBridge {
  _FakeIrohBridge({List<Map<String, dynamic>>? events})
    : _events =
          events ??
          [
            {'type': 'state', 'state': 'connected'},
            {
              'type': 'envelope',
              'envelope': {'type': 'host.info'},
            },
          ];

  int connectCalls = 0;
  final sent = <Map<String, dynamic>>[];
  final closedHandles = <int>[];
  final List<Map<String, dynamic>> _events;

  @override
  int connect(Map<String, dynamic> config) {
    connectCalls += 1;
    return 1;
  }

  @override
  bool send(int handle, Map<String, dynamic> envelope) {
    sent.add(envelope);
    return true;
  }

  @override
  Map<String, dynamic>? pollEvent(int handle) {
    if (_events.isEmpty) return null;
    return _events.removeAt(0);
  }

  @override
  void close(int handle) {
    closedHandles.add(handle);
  }
}
