enum TerminalOutputSequenceAction { accept, duplicate, gap, snapshot }

class TerminalOutputSequenceResult {
  const TerminalOutputSequenceResult({
    required this.action,
    required this.previousSeq,
    this.expectedSeq,
  });

  final TerminalOutputSequenceAction action;
  final int previousSeq;
  final int? expectedSeq;

  bool get shouldRender =>
      action == TerminalOutputSequenceAction.accept ||
      action == TerminalOutputSequenceAction.snapshot;
}

class TerminalOutputSequencer {
  final Map<String, int> _seqBySession = {};
  final Set<String> _resyncingSessions = {};

  int sequenceFor(String sessionId) => _seqBySession[sessionId] ?? 0;

  bool isResyncing(String sessionId) => _resyncingSessions.contains(sessionId);

  TerminalOutputSequenceResult observe({
    required String sessionId,
    required bool isBuffer,
    int? outputSeq,
    int? offset,
  }) {
    final previousSeq = sequenceFor(sessionId);
    if (isBuffer) {
      final isFullBuffer = (offset ?? 0) <= 0;
      if (isFullBuffer) {
        _resyncingSessions.remove(sessionId);
        if (outputSeq != null) {
          _seqBySession[sessionId] = outputSeq;
        }
      } else if (outputSeq != null && outputSeq >= previousSeq) {
        _seqBySession[sessionId] = outputSeq;
      }
      return TerminalOutputSequenceResult(
        action: TerminalOutputSequenceAction.snapshot,
        previousSeq: previousSeq,
      );
    }
    if (outputSeq == null) {
      if (_resyncingSessions.contains(sessionId)) {
        return TerminalOutputSequenceResult(
          action: TerminalOutputSequenceAction.gap,
          previousSeq: previousSeq,
        );
      }
      return TerminalOutputSequenceResult(
        action: TerminalOutputSequenceAction.accept,
        previousSeq: previousSeq,
      );
    }
    if (outputSeq <= previousSeq) {
      return TerminalOutputSequenceResult(
        action: TerminalOutputSequenceAction.duplicate,
        previousSeq: previousSeq,
      );
    }
    final expectedSeq = previousSeq + 1;
    if (previousSeq > 0 && outputSeq != expectedSeq) {
      _resyncingSessions.add(sessionId);
      return TerminalOutputSequenceResult(
        action: TerminalOutputSequenceAction.gap,
        previousSeq: previousSeq,
        expectedSeq: expectedSeq,
      );
    }
    if (_resyncingSessions.contains(sessionId)) {
      return TerminalOutputSequenceResult(
        action: TerminalOutputSequenceAction.gap,
        previousSeq: previousSeq,
        expectedSeq: expectedSeq,
      );
    }
    _seqBySession[sessionId] = outputSeq;
    return TerminalOutputSequenceResult(
      action: TerminalOutputSequenceAction.accept,
      previousSeq: previousSeq,
    );
  }

  void remove(String sessionId) {
    _seqBySession.remove(sessionId);
    _resyncingSessions.remove(sessionId);
  }

  void reset() {
    _seqBySession.clear();
    _resyncingSessions.clear();
  }
}
