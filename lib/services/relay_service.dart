import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../i18n.dart';
import '../models/remote_models.dart';

PairingPayload parsePairingPayload(String input) {
  final parsed = _decodePairingPayload(input);
  final server = parsed['server']?.toString().replaceFirst(RegExp(r'/$'), '');
  final code = parsed['code']?.toString();
  final secret = parsed['secret']?.toString();
  if (server == null ||
      server.isEmpty ||
      code == null ||
      code.isEmpty ||
      secret == null ||
      secret.isEmpty) {
    throw Exception(tr('relay.qrMissingFields', LocaleChoices.system.id));
  }
  return PairingPayload(
    server: server,
    code: code,
    secret: secret,
    hostName: parsed['hostName']?.toString(),
  );
}

Map<String, dynamic> _decodePairingPayload(String input) {
  final value = input.trim();
  if (value.isEmpty) {
    throw Exception(tr('relay.qrEmpty', LocaleChoices.system.id));
  }
  for (final candidate in [value, _tryBase64Decode(value)]) {
    if (candidate == null || candidate.isEmpty) continue;
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  throw Exception(tr('relay.qrInvalid', LocaleChoices.system.id));
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

Future<Map<String, dynamic>> postJson(
  String server,
  String path,
  Object body,
) async {
  final uri = Uri.parse('$server$path');
  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );
  final data = response.body.isEmpty
      ? <String, dynamic>{}
      : (jsonDecode(response.body) as Map<String, dynamic>);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(
      data['error']?.toString() ??
          tr(
            'relay.requestFailed',
            LocaleChoices.system.id,
            params: {'status': '${response.statusCode}'},
          ),
    );
  }
  return data;
}

Future<void> claimPairing(PairingPayload payload, String name) async {
  await postJson(payload.server, '/api/pairings/claim', {
    'code': payload.code,
    'secret': payload.secret,
    'name': name,
    'publicKey': '',
  });
}

class PairingCancelledException implements Exception {
  const PairingCancelledException();
  @override
  String toString() => tr('pair.cancelled', LocaleChoices.system.id);
}

Future<StoredDevice> waitPairingConfirmed(
  PairingPayload payload,
  String name, {
  bool Function()? isCancelled,
}) async {
  for (var index = 0; index < 90; index += 1) {
    if (isCancelled?.call() == true) throw const PairingCancelledException();
    final status = await postJson(payload.server, '/api/pairings/status', {
      'code': payload.code,
      'secret': payload.secret,
    });
    if (isCancelled?.call() == true) throw const PairingCancelledException();
    if (status['status'] == 'confirmed' &&
        status['deviceId'] != null &&
        status['token'] != null) {
      return StoredDevice(
        server: payload.server,
        hostId: '${status['hostId']}',
        deviceId: '${status['deviceId']}',
        token: '${status['token']}',
        name: name,
        hostName: status['hostName']?.toString() ?? payload.hostName,
      );
    }
    for (var step = 0; step < 20; step += 1) {
      if (isCancelled?.call() == true) throw const PairingCancelledException();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw Exception(tr('relay.waitTimeout', LocaleChoices.system.id));
}

WebSocketChannel createRelaySocket(StoredDevice device) {
  final server = device.server
      .replaceFirst(RegExp('^http:'), 'ws:')
      .replaceFirst(RegExp('^https:'), 'wss:');
  final uri = Uri.parse('$server/ws/client').replace(
    queryParameters: {
      'hostId': device.hostId,
      'deviceId': device.deviceId,
      'token': device.token,
    },
  );
  return IOWebSocketChannel.connect(
    uri,
    pingInterval: const Duration(seconds: 25),
  );
}

String encodeEnvelope(RelayEnvelope message) => jsonEncode(message.toJson());
