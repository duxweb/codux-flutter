import 'dart:async';

typedef TerminalBufferTimerFactory =
    Timer Function(Duration delay, void Function() callback);

class TerminalBufferRetryCoordinator {
  TerminalBufferRetryCoordinator({
    this.retryDelay = const Duration(milliseconds: 900),
    this.maxRetries = 3,
    this.onRetryExhausted,
    TerminalBufferTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new;

  final Duration retryDelay;
  final int maxRetries;
  final void Function(String sessionId)? onRetryExhausted;
  final TerminalBufferTimerFactory _timerFactory;

  Timer? _retryTimer;
  String _lastBufferedSessionId = '';
  String? _pendingSessionId;
  int _retryAttempt = 0;

  String get lastBufferedSessionId => _lastBufferedSessionId;
  String? get pendingSessionId => _pendingSessionId;
  int get retryAttempt => _retryAttempt;

  void resetLastBuffered() {
    _lastBufferedSessionId = '';
  }

  void reset() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _lastBufferedSessionId = '';
    _pendingSessionId = null;
    _retryAttempt = 0;
  }

  bool requestIfReady({
    required bool terminalReady,
    required String? sessionId,
    required bool Function(String sessionId) send,
    bool force = false,
  }) {
    final id = sessionId;
    if (!terminalReady ||
        id == null ||
        (!force && _lastBufferedSessionId == id)) {
      return false;
    }
    if (_pendingSessionId != id) {
      _retryAttempt = 0;
    }
    if (!force && _pendingSessionId == id) {
      return false;
    }
    final sent = send(id);
    if (!sent) return false;
    _lastBufferedSessionId = id;
    _pendingSessionId = id;
    _scheduleRetry(id, send);
    return true;
  }

  void markReceived({
    required String? sessionId,
    required String? activeSessionId,
  }) {
    final id = sessionId ?? activeSessionId;
    if (id == null || _pendingSessionId != id) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _pendingSessionId = null;
    _retryAttempt = 0;
    _lastBufferedSessionId = id;
  }

  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _scheduleRetry(String sessionId, bool Function(String sessionId) send) {
    _retryTimer?.cancel();
    if (_retryAttempt >= maxRetries) {
      onRetryExhausted?.call(sessionId);
      return;
    }
    _retryTimer = _timerFactory(retryDelay, () {
      if (_pendingSessionId != sessionId) return;
      _retryAttempt += 1;
      _lastBufferedSessionId = '';
      requestIfReady(
        terminalReady: true,
        sessionId: sessionId,
        send: send,
        force: true,
      );
    });
  }
}
