import 'terminal_output_sequencer.dart';

class TerminalOutputResyncResult {
  const TerminalOutputResyncResult({
    required this.render,
    required this.requestFullBuffer,
    required this.ack,
  });

  final bool render;
  final bool requestFullBuffer;
  final int? ack;
}

TerminalOutputResyncResult observeTerminalOutputForResync({
  required TerminalOutputSequencer sequencer,
  required String sessionId,
  required bool isBuffer,
  required int? outputSeq,
  required int? offset,
}) {
  final sequence = sequencer.observe(
    sessionId: sessionId,
    isBuffer: isBuffer,
    outputSeq: outputSeq,
    offset: offset,
  );
  switch (sequence.action) {
    case TerminalOutputSequenceAction.accept:
    case TerminalOutputSequenceAction.snapshot:
      return TerminalOutputResyncResult(
        render: true,
        requestFullBuffer: false,
        ack: outputSeq,
      );
    case TerminalOutputSequenceAction.duplicate:
      return TerminalOutputResyncResult(
        render: false,
        requestFullBuffer: false,
        ack: outputSeq,
      );
    case TerminalOutputSequenceAction.gap:
      return TerminalOutputResyncResult(
        render: false,
        requestFullBuffer: true,
        ack: outputSeq,
      );
  }
}
