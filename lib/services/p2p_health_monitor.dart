import 'dart:async';

typedef P2PHealthTimerFactory =
    Timer Function(Duration interval, void Function() callback);
typedef P2PHealthNow = DateTime Function();
typedef P2PHealthPingSender = bool Function(String id);
typedef P2PHealthOpenCheck = bool Function();
typedef P2PHealthChanged = void Function(bool stable);

class P2PHealthMonitor {
  P2PHealthMonitor({
    required this.isOpen,
    required this.sendPing,
    this.onStableChanged,
    this.interval = const Duration(seconds: 3),
    this.staleAfter = const Duration(milliseconds: 2500),
    this.maxMisses = 2,
    P2PHealthNow? now,
    P2PHealthTimerFactory? timerFactory,
  }) : _now = now ?? DateTime.now,
       _timerFactory =
           timerFactory ??
           ((duration, callback) =>
               Timer.periodic(duration, (_) => callback()));

  final P2PHealthOpenCheck isOpen;
  final P2PHealthPingSender sendPing;
  final P2PHealthChanged? onStableChanged;
  final Duration interval;
  final Duration staleAfter;
  final int maxMisses;
  final P2PHealthNow _now;
  final P2PHealthTimerFactory _timerFactory;

  Timer? _timer;
  DateTime? _pendingSentAt;
  String? _pendingId;
  int _misses = 0;
  int _sequence = 0;
  bool _stable = false;

  bool get stable => _stable;
  int get misses => _misses;
  String? get pendingId => _pendingId;
  bool get isRunning => _timer?.isActive == true;

  void start() {
    if (isRunning) return;
    _misses = 0;
    _sendNextPing();
    _timer = _timerFactory(interval, _sendNextPing);
  }

  void reset({bool notify = false}) {
    _timer?.cancel();
    _timer = null;
    _pendingSentAt = null;
    _pendingId = null;
    _misses = 0;
    _setStable(false, notify: notify);
  }

  int? handlePong(String? id) {
    final sentAt = _pendingSentAt;
    if (id == null || id != _pendingId || sentAt == null) return null;
    final rtt = _now().difference(sentAt).inMilliseconds;
    _pendingSentAt = null;
    _pendingId = null;
    _misses = 0;
    _setStable(true, notify: true);
    return rtt;
  }

  void dispose() {
    reset();
  }

  void _sendNextPing() {
    if (!isOpen()) {
      reset(notify: true);
      return;
    }

    final sentAt = _pendingSentAt;
    if (sentAt != null && _now().difference(sentAt) > staleAfter) {
      _misses += 1;
      if (_misses >= maxMisses) {
        _setStable(false, notify: true);
      }
    }

    final id = '${_now().microsecondsSinceEpoch}-${++_sequence}';
    _pendingId = id;
    _pendingSentAt = _now();
    if (!sendPing(id)) {
      _misses += 1;
      if (_misses >= maxMisses) {
        reset(notify: true);
      }
    }
  }

  void _setStable(bool next, {required bool notify}) {
    if (_stable == next) return;
    _stable = next;
    if (notify) onStableChanged?.call(next);
  }
}
