import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/remote_models.dart';
import 'log_service.dart';

typedef P2PSignalSender = bool Function(RelayEnvelope message);
typedef P2PEnvelopeHandler = void Function(RelayEnvelope message);
typedef P2PStateHandler = void Function(String state);

class P2PTerminalTransport {
  P2PTerminalTransport({
    required P2PSignalSender sendSignal,
    required P2PEnvelopeHandler onEnvelope,
    P2PStateHandler? onState,
    bool preferDomesticStun = false,
  }) : _sendSignal = sendSignal,
       _onEnvelope = onEnvelope,
       _onState = onState,
       _preferDomesticStun = preferDomesticStun;

  static const channelLabel = 'codux-terminal';
  static const _domesticStunUrls = ['stun:stun.miwifi.com:3478'];
  static const _globalStunUrls = [
    'stun:stun.l.google.com:19302',
    'stun:global.stun.twilio.com:3478',
  ];

  final P2PSignalSender _sendSignal;
  final P2PEnvelopeHandler _onEnvelope;
  final P2PStateHandler? _onState;
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  bool _starting = false;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  String _state = 'idle';
  bool _preferDomesticStun;

  String get state => _state;
  bool get isOpen => _channel?.state == RTCDataChannelState.RTCDataChannelOpen;

  void setPreferDomesticStun(bool value) {
    _preferDomesticStun = value;
  }

  Future<void> ensureStarted() async {
    if (isOpen || _starting || _peer != null) return;
    _starting = true;
    _setState('connecting');
    try {
      final peer = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
        'iceServers': [
          {'urls': _stunUrls()},
        ],
      });
      _peer = peer;
      peer.onIceCandidate = (candidate) {
        final value = candidate.candidate;
        if (value == null || value.isEmpty) return;
        _sendSignal(
          RelayEnvelope(
            type: 'p2p.candidate',
            payload: {
              'candidate': value,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          ),
        );
      };
      peer.onConnectionState = (state) {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _setState('connected');
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _setState('failed');
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _setState('disconnected');
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            _setState('closed');
          default:
            break;
        }
      };
      final channel = await peer.createDataChannel(
        channelLabel,
        RTCDataChannelInit()
          ..ordered = true
          ..binaryType = 'text',
      );
      _attachChannel(channel);
      final offer = await peer.createOffer({});
      await peer.setLocalDescription(offer);
      _sendSignal(
        RelayEnvelope(
          type: 'p2p.offer',
          payload: {'type': offer.type ?? 'offer', 'sdp': offer.sdp ?? ''},
        ),
      );
    } catch (error) {
      CoduxLog.error('[codux-flutter-p2p] start failed: $error');
      _setState('failed');
      await close();
    } finally {
      _starting = false;
    }
  }

  Future<void> handleAnswer(Map<dynamic, dynamic> payload) async {
    final peer = _peer;
    final sdp = payload['sdp']?.toString();
    if (peer == null || sdp == null || sdp.isEmpty) return;
    await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescriptionSet = true;
    for (final candidate in List<RTCIceCandidate>.from(_pendingCandidates)) {
      await peer.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> handleCandidate(Map<dynamic, dynamic> payload) async {
    final candidate = payload['candidate']?.toString();
    if (candidate == null || candidate.isEmpty) return;
    final sdpMid = payload['sdpMid']?.toString();
    final lineValue = payload['sdpMLineIndex'];
    final sdpMLineIndex = lineValue is num
        ? lineValue.toInt()
        : int.tryParse('${lineValue ?? ''}');
    final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    final peer = _peer;
    if (peer == null || !_remoteDescriptionSet) {
      _pendingCandidates.add(ice);
      return;
    }
    await peer.addCandidate(ice);
  }

  void handleState(Map<dynamic, dynamic> payload) {
    final state = payload['state']?.toString();
    if (state == null || state.isEmpty) return;
    _setState(state);
  }

  bool sendEnvelope(RelayEnvelope message) {
    final channel = _channel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    channel.send(RTCDataChannelMessage(jsonEncode(message.toJson())));
    return true;
  }

  Future<void> close() async {
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await channel.close();
    }
    final peer = _peer;
    _peer = null;
    if (peer != null) {
      await peer.close();
      await peer.dispose();
    }
    _setState('closed');
  }

  void _attachChannel(RTCDataChannel channel) {
    _channel = channel;
    channel.onDataChannelState = (state) {
      switch (state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          _setState('connected');
        case RTCDataChannelState.RTCDataChannelClosed:
          _setState('closed');
        default:
          break;
      }
    };
    channel.onMessage = (message) {
      try {
        final text = message.isBinary
            ? utf8.decode(message.binary)
            : message.text;
        _onEnvelope(
          RelayEnvelope.fromJson(jsonDecode(text) as Map<String, dynamic>),
        );
      } catch (error) {
        CoduxLog.warn('[codux-flutter-p2p] drop malformed message: $error');
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _setState('connected');
    }
  }

  List<String> _stunUrls() {
    if (_preferDomesticStun) {
      return [..._domesticStunUrls, ..._globalStunUrls];
    }
    return [..._globalStunUrls, ..._domesticStunUrls];
  }

  void _setState(String next) {
    if (_state == next) return;
    _state = next;
    _onState?.call(next);
  }
}
