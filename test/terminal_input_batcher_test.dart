import 'dart:async';

import 'package:codux_flutter/services/terminal_input_batcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('coalesces printable input until delay fires', () {
    final timers = <_FakeTimer>[];
    final sent = <String>[];
    final batcher = TerminalInputBatcher(
      send: sent.add,
      timerFactory: (delay, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );

    batcher.add('l');
    batcher.add('s');

    expect(sent, isEmpty);
    expect(batcher.pendingData, 'ls');

    timers.last.fire();

    expect(sent, ['ls']);
    expect(batcher.hasPendingData, isFalse);
  });

  test('flushes pending printable input before control keys', () {
    final timers = <_FakeTimer>[];
    final sent = <String>[];
    final batcher = TerminalInputBatcher(
      send: sent.add,
      timerFactory: (delay, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );

    batcher.add('git status');
    batcher.add('\r');

    expect(sent, ['git status', '\r']);
    expect(batcher.hasPendingData, isFalse);
    timers.single.fire();
    expect(sent, ['git status', '\r']);
  });

  test('flushes when batch reaches size limit', () {
    final sent = <String>[];
    final batcher = TerminalInputBatcher(send: sent.add, maxBatchCharacters: 3);

    batcher.add('a');
    batcher.add('bc');

    expect(sent, ['abc']);
    expect(batcher.hasPendingData, isFalse);
  });

  test('reset discards pending input', () {
    final timers = <_FakeTimer>[];
    final sent = <String>[];
    final batcher = TerminalInputBatcher(
      send: sent.add,
      timerFactory: (delay, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );

    batcher.add('abc');
    batcher.reset();
    timers.single.fire();

    expect(sent, isEmpty);
    expect(batcher.hasPendingData, isFalse);
  });
}

final class _FakeTimer implements Timer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  var _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
