class PairingPayload {
  const PairingPayload({
    required this.server,
    required this.code,
    required this.secret,
    required this.hostPublicKey,
    required this.devicePrivateKey,
    required this.devicePublicKey,
    required this.matchCode,
    this.cryptoVersion = 1,
    this.hostName,
    this.transport = 'iroh',
    this.iroh,
    this.pairingId,
  });
  final String server;
  final String code;
  final String secret;
  final String hostPublicKey;
  final String devicePrivateKey;
  final String devicePublicKey;
  final String matchCode;
  final int cryptoVersion;
  final String? hostName;
  final String transport;
  final IrohNodeAddr? iroh;
  final String? pairingId;
}

class IrohNodeAddr {
  const IrohNodeAddr({
    required this.nodeId,
    this.relayUrl,
    this.directAddresses = const [],
  });

  final String nodeId;
  final String? relayUrl;
  final List<String> directAddresses;

  factory IrohNodeAddr.fromJson(Map<String, dynamic> json) => IrohNodeAddr(
    nodeId: '${json['nodeId'] ?? ''}',
    relayUrl: json['relayUrl']?.toString(),
    directAddresses: (json['directAddresses'] as List? ?? const [])
        .map((item) => '$item')
        .where((item) => item.isNotEmpty)
        .toList(),
  );

  IrohNodeAddr stable() => IrohNodeAddr(
    nodeId: nodeId,
    relayUrl: relayUrl,
    directAddresses: directAddresses.toSet().toList(),
  );

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    if (relayUrl != null && relayUrl!.isNotEmpty) 'relayUrl': relayUrl,
    if (directAddresses.isNotEmpty) 'directAddresses': directAddresses,
  };
}

class StoredDevice {
  const StoredDevice({
    required this.server,
    required this.hostId,
    required this.deviceId,
    required this.token,
    required this.name,
    this.hostPublicKey = '',
    this.devicePrivateKey = '',
    this.devicePublicKey = '',
    this.cryptoVersion = 0,
    this.hostName,
    this.transport = 'iroh',
    this.iroh,
  });
  final String server;
  final String hostId;
  final String deviceId;
  final String token;
  final String name;
  final String hostPublicKey;
  final String devicePrivateKey;
  final String devicePublicKey;
  final int cryptoVersion;
  final String? hostName;
  final String transport;
  final IrohNodeAddr? iroh;

  StoredDevice copyWith({
    String? server,
    String? hostId,
    String? deviceId,
    String? token,
    String? name,
    String? hostPublicKey,
    String? devicePrivateKey,
    String? devicePublicKey,
    int? cryptoVersion,
    String? hostName,
    String? transport,
    IrohNodeAddr? iroh,
  }) {
    return StoredDevice(
      server: server ?? this.server,
      hostId: hostId ?? this.hostId,
      deviceId: deviceId ?? this.deviceId,
      token: token ?? this.token,
      name: name ?? this.name,
      hostPublicKey: hostPublicKey ?? this.hostPublicKey,
      devicePrivateKey: devicePrivateKey ?? this.devicePrivateKey,
      devicePublicKey: devicePublicKey ?? this.devicePublicKey,
      cryptoVersion: cryptoVersion ?? this.cryptoVersion,
      hostName: hostName ?? this.hostName,
      transport: transport ?? this.transport,
      iroh: iroh ?? this.iroh,
    );
  }

  factory StoredDevice.fromJson(Map<String, dynamic> json) => StoredDevice(
    server: '${json['server'] ?? ''}',
    hostId: '${json['hostId'] ?? ''}',
    deviceId: '${json['deviceId'] ?? ''}',
    token: '${json['token'] ?? ''}',
    name: '${json['name'] ?? ''}',
    hostPublicKey: '${json['hostPublicKey'] ?? ''}',
    devicePrivateKey: '${json['devicePrivateKey'] ?? ''}',
    devicePublicKey: '${json['devicePublicKey'] ?? ''}',
    cryptoVersion: json['cryptoVersion'] is num
        ? (json['cryptoVersion'] as num).toInt()
        : int.tryParse('${json['cryptoVersion'] ?? ''}') ?? 0,
    hostName: json['hostName'] == null ? null : '${json['hostName']}',
    transport: '${json['transport'] ?? 'iroh'}',
    iroh: json['iroh'] is Map
        ? IrohNodeAddr.fromJson(Map<String, dynamic>.from(json['iroh'] as Map))
        : null,
  );

  Map<String, dynamic> toJson() => {
    'server': server,
    'hostId': hostId,
    'deviceId': deviceId,
    'token': token,
    'name': name,
    if (hostPublicKey.isNotEmpty) 'hostPublicKey': hostPublicKey,
    if (devicePrivateKey.isNotEmpty) 'devicePrivateKey': devicePrivateKey,
    if (devicePublicKey.isNotEmpty) 'devicePublicKey': devicePublicKey,
    if (cryptoVersion > 0) 'cryptoVersion': cryptoVersion,
    if (hostName != null) 'hostName': hostName,
    'transport': transport,
    if (iroh != null) 'iroh': iroh!.toJson(),
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

  RelayEnvelope copyWith({
    String? type,
    String? id,
    String? hostId,
    String? deviceId,
    String? sessionId,
    int? seq,
    Object? payload,
    String? error,
    int? at,
  }) => RelayEnvelope(
    type: type ?? this.type,
    id: id ?? this.id,
    hostId: hostId ?? this.hostId,
    deviceId: deviceId ?? this.deviceId,
    sessionId: sessionId ?? this.sessionId,
    seq: seq ?? this.seq,
    payload: payload ?? this.payload,
    error: error ?? this.error,
    at: at ?? this.at,
  );
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (path != null) 'path': path,
  };
}

class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.title,
    required this.projectId,
    this.layoutKind = 'split',
    this.cols,
    this.rows,
    this.status,
    this.createdAt,
  });
  final String id;
  final String title;
  final String projectId;
  final String layoutKind;
  final int? cols;
  final int? rows;
  final String? status;
  final String? createdAt;

  factory TerminalInfo.fromJson(Map<String, dynamic> json) => TerminalInfo(
    id: '${json['id'] ?? ''}',
    title: '${json['title'] ?? 'Terminal'}',
    projectId: '${json['projectId'] ?? ''}',
    layoutKind: '${json['layoutKind'] ?? 'split'}',
    cols: json['cols'] is num
        ? (json['cols'] as num).toInt()
        : int.tryParse('${json['cols'] ?? ''}'),
    rows: json['rows'] is num
        ? (json['rows'] as num).toInt()
        : int.tryParse('${json['rows'] ?? ''}'),
    status: json['status']?.toString(),
    createdAt: json['createdAt']?.toString(),
  );
}

class RemoteWorktreeInfo {
  const RemoteWorktreeInfo({
    required this.id,
    required this.projectId,
    required this.name,
    required this.branch,
    required this.path,
    required this.status,
    required this.isDefault,
    required this.exists,
    this.baseBranch,
    this.changes = 0,
    this.incoming = 0,
    this.outgoing = 0,
    this.additions = 0,
    this.deletions = 0,
  });

  final String id;
  final String projectId;
  final String name;
  final String branch;
  final String path;
  final String status;
  final bool isDefault;
  final bool exists;
  final String? baseBranch;
  final int changes;
  final int incoming;
  final int outgoing;
  final int additions;
  final int deletions;

  factory RemoteWorktreeInfo.fromJson(Map<String, dynamic> json) {
    final gitSummary = json['gitSummary'] is Map
        ? Map<String, dynamic>.from(json['gitSummary'] as Map)
        : const <String, dynamic>{};
    return RemoteWorktreeInfo(
      id: '${json['id'] ?? ''}',
      projectId: '${json['projectId'] ?? ''}',
      name: '${json['name'] ?? ''}',
      branch: '${json['branch'] ?? ''}',
      path: '${json['path'] ?? ''}',
      status: '${json['status'] ?? ''}',
      isDefault: json['isDefault'] == true,
      exists: json['exists'] != false,
      baseBranch: json['baseBranch']?.toString(),
      changes: _intValue(gitSummary['changes']) ?? 0,
      incoming: _intValue(gitSummary['incoming']) ?? 0,
      outgoing: _intValue(gitSummary['outgoing']) ?? 0,
      additions: _intValue(gitSummary['additions']) ?? 0,
      deletions: _intValue(gitSummary['deletions']) ?? 0,
    );
  }

  RemoteWorktreeInfo copyWith({String? baseBranch}) {
    return RemoteWorktreeInfo(
      id: id,
      projectId: projectId,
      name: name,
      branch: branch,
      path: path,
      status: status,
      isDefault: isDefault,
      exists: exists,
      baseBranch: baseBranch ?? this.baseBranch,
      changes: changes,
      incoming: incoming,
      outgoing: outgoing,
      additions: additions,
      deletions: deletions,
    );
  }
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
