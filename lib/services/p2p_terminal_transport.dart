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
  static const uploadChannelLabel = 'codux-upload';
  static const _domesticStunUrls = ['stun:stun.miwifi.com:3478'];
  static const _globalStunUrls = [
    'stun:stun.l.google.com:19302',
    'stun:global.stun.twilio.com:3478',
  ];
  static const _terminalBufferedAmountHighWatermark = 192 * 1024;
  static const _terminalBufferedAmountLowWatermark = 48 * 1024;
  static const _bufferedAmountHighWatermark = 512 * 1024;
  static const _bufferedAmountLowWatermark = 128 * 1024;

  final P2PSignalSender _sendSignal;
  final P2PEnvelopeHandler _onEnvelope;
  final P2PStateHandler? _onState;
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  RTCDataChannel? _uploadChannel;
  bool _starting = false;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  String _state = 'idle';
  bool _preferDomesticStun;
  Timer? _disconnectTimer;

  String get state => _state;
  bool get isOpen => _isChannelOpen(_channel);
  bool get isUploadOpen => _isChannelOpen(_uploadChannel);

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
            if (isOpen) {
              _disconnectTimer?.cancel();
              _disconnectTimer = null;
              _setState('connected');
            }
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _disconnectTimer?.cancel();
            _disconnectTimer = null;
            _setState('failed');
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _scheduleDisconnectGrace();
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            _disconnectTimer?.cancel();
            _disconnectTimer = null;
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
      _attachChannel(channel, primary: true);
      final uploadChannel = await peer.createDataChannel(
        uploadChannelLabel,
        RTCDataChannelInit()
          ..ordered = true
          ..binaryType = 'text',
      );
      _attachChannel(uploadChannel, upload: true);
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
    final channel = _channelForMessage(message);
    if (!_isChannelOpen(channel)) {
      return false;
    }
    return _sendOnChannel(channel!, message);
  }

  bool _sendOnChannel(RTCDataChannel channel, RelayEnvelope message) {
    CoduxLog.debug(
      '[codux-flutter-p2p] send type=${message.type} session=${message.sessionId ?? ''}',
    );
    unawaited(
      channel
          .send(RTCDataChannelMessage(jsonEncode(message.toJson())))
          .catchError((Object error) {
            CoduxLog.warn('[codux-flutter-p2p] send failed: $error');
          }),
    );
    return true;
  }

  Future<bool> sendEnvelopeWithBackpressure(RelayEnvelope message) async {
    if (!await waitForBufferedAmountLow(upload: _isUploadMessage(message))) {
      return false;
    }
    return sendEnvelope(message);
  }

  Future<bool> waitUntilOpen({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    if (isOpen) return true;
    final completer = Completer<bool>();
    final timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(isOpen);
      }
    });
    final pollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (isOpen && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    try {
      return await completer.future;
    } finally {
      timeoutTimer.cancel();
      pollTimer.cancel();
    }
  }

  Future<bool> waitForBufferedAmountLow({
    bool upload = false,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final channel = upload ? _uploadChannel : _channel;
    if (!_isChannelOpen(channel)) {
      return false;
    }
    final highWatermark = upload
        ? _bufferedAmountHighWatermark
        : _terminalBufferedAmountHighWatermark;
    final lowWatermark = upload
        ? _bufferedAmountLowWatermark
        : _terminalBufferedAmountLowWatermark;
    int amount;
    try {
      amount = await channel!.getBufferedAmount();
    } catch (_) {
      amount = channel!.bufferedAmount ?? 0;
    }
    if (amount <= highWatermark) return true;

    final completer = Completer<bool>();
    final previousLow = channel.onBufferedAmountLow;
    final previousChange = channel.onBufferedAmountChange;
    void completeIfLow(int currentAmount) {
      if (currentAmount > lowWatermark || completer.isCompleted) {
        return;
      }
      completer.complete(true);
    }

    channel.bufferedAmountLowThreshold = lowWatermark;
    channel.onBufferedAmountLow = (currentAmount) {
      previousLow?.call(currentAmount);
      completeIfLow(currentAmount);
    };
    channel.onBufferedAmountChange = (currentAmount, changedAmount) {
      previousChange?.call(currentAmount, changedAmount);
      completeIfLow(currentAmount);
    };

    Timer? pollTimer;
    pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final current = upload ? _uploadChannel : _channel;
      if (current != channel ||
          current?.state != RTCDataChannelState.RTCDataChannelOpen) {
        if (!completer.isCompleted) completer.complete(false);
        return;
      }
      try {
        completeIfLow(await channel.getBufferedAmount());
      } catch (_) {
        completeIfLow(channel.bufferedAmount ?? 0);
      }
    });

    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      pollTimer.cancel();
      if (_channel == channel || _uploadChannel == channel) {
        channel.onBufferedAmountLow = previousLow;
        channel.onBufferedAmountChange = previousChange;
      }
    }
  }

  Future<void> close() async {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await channel.close();
    }
    final uploadChannel = _uploadChannel;
    _uploadChannel = null;
    if (uploadChannel != null && uploadChannel != channel) {
      await uploadChannel.close();
    }
    final peer = _peer;
    _peer = null;
    if (peer != null) {
      await peer.close();
      await peer.dispose();
    }
    _setState('closed');
  }

  void _attachChannel(
    RTCDataChannel channel, {
    bool primary = false,
    bool upload = false,
  }) {
    if (primary) {
      _channel = channel;
    }
    if (upload) {
      _uploadChannel = channel;
    }
    channel.onDataChannelState = (state) {
      switch (state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          if (channel == _channel) _setState('connected');
        case RTCDataChannelState.RTCDataChannelClosed:
          if (channel == _channel) _setState('closed');
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
    if (channel == _channel &&
        channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _setState('connected');
    }
  }

  RTCDataChannel? _channelForMessage(RelayEnvelope message) {
    if (_isUploadMessage(message)) {
      return _uploadChannel;
    }
    return _channel;
  }

  bool _isUploadMessage(RelayEnvelope message) {
    return message.type.startsWith('terminal.upload.');
  }

  bool _isChannelOpen(RTCDataChannel? channel) {
    return channel?.state == RTCDataChannelState.RTCDataChannelOpen;
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

  void _scheduleDisconnectGrace() {
    if (_state == 'disconnected' || _state == 'closed') return;
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(const Duration(seconds: 5), () {
      _disconnectTimer = null;
      if (_peer == null || isOpen) return;
      _setState('disconnected');
    });
  }
}
