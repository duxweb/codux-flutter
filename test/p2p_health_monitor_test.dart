import 'dart:async';

import 'package:codux_flutter/services/p2p_health_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('marks p2p stable only after matching pong', () {
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final sent = <String>[];
    final changes = <bool>[];
    final timers = <_FakeTimer>[];
    final monitor = P2PHealthMonitor(
      isOpen: () => true,
      sendPing: (id) {
        sent.add(id);
        return true;
      },
      onStableChanged: changes.add,
      now: () => now,
      timerFactory: (delay, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );

    monitor.start();

    expect(monitor.stable, isFalse);
    expect(sent, ['1000000-1']);
    expect(monitor.handlePong('wrong-id'), isNull);
    expect(monitor.stable, isFalse);

    now = now.add(const Duration(milliseconds: 42));
    expect(monitor.handlePong(sent.single), 42);

    expect(monitor.stable, isTrue);
    expect(monitor.misses, 0);
    expect(changes, [true]);
    expect(timers.single.isActive, isTrue);
  });

  test('downgrades p2p after repeated missed pongs', () {
    var now = DateTime.fromMillisecondsSinceEpoch(2000);
    final sent = <String>[];
    final changes = <bool>[];
    final timers = <_FakeTimer>[];
    final monitor = P2PHealthMonitor(
      isOpen: () => true,
      sendPing: (id) {
        sent.add(id);
        return true;
      },
      onStableChanged: changes.add,
      now: () => now,
      timerFactory: (delay, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );

    monitor.start();
    now = now.add(const Duration(milliseconds: 20));
    monitor.handlePong(sent.last);
    expect(monitor.stable, isTrue);

    now = now.add(const Duration(seconds: 3));
    timers.single.fire();
    expect(monitor.misses, 0);
    expect(monitor.stable, isTrue);

    now = now.add(const Duration(seconds: 3));
    timers.single.fire();
    expect(monitor.misses, 1);
    expect(monitor.stable, isTrue);

    now = now.add(const Duration(seconds: 3));
    timers.single.fire();
    expect(monitor.misses, 2);
    expect(monitor.stable, isFalse);
    expect(changes, [true, false]);
  });

  test('resets p2p health when data channel is no longer open', () {
    var open = true;
    var now = DateTime.fromMillisecondsSinceEpoch(3000);
    final sent = <String>[];
    final changes = <bool>[];
    final timers = <_FakeTimer>[];
    final monitor = P2PHealthMonitor(
      isOpen: () => open,
      sendPing: (id) {
        sent.add(id);
        return true;
      },
      onStableChanged: changes.add,
      now: () => now,
      timerFactory: (delay, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );

    monitor.start();
    now = now.add(const Duration(milliseconds: 12));
    monitor.handlePong(sent.single);
    expect(monitor.stable, isTrue);

    open = false;
    timers.single.fire();

    expect(monitor.stable, isFalse);
    expect(monitor.isRunning, isFalse);
    expect(changes, [true, false]);
  });
}

final class _FakeTimer implements Timer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  var _active = true;
  var _tick = 0;

  void fire() {
    if (!_active) return;
    _tick += 1;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}
