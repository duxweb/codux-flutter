import 'dart:convert';
import '../i18n.dart';
import '../models/remote_models.dart';
import 'e2e_crypto.dart';

Future<PairingPayload> parsePairingPayload(String input) async {
  final parsed = _decodePairingPayload(input);
  final transport = parsed['transport']?.toString() ?? '';
  final code = parsed['code']?.toString();
  final secret = parsed['secret']?.toString();
  final hostPublicKey = parsed['hostPublicKey']?.toString() ?? '';
  final cryptoVersion = parsed['cryptoVersion'] is num
      ? (parsed['cryptoVersion'] as num).toInt()
      : int.tryParse('${parsed['cryptoVersion'] ?? ''}') ?? 0;
  final iroh = parsed['iroh'] is Map
      ? IrohNodeAddr.fromJson(Map<String, dynamic>.from(parsed['iroh'] as Map))
      : null;
  final missingFields = <String>[
    if (transport != 'iroh') 'transport=iroh',
    if (code == null || code.isEmpty) 'code',
    if (secret == null || secret.isEmpty) 'secret',
    if (parsed['pairingId']?.toString().trim().isEmpty != false) 'pairingId',
    if (hostPublicKey.isEmpty) 'hostPublicKey',
    if (cryptoVersion < 1) 'cryptoVersion',
    if (iroh == null) 'iroh',
    if (iroh != null && iroh.nodeId.isEmpty) 'iroh.nodeId',
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
    server: '',
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
    transport: transport,
    iroh: iroh,
    pairingId: parsed['pairingId']?.toString(),
  );
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

RelayEnvelope irohPairingRequestEnvelope(PairingPayload payload, String name) {
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

StoredDevice irohConfirmedDevice({
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
  return StoredDevice(
    server: '',
    hostId: '${data['hostId']}',
    deviceId: '${data['deviceId']}',
    token: '${data['token']}',
    name: name,
    hostPublicKey: payload.hostPublicKey,
    devicePrivateKey: payload.devicePrivateKey,
    devicePublicKey: payload.devicePublicKey,
    cryptoVersion: payload.cryptoVersion,
    hostName: data['hostName']?.toString() ?? payload.hostName,
    transport: 'iroh',
    iroh: stableIrohNodeAddr(payload.iroh),
  );
}

IrohNodeAddr? stableIrohNodeAddr(IrohNodeAddr? value) {
  if (value == null) return null;
  return value.stable();
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
