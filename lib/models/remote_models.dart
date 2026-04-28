class PairingPayload {
  const PairingPayload({
    required this.server,
    required this.code,
    required this.secret,
    this.hostName,
  });
  final String server;
  final String code;
  final String secret;
  final String? hostName;
}

class StoredDevice {
  const StoredDevice({
    required this.server,
    required this.hostId,
    required this.deviceId,
    required this.token,
    required this.name,
    this.hostName,
  });
  final String server;
  final String hostId;
  final String deviceId;
  final String token;
  final String name;
  final String? hostName;

  StoredDevice copyWith({
    String? server,
    String? hostId,
    String? deviceId,
    String? token,
    String? name,
    String? hostName,
  }) {
    return StoredDevice(
      server: server ?? this.server,
      hostId: hostId ?? this.hostId,
      deviceId: deviceId ?? this.deviceId,
      token: token ?? this.token,
      name: name ?? this.name,
      hostName: hostName ?? this.hostName,
    );
  }

  factory StoredDevice.fromJson(Map<String, dynamic> json) => StoredDevice(
    server: '${json['server'] ?? ''}',
    hostId: '${json['hostId'] ?? ''}',
    deviceId: '${json['deviceId'] ?? ''}',
    token: '${json['token'] ?? ''}',
    name: '${json['name'] ?? ''}',
    hostName: json['hostName'] == null ? null : '${json['hostName']}',
  );

  Map<String, dynamic> toJson() => {
    'server': server,
    'hostId': hostId,
    'deviceId': deviceId,
    'token': token,
    'name': name,
    if (hostName != null) 'hostName': hostName,
  };
}

class RelayEnvelope {
  const RelayEnvelope({
    required this.type,
    this.id,
    this.hostId,
    this.deviceId,
    this.sessionId,
    this.seq,
    this.payload,
    this.error,
    this.at,
  });
  final String type;
  final String? id;
  final String? hostId;
  final String? deviceId;
  final String? sessionId;
  final int? seq;
  final Object? payload;
  final String? error;
  final int? at;

  factory RelayEnvelope.fromJson(Map<String, dynamic> json) => RelayEnvelope(
    type: '${json['type'] ?? ''}',
    id: json['id']?.toString(),
    hostId: json['hostId']?.toString(),
    deviceId: json['deviceId']?.toString(),
    sessionId: json['sessionId']?.toString(),
    seq: json['seq'] is num ? (json['seq'] as num).toInt() : null,
    payload: json['payload'],
    error: json['error']?.toString(),
    at: json['at'] is num ? (json['at'] as num).toInt() : null,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    if (id != null) 'id': id,
    if (hostId != null) 'hostId': hostId,
    if (deviceId != null) 'deviceId': deviceId,
    if (sessionId != null) 'sessionId': sessionId,
    if (seq != null) 'seq': seq,
    if (payload != null) 'payload': payload,
    if (error != null) 'error': error,
    if (at != null) 'at': at,
  };
}

class ProjectInfo {
  const ProjectInfo({required this.id, required this.name, this.path});
  final String id;
  final String name;
  final String? path;

  factory ProjectInfo.fromJson(Map<String, dynamic> json) => ProjectInfo(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? 'Project'}',
    path: json['path']?.toString(),
  );
}

class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.title,
    required this.projectId,
    this.kind,
    this.ownerKind,
    this.ownerDeviceId,
    this.resizeOwner,
    this.cols,
    this.rows,
    this.status,
  });
  final String id;
  final String title;
  final String projectId;
  final String? kind;
  final String? ownerKind;
  final String? ownerDeviceId;
  final String? resizeOwner;
  final int? cols;
  final int? rows;
  final String? status;

  factory TerminalInfo.fromJson(Map<String, dynamic> json) => TerminalInfo(
    id: '${json['id'] ?? ''}',
    title: '${json['title'] ?? 'Terminal'}',
    projectId: '${json['projectId'] ?? ''}',
    kind: json['kind']?.toString(),
    ownerKind: json['ownerKind']?.toString(),
    ownerDeviceId: json['ownerDeviceId']?.toString(),
    resizeOwner: json['resizeOwner']?.toString(),
    cols: json['cols'] is num
        ? (json['cols'] as num).toInt()
        : int.tryParse('${json['cols'] ?? ''}'),
    rows: json['rows'] is num
        ? (json['rows'] as num).toInt()
        : int.tryParse('${json['rows'] ?? ''}'),
    status: json['status']?.toString(),
  );
}

class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
  });

  final String name;
  final String path;
  final bool isDirectory;

  factory RemoteFileEntry.fromJson(Map<String, dynamic> json) =>
      RemoteFileEntry(
        name: '${json['name'] ?? ''}',
        path: '${json['path'] ?? ''}',
        isDirectory: json['isDirectory'] == true,
      );
}

class AIStatsInfo {
  const AIStatsInfo({
    required this.projectName,
    required this.todayTokens,
    required this.totalTokens,
    required this.currentSessionTokens,
    required this.requestCount,
    this.currentSessionCachedInputTokens = 0,
    this.projectCachedInputTokens = 0,
    this.todayCachedInputTokens = 0,
    this.currentTool,
    this.currentModel,
    this.contextUsagePercent,
    this.updatedAt,
    this.currentSessions = const [],
    this.todayTimeBuckets = const [],
    this.heatmap = const [],
    this.toolBreakdown = const [],
    this.modelBreakdown = const [],
  });

  final String projectName;
  final int todayTokens;
  final int totalTokens;
  final int currentSessionTokens;
  final int currentSessionCachedInputTokens;
  final int projectCachedInputTokens;
  final int todayCachedInputTokens;
  final int requestCount;
  final String? currentTool;
  final String? currentModel;
  final double? contextUsagePercent;
  final String? updatedAt;
  final List<AIStatsSessionInfo> currentSessions;
  final List<AIStatsTimeBucket> todayTimeBuckets;
  final List<AIStatsHeatmapDay> heatmap;
  final List<AIStatsBreakdownItem> toolBreakdown;
  final List<AIStatsBreakdownItem> modelBreakdown;

  factory AIStatsInfo.fromJson(Map<String, dynamic> json) => AIStatsInfo(
    projectName: '${json['projectName'] ?? 'Project'}',
    todayTokens:
        _intValue(json['todayTotalTokens']) ??
        _intValue(json['todayTokens']) ??
        0,
    totalTokens:
        _intValue(json['projectTotalTokens']) ??
        _intValue(json['totalTokens']) ??
        0,
    currentSessionTokens: _intValue(json['currentSessionTokens']) ?? 0,
    currentSessionCachedInputTokens:
        _intValue(json['currentSessionCachedInputTokens']) ?? 0,
    projectCachedInputTokens: _intValue(json['projectCachedInputTokens']) ?? 0,
    todayCachedInputTokens: _intValue(json['todayCachedInputTokens']) ?? 0,
    requestCount: _intValue(json['requestCount']) ?? 0,
    currentTool: json['currentTool']?.toString(),
    currentModel: json['currentModel']?.toString(),
    contextUsagePercent: _doubleValue(json['contextUsagePercent']),
    updatedAt: json['updatedAt']?.toString(),
    currentSessions: _listOf(
      json['currentSessions'],
      AIStatsSessionInfo.fromJson,
    ),
    todayTimeBuckets: _listOf(
      json['todayTimeBuckets'],
      AIStatsTimeBucket.fromJson,
    ),
    heatmap: _listOf(json['heatmap'], AIStatsHeatmapDay.fromJson),
    toolBreakdown: _listOf(
      json['toolBreakdown'],
      AIStatsBreakdownItem.fromJson,
    ),
    modelBreakdown: _listOf(
      json['modelBreakdown'],
      AIStatsBreakdownItem.fromJson,
    ),
  );
}

class AIStatsSessionInfo {
  const AIStatsSessionInfo({
    required this.sessionId,
    required this.title,
    required this.totalTokens,
    this.cachedInputTokens = 0,
    this.tool,
    this.model,
    this.status,
    this.isRunning = false,
  });

  final String sessionId;
  final String title;
  final int totalTokens;
  final int cachedInputTokens;
  final String? tool;
  final String? model;
  final String? status;
  final bool isRunning;

  factory AIStatsSessionInfo.fromJson(Map<String, dynamic> json) =>
      AIStatsSessionInfo(
        sessionId: '${json['sessionId'] ?? ''}',
        title: '${json['title'] ?? 'Session'}',
        totalTokens: _intValue(json['totalTokens']) ?? 0,
        cachedInputTokens: _intValue(json['cachedInputTokens']) ?? 0,
        tool: json['tool']?.toString(),
        model: json['model']?.toString(),
        status: json['status']?.toString(),
        isRunning: json['isRunning'] == true,
      );
}

class AIStatsTimeBucket {
  const AIStatsTimeBucket({
    required this.start,
    required this.totalTokens,
    this.cachedInputTokens = 0,
    this.requestCount = 0,
  });

  final String start;
  final int totalTokens;
  final int cachedInputTokens;
  final int requestCount;

  factory AIStatsTimeBucket.fromJson(Map<String, dynamic> json) =>
      AIStatsTimeBucket(
        start: '${json['start'] ?? ''}',
        totalTokens: _intValue(json['totalTokens']) ?? 0,
        cachedInputTokens: _intValue(json['cachedInputTokens']) ?? 0,
        requestCount: _intValue(json['requestCount']) ?? 0,
      );
}

class AIStatsHeatmapDay {
  const AIStatsHeatmapDay({
    required this.day,
    required this.totalTokens,
    this.cachedInputTokens = 0,
    this.requestCount = 0,
  });

  final String day;
  final int totalTokens;
  final int cachedInputTokens;
  final int requestCount;

  factory AIStatsHeatmapDay.fromJson(Map<String, dynamic> json) =>
      AIStatsHeatmapDay(
        day: '${json['day'] ?? ''}',
        totalTokens: _intValue(json['totalTokens']) ?? 0,
        cachedInputTokens: _intValue(json['cachedInputTokens']) ?? 0,
        requestCount: _intValue(json['requestCount']) ?? 0,
      );
}

class AIStatsBreakdownItem {
  const AIStatsBreakdownItem({
    required this.key,
    required this.totalTokens,
    this.cachedInputTokens = 0,
    this.requestCount = 0,
  });

  final String key;
  final int totalTokens;
  final int cachedInputTokens;
  final int requestCount;

  factory AIStatsBreakdownItem.fromJson(Map<String, dynamic> json) =>
      AIStatsBreakdownItem(
        key: '${json['key'] ?? '-'}',
        totalTokens: _intValue(json['totalTokens']) ?? 0,
        cachedInputTokens: _intValue(json['cachedInputTokens']) ?? 0,
        requestCount: _intValue(json['requestCount']) ?? 0,
      );
}

int? _intValue(Object? value) => value is num ? value.toInt() : null;
double? _doubleValue(Object? value) => value is num ? value.toDouble() : null;

List<T> _listOf<T>(Object? value, T Function(Map<String, dynamic>) mapper) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => mapper(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

class MobileSettings {
  const MobileSettings({
    required this.localName,
    this.accentId = 'cyan',
    this.localeId = 'system',
  });
  final String localName;
  final String accentId;
  final String localeId;

  MobileSettings copyWith({
    String? localName,
    String? accentId,
    String? localeId,
  }) {
    return MobileSettings(
      localName: localName ?? this.localName,
      accentId: accentId ?? this.accentId,
      localeId: localeId ?? this.localeId,
    );
  }

  factory MobileSettings.fromJson(Map<String, dynamic> json) => MobileSettings(
    localName: '${json['localName'] ?? ''}',
    accentId: '${json['accentId'] ?? 'cyan'}',
    localeId: '${json['localeId'] ?? 'system'}',
  );

  Map<String, dynamic> toJson() => {
    'localName': localName,
    'accentId': accentId,
    'localeId': localeId,
  };
}
