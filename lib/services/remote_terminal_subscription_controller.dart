import '../models/remote_models.dart';

class RemoteTerminalSubscriptionPlan {
  const RemoteTerminalSubscriptionPlan({
    this.unsubscribe,
    this.unsubscribeProjectId,
    this.subscribe,
    this.subscribeProjectId,
  });

  final RelayEnvelope? unsubscribe;
  final String? unsubscribeProjectId;
  final RelayEnvelope? subscribe;
  final String? subscribeProjectId;

  bool get hasWork => unsubscribe != null || subscribe != null;
}

class RemoteTerminalSubscriptionController {
  String? _projectId;

  String? get projectId => _projectId;

  void reset() {
    _projectId = null;
  }

  RemoteTerminalSubscriptionPlan replaceProject(String projectId) {
    final cleanProjectId = projectId.trim();
    if (cleanProjectId.isEmpty || _projectId == cleanProjectId) {
      return const RemoteTerminalSubscriptionPlan();
    }
    final previousProjectId = _projectId;
    _projectId = cleanProjectId;
    return RemoteTerminalSubscriptionPlan(
      unsubscribe: previousProjectId == null
          ? null
          : _projectEnvelope('terminal.unsubscribe', previousProjectId),
      unsubscribeProjectId: previousProjectId,
      subscribe: _projectEnvelope('terminal.subscribe', cleanProjectId),
      subscribeProjectId: cleanProjectId,
    );
  }
}

RelayEnvelope _projectEnvelope(String type, String projectId) {
  return RelayEnvelope(
    type: type,
    payload: {'scope': 'project', 'projectId': projectId},
  );
}
