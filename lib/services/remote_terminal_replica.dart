class RemoteTerminalReplica<T> {
  final Map<String, _RemoteTerminalReplicaSession<T>> _sessions = {};

  void bindSession(String sessionId, {required bool requireSnapshot}) {
    if (sessionId.trim().isEmpty) return;
    final session = _sessions.putIfAbsent(
      sessionId,
      _RemoteTerminalReplicaSession.new,
    );
    session.heldLive.clear();
    session.unsequencedLive.clear();
    if (requireSnapshot) {
      session.awaitingSnapshot = true;
    } else {
      session.awaitingSnapshot = false;
    }
  }

  bool isAwaitingSnapshot(String? sessionId) {
    if (sessionId == null || sessionId.trim().isEmpty) return false;
    return _sessions[sessionId]?.awaitingSnapshot ?? false;
  }

  bool isRestoringSnapshot(String? sessionId) {
    if (sessionId == null || sessionId.trim().isEmpty) return false;
    final session = _sessions[sessionId];
    return session?.awaitingSnapshot == true || session?.pageBuffer != null;
  }

  bool holdLiveOutput({
    required String sessionId,
    required bool isBuffer,
    required int? outputSeq,
    required T output,
  }) {
    if (isBuffer || !isAwaitingSnapshot(sessionId)) return false;
    final session = _sessions.putIfAbsent(
      sessionId,
      _RemoteTerminalReplicaSession.new,
    );
    if (outputSeq == null) {
      session.unsequencedLive.add(output);
    } else {
      session.heldLive.putIfAbsent(outputSeq, () => output);
    }
    return true;
  }

  List<T> acceptSnapshot({
    required String sessionId,
    required bool isBuffer,
    required int? offset,
    required bool truncated,
    required int? outputSeq,
  }) {
    if (!isBuffer) return const [];
    if ((offset ?? 0) > 0 && !truncated) return const [];
    final session = _sessions[sessionId];
    if (session == null) return const [];
    session.awaitingSnapshot = false;
    final baseSeq = outputSeq ?? 0;
    final keys = session.heldLive.keys.toList()..sort();
    final replay = <T>[];
    for (final key in keys) {
      if (key > baseSeq) {
        replay.add(session.heldLive[key] as T);
      }
    }
    replay.addAll(session.unsequencedLive);
    session.heldLive.clear();
    session.unsequencedLive.clear();
    return replay;
  }

  RemoteTerminalSnapshotPageResult acceptSnapshotPage({
    required String sessionId,
    required String data,
    required int offset,
    required int? bufferLength,
    required bool truncated,
  }) {
    final session = _sessions.putIfAbsent(
      sessionId,
      _RemoteTerminalReplicaSession.new,
    );
    final pageBuffer = offset == 0 || session.pageBuffer == null
        ? _RemoteTerminalPageBuffer(bufferLength)
        : session.pageBuffer!;
    if (offset == 0) {
      session.pageBuffer = pageBuffer;
    }
    final accepted = pageBuffer.accept(
      data: data,
      offset: offset,
      bufferLength: bufferLength,
      truncated: truncated,
    );
    if (!accepted.accepted) {
      session.pageBuffer = null;
      return accepted;
    }
    if (accepted.ready) {
      session.pageBuffer = null;
    } else {
      session.pageBuffer = pageBuffer;
    }
    return accepted;
  }

  void remove(String sessionId) {
    _sessions.remove(sessionId);
  }

  void reset() {
    _sessions.clear();
  }
}

class _RemoteTerminalReplicaSession<T> {
  bool awaitingSnapshot = false;
  final Map<int, T> heldLive = {};
  final List<T> unsequencedLive = [];
  _RemoteTerminalPageBuffer? pageBuffer;
}

class RemoteTerminalSnapshotPageResult {
  const RemoteTerminalSnapshotPageResult({
    required this.accepted,
    required this.ready,
    required this.data,
    required this.nextOffset,
    required this.progress,
  });

  final bool accepted;
  final bool ready;
  final String data;
  final int nextOffset;
  final double? progress;
}

class _RemoteTerminalPageBuffer {
  _RemoteTerminalPageBuffer(this.bufferLength);

  final StringBuffer _buffer = StringBuffer();
  int nextOffset = 0;
  int? bufferLength;

  RemoteTerminalSnapshotPageResult accept({
    required String data,
    required int offset,
    required int? bufferLength,
    required bool truncated,
  }) {
    this.bufferLength ??= bufferLength;
    if (offset != nextOffset) {
      return RemoteTerminalSnapshotPageResult(
        accepted: false,
        ready: false,
        data: '',
        nextOffset: nextOffset,
        progress: null,
      );
    }
    _buffer.write(data);
    nextOffset += data.runes.length;
    final expectedLength = bufferLength ?? this.bufferLength;
    final completeByLength =
        expectedLength != null && nextOffset >= expectedLength;
    final ready = !truncated || completeByLength;
    return RemoteTerminalSnapshotPageResult(
      accepted: true,
      ready: ready,
      data: ready ? _buffer.toString() : '',
      nextOffset: nextOffset,
      progress: expectedLength == null || expectedLength <= 0
          ? null
          : (nextOffset / expectedLength).clamp(0.0, 1.0),
    );
  }
}
