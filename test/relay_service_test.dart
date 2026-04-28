import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codux_flutter/models/remote_models.dart';
import 'package:codux_flutter/services/e2e_crypto.dart';
import 'package:codux_flutter/services/relay_service.dart';

void main() {
  test('match code uses the shared host and mobile formula', () {
    expect(
      RemoteE2ECrypto.matchCode(
        hostPublicKey: 'host-public-key',
        devicePublicKey: 'device-public-key',
        pairingCode: '205503D6',
        pairingSecret: 'pairing-secret',
      ),
      '8EC-D5F',
    );
  });

  test('pairing wait closes when Mac rejects or cancels the request', () async {
    final server = await _PairingStatusServer.start({
      'status': 'rejected',
      'hostId': 'host-1',
      'pairingId': 'pairing-1',
    });
    addTearDown(server.close);

    expect(
      () => waitPairingConfirmed(_payload(server.url), 'Phone'),
      throwsA(isA<PairingRejectedException>()),
    );
  });

  test('pairing wait stores confirmed device crypto fields', () async {
    final server = await _PairingStatusServer.start({
      'status': 'confirmed',
      'hostId': 'host-1',
      'hostName': 'Mac',
      'deviceId': 'device-1',
      'token': 'device-token',
      'hostPublicKey': 'host-public-key',
      'cryptoVersion': 1,
    });
    addTearDown(server.close);

    final device = await waitPairingConfirmed(_payload(server.url), 'Phone');

    expect(device.server, server.url);
    expect(device.hostId, 'host-1');
    expect(device.deviceId, 'device-1');
    expect(device.token, 'device-token');
    expect(device.hostPublicKey, 'host-public-key');
    expect(device.devicePrivateKey, 'device-private-key');
    expect(device.devicePublicKey, 'device-public-key');
    expect(device.cryptoVersion, 1);
    expect(device.hostName, 'Mac');
  });

  test('pairing wait fails if confirmed status has no device credentials', () async {
    final server = await _PairingStatusServer.start({
      'status': 'confirmed',
      'hostId': 'host-1',
      'hostName': 'Mac',
    });
    addTearDown(server.close);

    expect(
      () => waitPairingConfirmed(_payload(server.url), 'Phone'),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Pairing confirmed without device credentials'),
        ),
      ),
    );
  });
}

PairingPayload _payload(String server) => const PairingPayload(
  server: '',
  code: '205503D6',
  secret: 'pairing-secret',
  hostPublicKey: 'host-public-key',
  devicePrivateKey: 'device-private-key',
  devicePublicKey: 'device-public-key',
  matchCode: '8EC-D5F',
  cryptoVersion: 1,
).copyWithServer(server);

extension on PairingPayload {
  PairingPayload copyWithServer(String server) => PairingPayload(
    server: server,
    code: code,
    secret: secret,
    hostPublicKey: hostPublicKey,
    devicePrivateKey: devicePrivateKey,
    devicePublicKey: devicePublicKey,
    matchCode: matchCode,
    cryptoVersion: cryptoVersion,
    hostName: hostName,
  );
}

final class _PairingStatusServer {
  const _PairingStatusServer(this._server);

  final HttpServer _server;

  String get url => 'http://${_server.address.host}:${_server.port}';

  static Future<_PairingStatusServer> start(Map<String, Object?> status) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'POST' &&
          request.uri.path == '/api/pairings/status') {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(status));
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'not found'}));
      await request.response.close();
    });
    return _PairingStatusServer(server);
  }

  Future<void> close() => _server.close(force: true);
}
