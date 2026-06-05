import 'package:codux_flutter/services/terminal_output_resync.dart';
import 'package:codux_flutter/services/terminal_output_sequencer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('renders delayed burst output in order without resync', () {
    final sequencer = TerminalOutputSequencer();
    final rendered = <int>[];
    final acks = <int>[];
    var requestedFullBuffer = false;

    for (var seq = 1; seq <= 200; seq += 1) {
      final result = observeTerminalOutputForResync(
        sequencer: sequencer,
        sessionId: 'term-1',
        isBuffer: false,
        outputSeq: seq,
        offset: null,
      );
      if (result.render) rendered.add(seq);
      if (result.ack != null) acks.add(result.ack!);
      requestedFullBuffer = requestedFullBuffer || result.requestFullBuffer;
    }

    expect(rendered, List<int>.generate(200, (index) => index + 1));
    expect(acks, List<int>.generate(200, (index) => index + 1));
    expect(requestedFullBuffer, isFalse);
  });

  test('blocks backlog after a gap until full buffer restores state', () {
    final sequencer = TerminalOutputSequencer();
    final rendered = <int>[];
    var fullBufferRequests = 0;

    for (final seq in [1, 2, 5, 6, 7, 8, 9]) {
      final result = observeTerminalOutputForResync(
        sequencer: sequencer,
        sessionId: 'term-1',
        isBuffer: false,
        outputSeq: seq,
        offset: null,
      );
      if (result.render) rendered.add(seq);
      if (result.requestFullBuffer) fullBufferRequests += 1;
    }

    expect(rendered, [1, 2]);
    expect(fullBufferRequests, 5);

    final snapshot = observeTerminalOutputForResync(
      sequencer: sequencer,
      sessionId: 'term-1',
      isBuffer: true,
      outputSeq: 9,
      offset: 0,
    );
    final next = observeTerminalOutputForResync(
      sequencer: sequencer,
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 10,
      offset: null,
    );

    expect(snapshot.render, isTrue);
    expect(snapshot.requestFullBuffer, isFalse);
    expect(next.render, isTrue);
    expect(next.requestFullBuffer, isFalse);
  });
}
