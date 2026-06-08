import 'package:codux_flutter/services/remote_sync_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connection generation resets loaded flags and retry attempts', () {
    final state = RemoteSyncState()
      ..markProjectListReceived()
      ..markTerminalListReceived()
      ..nextProjectListRetryAttempt()
      ..nextTerminalListRetryAttempt();

    state.beginConnectionGeneration();

    expect(state.projectListLoaded, isFalse);
    expect(state.terminalListLoaded, isFalse);
    expect(state.projectListRetryAttempt, 0);
    expect(state.terminalListRetryAttempt, 0);
    expect(state.shouldRequestProjectList(), isTrue);
    expect(state.shouldRequestTerminalList(), isTrue);
  });

  test('loaded lists are not requested again unless forced', () {
    final state = RemoteSyncState()
      ..markProjectListReceived()
      ..markTerminalListReceived();

    expect(state.shouldRequestProjectList(), isFalse);
    expect(state.shouldRequestTerminalList(), isFalse);
    expect(state.shouldRequestProjectList(force: true), isTrue);
    expect(state.shouldRequestTerminalList(force: true), isTrue);
  });
}
