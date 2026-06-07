import 'dart:convert';

import 'package:codux_flutter/models/remote_models.dart';
import 'package:codux_flutter/services/e2e_crypto.dart';
import 'package:codux_flutter/services/remote_protocol_service.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('stored device reads v3 transport candidates', () {
    final device = StoredDevice.fromJson({
      'server': 'https://codux-service.dux.plus',
      'hostId': 'host-1',
      'deviceId': 'device-1',
      'token': 'token-1',
      'name': 'Phone',
      'transports': [
        {
          'kind': 'websocketRelay',
          'role': 'host',
          'url': 'https://codux-service.dux.plus',
        },
      ],
    });

    expect(device.transport, RemoteTransportKind.websocketRelay);
    expect(device.preferredTransport.url, 'https://codux-service.dux.plus');
  });

  test(
    'v3 pairing payload and confirmation use transport candidates',
    () async {
      final qr = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'protocolVersion': remoteProtocolVersion,
                'code': '205503D6',
                'secret': 'pairing-secret',
                'pairingId': 'pair-1',
                'hostPublicKey': 'host-public-key',
                'cryptoVersion': 1,
                'hostName': 'Mac',
                'transports': [
                  {
                    'kind': 'websocketRelay',
                    'role': 'host',
                    'url': 'https://codux-service.dux.plus',
                  },
                  {
                    'kind': 'webRtc',
                    'role': 'host',
                    'url': 'https://codux-service.dux.plus',
                  },
                ],
              }),
            ),
          )
          .replaceAll('=', '');

      final payload = await parsePairingPayload(qr);
      expect(payload.transport.kind, RemoteTransportKind.websocketRelay);
      expect(payload.pairingId, 'pair-1');
      expect(payload.transport.url, 'https://codux-service.dux.plus');

      final request = pairingRequestEnvelope(payload, 'Phone');
      expect(request.type, 'pairing.request');
      expect((request.payload as Map)['pairingId'], 'pair-1');
      expect((request.payload as Map)['deviceName'], 'Phone');
      expect(
        (request.payload as Map)['devicePublicKey'],
        payload.devicePublicKey,
      );

      final confirmed = confirmedDevice(
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
      expect(confirmed.transport, RemoteTransportKind.webRtc);
      expect(confirmed.server, 'https://codux-service.dux.plus');
      expect(confirmed.devicePublicKey, payload.devicePublicKey);
      expect(confirmed.toJson()['transports'], [
        {
          'kind': 'websocketRelay',
          'role': 'host',
          'url': 'https://codux-service.dux.plus',
        },
        {
          'kind': 'webRtc',
          'role': 'host',
          'url': 'https://codux-service.dux.plus',
        },
      ]);
    },
  );

  test('pairing payload rejects missing supported transport', () async {
    final qr = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'protocolVersion': remoteProtocolVersion,
              'code': '205503D6',
              'secret': 'pairing-secret',
              'pairingId': 'pair-1',
              'hostPublicKey': 'host-public-key',
              'cryptoVersion': 1,
              'transports': [
                {'kind': 'webRtc'},
              ],
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
              'protocolVersion': remoteProtocolVersion,
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
            .having(
              (error) => error.toString(),
              'message',
              contains('transports.websocketRelay.url'),
            ),
      ),
    );
  });

  test('confirmation rejects incomplete device credentials', () async {
    final payload = await parsePairingPayload(
      base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'protocolVersion': remoteProtocolVersion,
                'code': '205503D6',
                'secret': 'pairing-secret',
                'pairingId': 'pair-1',
                'hostPublicKey': 'host-public-key',
                'cryptoVersion': 1,
                'transports': [
                  {
                    'kind': 'websocketRelay',
                    'url': 'https://codux-service.dux.plus',
                  },
                ],
              }),
            ),
          )
          .replaceAll('=', ''),
    );
    expect(
      () => confirmedDevice(
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
