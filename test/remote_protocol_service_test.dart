import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:codux_flutter/models/remote_models.dart';
import 'package:codux_flutter/services/e2e_crypto.dart';
import 'package:codux_flutter/services/remote_protocol_service.dart';

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

  test('stored device defaults to iroh transport', () {
    final device = StoredDevice.fromJson({
      'server': '',
      'hostId': 'host-1',
      'deviceId': 'device-1',
      'token': 'token-1',
      'name': 'Phone',
    });

    expect(device.transport, 'iroh');
  });

  test(
    'iroh pairing payload and confirmation use protocol transport fields',
    () async {
      final qr = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'transport': 'iroh',
                'code': '205503D6',
                'secret': 'pairing-secret',
                'pairingId': 'pair-1',
                'hostPublicKey': 'host-public-key',
                'cryptoVersion': 1,
                'hostName': 'Mac',
                'iroh': {
                  'nodeId': 'node-1',
                  'relayUrl': 'https://relay.iroh.network',
                  'directAddresses': ['127.0.0.1:12345'],
                },
              }),
            ),
          )
          .replaceAll('=', '');

      final payload = await parsePairingPayload(qr);
      expect(payload.transport, 'iroh');
      expect(payload.pairingId, 'pair-1');
      expect(payload.iroh?.nodeId, 'node-1');

      final request = irohPairingRequestEnvelope(payload, 'Phone');
      expect(request.type, 'pairing.request');
      expect((request.payload as Map)['pairingId'], 'pair-1');
      expect((request.payload as Map)['deviceName'], 'Phone');
      expect(
        (request.payload as Map)['devicePublicKey'],
        payload.devicePublicKey,
      );
      expect((request.payload as Map).containsKey('name'), isFalse);
      expect((request.payload as Map).containsKey('publicKey'), isFalse);

      final confirmed = irohConfirmedDevice(
        payload: payload,
        name: 'Phone',
        confirmed: const RelayEnvelope(
          type: 'pairing.confirmed',
          payload: {
            'hostId': 'host-1',
            'deviceId': 'device-1',
            'token': 'token-1',
            'hostName': 'Mac',
          },
        ),
      );
      expect(confirmed.transport, 'iroh');
      expect(confirmed.server, isEmpty);
      expect(confirmed.iroh?.nodeId, 'node-1');
      expect(confirmed.iroh?.directAddresses, isEmpty);
      expect(confirmed.toJson()['iroh'], {'nodeId': 'node-1'});
      expect(confirmed.devicePublicKey, payload.devicePublicKey);
    },
  );

  test('pairing payload rejects non-iroh transport', () async {
    final qr = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'transport': 'relay',
              'code': '205503D6',
              'secret': 'pairing-secret',
              'pairingId': 'pair-1',
              'hostPublicKey': 'host-public-key',
              'cryptoVersion': 1,
              'iroh': {'nodeId': 'node-1'},
            }),
          ),
        )
        .replaceAll('=', '');

    expect(() => parsePairingPayload(qr), throwsException);
  });

  test('pairing payload reports missing encrypted fields', () async {
    final qr = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'transport': 'iroh',
              'code': '205503D6',
              'cryptoVersion': 1,
            }),
          ),
        )
        .replaceAll('=', '');

    expect(
      () => parsePairingPayload(qr),
      throwsA(
        isA<Exception>()
            .having((error) => error.toString(), 'message', contains('secret'))
            .having(
              (error) => error.toString(),
              'message',
              contains('pairingId'),
            )
            .having(
              (error) => error.toString(),
              'message',
              contains('hostPublicKey'),
            )
            .having((error) => error.toString(), 'message', contains('iroh')),
      ),
    );
  });

  test('iroh confirmation rejects incomplete device credentials', () async {
    final payload = await parsePairingPayload(
      base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'transport': 'iroh',
                'code': '205503D6',
                'secret': 'pairing-secret',
                'pairingId': 'pair-1',
                'hostPublicKey': 'host-public-key',
                'cryptoVersion': 1,
                'iroh': {'nodeId': 'node-1'},
              }),
            ),
          )
          .replaceAll('=', ''),
    );
    expect(
      () => irohConfirmedDevice(
        payload: payload,
        name: 'Phone',
        confirmed: const RelayEnvelope(
          type: 'pairing.confirmed',
          payload: {'hostId': 'host-1'},
        ),
      ),
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
