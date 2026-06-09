import 'package:codux_flutter/services/remote_terminal_replica.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('holds live output until the bound session snapshot arrives', () {
    final replica = RemoteTerminalReplica<String>();

    replica.bindSession('session-1', requireSnapshot: true);

    expect(
      replica.holdLiveOutput(
        sessionId: 'session-1',
        isBuffer: false,
        outputSeq: 12,
        output: 'live-12',
      ),
      isTrue,
    );
    expect(
      replica.holdLiveOutput(
        sessionId: 'session-1',
        isBuffer: false,
        outputSeq: 11,
        output: 'live-11',
      ),
      isTrue,
    );

    final replay = replica.acceptSnapshot(
      sessionId: 'session-1',
      isBuffer: true,
      offset: 0,
      truncated: false,
      outputSeq: 11,
    );

    expect(replay, ['live-12']);
    expect(replica.isAwaitingSnapshot('session-1'), isFalse);
  });

  test('does not release snapshot barrier for partial buffers', () {
    final replica = RemoteTerminalReplica<String>();

    replica.bindSession('session-1', requireSnapshot: true);
    final replay = replica.acceptSnapshot(
      sessionId: 'session-1',
      isBuffer: true,
      offset: 20,
      truncated: false,
      outputSeq: 3,
    );

    expect(replay, isEmpty);
    expect(replica.isAwaitingSnapshot('session-1'), isTrue);
  });

  test('assembles paged snapshot before releasing data', () {
    final replica = RemoteTerminalReplica<String>();

    replica.bindSession('session-1', requireSnapshot: true);

    final first = replica.acceptSnapshotPage(
      sessionId: 'session-1',
      data: 'abcd',
      offset: 0,
      bufferLength: 8,
      truncated: true,
    );

    expect(first.accepted, isTrue);
    expect(first.ready, isFalse);
    expect(first.data, isEmpty);
    expect(first.nextOffset, 4);
    expect(first.progress, 0.5);
    expect(replica.isRestoringSnapshot('session-1'), isTrue);

    final second = replica.acceptSnapshotPage(
      sessionId: 'session-1',
      data: 'efgh',
      offset: 4,
      bufferLength: 8,
      truncated: false,
    );

    expect(second.accepted, isTrue);
    expect(second.ready, isTrue);
    expect(second.data, 'abcdefgh');
    expect(second.nextOffset, 8);
    expect(second.progress, 1);
    expect(replica.isRestoringSnapshot('session-1'), isTrue);
  });

  test('rejects out of order paged snapshot offsets', () {
    final replica = RemoteTerminalReplica<String>();

    replica.bindSession('session-1', requireSnapshot: true);
    replica.acceptSnapshotPage(
      sessionId: 'session-1',
      data: 'abcd',
      offset: 0,
      bufferLength: 8,
      truncated: true,
    );

    final result = replica.acceptSnapshotPage(
      sessionId: 'session-1',
      data: 'gh',
      offset: 6,
      bufferLength: 8,
      truncated: false,
    );

    expect(result.accepted, isFalse);
    expect(result.ready, isFalse);
    expect(result.nextOffset, 4);
    expect(replica.isRestoringSnapshot('session-1'), isTrue);
  });
}
