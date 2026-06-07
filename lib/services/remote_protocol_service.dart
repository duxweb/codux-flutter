import 'dart:convert';
import 'package:http/http.dart' as http;
import '../i18n.dart';
import '../models/remote_models.dart';
import 'e2e_crypto.dart';

const String remoteProtocolVersion = 'v3.0';

Future<PairingPayload> parsePairingPayload(String input) async {
  final parsed = _decodePairingPayload(input);
  final code = parsed['code']?.toString();
  final secret = parsed['secret']?.toString();
  final hostPublicKey = parsed['hostPublicKey']?.toString() ?? '';
  final cryptoVersion = parsed['cryptoVersion'] is num
      ? (parsed['cryptoVersion'] as num).toInt()
      : int.tryParse('${parsed['cryptoVersion'] ?? ''}') ?? 0;
  final transports = _normalizedPairingTransports(parsed);
  final hasSupportedTransport = transports.any(
    (item) =>
        item.kind == RemoteTransportKind.websocketRelay &&
        item.url.trim().isNotEmpty,
  );
  final missingFields = <String>[
    if (code == null || code.isEmpty) 'code',
    if (secret == null || secret.isEmpty) 'secret',
    if (parsed['pairingId']?.toString().trim().isEmpty != false) 'pairingId',
    if (hostPublicKey.isEmpty) 'hostPublicKey',
    if (cryptoVersion < 1) 'cryptoVersion',
    if (!hasSupportedTransport) 'transports.websocketRelay.url',
  ];
  if (missingFields.isNotEmpty) {
    throw Exception(
      '${tr('remote.qrMissingFields', LocaleChoices.system.id)} (${missingFields.join(', ')})',
    );
  }
  final pairingCode = code!;
  final pairingSecret = secret!;
  final deviceKeyPair = await RemoteE2ECrypto.newDeviceKeyPair();
  return PairingPayload(
    code: pairingCode,
    secret: pairingSecret,
    hostPublicKey: hostPublicKey,
    devicePrivateKey: deviceKeyPair.privateKey,
    devicePublicKey: deviceKeyPair.publicKey,
    matchCode: RemoteE2ECrypto.matchCode(
      hostPublicKey: hostPublicKey,
      devicePublicKey: deviceKeyPair.publicKey,
      pairingCode: pairingCode,
      pairingSecret: pairingSecret,
    ),
    cryptoVersion: cryptoVersion,
    hostName: parsed['hostName']?.toString(),
    transports: transports,
    pairingId: parsed['pairingId']?.toString(),
  );
}

List<RemoteTransportCandidate> _normalizedPairingTransports(
  Map<String, dynamic> parsed,
) {
  return remoteTransportCandidatesFromJson(parsed['transports']);
}

Map<String, dynamic> _decodePairingPayload(String input) {
  final value = input.trim();
  if (value.isEmpty) {
    throw Exception(tr('remote.qrEmpty', LocaleChoices.system.id));
  }
  for (final candidate in [value, _tryBase64Decode(value)]) {
    if (candidate == null || candidate.isEmpty) continue;
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  throw Exception(tr('remote.qrInvalid', LocaleChoices.system.id));
}

String? _tryBase64Decode(String value) {
  final normalized = value
      .replaceFirst(RegExp(r'^codux://pair\?data='), '')
      .replaceFirst(RegExp(r'^codux-pair:'), '');
  try {
    return utf8.decode(base64Url.decode(base64Url.normalize(normalized)));
  } catch (_) {}
  try {
    return utf8.decode(base64.decode(base64.normalize(normalized)));
  } catch (_) {}
  return null;
}

RelayEnvelope pairingRequestEnvelope(PairingPayload payload, String name) {
  final pairingId = payload.pairingId?.trim();
  if (pairingId == null || pairingId.isEmpty) {
    throw Exception(tr('remote.qrMissingFields', LocaleChoices.system.id));
  }
  return RelayEnvelope(
    type: 'pairing.request',
    deviceId: payload.devicePublicKey,
    payload: {
      'pairingId': pairingId,
      'code': payload.code,
      'secret': payload.secret,
      'deviceName': name,
      'devicePublicKey': payload.devicePublicKey,
    },
  );
}

Future<StoredDevice> claimPairingOverRelay({
  required PairingPayload payload,
  required String name,
  http.Client? client,
  Duration timeout = const Duration(seconds: 90),
}) async {
  RemoteTransportCandidate? transport;
  for (final candidate in payload.transports) {
    if (candidate.kind == RemoteTransportKind.websocketRelay &&
        candidate.url.trim().isNotEmpty) {
      transport = candidate;
      break;
    }
  }
  if (transport == null) {
    throw Exception(tr('remote.qrMissingFields', LocaleChoices.system.id));
  }
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    await _postJson(httpClient, transport.url, '/api/pairings/claim', {
      'code': payload.code,
      'secret': payload.secret,
      'name': name,
      'publicKey': payload.devicePublicKey,
    });
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final status = await _postJson(
        httpClient,
        transport.url,
        '/api/pairings/status',
        {'code': payload.code, 'secret': payload.secret},
      );
      final state = '${status['status'] ?? ''}';
      if (state == 'confirmed') {
        return confirmedDevice(
          payload: payload,
          name: name,
          confirmed: RelayEnvelope(type: 'pairing.confirmed', payload: status),
        );
      }
      if (state == 'rejected') throw const PairingRejectedException();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    throw Exception(tr('remote.waitTimeout', LocaleChoices.system.id));
  } finally {
    if (ownsClient) httpClient.close();
  }
}

Future<Map<String, dynamic>> _postJson(
  http.Client client,
  String base,
  String path,
  Map<String, dynamic> body,
) async {
  final uri = Uri.parse(base.trim()).replace(path: path, queryParameters: null);
  final response = await client
      .post(
        uri,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 12));
  final decoded = response.body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(response.body);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    if (decoded is Map && decoded['error'] != null) {
      throw Exception(decoded['error']);
    }
    throw Exception('HTTP ${response.statusCode}');
  }
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return <String, dynamic>{};
}

StoredDevice confirmedDevice({
  required PairingPayload payload,
  required String name,
  required RelayEnvelope confirmed,
}) {
  final data = confirmed.payload;
  if (data is! Map ||
      data['hostId'] == null ||
      data['deviceId'] == null ||
      data['token'] == null) {
    throw Exception('Pairing confirmed without device credentials');
  }
  RemoteTransportCandidate? relay;
  for (final candidate in payload.transports) {
    if (candidate.kind == RemoteTransportKind.websocketRelay &&
        candidate.url.trim().isNotEmpty) {
      relay = candidate;
      break;
    }
  }
  final server = relay?.url ?? '';
  return StoredDevice(
    server: server,
    hostId: '${data['hostId']}',
    deviceId: '${data['deviceId']}',
    token: '${data['token']}',
    name: name,
    hostPublicKey: payload.hostPublicKey,
    devicePrivateKey: payload.devicePrivateKey,
    devicePublicKey: payload.devicePublicKey,
    cryptoVersion: payload.cryptoVersion,
    hostName: data['hostName']?.toString() ?? payload.hostName,
    transports: payload.transports,
  );
}

class PairingCancelledException implements Exception {
  const PairingCancelledException();
  @override
  String toString() => tr('pair.cancelled', LocaleChoices.system.id);
}

class PairingRejectedException implements Exception {
  const PairingRejectedException();
  @override
  String toString() => tr('pair.rejected', LocaleChoices.system.id);
}
