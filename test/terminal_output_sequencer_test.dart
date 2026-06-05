import 'package:codux_flutter/services/terminal_output_sequencer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts ordered terminal output', () {
    final sequencer = TerminalOutputSequencer();

    final first = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 1,
    );
    final second = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 2,
    );

    expect(first.action, TerminalOutputSequenceAction.accept);
    expect(second.action, TerminalOutputSequenceAction.accept);
    expect(sequencer.sequenceFor('term-1'), 2);
  });

  test('drops duplicate terminal output', () {
    final sequencer = TerminalOutputSequencer()
      ..observe(sessionId: 'term-1', isBuffer: false, outputSeq: 1)
      ..observe(sessionId: 'term-1', isBuffer: false, outputSeq: 2);

    final duplicate = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 2,
    );

    expect(duplicate.action, TerminalOutputSequenceAction.duplicate);
    expect(duplicate.previousSeq, 2);
    expect(sequencer.sequenceFor('term-1'), 2);
  });

  test('detects gaps and blocks later deltas until full buffer arrives', () {
    final sequencer = TerminalOutputSequencer()
      ..observe(sessionId: 'term-1', isBuffer: false, outputSeq: 1);

    final gap = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 3,
    );
    final laterDelta = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 4,
    );

    expect(gap.action, TerminalOutputSequenceAction.gap);
    expect(gap.expectedSeq, 2);
    expect(laterDelta.action, TerminalOutputSequenceAction.gap);
    expect(sequencer.sequenceFor('term-1'), 1);
    expect(sequencer.isResyncing('term-1'), isTrue);
  });

  test('full buffer clears gap state and resumes ordered output', () {
    final sequencer = TerminalOutputSequencer()
      ..observe(sessionId: 'term-1', isBuffer: false, outputSeq: 1)
      ..observe(sessionId: 'term-1', isBuffer: false, outputSeq: 3);

    final snapshot = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: true,
      outputSeq: 3,
      offset: 0,
    );
    final next = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 4,
    );

    expect(snapshot.action, TerminalOutputSequenceAction.snapshot);
    expect(sequencer.isResyncing('term-1'), isFalse);
    expect(next.action, TerminalOutputSequenceAction.accept);
    expect(sequencer.sequenceFor('term-1'), 4);
  });

  test('full buffer can reset sequence after host restart', () {
    final sequencer = TerminalOutputSequencer()
      ..observe(sessionId: 'term-1', isBuffer: false, outputSeq: 8);

    final snapshot = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: true,
      outputSeq: 0,
      offset: 0,
    );
    final next = sequencer.observe(
      sessionId: 'term-1',
      isBuffer: false,
      outputSeq: 1,
    );

    expect(snapshot.action, TerminalOutputSequenceAction.snapshot);
    expect(next.action, TerminalOutputSequenceAction.accept);
    expect(sequencer.sequenceFor('term-1'), 1);
  });
}
