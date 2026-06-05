import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:codux_remote_iroh/codux_remote_iroh.dart';
import 'package:codux_native_terminal/codux_native_terminal.dart';
import 'i18n.dart';
import 'models/remote_models.dart';
import 'screens/scanner_screen.dart';
import 'screens/settings_screen.dart';
import 'services/e2e_crypto.dart';
import 'services/log_service.dart';
import 'services/local_voice_recognition_service.dart';
import 'services/remote_protocol_service.dart';
import 'services/storage_service.dart';
import 'services/terminal_buffer_retry.dart';
import 'services/terminal_input_batcher.dart';
import 'services/terminal_input_payload.dart';
import 'services/terminal_payload_codec.dart';
import 'services/terminal_upload_sender.dart';
import 'theme/app_theme.dart';
import 'widgets/ai_stats_panel.dart';
import 'widgets/app_toast.dart';
import 'widgets/connect_hint.dart';
import 'widgets/device_home_screen.dart';
import 'widgets/pairing_overlay.dart';
import 'widgets/project_files_panel.dart';
import 'widgets/project_form_overlay.dart';
import 'widgets/project_tab_bar.dart';
import 'widgets/remote_file_picker.dart';
import 'widgets/voice_input_overlay.dart';
import 'widgets/terminal_header.dart';
import 'widgets/terminal_switcher_screen.dart';
import 'widgets/terminal_transition_mask.dart';
import 'widgets/toolbar.dart';

const String _remoteProtocolVersion = 'v2.0';

enum _TerminalUploadSource { file, image }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: AppColors.bgSurface,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const CoduxFlutterApp());
}

class CoduxFlutterApp extends StatefulWidget {
  const CoduxFlutterApp({super.key, this.irohBridge, this.initialDevices});

  final CoduxRemoteIrohBridge? irohBridge;
  final List<StoredDevice>? initialDevices;

  @override
  State<CoduxFlutterApp> createState() => _CoduxFlutterAppState();
}

class _CoduxFlutterAppState extends State<CoduxFlutterApp> {
  AccentOption _accent = AccentChoices.cyan;
  LocaleOption _locale = LocaleChoices.zhCN;

  void _setAccent(AccentOption next) => setState(() => _accent = next);
  void _setLocale(LocaleOption next) => setState(() => _locale = next);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Codux Mobile',
      theme: buildAppTheme(accent: _accent.color),
      locale: flutterLocaleForOption(_locale),
      supportedLocales: supportedFlutterLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: AppPreferences(
        accent: _accent,
        locale: _locale,
        child: CoduxHomePage(
          onChangeAccent: _setAccent,
          onChangeLocale: _setLocale,
          irohBridge: widget.irohBridge,
          initialDevices: widget.initialDevices,
        ),
      ),
    );
  }
}

class CoduxHomePage extends StatefulWidget {
  const CoduxHomePage({
    super.key,
    required this.onChangeAccent,
    required this.onChangeLocale,
    this.irohBridge,
    this.initialDevices,
  });

  final ValueChanged<AccentOption> onChangeAccent;
  final ValueChanged<LocaleOption> onChangeLocale;
  final CoduxRemoteIrohBridge? irohBridge;
  final List<StoredDevice>? initialDevices;

  @override
  State<CoduxHomePage> createState() => _CoduxHomePageState();
}

class _CoduxHomePageState extends State<CoduxHomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _storage = StorageService();
  final _settingsNameController = TextEditingController();
  final _fileEditorController = CodeEditingController();
  final _projectNameController = TextEditingController();
  final _projectPathController = TextEditingController();

  late final AnimationController _maskController;
  late final Animation<double> _maskOpacity;
  late final AnimationController _edgeBackController;
  late final TerminalBufferRetryCoordinator _terminalBufferRetry;
  late final TerminalInputBatcher _terminalInputBatcher;
  late final TerminalUploadSender _terminalUploadSender;
  late final CoduxRemoteIroh _irohTransport;
  late final LocalVoiceRecognitionService _voiceService;
  Completer<StoredDevice>? _irohPairingCompleter;
  String? _irohPairingDeviceName;
  bool _irohPairingRequestSent = false;
  Completer<void>? _terminalUploadCompletion;
  CoduxNativeTerminalController? _nativeTerminalController;
  String _pendingTerminalOutput = '';
  final Map<String, String> _terminalOutputCache = {};
  final Map<String, int> _terminalBufferLengths = {};
  final Map<String, int> _terminalOutputSeqBySession = {};
  final Map<String, String> _lastTerminalIdByProject = {};
  final Set<String> _protocolBlockedHostIds = {};
  double _terminalCursorBottom = 0;
  int? _lastTerminalCols;
  int? _lastTerminalRows;
  int? _pendingTerminalCols;
  int? _pendingTerminalRows;
  int _terminalInputSeq = 0;
  final Map<String, _PendingTerminalInput> _pendingTerminalInputs = {};
  bool _keyboardVisible = false;

  List<StoredDevice> _devices = [];
  List<ProjectInfo> _projects = [];
  List<TerminalInfo> _terminals = [];
  List<RemoteWorktreeInfo> _worktrees = [];
  List<String> _worktreeBaseBranches = [];
  StoredDevice? _activeDevice;
  MobileSettings _settings = const MobileSettings(localName: '');
  String _detectedDeviceName = 'Codux Mobile';
  String _status = '';
  String? _selectedProjectId;
  String? _sessionId;
  String? _creatingTerminalProjectId;
  String? _defaultWorktreeBaseBranch;
  bool _showSettings = false;
  bool _showScanner = false;
  PairingPayload? _pendingPairing;
  bool _pairingInFlight = false;
  bool _pairingCancelled = false;
  String? _pairingError;
  bool _showTerminal = false;
  bool _showTerminalSwitcher = false;
  bool _terminalReady = false;
  bool _terminalBufferLoading = false;
  bool _terminalUploadLoading = false;
  String _terminalUploadStatus = '';
  bool _terminalListLoaded = false;
  bool _projectListLoaded = false;
  bool _backgroundConnect = false;
  bool _shouldReconnect = true;
  bool _transportReady = false;
  bool _remoteProtocolReady = false;
  bool _hostResponsive = false;
  bool _appSuspended = false;
  bool _disposing = false;
  bool _hasShownTerminal = false;
  bool _aiStatsLoading = false;
  bool _showProjectForm = false;
  bool _showFilePicker = false;
  bool _showVoiceOverlay = false;
  bool _filePickerLoading = false;
  String _projectFormMode = 'add';
  String _filePickerMode = 'projectForm';
  String _filePickerPath = '';
  String? _filePickerParent;
  List<RemoteFileEntry> _filePickerEntries = [];
  List<RemoteFileEntry> _projectFileEntries = [];
  AIStatsInfo? _currentAIStats;
  String _workspaceMode = 'terminal';
  String _projectFilesPath = '';
  final Map<String, String> _projectFilePathMemory = {};
  String? _projectFilesParent;
  String? _editingFilePath;
  String? _toastMessage;
  String? _blockingLoadingMessage;
  bool _projectFilesLoading = false;
  bool _worktreeListLoading = false;
  bool _fileEditorLoading = false;
  bool _fileEditorSaving = false;
  bool _fileEditorEditing = false;
  bool _fileEditorEditable = true;
  int _reconnectAttempt = 0;
  bool _appInForeground = true;

  bool _irohReady = false;
  int _transportGeneration = 0;
  int _sendSeq = 0;
  int _receiveSeq = 0;
  Future<void> _sendChain = Future<void>.value();
  Future<void> _receiveChain = Future<void>.value();
  Timer? _reconnectTimer;
  Timer? _healthTimer;
  Timer? _toastTimer;
  Timer? _filePickerTimeoutTimer;
  Timer? _projectListRetryTimer;
  Timer? _terminalListRetryTimer;
  Timer? _hostResponseTimer;
  Timer? _latencyProbeTimer;
  Timer? _pingTimeoutTimer;
  int _projectListRetryAttempt = 0;
  int _terminalListRetryAttempt = 0;
  double? _edgeBackDragStartX;
  double _edgeBackDragDeltaX = 0;
  double _edgeBackDragDeltaY = 0;
  String _lastTransportState = 'iroh';
  String _irohConnectionPath = 'unknown';
  DateTime? _lastConnectedAt;
  DateTime? _connectionGraceUntil;
  DateTime? _pingSentAt;
  String? _pendingPingId;
  String? _selectedWorktreeId;
  int _pingSeq = 0;
  int? _latencyMs;
  Timer? _connectionGraceTimer;

  bool get _isConnected => _irohReady && _transportReady;
  bool get _isHostReady =>
      _isConnected &&
      _hostResponsive &&
      _projectListLoaded &&
      _terminalListLoaded;
  bool get _isRecoveringConnection {
    final graceUntil = _connectionGraceUntil;
    return _appInForeground &&
        _activeDevice != null &&
        _shouldReconnect &&
        graceUntil != null &&
        DateTime.now().isBefore(graceUntil);
  }

  bool get _isDeviceListConnected => _isHostReady;

  String _t(String key, {Map<String, String>? params}) =>
      AppPreferences.of(context).t(key, params: params);

  String get _connectionStatusText {
    if (!_isConnected) {
      if (_isRecoveringConnection) return _t('app.reconnecting');
      if (_activeDevice != null && _backgroundConnect) {
        return _t('app.connecting');
      }
      if (_status.isEmpty || _status == _t('app.connected')) {
        return _t('app.notConnected');
      }
      return _status;
    }
    if (!_hostResponsive) {
      return _t('app.connecting');
    }
    if (!_projectListLoaded || !_terminalListLoaded) {
      return _t('app.syncing');
    }
    return _terminalTransportStatusText;
  }

  String get _deviceListStatusText {
    if (!_isConnected) {
      if (_isRecoveringConnection) return _t('app.reconnectingShort');
      if (_activeDevice != null && _backgroundConnect) {
        return _t('app.connecting');
      }
      if (_status.isEmpty || _status == _t('app.connected')) {
        return _t('app.notConnected');
      }
      return _status;
    }
    if (!_hostResponsive) {
      return _t('app.connecting');
    }
    if (!_projectListLoaded || !_terminalListLoaded) {
      return _t('app.syncing');
    }
    return _terminalTransportStatusText;
  }

  String get _terminalTransportStatusText {
    return _irohConnectionPathLabel(_irohConnectionPath);
  }

  String _irohConnectionPathLabel(String path) {
    return switch (path) {
      'direct' => _t('connection.direct'),
      'relay' => _t('connection.relay'),
      _ => 'Iroh',
    };
  }

  void _clearConnectionGrace() {
    _connectionGraceTimer?.cancel();
    _connectionGraceTimer = null;
    _connectionGraceUntil = null;
  }

  void _startConnectionGrace({
    required String reason,
    Duration duration = const Duration(seconds: 8),
  }) {
    if (!_shouldReconnect || !_appInForeground) return;
    _connectionGraceTimer?.cancel();
    _connectionGraceUntil = DateTime.now().add(duration);
    CoduxLog.info(
      '[codux-flutter-iroh] grace reason=$reason until=${_connectionGraceUntil!.toIso8601String()} transport=$_lastTransportState lastConnectedAt=${_lastConnectedAt?.toIso8601String() ?? 'null'}',
    );
    _connectionGraceTimer = Timer(duration, () {
      if (!mounted || _disposing) return;
      if (_connectionGraceUntil == null) return;
      if (DateTime.now().isBefore(_connectionGraceUntil!)) return;
      setState(() {
        _connectionGraceUntil = null;
      });
      CoduxLog.info('[codux-flutter-iroh] grace expired reason=$reason');
    });
  }

  void _markTransportConnected(String transport) {
    _lastTransportState = transport;
    _lastConnectedAt = DateTime.now();
    _clearConnectionGrace();
  }

  void _cancelHostResponseProbe() {
    _hostResponseTimer?.cancel();
    _hostResponseTimer = null;
  }

  void _startHostResponseProbe({
    required String reason,
    Duration duration = const Duration(seconds: 6),
  }) {
    final device = _activeDevice;
    final generation = _transportGeneration;
    if (!_transportReady || device == null) return;
    _cancelHostResponseProbe();
    CoduxLog.info(
      '[codux-flutter-remote] host probe start reason=$reason timeoutMs=${duration.inMilliseconds}',
    );
    _hostResponseTimer = Timer(duration, () {
      if (!mounted || _disposing || !_appInForeground) return;
      if (_transportGeneration != generation ||
          !_transportReady ||
          _hostResponsive) {
        return;
      }
      _failHostConnection(device, 'host_response_timeout:$reason');
    });
  }

  bool _isCompatibleRemoteProtocol(Object? payload) {
    if (payload is! Map) return false;
    return payload['protocolVersion'] == _remoteProtocolVersion;
  }

  void _markRemoteProtocolReady({bool force = false}) {
    if (_remoteProtocolReady && !force) return;
    _remoteProtocolReady = true;
    _sendInitialTransportRequests(force: force);
  }

  void _failRemoteProtocol(StoredDevice target, Object? payload) {
    final version = payload is Map ? '${payload['protocolVersion'] ?? ''}' : '';
    CoduxLog.warn(
      '[codux-flutter-iroh] incompatible protocol expected=$_remoteProtocolVersion received=$version host=${target.hostId} device=${target.deviceId}',
    );
    _shouldReconnect = false;
    final shouldPrompt = _protocolBlockedHostIds.add(target.hostId);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cancelHostResponseProbe();
    _clearConnectionGrace();
    _clearLatencyProbe();
    _irohReady = false;
    unawaited(_irohTransport.close());
    _terminalInputBatcher.reset();
    _clearPendingTerminalInputs();
    final message = _t('connection.upgradeRequired');
    setState(() {
      _transportReady = false;
      _remoteProtocolReady = false;
      _hostResponsive = false;
      _backgroundConnect = false;
      _showTerminal = false;
      _workspaceMode = 'terminal';
      _projects = [];
      _projectListLoaded = false;
      _terminals = [];
      _worktrees = [];
      _worktreeBaseBranches = [];
      _terminalListLoaded = false;
      _projectListRetryTimer?.cancel();
      _terminalListRetryTimer?.cancel();
      _projectListRetryAttempt = 0;
      _terminalListRetryAttempt = 0;
      _selectedProjectId = null;
      _defaultWorktreeBaseBranch = null;
      _selectedWorktreeId = null;
      _sessionId = null;
      _showTerminalSwitcher = false;
      _status = message;
      _terminalBufferRetry.reset();
      _terminalBufferLoading = false;
    });
    if (shouldPrompt) {
      _showToast(message);
    }
  }

  void _markHostResponsive(String source, {String? transport}) {
    final wasResponsive = _hostResponsive;
    _hostResponsive = true;
    _cancelHostResponseProbe();
    _markTransportConnected(transport ?? 'iroh');
    if (!wasResponsive) {
      CoduxLog.info('[codux-flutter-iroh] host responsive source=$source');
    }
  }

  void _clearLatencyProbe() {
    _latencyProbeTimer?.cancel();
    _latencyProbeTimer = null;
    _pingTimeoutTimer?.cancel();
    _pingTimeoutTimer = null;
    _pingSentAt = null;
    _pendingPingId = null;
    _latencyMs = null;
  }

  void _recordTransportPong(Object? payload) {
    final sentAt = _pingSentAt;
    if (sentAt == null) return;
    if (payload is Map && _pendingPingId != null) {
      final id = payload['id']?.toString();
      if (id != null && id != _pendingPingId) return;
    }
    final nextLatency = DateTime.now().difference(sentAt).inMilliseconds;
    _pingTimeoutTimer?.cancel();
    _pingTimeoutTimer = null;
    _pingSentAt = null;
    _pendingPingId = null;
    if (nextLatency <= 0 || nextLatency > 60000) return;
    if (_latencyMs == nextLatency) return;
    setState(() => _latencyMs = nextLatency);
  }

  void _sendHostInfoRequest() {
    if (!_transportReady || !_irohReady) return;
    _send(const RelayEnvelope(type: 'host.info'));
  }

  void _sendTransportPing() {
    final target = _activeDevice;
    if (!_transportReady || !_irohReady || target == null) return;
    if (_pendingPingId != null) return;
    final pingId = '${DateTime.now().microsecondsSinceEpoch}-${++_pingSeq}';
    _pendingPingId = pingId;
    _pingSentAt = DateTime.now();
    final sent = _send(
      RelayEnvelope(type: 'transport.ping', payload: {'id': pingId}),
    );
    if (!sent) {
      _pendingPingId = null;
      _pingSentAt = null;
      return;
    }
    _pingTimeoutTimer?.cancel();
    _pingTimeoutTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || _disposing || !_appInForeground) return;
      if (_pendingPingId != pingId) return;
      _pendingPingId = null;
      _pingSentAt = null;
      _failHostConnection(target, 'transport_ping_timeout');
    });
  }

  void _startLatencyProbe() {
    if (_latencyProbeTimer != null) return;
    _sendTransportPing();
    _latencyProbeTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _sendTransportPing(),
    );
  }

  void _failHostConnection(StoredDevice target, String reason) {
    CoduxLog.warn(
      '[codux-flutter-remote] host unavailable reason=$reason host=${target.hostId} device=${target.deviceId}',
    );
    _disconnectTransport(
      status: _t('connection.failedRetry'),
      closeTerminal: false,
      notifyHost: false,
    );
    if (_appSuspended || !_appInForeground) {
      CoduxLog.info(
        '[codux-flutter-iroh] reconnect deferred reason=$reason appSuspended=$_appSuspended',
      );
      return;
    }
    _scheduleReconnect(target);
  }

  void _disconnectTransport({
    required String status,
    bool closeTerminal = false,
    bool notifyHost = true,
  }) {
    if (notifyHost && _irohReady) {
      _send(const RelayEnvelope(type: 'device.disconnected'));
    }
    _cancelHostResponseProbe();
    _clearConnectionGrace();
    _lastConnectedAt = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    _clearLatencyProbe();
    _irohReady = false;
    unawaited(_irohTransport.close());
    _terminalInputBatcher.reset();
    _clearPendingTerminalInputs();
    setState(() {
      _transportReady = false;
      _remoteProtocolReady = false;
      _hostResponsive = false;
      _backgroundConnect = false;
      if (closeTerminal) {
        _showTerminal = false;
        _workspaceMode = 'terminal';
      }
      _status = status;
      _terminalBufferRetry.reset();
      _terminalBufferLoading = false;
    });
  }

  void _recoverForegroundState() {
    if (!_transportReady) {
      final device = _activeDevice;
      if (device != null) _connect(device, true);
      return;
    }
    _backgroundConnect = false;
    setState(() => _hostResponsive = false);
    _requestProjectList(resetRetry: true);
    _requestTerminalList(resetRetry: true);
    _send(const RelayEnvelope(type: 'host.info'));
    _restoreVisibleTerminalFromCache();
    _flushPendingTerminalResize(force: true);
    _requestBufferIfReady(force: true);
    _terminalInputBatcher.flush();
    _startHostResponseProbe(reason: 'foreground_resume');
  }

  void _restoreVisibleTerminalFromCache() {
    final id = _sessionId;
    if (id == null) return;
    _restoreTerminalSessionFromCache(id);
  }

  bool _restoreTerminalSessionFromCache(
    String sessionId, {
    bool clearFirst = true,
  }) {
    final cached = _terminalOutputCache[sessionId];
    if (cached == null || cached.isEmpty) return false;
    _pendingTerminalOutput = '';
    final controller = _nativeTerminalController;
    if (controller == null) {
      _pendingTerminalOutput = cached;
    } else if (clearFirst) {
      _replaceTerminalData(cached, replayingBuffer: true);
    } else {
      _writeTerminalData(cached, replayingBuffer: true);
    }
    return true;
  }

  ProjectInfo? get _selectedProject {
    for (final project in _projects) {
      if (project.id == _selectedProjectId) return project;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _maskController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _maskOpacity = CurvedAnimation(
      parent: _maskController,
      curve: Curves.easeOutCubic,
    );
    _edgeBackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _terminalBufferRetry = TerminalBufferRetryCoordinator(
      onRetryExhausted: (sessionId) {
        if (!mounted || _sessionId != sessionId) return;
        setState(() => _terminalBufferLoading = false);
      },
    );
    _terminalInputBatcher = TerminalInputBatcher(
      send: (data) => _sendInputNow(data, source: 'typed-batch'),
    );
    _terminalUploadSender = TerminalUploadSender(
      send: _sendTerminalUploadEnvelopeReliable,
      afterChunkAck: () => Future<void>.delayed(Duration.zero),
    );
    _irohTransport = CoduxRemoteIroh(bridge: widget.irohBridge)
      ..onState = _handleIrohState
      ..onEnvelope = (envelope) {
        _handleIrohEnvelope(RelayEnvelope.fromJson(envelope));
      };
    _voiceService = LocalVoiceRecognitionService(
      onLog: (message) => CoduxLog.info('[codux-flutter-voice] $message'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposing = true;
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _healthTimer?.cancel();
    _connectionGraceTimer?.cancel();
    _latencyProbeTimer?.cancel();
    _pingTimeoutTimer?.cancel();
    _toastTimer?.cancel();
    _filePickerTimeoutTimer?.cancel();
    _projectListRetryTimer?.cancel();
    _terminalListRetryTimer?.cancel();
    _hostResponseTimer?.cancel();
    _terminalBufferRetry.dispose();
    _terminalInputBatcher.dispose();
    _terminalUploadCompletion?.completeError(
      StateError('Terminal upload cancelled'),
    );
    _terminalUploadCompletion = null;
    _terminalUploadSender.dispose();
    _clearPendingTerminalInputs();
    _voiceService.dispose();
    unawaited(_irohTransport.close());
    _nativeTerminalController?.dispose();
    _settingsNameController.dispose();
    _fileEditorController.dispose();
    _projectNameController.dispose();
    _projectPathController.dispose();
    _maskController.dispose();
    _edgeBackController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    CoduxLog.info('[codux-flutter-lifecycle] state=${state.name}');
    if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      _appSuspended = false;
      final device = _activeDevice;
      if (device == null) return;
      if (_irohReady) {
        CoduxLog.info(
          '[codux-flutter-lifecycle] resume keep existing transport host=${device.hostId} device=${device.deviceId}',
        );
        _recoverForegroundState();
        return;
      }
      CoduxLog.info(
        '[codux-flutter-lifecycle] resume reconnect host=${device.hostId} device=${device.deviceId}',
      );
      _connect(device, true);
      return;
    }
    if (state == AppLifecycleState.inactive) {
      return;
    }
    if (state == AppLifecycleState.paused && _showVoiceOverlay) {
      CoduxLog.info('[codux-flutter-lifecycle] pause ignored for voice input');
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _appInForeground = false;
      _appSuspended = true;
      _disconnectTransport(
        status: _t('app.disconnected'),
        closeTerminal: false,
      );
      if (mounted) {
        setState(() {
          _terminalBufferRetry.reset();
          _terminalBufferLoading = false;
        });
      }
    }
  }

  Future<void> _bootstrap() async {
    final initialDevices = widget.initialDevices;
    if (initialDevices != null) {
      if (!mounted) return;
      setState(() {
        _devices = initialDevices;
        _activeDevice = initialDevices.isNotEmpty ? initialDevices.first : null;
        _showTerminal = false;
      });
      if (initialDevices.isNotEmpty) {
        unawaited(_restoreCachedProjects(initialDevices.first));
        _connect(initialDevices.first, true);
      }
      return;
    }
    await _loadDeviceName();
    final loadedSettings = await _storage.loadSettings();
    final devices = await _storage.loadDevices();
    if (!mounted) return;
    final next =
        loadedSettings ?? MobileSettings(localName: _detectedDeviceName);
    widget.onChangeAccent(AccentChoices.byId(next.accentId));
    widget.onChangeLocale(LocaleChoices.byId(next.localeId));
    setState(() {
      _settings = next;
      _settingsNameController.text = next.localName;
      _devices = devices;
      _activeDevice = devices.isNotEmpty ? devices.first : null;
      _showTerminal = false;
    });
    if (devices.isNotEmpty) {
      unawaited(_restoreCachedProjects(devices.first));
      _connect(devices.first, true);
    }
  }

  Future<void> _restoreCachedProjects(StoredDevice device) async {
    try {
      final cached = await _storage.loadCachedProjects(device);
      if (!mounted ||
          _activeDevice?.hostId != device.hostId ||
          cached.isEmpty ||
          _projects.isNotEmpty) {
        return;
      }
      setState(() {
        _projects = cached;
        _selectedProjectId = cached.first.id;
      });
      CoduxLog.info(
        '[codux-flutter-projects] cache restored count=${cached.length} host=${device.hostId}',
      );
    } catch (error) {
      CoduxLog.warn('[codux-flutter-projects] cache restore failed: $error');
    }
  }

  Future<void> _loadDeviceName() async {
    try {
      final plugin = DeviceInfoPlugin();
      final info = await plugin.deviceInfo;
      final data = info.data;
      final name =
          (data['name'] ??
                  data['model'] ??
                  data['product'] ??
                  data['localizedModel'] ??
                  'Codux Mobile')
              .toString();
      _detectedDeviceName = name;
    } catch (_) {
      _detectedDeviceName = 'Codux Mobile';
    }
  }

  Future<void> _saveDevices(List<StoredDevice> devices) async {
    setState(() {
      _devices = devices;
      final activeId = _activeDevice?.deviceId;
      _activeDevice = devices.isEmpty
          ? null
          : devices.firstWhere(
              (item) => item.deviceId == activeId,
              orElse: () => devices.first,
            );
    });
    await _storage.saveDevices(devices);
  }

  Future<void> _saveDevice(StoredDevice device) async {
    final next = [
      device,
      ..._devices.where((item) => item.deviceId != device.deviceId),
    ];
    await _saveDevices(next);
    setState(() {
      _activeDevice = device;
      _showTerminal = false;
      _status = _t('pair.success');
    });
    _connect(device);
  }

  void _handleScannedPayload(String raw) {
    if (!_showScanner || _pendingPairing != null) return;
    unawaited(_prepareScannedPayload(raw));
  }

  Future<void> _prepareScannedPayload(String raw) async {
    try {
      final payload = await parsePairingPayload(raw);
      if (!mounted || !_showScanner || _pendingPairing != null) return;
      setState(() {
        _showScanner = false;
        _pendingPairing = payload;
        _pairingInFlight = false;
        _pairingCancelled = false;
        _pairingError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _showScanner = false);
      _showToast(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _cancelPairing() {
    if (_pairingInFlight) {
      setState(() => _pairingCancelled = true);
      return;
    }
    setState(() {
      _pendingPairing = null;
      _pairingInFlight = false;
      _pairingCancelled = false;
      _pairingError = null;
    });
  }

  Future<void> _confirmPairing() async {
    final payload = _pendingPairing;
    if (payload == null || _pairingInFlight) return;
    final name = _settings.localName.isNotEmpty
        ? _settings.localName
        : _detectedDeviceName;
    setState(() {
      _pairingInFlight = true;
      _pairingCancelled = false;
      _pairingError = null;
      _status = _t('pair.submitting');
    });
    try {
      final confirmed = await _confirmIrohPairing(payload, name);
      if (!mounted) return;
      final hostName = confirmed.hostName?.trim().isNotEmpty == true
          ? confirmed.hostName!.trim()
          : confirmed.name;
      setState(() {
        _pendingPairing = null;
        _pairingInFlight = false;
        _pairingCancelled = false;
        _pairingError = null;
      });
      await _saveDevice(confirmed);
      _showToast(_t('device.bound', params: {'name': hostName}));
    } on PairingCancelledException {
      if (!mounted) return;
      setState(() {
        _pendingPairing = null;
        _pairingInFlight = false;
        _pairingCancelled = false;
        _pairingError = null;
        _status = _t('pair.cancelled');
      });
    } on PairingRejectedException {
      if (!mounted) return;
      setState(() {
        _pendingPairing = null;
        _pairingInFlight = false;
        _pairingCancelled = false;
        _pairingError = null;
        _status = _t('pair.rejected');
      });
      _showToast(_t('pair.rejected'));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _pairingInFlight = false;
        _pairingCancelled = false;
        _pairingError = error.toString().replaceFirst('Exception: ', '');
        _status = _pairingError ?? _t('pair.failed');
      });
    }
  }

  Future<StoredDevice> _confirmIrohPairing(
    PairingPayload payload,
    String name,
  ) async {
    final nodeAddr = payload.iroh;
    if (nodeAddr == null) {
      throw Exception(_t('remote.qrMissingFields'));
    }
    final completer = Completer<StoredDevice>();
    _irohPairingCompleter = completer;
    _irohPairingDeviceName = name;
    _irohPairingRequestSent = false;
    setState(() => _status = _t('pair.waiting'));
    await _irohTransport.connect(nodeAddr: nodeAddr.toJson());
    try {
      return await Future.any<StoredDevice>([
        completer.future,
        _waitIrohPairingCancelled(),
        Future<StoredDevice>.delayed(
          const Duration(seconds: 90),
          () => throw Exception(_t('remote.waitTimeout')),
        ),
      ]);
    } finally {
      _irohPairingCompleter = null;
      _irohPairingDeviceName = null;
      _irohPairingRequestSent = false;
      await _irohTransport.close();
      _irohReady = false;
    }
  }

  Future<StoredDevice> _waitIrohPairingCancelled() async {
    while (!_pairingCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const PairingCancelledException();
  }

  Future<void> _saveSettings() async {
    final next = _settings.copyWith(
      localName: _settingsNameController.text.trim().isEmpty
          ? _detectedDeviceName
          : _settingsNameController.text.trim(),
    );
    await _storage.saveSettings(next);
    setState(() {
      _settings = next;
      _status = _t('settings.saved');
    });
    _popCupertinoPage(() {
      _showSettings = false;
    });
    _send(
      RelayEnvelope(type: 'device.info', payload: {'name': next.localName}),
    );
  }

  void _connect([StoredDevice? device, bool background = false]) {
    final target = device ?? _activeDevice;
    if (target == null) {
      setState(() => _showScanner = true);
      return;
    }
    if (_protocolBlockedHostIds.contains(target.hostId)) {
      if (!background) {
        setState(() => _status = _t('connection.upgradeRequired'));
      }
      return;
    }
    _shouldReconnect = true;
    _backgroundConnect = background;
    final generation = ++_transportGeneration;
    CoduxLog.info(
      '[codux-flutter-iroh] connect start gen=$generation background=$background host=${target.hostId} device=${target.deviceId}',
    );
    _cancelHostResponseProbe();
    _reconnectTimer?.cancel();
    _healthTimer?.cancel();
    _clearLatencyProbe();
    unawaited(_irohTransport.close());
    _irohReady = false;
    _sendSeq = DateTime.now().microsecondsSinceEpoch;
    _receiveSeq = 0;
    _sendChain = Future<void>.value();
    _receiveChain = Future<void>.value();
    RemoteE2ECrypto.clearCache();
    if (background && _lastConnectedAt != null) {
      _startConnectionGrace(reason: 'background_connect');
    }
    if (!background) _clearTerminal();
    if (!background) _terminalInputBatcher.reset();
    setState(() {
      _transportReady = false;
      _remoteProtocolReady = false;
      _hostResponsive = false;
      if (!background) {
        _status = _t('app.connecting');
        _projects = [];
        _projectListLoaded = false;
        _terminals = [];
        _worktrees = [];
        _worktreeBaseBranches = [];
        _terminalListLoaded = false;
        _projectListRetryTimer?.cancel();
        _terminalListRetryTimer?.cancel();
        _projectListRetryAttempt = 0;
        _terminalListRetryAttempt = 0;
        _selectedProjectId = null;
        _defaultWorktreeBaseBranch = null;
        _selectedWorktreeId = null;
        _sessionId = null;
        _showTerminalSwitcher = false;
        _terminalBufferRetry.reset();
        _terminalBufferLoading = false;
      }
      _activeDevice = target;
    });
    unawaited(_restoreCachedProjects(target));
    final nodeAddr = stableIrohNodeAddr(target.iroh);
    if (target.transport != 'iroh' || nodeAddr == null) {
      setState(() => _status = _t('pair.repairRequired'));
      return;
    }
    CoduxLog.info(
      '[codux-flutter-iroh] dial nodeId=${nodeAddr.nodeId} relay=${nodeAddr.relayUrl ?? ''} direct=${nodeAddr.directAddresses.length}',
    );
    _irohTransport.connect(nodeAddr: nodeAddr.toJson()).catchError((
      Object error,
    ) {
      CoduxLog.warn(
        '[codux-flutter-iroh] connect failed gen=$generation error=$error',
      );
      if (generation != _transportGeneration) return;
      if (!_backgroundConnect && mounted) {
        setState(() => _status = _t('connection.failedRetry'));
      }
      _handleIrohClosed('connect_failed');
    });
    _healthTimer = Timer(const Duration(seconds: 16), () {
      if (generation != _transportGeneration) return;
      if (!_irohReady) {
        CoduxLog.warn('[codux-flutter-iroh] connect timeout gen=$generation');
        if (!_backgroundConnect && mounted) {
          setState(() => _status = _t('connection.failedRetry'));
        }
        _handleIrohClosed('hello_timeout');
      }
    });
  }

  void _scheduleReconnect(StoredDevice target) {
    if (!_shouldReconnect) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt += 1;
    final delay = Duration(
      milliseconds: (800 * (1 << (_reconnectAttempt - 1).clamp(0, 5))).clamp(
        800,
        30000,
      ),
    );
    CoduxLog.info(
      '[codux-flutter-iroh] reconnect scheduled host=${target.hostId} device=${target.deviceId} attempt=$_reconnectAttempt delayMs=${delay.inMilliseconds}',
    );
    _reconnectTimer = Timer(delay, () => _connect(target, true));
  }

  void _sendInitialTransportRequests({bool force = false}) {
    if (force) {
      _terminalBufferRetry.reset();
    }
    final target = _activeDevice;
    _send(
      RelayEnvelope(
        type: 'device.info',
        payload: {
          'name': _settings.localName.isNotEmpty
              ? _settings.localName
              : (target?.name ?? _detectedDeviceName),
        },
      ),
    );
    _requestProjectList(resetRetry: force);
    _requestTerminalList(resetRetry: force);
  }

  void _requestProjectList({bool resetRetry = false}) {
    if (!_remoteProtocolReady) return;
    if (resetRetry) {
      _projectListRetryTimer?.cancel();
      _projectListRetryTimer = null;
      _projectListRetryAttempt = 0;
    }
    final sent = _send(const RelayEnvelope(type: 'project.list'));
    if (sent && !_projectListLoaded) {
      CoduxLog.info(
        '[codux-flutter-projects] request project.list attempt=$_projectListRetryAttempt',
      );
      _scheduleProjectListRetry();
    }
  }

  void _scheduleProjectListRetry() {
    if (!_transportReady || _projectListLoaded) return;
    _projectListRetryTimer?.cancel();
    if (_projectListRetryAttempt >= 6) return;
    final delay = Duration(
      milliseconds: (800 * (1 << _projectListRetryAttempt)).clamp(800, 5000),
    );
    _projectListRetryTimer = Timer(delay, () {
      if (!mounted || !_transportReady || _projectListLoaded) return;
      _projectListRetryAttempt += 1;
      CoduxLog.info(
        '[codux-flutter-projects] retry project.list attempt=$_projectListRetryAttempt',
      );
      _requestProjectList();
    });
  }

  void _markProjectListReceived() {
    _projectListLoaded = true;
    _projectListRetryAttempt = 0;
    _projectListRetryTimer?.cancel();
    _projectListRetryTimer = null;
    CoduxLog.info('[codux-flutter-projects] project.list received');
  }

  void _requestTerminalList({bool resetRetry = false}) {
    if (!_remoteProtocolReady) return;
    if (resetRetry) {
      _terminalListRetryTimer?.cancel();
      _terminalListRetryTimer = null;
      _terminalListRetryAttempt = 0;
    }
    final sent = _send(const RelayEnvelope(type: 'terminal.list'));
    if (sent && !_terminalListLoaded) {
      CoduxLog.info(
        '[codux-flutter-terminal] request terminal.list attempt=$_terminalListRetryAttempt',
      );
      _scheduleTerminalListRetry();
    }
  }

  void _requestWorktreeList({bool loading = false}) {
    final project = _selectedProject;
    if (!_remoteProtocolReady || project == null) return;
    if (loading) {
      setState(() => _worktreeListLoading = true);
    }
    _send(
      RelayEnvelope(
        type: 'worktree.list',
        payload: {
          'projectId': project.id,
          if (project.path != null) 'projectPath': project.path,
        },
      ),
    );
  }

  void _scheduleTerminalListRetry() {
    if (!_transportReady || _terminalListLoaded) return;
    _terminalListRetryTimer?.cancel();
    if (_terminalListRetryAttempt >= 6) return;
    final delay = Duration(
      milliseconds: (800 * (1 << _terminalListRetryAttempt)).clamp(800, 5000),
    );
    _terminalListRetryTimer = Timer(delay, () {
      if (!mounted || !_transportReady || _terminalListLoaded) return;
      _terminalListRetryAttempt += 1;
      CoduxLog.info(
        '[codux-flutter-terminal] retry terminal.list attempt=$_terminalListRetryAttempt',
      );
      _requestTerminalList();
    });
  }

  void _markTerminalListReceived() {
    _terminalListLoaded = true;
    _terminalListRetryAttempt = 0;
    _terminalListRetryTimer?.cancel();
    _terminalListRetryTimer = null;
    CoduxLog.info('[codux-flutter-terminal] terminal.list received');
  }

  Future<void> _cacheProjects(List<ProjectInfo> projects) async {
    final device = _activeDevice;
    if (device == null) return;
    try {
      await _storage.saveCachedProjects(device, projects);
    } catch (error) {
      CoduxLog.warn('[codux-flutter-projects] cache save failed: $error');
    }
  }

  bool _send(RelayEnvelope message) {
    if (!_irohReady) {
      setState(() => _status = _t('app.remoteNotConnected'));
      CoduxLog.warn(
        '[codux-flutter-iroh] drop type=${message.type} reason=not_ready',
      );
      return false;
    }
    final activeDevice = _activeDevice;
    final seq = activeDevice == null ? null : ++_sendSeq;
    final previous = _sendChain.catchError((_) {});
    final task = previous
        .then((_) async {
          if (!_irohReady) return;
          CoduxLog.warn(
            '[codux-flutter-iroh] send type=${message.type} session=${message.sessionId ?? ''}',
          );
          if (activeDevice == null) {
            await _irohTransport.send(message.toJson());
            return;
          }
          final encrypted = await RemoteE2ECrypto.encryptEnvelope(
            inner: message,
            device: activeDevice,
            seq: seq!,
          );
          if (!_irohReady) return;
          await _irohTransport.send(encrypted.toJson());
        })
        .catchError((Object error) {
          CoduxLog.error('[codux-flutter-e2e] iroh encrypt failed: $error');
          if (mounted) setState(() => _status = _t('pair.repairRequired'));
        });
    _sendChain = task;
    return true;
  }

  bool _sendTerminalEnvelope(RelayEnvelope message) {
    return _send(message);
  }

  Future<bool> _sendTerminalEnvelopeReliable(RelayEnvelope message) async {
    return _send(message);
  }

  Future<bool> _sendTerminalUploadEnvelopeReliable(
    RelayEnvelope message,
  ) async {
    return _send(message);
  }

  Future<void> _handleTransportEnvelope(
    RelayEnvelope message,
    StoredDevice target,
  ) async {
    try {
      if (message.type == 'secure.message') {
        message = await RemoteE2ECrypto.decryptEnvelope(
          outer: message,
          device: target,
        );
        final seq = message.seq;
        if (seq != null) {
          if (seq <= _receiveSeq) {
            CoduxLog.warn(
              '[codux-flutter-e2e] drop replay seq=$seq previous=$_receiveSeq',
            );
            return;
          }
          _receiveSeq = seq;
        }
      }
      _healthTimer?.cancel();
      _healthTimer = null;
      CoduxLog.warn(
        '[codux-flutter-iroh] recv type=${message.type} session=${message.sessionId ?? ''}',
      );
      switch (message.type) {
        case 'hello':
          if (!_transportReady) {
            _reconnectAttempt = 0;
            CoduxLog.info('[codux-flutter-iroh] hello received');
            setState(() {
              _transportReady = true;
              _hasShownTerminal = true;
              if (!_backgroundConnect) _status = _t('app.connected');
            });
            _markTransportConnected('iroh');
            _sendHostInfoRequest();
            _startHostResponseProbe(reason: 'hello');
          }
        case 'host.offline':
          final payload = message.payload;
          final messageText = payload is Map
              ? '${payload['message'] ?? _t('connection.macDisconnected')}'
              : _t('connection.macDisconnected');
          _terminalInputBatcher.reset();
          _clearPendingTerminalInputs();
          _clearLatencyProbe();
          setState(() {
            _transportReady = false;
            _remoteProtocolReady = false;
            _hostResponsive = false;
            _showTerminal = false;
            _workspaceMode = 'terminal';
            _projects = [];
            _projectListLoaded = false;
            _terminals = [];
            _worktrees = [];
            _worktreeBaseBranches = [];
            _terminalListLoaded = false;
            _projectListRetryTimer?.cancel();
            _terminalListRetryTimer?.cancel();
            _projectListRetryAttempt = 0;
            _terminalListRetryAttempt = 0;
            _selectedProjectId = null;
            _defaultWorktreeBaseBranch = null;
            _selectedWorktreeId = null;
            _sessionId = null;
            _showTerminalSwitcher = false;
            _status = messageText;
            _terminalBufferRetry.reset();
            _terminalBufferLoading = false;
          });
          _clearConnectionGrace();
          _cancelHostResponseProbe();
          _scheduleReconnect(target);
        case 'secure.required':
          setState(() {
            _status = _t('pair.repairRequired');
          });
        case 'host.info':
          if (!_isCompatibleRemoteProtocol(message.payload)) {
            _failRemoteProtocol(target, message.payload);
            return;
          }
          _markHostResponsive('host.info', transport: 'iroh');
          final payload = message.payload;
          if (payload is Map && payload['name'] != null) {
            _updateDevice(target.deviceId, hostName: '${payload['name']}');
          }
          _markRemoteProtocolReady(
            force: !_projectListLoaded || !_terminalListLoaded,
          );
          _startLatencyProbe();
        case 'transport.pong':
          _markHostResponsive('transport.pong');
          _recordTransportPong(message.payload);
        case 'project.list':
          _markHostResponsive('project.list');
          _markProjectListReceived();
          final payload = message.payload;
          final list = payload is Map
              ? (payload['projects'] as List<dynamic>? ?? [])
              : <dynamic>[];
          final next = list
              .map((item) => ProjectInfo.fromJson(item as Map<String, dynamic>))
              .toList();
          setState(() {
            _projects = next;
            _selectedProjectId =
                next.any((item) => item.id == _selectedProjectId)
                ? _selectedProjectId
                : (next.isNotEmpty ? next.first.id : null);
          });
          CoduxLog.info(
            '[codux-flutter-projects] project.list count=${next.length}',
          );
          unawaited(_cacheProjects(next));
          _ensureTerminalForSelectedProject();
        case 'terminal.list':
          _markHostResponsive('terminal.list');
          _markTerminalListReceived();
          final payload = message.payload;
          final list = payload is Map
              ? (payload['terminals'] as List<dynamic>? ?? [])
              : <dynamic>[];
          final next = list
              .map(
                (item) => TerminalInfo.fromJson(item as Map<String, dynamic>),
              )
              .toList();
          CoduxLog.info(
            '[codux-flutter-terminal] terminal.list count=${next.length}',
          );
          final activeSessionMissing =
              _sessionId != null &&
              !next.any(
                (item) => item.id == _sessionId && _isAccessibleTerminal(item),
              );
          if (activeSessionMissing) {
            final missingSessionId = _sessionId;
            _terminalInputBatcher.reset();
            _clearPendingTerminalInputs(sessionId: missingSessionId);
            if (missingSessionId != null) {
              _terminalOutputCache.remove(missingSessionId);
              _terminalBufferLengths.remove(missingSessionId);
              _terminalOutputSeqBySession.remove(missingSessionId);
              _lastTerminalIdByProject.removeWhere(
                (_, terminalId) => terminalId == missingSessionId,
              );
            }
          }
          setState(() {
            _terminals = next;
            _terminalListLoaded = true;
            if (activeSessionMissing) {
              _sessionId = null;
              _terminalBufferRetry.reset();
              _terminalBufferLoading = false;
            }
          });
          _ensureTerminalForSelectedProject();
          if (_showTerminal && _sessionId != null) {
            _requestBufferIfReady();
          }
        case 'terminal.created':
          final payload = message.payload;
          if (payload is Map<String, dynamic>) {
            final terminal = TerminalInfo.fromJson(payload);
            CoduxLog.info(
              '[codux-flutter-terminal] created session=${terminal.id} project=${terminal.projectId}',
            );
            setState(() {
              _terminals = [
                terminal,
                ..._terminals.where((item) => item.id != terminal.id),
              ];
              _sessionId = terminal.id;
              _selectedProjectId = terminal.projectId;
              _lastTerminalIdByProject[terminal.projectId] = terminal.id;
              _creatingTerminalProjectId = null;
              _terminalBufferRetry.reset();
              _terminalBufferLoading = false;
            });
            _clearTerminal();
            _flushPendingTerminalResize(force: true);
            _requestBufferIfReady();
            _terminalInputBatcher.flush();
          }
        case 'terminal.closed':
          final closedSessionId = message.sessionId;
          final closedActiveSession =
              closedSessionId != null && _sessionId == closedSessionId;
          if (closedActiveSession) {
            _terminalInputBatcher.reset();
            _clearPendingTerminalInputs(sessionId: closedSessionId);
          }
          setState(() {
            _terminals = _terminals
                .where((item) => item.id != closedSessionId)
                .toList();
            if (closedSessionId != null) {
              _terminalOutputCache.remove(closedSessionId);
              _terminalBufferLengths.remove(closedSessionId);
              _terminalOutputSeqBySession.remove(closedSessionId);
              _lastTerminalIdByProject.removeWhere(
                (_, terminalId) => terminalId == closedSessionId,
              );
            }
            if (closedActiveSession) {
              _sessionId = null;
              _terminalBufferRetry.reset();
              _terminalBufferLoading = false;
              _terminalCursorBottom = 0;
            }
            _creatingTerminalProjectId = null;
          });
          if (closedActiveSession) _clearTerminal();
        case 'worktree.list':
          _markHostResponsive('worktree.list');
          final payload = message.payload;
          if (payload is Map) {
            final list = _worktreeListPayload(payload);
            setState(() {
              _worktrees = list;
              _selectedWorktreeId = payload['selectedWorktreeId']?.toString();
              _worktreeBaseBranches = _stringListPayload(
                payload['baseBranches'],
              );
              _defaultWorktreeBaseBranch = payload['defaultBaseBranch']
                  ?.toString();
              _worktreeListLoading = false;
            });
          }
        case 'worktree.updated':
          final payload = message.payload;
          if (payload is Map) {
            final list = _worktreeListPayload(payload);
            setState(() {
              _worktrees = list;
              _selectedWorktreeId = payload['selectedWorktreeId']?.toString();
              _worktreeBaseBranches = _stringListPayload(
                payload['baseBranches'],
              );
              _defaultWorktreeBaseBranch = payload['defaultBaseBranch']
                  ?.toString();
              _worktreeListLoading = false;
            });
          }
          _requestTerminalList(resetRetry: true);
        case 'terminal.output':
          _handleTerminalOutput(message);
        case 'file.list':
          final payload = message.payload;
          if (payload is Map) {
            final list = (payload['entries'] as List<dynamic>? ?? [])
                .whereType<Map<String, dynamic>>()
                .map(RemoteFileEntry.fromJson)
                .toList();
            final purpose = payload['purpose']?.toString();
            if (purpose == 'projectFiles') {
              final nextPath = '${payload['path'] ?? ''}';
              setState(() {
                _projectFilesPath = nextPath;
                _projectFilesParent = payload['parent']?.toString();
                _projectFileEntries = list;
                _projectFilesLoading = false;
                final projectId = _selectedProjectId;
                if (projectId != null && nextPath.isNotEmpty) {
                  _projectFilePathMemory[projectId] = nextPath;
                }
              });
            } else {
              setState(() {
                _filePickerPath = '${payload['path'] ?? ''}';
                _filePickerParent = payload['parent']?.toString();
                _filePickerEntries = list;
                _filePickerLoading = false;
                _filePickerTimeoutTimer?.cancel();
                _showFilePicker = true;
              });
            }
          }
        case 'project.updated':
          _refreshLists();
          _showToast(_t('project.updated'));
        case 'ai.stats':
          final payload = message.payload;
          if (payload is Map<String, dynamic>) {
            setState(() {
              _currentAIStats = AIStatsInfo.fromJson(payload);
              _aiStatsLoading = false;
              _workspaceMode = 'stats';
            });
          }
        case 'file.read':
          final payload = message.payload;
          if (payload is Map) {
            setState(() {
              final content = '${payload['content'] ?? ''}';
              _editingFilePath = '${payload['path'] ?? ''}';
              _fileEditorController.text = content;
              _fileEditorController.highlightEnabled = content.length <= 80000;
              _fileEditorEditable = content.length <= 200000;
              _fileEditorEditing = false;
              _fileEditorLoading = false;
              if (!_fileEditorEditable) {
                _showToast(_t('file.readOnlyLarge'));
              }
            });
          }
        case 'file.written':
          setState(() => _fileEditorSaving = false);
          _showToast(_t('file.saved'));
        case 'file.renamed':
          _requestProjectFiles(_projectFilesPath);
          _showToast(_t('file.renamed'));
        case 'file.deleted':
          final payload = message.payload;
          final deletedPath = payload is Map
              ? payload['path']?.toString()
              : null;
          if (deletedPath != null && deletedPath == _editingFilePath) {
            setState(() => _editingFilePath = null);
          }
          _requestProjectFiles(_projectFilesPath);
          _showToast(_t('file.deleted'));
        case 'terminal.uploaded':
          _handleTerminalUploaded(message);
        case 'terminal.upload.ack':
          _terminalUploadSender.handleAck(message);
        case 'terminal.input.ack':
          _handleTerminalInputAck(message);
        case 'error':
          final payload = message.payload;
          setState(() {
            _aiStatsLoading = false;
            _filePickerLoading = false;
            _worktreeListLoading = false;
            _blockingLoadingMessage = null;
            _status =
                message.error ??
                (payload is Map
                    ? '${payload['message'] ?? _t('remote.error')}'
                    : _t('remote.error'));
          });
      }
    } catch (error) {
      CoduxLog.error('[codux-flutter-e2e] receive failed: $error');
    }
  }

  void _handleIrohState(String rawState) {
    final state = rawState.split(':').first.trim();
    final detail = rawState.length > state.length
        ? rawState.substring(state.length + 1).trim()
        : '';
    CoduxLog.warn(
      detail.isEmpty
          ? '[codux-flutter-iroh] state=$state'
          : '[codux-flutter-iroh] state=$state detail=$detail',
    );
    if (!mounted || _disposing) return;
    if (state == 'path') {
      final path = _parseIrohPath(detail);
      if (path != null) {
        setState(() => _irohConnectionPath = path);
      }
      return;
    }
    final pairingCompleter = _irohPairingCompleter;
    if (pairingCompleter != null) {
      if (state == 'connected') {
        _irohReady = true;
        if (_pendingPairing != null) {
          setState(() => _status = _t('pair.waiting'));
        }
        if (!_irohPairingRequestSent) {
          final payload = _pendingPairing;
          final name = _irohPairingDeviceName;
          if (payload != null && name != null) {
            _irohPairingRequestSent = true;
            final request = irohPairingRequestEnvelope(payload, name).toJson();
            unawaited(
              _irohTransport
                  .send(request)
                  .then((sent) {
                    if (!sent && !pairingCompleter.isCompleted) {
                      pairingCompleter.completeError(
                        Exception('Iroh pairing request failed'),
                      );
                    }
                  })
                  .catchError((Object error) {
                    if (!pairingCompleter.isCompleted) {
                      pairingCompleter.completeError(error);
                    }
                  }),
            );
          }
        }
        return;
      }
      if ((state == 'failed' || state == 'closed') &&
          !pairingCompleter.isCompleted) {
        pairingCompleter.completeError(
          Exception('Iroh pairing connection $state'),
        );
        return;
      }
    }
    if (state == 'connected') {
      _reconnectAttempt = 0;
      setState(() {
        _irohReady = true;
        _transportReady = true;
        _hasShownTerminal = true;
        if (!_backgroundConnect) _status = _t('app.connected');
      });
      _markTransportConnected('iroh');
      _sendHostInfoRequest();
      _startHostResponseProbe(reason: 'iroh');
      return;
    }
    if (state == 'failed' || state == 'closed') {
      _handleIrohClosed(state);
    }
  }

  String? _parseIrohPath(String detail) {
    for (final part in detail.split(';')) {
      final trimmed = part.trim();
      if (!trimmed.startsWith('path=')) continue;
      final value = trimmed.substring(5).trim();
      if (value == 'direct' ||
          value == 'relay' ||
          value == 'mixed' ||
          value == 'none') {
        return value;
      }
    }
    return null;
  }

  void _handleIrohEnvelope(RelayEnvelope message) {
    CoduxLog.warn(
      '[codux-flutter-iroh] envelope type=${message.type} session=${message.sessionId ?? ''}',
    );
    if (_irohPairingCompleter != null &&
        (message.type == 'pairing.confirmed' ||
            message.type == 'pairing.rejected')) {
      _handleIrohPairingEnvelope(message);
      return;
    }
    final target = _activeDevice;
    if (target == null || target.transport != 'iroh') return;
    final previous = _receiveChain.catchError((_) {});
    final task = previous
        .then((_) => _handleTransportEnvelope(message, target))
        .catchError((Object error) {
          CoduxLog.error('[codux-flutter-iroh] receive queue failed: $error');
        });
    _receiveChain = task;
  }

  void _handleIrohPairingEnvelope(RelayEnvelope message) {
    final completer = _irohPairingCompleter;
    final payload = _pendingPairing;
    final name = _irohPairingDeviceName;
    if (completer == null || payload == null || name == null) return;
    if (message.type == 'pairing.confirmed') {
      try {
        completer.complete(
          irohConfirmedDevice(payload: payload, name: name, confirmed: message),
        );
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    } else if (message.type == 'pairing.rejected') {
      completer.completeError(const PairingRejectedException());
    }
  }

  void _handleIrohClosed(String reason) {
    _irohReady = false;
    if (_activeDevice?.transport != 'iroh') return;
    setState(() {
      _transportReady = false;
      _remoteProtocolReady = false;
      _hostResponsive = false;
      _status = _t('app.reconnecting');
      _terminalBufferRetry.reset();
      _terminalBufferLoading = false;
    });
    if (_lastConnectedAt == null) {
      _clearConnectionGrace();
    } else {
      _startConnectionGrace(reason: reason);
    }
    final target = _activeDevice;
    if (target != null && _appInForeground && !_appSuspended) {
      _scheduleReconnect(target);
    }
  }

  void _handleTerminalOutput(RelayEnvelope message) {
    final payload = message.payload;
    if (payload is! Map || payload['data'] == null) return;
    final sessionId = message.sessionId;
    if (sessionId == null || sessionId != _sessionId) {
      CoduxLog.debug(
        '[codux-flutter-output] skip inactive session=${message.sessionId ?? ''} active=${_sessionId ?? ''}',
      );
      return;
    }
    final decoded = decodeTerminalOutputPayload(payload);
    final raw = decoded.data;
    final isBuffer = decoded.isBuffer;
    final outputSeq = _intPayloadValue(payload['outputSeq']);
    final previousSeq = _terminalOutputSeqBySession[sessionId] ?? 0;
    if (!isBuffer && outputSeq != null && outputSeq <= previousSeq) {
      _sendTerminalOutputAck(sessionId, outputSeq, decoded.bufferLength);
      CoduxLog.debug(
        '[codux-flutter-output] drop duplicate seq=$outputSeq previous=$previousSeq session=$sessionId',
      );
      return;
    }
    CoduxLog.debug(
      '[codux-flutter-output] bytes=${raw.codeUnits.length} buffer=$isBuffer session=${message.sessionId ?? ''}',
    );
    if (isBuffer) {
      final isFullBuffer = (decoded.offset ?? 0) <= 0;
      final localCacheEmpty = (_terminalOutputCache[sessionId] ?? '').isEmpty;
      if (!isFullBuffer && localCacheEmpty) {
        _terminalBufferLengths[sessionId] = 0;
        _terminalBufferRetry.resetLastBuffered();
        _requestBufferIfReady(force: true, full: true);
        if (raw.isEmpty) return;
      }
      _markTerminalBufferReceived(sessionId);
      if (isFullBuffer || !_terminalOutputCache.containsKey(sessionId)) {
        _replaceTerminalOutputCache(sessionId, raw, decoded.bufferLength);
        _replaceTerminalData(raw, replayingBuffer: true);
      } else {
        _appendTerminalOutputCache(sessionId, raw, decoded.bufferLength);
      }
    } else if (raw.isNotEmpty && _terminalBufferLoading) {
      setState(() => _terminalBufferLoading = false);
    }
    if (raw.isNotEmpty) {
      if (!isBuffer) {
        _appendTerminalOutputCache(sessionId, raw, decoded.bufferLength);
        _writeTerminalData(raw, replayingBuffer: false);
      } else if ((decoded.offset ?? 0) > 0) {
        _writeTerminalData(raw, replayingBuffer: true);
      }
    }
    if (outputSeq != null) {
      if (outputSeq > previousSeq) {
        _terminalOutputSeqBySession[sessionId] = outputSeq;
      }
      _sendTerminalOutputAck(sessionId, outputSeq, decoded.bufferLength);
    }
  }

  void _handleTerminalUploaded(RelayEnvelope message) {
    final payload = message.payload;
    if (payload is Map && payload['path'] != null) {
      final completion = _terminalUploadCompletion;
      if (completion != null && !completion.isCompleted) {
        completion.complete();
      }
      _terminalUploadCompletion = null;
      final inserted = payload['inserted'] == true;
      final mode = payload['mode']?.toString();
      final tool = payload['tool']?.toString();
      final kind = payload['kind']?.toString();
      if (!inserted) {
        final path = '${payload['path']}';
        _insertTerminalText('$path ');
      }
      setState(() {
        _terminalUploadLoading = false;
        _terminalUploadStatus = '';
        _status = kind == 'file'
            ? _t('upload.fileSentPath')
            : mode == 'clipboard'
            ? _t(
                'upload.imageSentTool',
                params: {'tool': tool ?? _t('upload.aiTool')},
              )
            : _t('upload.imageSentPath');
      });
    }
  }

  void _updateDevice(String deviceId, {String? hostName}) {
    final next = _devices
        .map(
          (item) => item.deviceId == deviceId
              ? item.copyWith(hostName: hostName)
              : item,
        )
        .toList();
    _saveDevices(next);
  }

  void _requestBufferIfReady({bool force = false, bool full = false}) {
    final sent = _terminalBufferRetry.requestIfReady(
      terminalReady: _terminalReady,
      sessionId: _sessionId,
      force: force,
      send: (sessionId) {
        unawaited(
          _sendTerminalEnvelopeReliable(
            RelayEnvelope(
              type: 'terminal.buffer',
              sessionId: sessionId,
              payload: {
                'offset': full ? 0 : (_terminalBufferLengths[sessionId] ?? 0),
                if (_pendingTerminalCols != null) 'cols': _pendingTerminalCols,
                if (_pendingTerminalRows != null) 'rows': _pendingTerminalRows,
                if (!full && (_terminalOutputSeqBySession[sessionId] ?? 0) > 0)
                  'resumeFromSeq': _terminalOutputSeqBySession[sessionId],
              },
            ),
          ),
        );
        return true;
      },
    );
    if (sent && !_terminalBufferLoading && mounted) {
      CoduxLog.info(
        '[codux-flutter-terminal] request terminal.buffer session=${_sessionId ?? ''}',
      );
      setState(() => _terminalBufferLoading = true);
    }
  }

  void _markTerminalBufferReceived(String? sessionId) {
    _terminalBufferRetry.markReceived(
      sessionId: sessionId,
      activeSessionId: _sessionId,
    );
    if (_terminalBufferLoading && mounted) {
      setState(() => _terminalBufferLoading = false);
    }
    CoduxLog.info(
      '[codux-flutter-terminal] terminal.buffer received session=${sessionId ?? ''}',
    );
  }

  void _clearTerminal() {
    CoduxLog.debug(
      '[codux-flutter-terminal] clear session=${_sessionId ?? ''}',
    );
    _pendingTerminalOutput = '';
    _nativeTerminalController?.clear();
  }

  void _writeTerminalData(String data, {required bool replayingBuffer}) {
    final displayData = _filterStandalonePromptLines(data);
    if (displayData.isEmpty) return;
    final controller = _nativeTerminalController;
    if (controller == null) {
      CoduxLog.debug(
        '[codux-flutter-output] pending bytes=${displayData.codeUnits.length} replay=$replayingBuffer',
      );
      _pendingTerminalOutput += displayData;
      return;
    }
    CoduxLog.debug(
      '[codux-flutter-output] write-native bytes=${displayData.codeUnits.length} replay=$replayingBuffer',
    );
    controller.write(displayData);
  }

  void _replaceTerminalData(String data, {required bool replayingBuffer}) {
    final displayData = replayingBuffer
        ? data
        : _filterStandalonePromptLines(data);
    _pendingTerminalOutput = '';
    final controller = _nativeTerminalController;
    if (controller == null) {
      _pendingTerminalOutput = displayData;
      return;
    }
    CoduxLog.debug(
      '[codux-flutter-output] replace-native bytes=${displayData.codeUnits.length} replay=$replayingBuffer',
    );
    controller.replace(displayData);
  }

  bool _restoreNativeTerminalController(
    CoduxNativeTerminalController controller,
  ) {
    final sessionId = _sessionId;
    if (sessionId != null) {
      final cached = _terminalOutputCache[sessionId];
      if (cached != null && cached.isNotEmpty) {
        _pendingTerminalOutput = '';
        unawaited(controller.replace(cached));
        return true;
      }
    }
    final pending = _pendingTerminalOutput;
    _pendingTerminalOutput = '';
    if (pending.isNotEmpty) {
      unawaited(controller.write(pending));
      return true;
    }
    return false;
  }

  String _filterStandalonePromptLines(String data) {
    if (!data.contains('%')) return data;
    final output = StringBuffer();
    var index = 0;
    while (index < data.length) {
      var end = index;
      while (end < data.length) {
        final codeUnit = data.codeUnitAt(end);
        if (codeUnit == 10 || codeUnit == 13) break;
        end += 1;
      }

      var lineEnd = end;
      if (end < data.length) {
        final codeUnit = data.codeUnitAt(end);
        if (codeUnit == 13 &&
            end + 1 < data.length &&
            data.codeUnitAt(end + 1) == 10) {
          lineEnd = end + 2;
        } else {
          lineEnd = end + 1;
        }
      }

      final line = data.substring(index, end);
      final isTerminatedLine = end < data.length;
      final isStandalonePromptArtifact =
          isTerminatedLine && _stripTerminalControls(line).trim() == '%';
      if (!isStandalonePromptArtifact) {
        output.write(data.substring(index, lineEnd));
      }
      index = lineEnd;
    }
    return output.toString();
  }

  String _stripTerminalControls(String data) {
    return data
        .replaceAll(RegExp('\u001B\\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll(
          RegExp('\u001B\\][^\u0007\u001B]*(?:\u0007|\u001B\\\\)'),
          '',
        );
  }

  void _replaceTerminalOutputCache(
    String sessionId,
    String data,
    int? bufferLength,
  ) {
    _terminalOutputCache[sessionId] = data;
    if (bufferLength != null) {
      _terminalBufferLengths[sessionId] = bufferLength;
    }
  }

  void _appendTerminalOutputCache(
    String sessionId,
    String data,
    int? bufferLength,
  ) {
    if (data.isNotEmpty) {
      final current = _terminalOutputCache[sessionId] ?? '';
      var next = current + data;
      if (next.length > 2000000) {
        next = next.substring(next.length - 2000000);
      }
      _terminalOutputCache[sessionId] = next;
    }
    if (bufferLength != null) {
      _terminalBufferLengths[sessionId] = bufferLength;
    }
  }

  void _sendTerminalResize(int cols, int rows) {
    final id = _sessionId;
    if (cols <= 0 || rows <= 0) return;
    final nextCols = cols;
    _pendingTerminalCols = nextCols;
    _pendingTerminalRows = rows;
    if (id == null) return;
    final terminal = _currentTerminal();
    if (!_canResizeTerminal(terminal)) return;
    final nextRows = _keyboardVisible ? (_lastTerminalRows ?? rows) : rows;
    if (_lastTerminalCols == nextCols && _lastTerminalRows == nextRows) {
      return;
    }
    _lastTerminalCols = nextCols;
    _lastTerminalRows = nextRows;
    _sendTerminalEnvelope(
      RelayEnvelope(
        type: 'terminal.resize',
        sessionId: id,
        payload: {'cols': nextCols, 'rows': nextRows},
      ),
    );
  }

  void _flushPendingTerminalResize({bool force = false}) {
    final cols = _pendingTerminalCols;
    final rows = _pendingTerminalRows;
    final id = _sessionId;
    if (id == null || cols == null || rows == null || cols <= 0 || rows <= 0) {
      return;
    }
    final terminal = _currentTerminal();
    if (!_canResizeTerminal(terminal)) return;
    if (!force && _lastTerminalCols == cols && _lastTerminalRows == rows) {
      return;
    }
    _lastTerminalCols = cols;
    _lastTerminalRows = rows;
    _sendTerminalEnvelope(
      RelayEnvelope(
        type: 'terminal.resize',
        sessionId: id,
        payload: {'cols': cols, 'rows': rows},
      ),
    );
  }

  void _queueTerminalTyping(String data) {
    if (data.isEmpty) return;
    _terminalInputBatcher.add(data);
  }

  void _sendTerminalKey(String data) {
    if (data.isEmpty) return;
    _terminalInputBatcher.flush();
    _sendInputNow(data, source: 'key');
  }

  void _insertTerminalText(String text) {
    if (text.isEmpty) return;
    _terminalInputBatcher.flush();
    _sendInputNow(terminalPastePayload(text), source: 'insert');
  }

  void _sendInputNow(String data, {required String source}) {
    if (data.isEmpty) return;
    var id = _sessionId;
    if (id == null) {
      CoduxLog.debug(
        '[codux-flutter-input] no session, ensure terminal before input',
      );
      _ensureTerminalForSelectedProject();
      id = _sessionId;
    }
    if (id == null) {
      setState(() => _status = _t('terminal.creating'));
      return;
    }
    final inputId =
        '${DateTime.now().microsecondsSinceEpoch}-${++_terminalInputSeq}';
    CoduxLog.debug(
      '[codux-flutter-input] source=$source id=$inputId bytes=${data.codeUnits.length} session=$id',
    );
    _pendingTerminalInputs[inputId] = _PendingTerminalInput(
      inputId: inputId,
      sessionId: id,
      data: data,
      source: source,
    );
    _sendPendingTerminalInput(inputId);
  }

  void _sendPendingTerminalInput(String inputId) {
    final pending = _pendingTerminalInputs[inputId];
    if (pending == null || pending.sessionId != _sessionId) return;
    pending.retryTimer?.cancel();
    final sent = _sendTerminalEnvelope(
      RelayEnvelope(
        type: 'terminal.input',
        sessionId: pending.sessionId,
        payload: {
          'data': pending.data,
          'inputId': pending.inputId,
          'source': pending.source,
        },
      ),
    );
    if (!sent) {
      CoduxLog.warn('[codux-flutter-input] send failed id=$inputId');
    }
    pending.attempt += 1;
    if (pending.attempt > 3) {
      _pendingTerminalInputs.remove(inputId);
      CoduxLog.warn('[codux-flutter-input] ack exhausted id=$inputId');
      return;
    }
    pending.retryTimer = Timer(
      Duration(milliseconds: 700 * pending.attempt),
      () => _sendPendingTerminalInput(inputId),
    );
  }

  void _handleTerminalInputAck(RelayEnvelope message) {
    final payload = message.payload;
    if (payload is! Map) return;
    final inputId = payload['inputId']?.toString();
    if (inputId == null || inputId.isEmpty) return;
    final pending = _pendingTerminalInputs.remove(inputId);
    pending?.retryTimer?.cancel();
    if (CoduxLog.isDebugEnabled) {
      CoduxLog.debug(
        '[codux-flutter-input] ack id=$inputId ok=${payload['ok'] ?? true}',
      );
    }
  }

  void _clearPendingTerminalInputs({String? sessionId}) {
    final entries = _pendingTerminalInputs.entries.toList();
    for (final entry in entries) {
      if (sessionId != null && entry.value.sessionId != sessionId) continue;
      entry.value.retryTimer?.cancel();
      _pendingTerminalInputs.remove(entry.key);
    }
  }

  void _sendTerminalOutputAck(
    String sessionId,
    int outputSeq,
    int? bufferLength,
  ) {
    final payload = <String, Object>{'outputSeq': outputSeq};
    if (bufferLength != null) {
      payload['bufferLength'] = bufferLength;
    }
    _sendTerminalEnvelope(
      RelayEnvelope(
        type: 'terminal.output.ack',
        sessionId: sessionId,
        payload: payload,
      ),
    );
  }

  int? _intPayloadValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}');
  }

  List<String> _stringListPayload(Object? value) {
    if (value is! List) return const [];
    return value
        .map((item) => '$item'.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  List<RemoteWorktreeInfo> _worktreeListPayload(Map payload) {
    final baseBranchByWorktreeId = <String, String>{};
    final tasks = payload['tasks'];
    if (tasks is List) {
      for (final task in tasks.whereType<Map>()) {
        final worktreeId = task['worktreeId']?.toString() ?? '';
        final baseBranch = task['baseBranch']?.toString().trim() ?? '';
        if (worktreeId.isEmpty || baseBranch.isEmpty) continue;
        baseBranchByWorktreeId[worktreeId] = baseBranch;
      }
    }
    return (payload['worktrees'] as List<dynamic>? ?? []).whereType<Map>().map((
      item,
    ) {
      final worktree = RemoteWorktreeInfo.fromJson(
        Map<String, dynamic>.from(item),
      );
      return worktree.copyWith(baseBranch: baseBranchByWorktreeId[worktree.id]);
    }).toList();
  }

  void _createTerminal([String? projectId, String layoutKind = 'split']) {
    final target =
        projectId ??
        _selectedProjectId ??
        (_projects.isNotEmpty ? _projects.first.id : null);
    if (target == null) {
      setState(() => _status = _t('project.noAvailable'));
      return;
    }
    if (_creatingTerminalProjectId == target) return;
    _creatingTerminalProjectId = target;
    _clearTerminal();
    _send(
      RelayEnvelope(
        type: 'terminal.create',
        payload: {'projectId': target, 'command': '', 'layoutKind': layoutKind},
      ),
    );
  }

  bool _isAccessibleTerminal(TerminalInfo terminal) {
    return terminal.id.isNotEmpty && terminal.projectId.isNotEmpty;
  }

  TerminalInfo? _currentTerminal() {
    final id = _sessionId;
    if (id == null) return null;
    for (final terminal in _terminals) {
      if (terminal.id == id) return terminal;
    }
    return null;
  }

  bool _canResizeTerminal(TerminalInfo? terminal) {
    return terminal != null && _isAccessibleTerminal(terminal);
  }

  List<TerminalInfo> _currentProjectTerminals() {
    final projectId = _selectedProjectId;
    if (projectId == null) return const [];
    final terminals = _terminals
        .where(
          (item) => item.projectId == projectId && _isAccessibleTerminal(item),
        )
        .toList();
    terminals.sort(_compareTerminals);
    return terminals;
  }

  int _compareTerminals(TerminalInfo left, TerminalInfo right) {
    final createdAt = (left.createdAt ?? '').compareTo(right.createdAt ?? '');
    if (createdAt != 0) return createdAt;
    return left.id.compareTo(right.id);
  }

  TerminalInfo _preferredTerminalForProject(
    String projectId,
    Iterable<TerminalInfo> terminals,
  ) {
    final list = terminals.toList();
    final rememberedId = _lastTerminalIdByProject[projectId];
    if (rememberedId != null) {
      for (final terminal in list) {
        if (terminal.id == rememberedId) return terminal;
      }
    }
    for (final terminal in list) {
      if (_terminalOutputCache[terminal.id]?.isNotEmpty == true) {
        return terminal;
      }
    }
    return list.first;
  }

  void _selectTerminal(TerminalInfo terminal) {
    if (!_isAccessibleTerminal(terminal)) return;
    _terminalInputBatcher.flush();
    setState(() {
      _sessionId = terminal.id;
      _selectedProjectId = terminal.projectId;
      _lastTerminalIdByProject[terminal.projectId] = terminal.id;
      _workspaceMode = 'terminal';
      _terminalBufferRetry.reset();
      _terminalBufferLoading = false;
      _creatingTerminalProjectId = null;
      _terminalCursorBottom = 0;
    });
    final restored = _restoreTerminalSessionFromCache(terminal.id);
    if (!restored) _clearTerminal();
    _flushPendingTerminalResize(force: true);
    _requestBufferIfReady(force: true, full: !restored);
    _focusTerminalViewSoon();
    if (restored && _terminalBufferLoading && mounted) {
      setState(() => _terminalBufferLoading = false);
    }
  }

  void _createCurrentProjectTerminal() {
    final projectId = _selectedProjectId;
    if (projectId == null) {
      _showToast(_t('project.selectFirst'));
      return;
    }
    setState(() => _workspaceMode = 'terminal');
    _createTerminal(projectId);
  }

  void _createCurrentProjectTabTerminal() {
    final projectId = _selectedProjectId;
    if (projectId == null) {
      _showToast(_t('project.selectFirst'));
      return;
    }
    setState(() => _workspaceMode = 'terminal');
    _createTerminal(projectId, 'tab');
  }

  void _closeCurrentTerminal() {
    final terminal = _currentTerminal();
    if (terminal == null || !_isAccessibleTerminal(terminal)) return;
    _closeTerminal(terminal);
  }

  void _closeTerminal(TerminalInfo terminal) {
    if (!_isAccessibleTerminal(terminal)) return;
    final closingCurrent = _sessionId == terminal.id;
    if (closingCurrent) {
      _terminalInputBatcher.reset();
    }
    setState(() {
      _terminals = _terminals.where((item) => item.id != terminal.id).toList();
      _terminalOutputCache.remove(terminal.id);
      _terminalBufferLengths.remove(terminal.id);
      _terminalOutputSeqBySession.remove(terminal.id);
      _lastTerminalIdByProject.removeWhere(
        (_, terminalId) => terminalId == terminal.id,
      );
      if (closingCurrent) {
        _sessionId = null;
        _terminalBufferRetry.reset();
        _terminalBufferLoading = false;
        _terminalCursorBottom = 0;
      }
    });
    if (closingCurrent) {
      _clearTerminal();
    }
    _send(RelayEnvelope(type: 'terminal.close', sessionId: terminal.id));
  }

  Future<void> _openTerminalSwitcher() async {
    if (_showTerminalSwitcher) return;
    _requestWorktreeList(loading: _worktrees.isEmpty);
    await _pushCupertinoPage(() {
      _showTerminalSwitcher = true;
    });
  }

  void _closeTerminalSwitcher() {
    _popCupertinoPage(() {
      _showTerminalSwitcher = false;
    });
  }

  void _selectTerminalFromSwitcher(TerminalInfo terminal) {
    _selectTerminal(terminal);
    _closeTerminalSwitcher();
  }

  void _selectWorktree(RemoteWorktreeInfo worktree) {
    final project = _selectedProject;
    if (project == null) {
      _showToast(_t('project.selectFirst'));
      return;
    }
    setState(() => _worktreeListLoading = true);
    _send(
      RelayEnvelope(
        type: 'worktree.select',
        payload: {
          'projectId': project.id,
          'worktreeId': worktree.id,
          if (project.path != null) 'projectPath': project.path,
        },
      ),
    );
  }

  Future<void> _createWorktree() async {
    final project = _selectedProject;
    if (project == null || project.path == null || project.path!.isEmpty) {
      _showToast(_t('project.selectPathFirst'));
      return;
    }
    final branchOptions = _worktreeCreatorBranchOptions();
    final request = await showDialog<_WorktreeCreateDraft>(
      context: context,
      builder: (ctx) => _WorktreeCreateDialog(
        title: _t('worktree.new'),
        baseBranchLabel: _t('worktree.baseBranch'),
        nameLabel: _t('worktree.name'),
        cancelLabel: _t('app.cancel'),
        createLabel: _t('common.create'),
        branchOptions: branchOptions,
        initialBaseBranch: _worktreeCreatorDefaultBaseBranch(branchOptions),
        initialName: _defaultWorktreeName(),
      ),
    );
    if (request == null) return;
    if (request.baseBranch.isEmpty) {
      _showToast(_t('worktree.baseBranchRequired'));
      return;
    }
    if (request.name.isEmpty) {
      _showToast(_t('worktree.nameRequired'));
      return;
    }
    setState(() => _worktreeListLoading = true);
    _send(
      RelayEnvelope(
        type: 'worktree.create',
        payload: {
          'projectId': project.id,
          'projectPath': project.path,
          'baseBranch': request.baseBranch,
          'branchName': request.name,
          'taskTitle': request.name,
        },
      ),
    );
  }

  List<String> _worktreeCreatorBranchOptions() {
    final values = <String>[];
    void push(String? value) {
      final branch = value?.trim() ?? '';
      if (branch.isEmpty || values.contains(branch)) return;
      values.add(branch);
    }

    push(_defaultWorktreeBaseBranch);
    for (final branch in _worktreeBaseBranches) {
      push(branch);
    }
    for (final worktree in _worktrees) {
      push(worktree.branch);
    }
    return values;
  }

  String _worktreeCreatorDefaultBaseBranch(List<String> options) {
    final preferred = _defaultWorktreeBaseBranch?.trim() ?? '';
    if (preferred.isNotEmpty && options.contains(preferred)) {
      return preferred;
    }
    return options.isNotEmpty ? options.first : '';
  }

  Future<void> _mergeWorktree(RemoteWorktreeInfo worktree) async {
    final confirmed = await _confirmWorktreeAction(
      title: _t('worktree.merge'),
      message: _t(
        'worktree.mergeConfirm',
        params: {'name': _worktreeTitle(worktree)},
      ),
      destructive: false,
    );
    if (!confirmed) return;
    _sendWorktreeOperation('worktree.merge', worktree);
  }

  Future<void> _deleteWorktree(RemoteWorktreeInfo worktree) async {
    final confirmed = await _confirmWorktreeAction(
      title: _t('worktree.delete'),
      message: _t(
        'worktree.deleteConfirm',
        params: {'name': _worktreeTitle(worktree)},
      ),
      destructive: true,
    );
    if (!confirmed) return;
    _sendWorktreeOperation('worktree.delete', worktree);
  }

  void _sendWorktreeOperation(String type, RemoteWorktreeInfo worktree) {
    final project = _selectedProject;
    if (project == null || project.path == null || project.path!.isEmpty) {
      _showToast(_t('project.selectPathFirst'));
      return;
    }
    setState(() => _worktreeListLoading = true);
    _send(
      RelayEnvelope(
        type: type,
        payload: {
          'projectId': project.id,
          'projectPath': project.path,
          'worktreePath': worktree.path,
          'worktreeId': worktree.id,
          if (type == 'worktree.delete') 'removeBranch': true,
          if (type == 'worktree.merge') 'removeBranch': false,
        },
      ),
    );
  }

  Future<bool> _confirmWorktreeAction({
    required String title,
    required String message,
    required bool destructive,
  }) async {
    final accent = Theme.of(context).colorScheme.secondary;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.bgSurface,
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: _IconTextLabel(
                  icon: Icons.close_rounded,
                  label: _t('app.cancel'),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(
                  foregroundColor: destructive ? AppColors.danger : accent,
                ),
                child: _IconTextLabel(
                  icon: destructive
                      ? Icons.delete_outline_rounded
                      : Icons.call_merge_rounded,
                  label: title,
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  String _worktreeTitle(RemoteWorktreeInfo worktree) {
    if (worktree.name.isNotEmpty) return worktree.name;
    if (worktree.branch.isNotEmpty) return worktree.branch;
    return worktree.id;
  }

  Future<void> _refreshDeviceList() async {
    final device = _activeDevice;
    if (device == null) return;
    if (!_isConnected) {
      _connect(device);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      return;
    }
    _sendTransportPing();
    _sendHostInfoRequest();
    _requestProjectList(resetRetry: true);
    _requestTerminalList(resetRetry: true);
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  void _refreshLists() {
    _sendTransportPing();
    _requestProjectList(resetRetry: true);
    _requestTerminalList(resetRetry: true);
  }

  void _rebuildCurrentTerminal() {
    final projectId = _selectedProjectId;
    if (projectId == null) {
      _showToast(_t('project.selectFirst'));
      return;
    }
    String? closingSessionId;
    final current = _currentTerminal();
    final projectTerminals = _terminals
        .where(
          (terminal) =>
              terminal.projectId == projectId &&
              _isAccessibleTerminal(terminal),
        )
        .toList();
    if (current != null &&
        current.projectId == projectId &&
        _isAccessibleTerminal(current)) {
      closingSessionId = current.id;
    } else if (projectTerminals.isNotEmpty) {
      closingSessionId = projectTerminals.first.id;
    }
    final shouldCreateReplacement = projectTerminals.length > 1;
    _terminalInputBatcher.reset();
    setState(() {
      if (closingSessionId != null) {
        _terminals = _terminals
            .where((item) => item.id != closingSessionId)
            .toList();
        _terminalOutputCache.remove(closingSessionId);
        _terminalBufferLengths.remove(closingSessionId);
        _terminalOutputSeqBySession.remove(closingSessionId);
        _lastTerminalIdByProject.removeWhere(
          (_, terminalId) => terminalId == closingSessionId,
        );
      }
      _sessionId = null;
      _terminalBufferRetry.reset();
      _terminalBufferLoading = false;
      _creatingTerminalProjectId = null;
      _terminalCursorBottom = 0;
    });
    _clearTerminal();
    if (closingSessionId != null) {
      _send(RelayEnvelope(type: 'terminal.close', sessionId: closingSessionId));
    }
    if (shouldCreateReplacement) {
      _createTerminal(projectId);
    }
    _showToast(_t('terminal.rebuilding'));
  }

  void _ensureTerminalForSelectedProject() {
    if (!_showTerminal || _workspaceMode != 'terminal') return;
    final projectId = _selectedProjectId;
    if (projectId == null) return;
    if (!_terminalListLoaded) {
      _requestTerminalList();
      return;
    }
    if (_sessionId != null &&
        _terminals.any(
          (item) =>
              item.id == _sessionId &&
              item.projectId == projectId &&
              _isAccessibleTerminal(item),
        )) {
      return;
    }
    final existing = _terminals.where(
      (item) => item.projectId == projectId && _isAccessibleTerminal(item),
    );
    if (existing.isNotEmpty) {
      final terminal = _preferredTerminalForProject(projectId, existing);
      setState(() {
        _sessionId = terminal.id;
        _lastTerminalIdByProject[projectId] = terminal.id;
        _terminalBufferRetry.reset();
        _terminalBufferLoading = false;
        _creatingTerminalProjectId = null;
        _terminalCursorBottom = 0;
      });
      final restored = _restoreTerminalSessionFromCache(terminal.id);
      if (!restored) _clearTerminal();
      _flushPendingTerminalResize(force: true);
      _requestBufferIfReady(force: true, full: !restored);
      _terminalInputBatcher.flush();
      if (restored && _terminalBufferLoading && mounted) {
        setState(() => _terminalBufferLoading = false);
      }
      return;
    }
    _createTerminal(projectId);
  }

  void _requestProjectEdit() {
    final project = _selectedProject;
    if (project == null) {
      _showSnack(_t('project.selectFirst'));
      return;
    }
    setState(() {
      _projectFormMode = 'edit';
      _projectNameController.text = project.name;
      _projectPathController.text = project.path ?? '';
      _showProjectForm = true;
    });
  }

  void _requestProjectAdd() {
    setState(() {
      _projectFormMode = 'add';
      _projectNameController.clear();
      _projectPathController.clear();
      _showProjectForm = true;
    });
  }

  void _chooseProjectFormPath() {
    _filePickerMode = 'projectForm';
    final current = _projectPathController.text.trim();
    _openRemoteFilePicker(current.isEmpty ? null : current);
  }

  void _saveProjectForm() {
    final path = _projectPathController.text.trim();
    if (path.isEmpty) {
      _showToast(_t('project.selectPathFirst'));
      return;
    }
    final name = _projectNameController.text.trim().isEmpty
        ? _lastPathComponent(path)
        : _projectNameController.text.trim();
    if (_projectFormMode == 'edit') {
      final project = _selectedProject;
      if (project == null) return;
      _send(
        RelayEnvelope(
          type: 'project.edit',
          payload: {'projectId': project.id, 'path': path, 'name': name},
        ),
      );
    } else {
      _send(
        RelayEnvelope(
          type: 'project.add',
          payload: {'path': path, 'name': name},
        ),
      );
    }
    setState(() => _showProjectForm = false);
    _showToast(_t('project.saveSubmitted'));
  }

  void _openRemoteFilePicker([String? path]) {
    _filePickerTimeoutTimer?.cancel();
    setState(() {
      _showFilePicker = true;
      _filePickerLoading = true;
      _filePickerPath = path ?? _filePickerPath;
    });
    _filePickerTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || !_filePickerLoading) return;
      setState(() => _filePickerLoading = false);
      _showToast(_t('remote.dirTimeout'));
    });
    final payload = path == null
        ? <String, Object>{}
        : <String, Object>{'path': path};
    _send(RelayEnvelope(type: 'file.list', payload: payload));
  }

  void _selectRemoteProjectFolder(RemoteFileEntry entry) {
    if (_filePickerMode == 'projectForm') {
      setState(() {
        _projectPathController.text = entry.path;
        if (_projectNameController.text.trim().isEmpty) {
          _projectNameController.text = entry.name.isEmpty
              ? _lastPathComponent(entry.path)
              : entry.name;
        }
        _showFilePicker = false;
      });
      return;
    }
    setState(() => _showFilePicker = false);
  }

  String _lastPathComponent(String path) {
    final parts = path.split('/').where((item) => item.isNotEmpty).toList();
    return parts.isEmpty ? 'Project' : parts.last;
  }

  void _requestProjectRemove() {
    final project = _selectedProject;
    if (project == null) {
      _showSnack(_t('project.selectFirst'));
      return;
    }
    _send(
      RelayEnvelope(type: 'project.remove', payload: {'projectId': project.id}),
    );
    _showToast(_t('project.removeRequested'));
  }

  void _requestAIStats() {
    final project = _selectedProject;
    if (project == null) {
      _showToast(_t('project.selectFirst'));
      return;
    }
    setState(() {
      _workspaceMode = 'stats';
      _aiStatsLoading = true;
    });
    _send(RelayEnvelope(type: 'ai.stats', payload: {'projectId': project.id}));
  }

  void _syncTerminalToSelectedProject({bool requestListIfMissing = true}) {
    final projectId = _selectedProjectId;
    if (projectId == null) return;
    if (_sessionId != null) {
      final current = _terminals.any(
        (item) =>
            item.id == _sessionId &&
            item.projectId == projectId &&
            _isAccessibleTerminal(item),
      );
      if (current) return;
    }
    _terminalInputBatcher.reset();
    setState(() {
      _sessionId = null;
      _terminalBufferRetry.reset();
      _terminalBufferLoading = false;
    });
    if (requestListIfMissing) {
      _ensureTerminalForSelectedProject();
    }
  }

  void _showTerminalMode() {
    setState(() => _workspaceMode = 'terminal');
    _syncTerminalToSelectedProject();
    _requestBufferIfReady(force: true, full: true);
    _focusTerminalViewSoon();
  }

  void _showFilesMode() {
    final project = _selectedProject;
    if (project == null) {
      _showToast(_t('project.selectFirst'));
      return;
    }
    final rememberedPath = _projectFilePathMemory[project.id];
    final targetPath = rememberedPath?.isNotEmpty == true
        ? rememberedPath
        : (_projectFilesPath.isNotEmpty ? _projectFilesPath : project.path);
    setState(() {
      _workspaceMode = 'files';
    });
    _requestProjectFiles(targetPath);
  }

  void _requestProjectFiles([String? path]) {
    final project = _selectedProject;
    final target = path ?? project?.path;
    if (target == null || target.isEmpty) {
      _showToast(_t('project.currentNoDir'));
      return;
    }
    setState(() {
      _projectFilesLoading = true;
      _projectFilesPath = target;
      if (project != null) {
        _projectFilePathMemory[project.id] = target;
      }
    });
    _send(
      RelayEnvelope(
        type: 'file.list',
        payload: {'path': target, 'purpose': 'projectFiles'},
      ),
    );
  }

  String _parentPathOf(String path) {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return '/';
    return normalized.substring(0, index);
  }

  Future<void> _copyProjectFilePath(RemoteFileEntry entry) async {
    final message = AppPreferences.of(context).t('file.pathCopied');
    await Clipboard.setData(ClipboardData(text: entry.path));
    _showToast(message);
  }

  Future<void> _renameProjectFile(RemoteFileEntry entry) async {
    final prefs = AppPreferences.of(context);
    final controller = TextEditingController(text: entry.name);
    final nextName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(prefs.t('file.renameTitle')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: prefs.t('file.renameLabel')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(prefs.t('file.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(prefs.t('file.save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nextName == null || nextName.isEmpty || nextName == entry.name) return;
    if (nextName.contains('/')) {
      _showToast(prefs.t('file.nameInvalid'));
      return;
    }
    final parent = _parentPathOf(entry.path);
    final newPath = parent == '/' ? '/$nextName' : '$parent/$nextName';
    _send(
      RelayEnvelope(
        type: 'file.rename',
        payload: {'path': entry.path, 'newPath': newPath},
      ),
    );
  }

  Future<void> _deleteProjectFile(RemoteFileEntry entry) async {
    final prefs = AppPreferences.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(prefs.t('file.deleteTitle')),
        content: Text(
          prefs.t('file.deleteConfirm', params: {'name': entry.name}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(prefs.t('file.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(prefs.t('file.menuDelete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _send(RelayEnvelope(type: 'file.delete', payload: {'path': entry.path}));
  }

  void _openFileLocation(String path) {
    if (_showFilePicker) {
      _openRemoteFilePicker(path);
      return;
    }
    _requestProjectFiles(path);
  }

  void _requestFileRead(RemoteFileEntry entry) {
    if (entry.isDirectory) return;
    setState(() {
      _editingFilePath = entry.path;
      _fileEditorController.clear();
      _fileEditorController.highlightEnabled = true;
      _fileEditorLoading = true;
      _fileEditorEditing = false;
      _fileEditorEditable = true;
    });
    _send(RelayEnvelope(type: 'file.read', payload: {'path': entry.path}));
  }

  void _saveEditingFile() {
    final path = _editingFilePath;
    if (path == null || _fileEditorSaving || !_fileEditorEditing) return;
    setState(() => _fileEditorSaving = true);
    _send(
      RelayEnvelope(
        type: 'file.write',
        payload: {'path': path, 'content': _fileEditorController.text},
      ),
    );
  }

  void _focusTerminalSoon() {
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      _nativeTerminalController?.focusKeyboard();
    });
  }

  void _toggleTerminalKeyboard() {
    if (_keyboardVisible) {
      _nativeTerminalController?.hideKeyboard();
      return;
    }
    _focusTerminalSoon();
  }

  void _focusTerminalViewSoon() {
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      _nativeTerminalController?.requestResize();
    });
  }

  Future<void> _removeDevice(StoredDevice device) async {
    final next = _devices
        .where((item) => item.deviceId != device.deviceId)
        .toList();
    if (_activeDevice?.deviceId == device.deviceId) {
      _shouldReconnect = false;
      _irohReady = false;
      unawaited(_irohTransport.close());
      _clearLatencyProbe();
    }
    await _saveDevices(next);
    if (next.isEmpty) {
      setState(() => _showTerminal = false);
    }
  }

  void _openDeviceTerminal(StoredDevice device) {
    if (device.deviceId != _activeDevice?.deviceId || !_isConnected) return;
    final terminal = _currentTerminal();
    unawaited(
      _pushCupertinoPage(() {
        _showTerminal = true;
        _workspaceMode = 'terminal';
        _terminalBufferLoading = false;
        if (terminal != null) {
          _lastTerminalIdByProject[terminal.projectId] = terminal.id;
        }
      }),
    );
    _sendInitialTransportRequests(force: true);
    _requestBufferIfReady(force: true, full: true);
    _focusTerminalViewSoon();
  }

  Future<void> _editDevice(StoredDevice device) async {
    final accent = Theme.of(context).colorScheme.secondary;
    final nameController = TextEditingController(
      text: device.hostName?.isNotEmpty == true ? device.hostName : device.name,
    );
    final next = await showDialog<StoredDevice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(_t('device.editTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              cursorColor: accent,
              decoration: InputDecoration(
                labelText: _t('device.nameLabel'),
                labelStyle: const TextStyle(color: AppColors.textMuted),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: accent),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: accent),
            onPressed: () => Navigator.pop(ctx),
            child: Text(_t('app.cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: accent),
            onPressed: () {
              Navigator.pop(
                ctx,
                device.copyWith(
                  hostName: nameController.text.trim().isEmpty
                      ? device.hostName
                      : nameController.text.trim(),
                ),
              );
            },
            child: Text(_t('common.save')),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (next == null) return;
    final devices = _devices
        .map((item) => item.deviceId == next.deviceId ? next : item)
        .toList();
    await _saveDevices(devices);
    if (_activeDevice?.deviceId == next.deviceId) {
      _connect(next, true);
    }
  }

  void _onProjectSelected(ProjectInfo project) {
    final projectChanged = _selectedProjectId != project.id;
    final resetTerminal = projectChanged && _workspaceMode == 'terminal';
    if (resetTerminal) {
      _terminalInputBatcher.reset();
    }
    setState(() {
      _selectedProjectId = project.id;
      _currentAIStats = null;
      _projectFileEntries = [];
      _projectFilesPath = project.path ?? '';
      _projectFilesParent = null;
      if (projectChanged) {
        _projectFilePathMemory.remove(project.id);
        _worktrees = [];
        _worktreeBaseBranches = [];
        _defaultWorktreeBaseBranch = null;
        _selectedWorktreeId = null;
      }
      if (resetTerminal) {
        _sessionId = null;
        _terminalBufferRetry.reset();
        _terminalBufferLoading = false;
        _creatingTerminalProjectId = null;
        _terminalCursorBottom = 0;
      }
    });
    _send(
      RelayEnvelope(type: 'project.select', payload: {'projectId': project.id}),
    );
    _requestWorktreeList(loading: _showTerminalSwitcher);
    if (_workspaceMode == 'stats') {
      _requestAIStats();
      return;
    }
    if (_workspaceMode == 'files') {
      _requestProjectFiles(project.path);
      return;
    }
    if (resetTerminal) {
      _ensureTerminalForSelectedProject();
      return;
    }
    final current = _terminals.any(
      (item) =>
          item.id == _sessionId &&
          item.projectId == project.id &&
          _isAccessibleTerminal(item),
    );
    if (!current) {
      _ensureTerminalForSelectedProject();
    }
  }

  Future<void> _pasteToTerminal() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text?.isNotEmpty == true) {
      _insertTerminalText(data!.text!);
    }
  }

  Future<void> _copyTerminalSelection() async {
    final prefs = AppPreferences.of(context);
    final copied = await _nativeTerminalController?.copySelection() ?? false;
    _showSnack(
      copied ? prefs.t('toolbar.copyDone') : prefs.t('toolbar.copyEmpty'),
    );
  }

  Future<void> _startVoiceInput() async {
    if (_showVoiceOverlay) return;
    setState(() => _showVoiceOverlay = true);
  }

  Future<void> _chooseUploadForTerminal() async {
    if (_terminalUploadLoading) return;
    if (!_canUploadOverCurrentPath) {
      _showSnack(_t('upload.directRequired'));
      setState(() => _status = _t('upload.directRequired'));
      return;
    }
    final prefs = AppPreferences.of(context);
    final source = await showModalBottomSheet<_TerminalUploadSource>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      barrierColor: AppColors.backdrop,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.attach_file_rounded),
                  title: Text(prefs.t('upload.chooseFile')),
                  onTap: () =>
                      Navigator.of(context).pop(_TerminalUploadSource.file),
                ),
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: Text(prefs.t('upload.chooseImage')),
                  onTap: () =>
                      Navigator.of(context).pop(_TerminalUploadSource.image),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (source == null || !mounted) return;
    await _uploadPickedFileToTerminal(source);
  }

  String _uploadKindForSource(_TerminalUploadSource source) =>
      source == _TerminalUploadSource.image ? 'image' : 'file';

  String _uploadingTextForSource(_TerminalUploadSource source) =>
      source == _TerminalUploadSource.image
      ? _t('upload.imageUploading')
      : _t('upload.fileUploading');

  String _insertingTextForSource(_TerminalUploadSource source) =>
      source == _TerminalUploadSource.image
      ? _t('upload.imageInserting')
      : _t('upload.fileInserting');

  Future<void> _uploadPickedFileToTerminal(_TerminalUploadSource source) async {
    if (_terminalUploadLoading) return;
    if (!_canUploadOverCurrentPath) {
      _showSnack(_t('upload.directRequired'));
      setState(() => _status = _t('upload.directRequired'));
      return;
    }
    final id = _sessionId;
    if (id == null) {
      setState(() => _status = _t('terminal.createOrSelectFirst'));
      return;
    }
    final result = await FilePicker.pickFiles(
      type: source == _TerminalUploadSource.image
          ? FileType.image
          : FileType.any,
      allowMultiple: false,
      withData: true,
    );
    final files = result?.files;
    final picked = files == null || files.isEmpty ? null : files.single;
    if (picked == null) return;
    if (picked.size > 20 * 1024 * 1024) {
      _showSnack(_t('upload.fileTooLarge'));
      return;
    }
    final bytes =
        picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null) {
      _showSnack(_t('upload.fileReadFailed'));
      return;
    }
    if (bytes.isEmpty) return;
    if (!_canUploadOverCurrentPath) {
      _showSnack(_t('upload.directRequired'));
      setState(() => _status = _t('upload.directRequired'));
      return;
    }
    _terminalUploadCompletion?.completeError(
      StateError('Terminal upload superseded'),
    );
    final uploadCompletion = Completer<void>();
    _terminalUploadCompletion = uploadCompletion;
    final uploadingMessage = _uploadingTextForSource(source);
    setState(() {
      _terminalUploadLoading = true;
      _terminalUploadStatus = uploadingMessage;
      _status = _terminalUploadStatus;
    });
    try {
      await _terminalUploadSender.uploadFile(
        sessionId: id,
        name: picked.name,
        mime: _mimeForUpload(
          picked.name,
          image: source == _TerminalUploadSource.image,
        ),
        bytes: bytes,
        kind: _uploadKindForSource(source),
        onProgress: (progress) {
          if (!mounted) return;
          final message = '$uploadingMessage ${progress.percent}%';
          setState(() {
            _terminalUploadStatus = message;
            _status = message;
          });
        },
      );
      if (!mounted) return;
      final insertingMessage = _insertingTextForSource(source);
      setState(() {
        _terminalUploadStatus = insertingMessage;
        _status = insertingMessage;
      });
      await uploadCompletion.future.timeout(const Duration(seconds: 30));
    } catch (error) {
      CoduxLog.warn('[codux-flutter-upload] upload failed: $error');
      if (!mounted) return;
      if (_terminalUploadCompletion == uploadCompletion) {
        _terminalUploadCompletion = null;
      }
      setState(() {
        _terminalUploadLoading = false;
        _terminalUploadStatus = '';
        _status = '${_t('remote.error')}: $error';
      });
    }
  }

  bool get _canUploadOverCurrentPath => _irohConnectionPath == 'direct';

  String _mimeForUpload(String name, {required bool image}) {
    final parts = name.split('.');
    final extension = parts.length > 1 ? parts.last.toLowerCase() : '';
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'pdf' => 'application/pdf',
      'json' => 'application/json',
      'txt' || 'log' || 'md' => 'text/plain',
      'csv' => 'text/csv',
      'html' || 'htm' => 'text/html',
      'zip' => 'application/zip',
      _ => image ? 'image/*' : 'application/octet-stream',
    };
  }

  Future<void> _checkUpdate() async {
    setState(() {
      _status = _t('update.checking');
      _blockingLoadingMessage = _t('update.loading');
    });
    try {
      final info = await PackageInfo.fromPlatform();
      final update = Platform.isIOS
          ? await _fetchAppStoreUpdate(info)
          : await _fetchGithubUpdate(info);
      if (update == null) return;
      if (!mounted) return;
      final accent = Theme.of(context).colorScheme.secondary;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgSurface,
          title: Text(
            _t('update.foundTitle', params: {'version': update.version}),
          ),
          content: Text(
            _t(
              Platform.isIOS ? 'update.foundBodyAppStore' : 'update.foundBody',
              params: {'version': info.version},
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: accent),
              onPressed: () => Navigator.pop(ctx),
              child: Text(_t('common.later')),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: accent),
              onPressed: () {
                Navigator.pop(ctx);
                if (update.url.isNotEmpty) _openUrl(update.url);
              },
              child: Text(
                Platform.isIOS
                    ? _t('common.openAppStore')
                    : _t('common.openGithub'),
              ),
            ),
          ],
        ),
      );
    } catch (error) {
      _showToast(_t('update.failed', params: {'reason': '$error'}));
    } finally {
      if (mounted) setState(() => _blockingLoadingMessage = null);
    }
  }

  Future<_AvailableUpdate?> _fetchGithubUpdate(PackageInfo info) async {
    final uri = Uri.parse(
      'https://api.github.com/repos/duxweb/codux-flutter/releases/latest',
    );
    final response = await http
        .get(
          uri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 404) {
      _showToast(_t('update.noRelease'));
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _showToast(
        _t('update.httpFailed', params: {'status': '${response.statusCode}'}),
      );
      return null;
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = '${json['tag_name'] ?? ''}'.trim();
    final url = '${json['html_url'] ?? ''}'.trim();
    if (tag.isEmpty) {
      _showToast(_t('update.noVersion'));
      return null;
    }
    final hasUpdate = _compareVersion(tag, info.version) > 0;
    if (!hasUpdate) {
      _showToast(_t('update.latest', params: {'version': info.version}));
      return null;
    }
    return _AvailableUpdate(version: tag, url: url);
  }

  Future<_AvailableUpdate?> _fetchAppStoreUpdate(PackageInfo info) async {
    final uri = Uri.https('itunes.apple.com', '/lookup', {
      'bundleId': info.packageName,
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _showToast(
        _t('update.httpFailed', params: {'status': '${response.statusCode}'}),
      );
      return null;
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final results = json['results'] as List<dynamic>? ?? const [];
    if (results.isEmpty) {
      _showToast(_t('update.appStorePending'));
      return null;
    }
    final first = results.first as Map<String, dynamic>;
    final version = '${first['version'] ?? ''}'.trim();
    final url = '${first['trackViewUrl'] ?? ''}'.trim();
    if (version.isEmpty) {
      _showToast(_t('update.noVersion'));
      return null;
    }
    final hasUpdate = _compareVersion(version, info.version) > 0;
    if (!hasUpdate) {
      _showToast(_t('update.latest', params: {'version': info.version}));
      return null;
    }
    return _AvailableUpdate(version: version, url: url);
  }

  int _compareVersion(String left, String right) {
    List<int> parse(String value) => value
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .take(3)
        .map(int.parse)
        .toList();
    final a = parse(left);
    final b = parse(right);
    for (var index = 0; index < 3; index += 1) {
      final av = index < a.length ? a[index] : 0;
      final bv = index < b.length ? b[index] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  Future<void> _showAboutDialogNow() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    final accent = Theme.of(context).colorScheme.secondary;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(_t('app.about')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('app.aboutText')),
            const SizedBox(height: AppSpacing.m),
            Text(
              'v${info.version}+${info.buildNumber}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 14),
            ),
            const SizedBox(height: AppSpacing.s),
            SelectableText(
              'github.com/duxweb/codux-flutter',
              style: TextStyle(color: accent, fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: accent),
            onPressed: () =>
                _openUrl('https://github.com/duxweb/codux-flutter'),
            child: const Text('GitHub'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: accent),
            onPressed: () => Navigator.pop(ctx),
            child: Text(_t('app.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String value) async {
    final uri = Uri.parse(value);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri);
    }
  }

  void _showSnack(String message) => _showToast(message);

  void _showToast(String message) {
    if (!mounted) return;
    _toastTimer?.cancel();
    setState(() => _toastMessage = message);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toastMessage = null);
    });
  }

  void _confirmRemoveDevice(StoredDevice device) {
    final accent = Theme.of(context).colorScheme.secondary;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(_t('app.removeDevice')),
        content: Text(
          _t(
            'app.removeDeviceConfirm',
            params: {'name': device.hostName ?? device.name},
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: accent),
            onPressed: () => Navigator.pop(ctx),
            child: Text(_t('app.cancel')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _removeDevice(device);
            },
            child: Text(
              _t('app.remove'),
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _handleBackNavigation() {
    if (_editingFilePath != null) {
      setState(() {
        _editingFilePath = null;
        _fileEditorLoading = false;
        _fileEditorSaving = false;
        _fileEditorEditing = false;
      });
      return;
    }
    if (_showScanner) {
      setState(() => _showScanner = false);
      return;
    }
    if (_showFilePicker) {
      _filePickerTimeoutTimer?.cancel();
      setState(() => _showFilePicker = false);
      return;
    }
    if (_showProjectForm) {
      setState(() => _showProjectForm = false);
      return;
    }
    if (_showSettings) {
      _popCupertinoPage(() {
        _showSettings = false;
      });
      return;
    }
    if (_showTerminalSwitcher) {
      _popCupertinoPage(() {
        _showTerminalSwitcher = false;
      });
      return;
    }
    if (_pendingPairing != null) {
      _cancelPairing();
      return;
    }
    if (_showTerminal) {
      _popCupertinoPage(() {
        _showTerminal = false;
        _workspaceMode = 'terminal';
      });
      return;
    }
    _disconnectTransport(status: _t('app.disconnected'), closeTerminal: true);
    SystemNavigator.pop();
  }

  void _handleWorkspaceEdgeDragStart(DragStartDetails details) {
    if (!Platform.isIOS ||
        (!_showTerminal && !_showSettings && !_showTerminalSwitcher)) {
      return;
    }
    final edgeWidth = MediaQuery.viewPaddingOf(context).left + 24.0;
    final startX = details.localPosition.dx;
    if (startX > edgeWidth) {
      _edgeBackDragStartX = null;
      return;
    }
    _edgeBackDragStartX = startX;
    _edgeBackDragDeltaX = 0;
    _edgeBackDragDeltaY = 0;
    _edgeBackController.stop();
  }

  void _handleWorkspaceEdgeDragUpdate(DragUpdateDetails details) {
    if (_edgeBackDragStartX == null) return;
    _edgeBackDragDeltaX += details.delta.dx;
    _edgeBackDragDeltaY += details.delta.dy;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    _edgeBackController.value = (_edgeBackDragDeltaX / width).clamp(0.0, 1.0);
  }

  void _handleWorkspaceEdgeDragEnd(DragEndDetails details) {
    if (_edgeBackDragStartX == null) return;
    final dragX = _edgeBackDragDeltaX;
    final dragY = _edgeBackDragDeltaY.abs();
    final velocityX = details.velocity.pixelsPerSecond.dx;
    _edgeBackDragStartX = null;
    _edgeBackDragDeltaX = 0;
    _edgeBackDragDeltaY = 0;
    final width = MediaQuery.sizeOf(context).width;
    final progress = width <= 0 ? 0.0 : (dragX / width).clamp(0.0, 1.0);
    final shouldComplete =
        dragX > 72 &&
        dragX > dragY * 1.4 &&
        (velocityX > 260 || progress > 0.34);
    if (shouldComplete) {
      unawaited(_completeCupertinoPageBack());
    } else {
      unawaited(
        _edgeBackController.animateBack(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  Future<void> _completeCupertinoPageBack() async {
    await _edgeBackController.animateTo(
      1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(() {
      if (_showSettings) {
        _showSettings = false;
      } else if (_showTerminalSwitcher) {
        _showTerminalSwitcher = false;
      } else {
        _showTerminal = false;
      }
      _workspaceMode = 'terminal';
    });
    _edgeBackController.value = 0;
  }

  Future<void> _pushCupertinoPage(VoidCallback updateState) async {
    _edgeBackController.value = 1;
    setState(updateState);
    await _edgeBackController.animateBack(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _popCupertinoPage(VoidCallback updateState) async {
    if (!Platform.isIOS) {
      setState(updateState);
      return;
    }
    await _edgeBackController.animateTo(
      1,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(updateState);
    _edgeBackController.value = 0;
  }

  void _cancelWorkspaceEdgeBack() {
    _edgeBackDragStartX = null;
    _edgeBackDragDeltaX = 0;
    _edgeBackDragDeltaY = 0;
    unawaited(
      _edgeBackController.animateBack(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.viewPadding.top;
    final bottomInset = media.viewPadding.bottom;
    _keyboardVisible = media.viewInsets.bottom > bottomInset + 8.0;

    final prefs = AppPreferences.of(context);
    final deviceHome = DeviceHomeScreen(
      devices: _devices,
      activeDeviceId: _activeDevice?.deviceId,
      ready: _isDeviceListConnected,
      status: _deviceListStatusText,
      latencyMs: _isDeviceListConnected ? _latencyMs : null,
      topInset: topInset,
      bottomInset: bottomInset,
      onOpen: _openDeviceTerminal,
      onConnect: (device) => _connect(device),
      onAdd: () => setState(() => _showScanner = true),
      onEdit: _editDevice,
      onDelete: _confirmRemoveDevice,
      onRefresh: _refreshDeviceList,
      onSettings: () => _pushCupertinoPage(() {
        _showSettings = true;
      }),
      onCheckUpdate: _checkUpdate,
      onAbout: _showAboutDialogNow,
    );
    final settingsPage = SettingsScreen(
      nameController: _settingsNameController,
      detectedName: _detectedDeviceName,
      topInset: topInset,
      bottomInset: bottomInset,
      currentAccent: prefs.accent,
      currentLocale: prefs.locale,
      onChangeAccent: (next) {
        widget.onChangeAccent(next);
        setState(() => _settings = _settings.copyWith(accentId: next.id));
      },
      onChangeLocale: (next) {
        widget.onChangeLocale(next);
        setState(() => _settings = _settings.copyWith(localeId: next.id));
      },
      onUseDetectedName: () =>
          setState(() => _settingsNameController.text = _detectedDeviceName),
      onSave: _saveSettings,
      onBack: () => _popCupertinoPage(() {
        _showSettings = false;
      }),
    );
    final switcherPage = TerminalSwitcherScreen(
      topInset: topInset,
      bottomInset: bottomInset,
      terminals: _currentProjectTerminals(),
      worktrees: _worktrees,
      activeTerminalId: _sessionId,
      selectedWorktreeId: _selectedWorktreeId,
      loadingWorktrees: _worktreeListLoading,
      onBack: _closeTerminalSwitcher,
      onSelectTerminal: _selectTerminalFromSwitcher,
      onCreateSplit: _createCurrentProjectTerminal,
      onCreateTab: _createCurrentProjectTabTerminal,
      onCloseTerminal: _closeTerminal,
      onSelectWorktree: _selectWorktree,
      onCreateWorktree: _createWorktree,
      onMergeWorktree: _mergeWorktree,
      onDeleteWorktree: _deleteWorktree,
      onRefreshWorktrees: () => _requestWorktreeList(loading: true),
    );
    Widget body;
    if (_showSettings) {
      body = _buildCupertinoBackPage(base: deviceHome, page: settingsPage);
    } else if (_showTerminalSwitcher) {
      body = _buildCupertinoBackPage(
        base: _buildWorkspace(topInset, bottomInset),
        page: switcherPage,
      );
    } else if (!_showTerminal) {
      body = deviceHome;
    } else {
      body = _buildCupertinoBackPage(
        base: deviceHome,
        page: _buildWorkspace(topInset, bottomInset),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBackNavigation();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            body,
            if (Platform.isIOS &&
                (_showTerminal || _showSettings || _showTerminalSwitcher))
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: media.viewPadding.left + 36,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: _handleWorkspaceEdgeDragStart,
                  onHorizontalDragUpdate: _handleWorkspaceEdgeDragUpdate,
                  onHorizontalDragEnd: _handleWorkspaceEdgeDragEnd,
                  onHorizontalDragCancel: _cancelWorkspaceEdgeBack,
                ),
              ),
            if (_showScanner)
              ScannerScreen(
                bottomInset: bottomInset,
                onDetected: _handleScannedPayload,
                onClose: () => setState(() => _showScanner = false),
              ),
            if (_pendingPairing != null)
              PairingOverlay(
                payload: _pendingPairing!,
                waiting: _pairingInFlight,
                errorMessage: _pairingError,
                onCancel: _cancelPairing,
                onConfirm: _confirmPairing,
              ),
            if (_showProjectForm)
              ProjectFormOverlay(
                topInset: topInset,
                bottomInset: bottomInset,
                title: _projectFormMode == 'edit'
                    ? _t('project.edit')
                    : _t('project.add'),
                nameController: _projectNameController,
                pathController: _projectPathController,
                onClose: () => setState(() => _showProjectForm = false),
                onChoosePath: _chooseProjectFormPath,
                onSave: _saveProjectForm,
              ),
            if (_showFilePicker)
              RemoteFilePicker(
                topInset: topInset,
                bottomInset: bottomInset,
                title: _filePickerMode == 'edit'
                    ? _t('project.pathLabel')
                    : _t('project.pathLabel'),
                path: _filePickerPath,
                parent: _filePickerParent,
                entries: _filePickerEntries,
                loading: _filePickerLoading,
                onClose: () {
                  _filePickerTimeoutTimer?.cancel();
                  setState(() => _showFilePicker = false);
                },
                onOpenPath: _openRemoteFilePicker,
                onSelect: _selectRemoteProjectFolder,
                onOpenHome: () => _openRemoteFilePicker(),
                onOpenRoot: () => _openRemoteFilePicker('/'),
                onOpenVolumes: () => _openRemoteFilePicker('/Volumes'),
              ),
            if (_showVoiceOverlay)
              VoiceInputOverlay(
                topInset: topInset,
                bottomInset: bottomInset,
                service: _voiceService,
                onClose: () => setState(() => _showVoiceOverlay = false),
                onSend: (text) {
                  _insertTerminalText(text);
                  setState(() => _showVoiceOverlay = false);
                },
              ),
            if (_editingFilePath != null)
              FileEditorOverlay(
                path: _editingFilePath!,
                controller: _fileEditorController,
                loading: _fileEditorLoading,
                saving: _fileEditorSaving,
                editing: _fileEditorEditing,
                editable: _fileEditorEditable,
                onClose: () => setState(() => _editingFilePath = null),
                onEdit: () => setState(() => _fileEditorEditing = true),
                onSave: _saveEditingFile,
              ),
            if (_blockingLoadingMessage != null)
              BlockingLoading(message: _blockingLoadingMessage!),
            if (_toastMessage != null)
              AppToast(message: _toastMessage!, bottomInset: bottomInset),
          ],
        ),
      ),
    );
  }

  Widget _buildCupertinoBackPage({required Widget base, required Widget page}) {
    return AnimatedBuilder(
      animation: _edgeBackController,
      builder: (context, child) {
        return Stack(
          children: [
            base,
            cupertino.CupertinoPageTransition(
              primaryRouteAnimation: ReverseAnimation(_edgeBackController),
              secondaryRouteAnimation: const AlwaysStoppedAnimation<double>(0),
              linearTransition: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 16,
                      offset: const Offset(-8, 0),
                    ),
                  ],
                ),
                child: page,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildWorkspace(double topInset, double bottomInset) {
    final showTerminalToolbar = _workspaceMode == 'terminal' && _isConnected;
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardActiveThreshold = bottomInset + 8.0;
    final effectiveKeyboardHeight = keyboardHeight > keyboardActiveThreshold
        ? keyboardHeight
        : 0.0;
    final toolbarBottom = effectiveKeyboardHeight > 0
        ? effectiveKeyboardHeight
        : bottomInset;
    final keyboardOverlap = (toolbarBottom - bottomInset).clamp(
      0.0,
      double.infinity,
    );
    final toolbarSafeInset = toolbarBottom.clamp(0.0, bottomInset);
    const terminalBackground = AppColors.bgBase;
    final terminalPadding = Platform.isIOS
        ? const EdgeInsets.fromLTRB(0, 0, 0, 0)
        : const EdgeInsets.fromLTRB(8, 6, 8, 6);

    Widget terminalBody = MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const toolbarBaseHeight = 76.0;
            final terminalToolbarHeight = toolbarBaseHeight + toolbarSafeInset;
            final viewportHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : MediaQuery.sizeOf(context).height;
            final terminalHeight =
                (viewportHeight -
                        (showTerminalToolbar ? terminalToolbarHeight : 0.0))
                    .clamp(120.0, viewportHeight);
            final terminalViewHeight =
                (terminalHeight - terminalPadding.vertical).clamp(
                  0.0,
                  terminalHeight,
                );
            final visibleTerminalBottom = (terminalViewHeight - keyboardOverlap)
                .clamp(0.0, terminalViewHeight);
            final terminalShift =
                showTerminalToolbar &&
                    effectiveKeyboardHeight > 0 &&
                    _terminalCursorBottom > visibleTerminalBottom
                ? (_terminalCursorBottom - visibleTerminalBottom).clamp(
                    0.0,
                    keyboardOverlap,
                  )
                : 0.0;

            final showHostSyncOverlay =
                _isConnected &&
                ((!_projectListLoaded && _projects.isEmpty) ||
                    (!_terminalListLoaded && _terminals.isEmpty));
            final showUploadOverlay =
                _hasShownTerminal &&
                _workspaceMode == 'terminal' &&
                _terminalUploadLoading &&
                _terminalUploadStatus.isNotEmpty;
            final showHistoryOverlay =
                _hasShownTerminal &&
                _workspaceMode == 'terminal' &&
                !_terminalUploadLoading &&
                _terminalBufferLoading &&
                _sessionId != null &&
                _terminalBufferRetry.pendingSessionId == _sessionId;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: terminalHeight,
                  child: Transform.translate(
                    offset: Offset(0, -terminalShift),
                    child: ColoredBox(
                      color: terminalBackground,
                      child: Padding(
                        padding: terminalPadding,
                        child: Stack(
                          children: [
                            if (_hasShownTerminal)
                              CoduxNativeTerminalView(
                                scrollEnabled: !_keyboardVisible,
                                onControllerCreated: (controller) {
                                  _nativeTerminalController = controller;
                                  controller.setLogLevel(
                                    CoduxLog.nativeLevelName,
                                  );
                                  final restored =
                                      _restoreNativeTerminalController(
                                        controller,
                                      );
                                  if (restored && _terminalBufferLoading) {
                                    setState(
                                      () => _terminalBufferLoading = false,
                                    );
                                  }
                                  _terminalReady = false;
                                  _terminalBufferRetry.resetLastBuffered();
                                  controller.requestResize();
                                },
                                onInput: _queueTerminalTyping,
                                onTerminalResponse: (data) {
                                  CoduxLog.debug(
                                    '[codux-flutter-response] local bytes=${data.codeUnits.length}',
                                  );
                                },
                                onResize: (cols, rows) {
                                  final firstResize = !_terminalReady;
                                  _terminalReady = true;
                                  _sendTerminalResize(cols, rows);
                                  if (firstResize) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (!mounted) return;
                                          _requestBufferIfReady(
                                            force: true,
                                            full: true,
                                          );
                                        });
                                  }
                                },
                                onMetrics: (metrics) {
                                  final cursorBottom =
                                      metrics.cursorBottomPx /
                                      MediaQuery.devicePixelRatioOf(context);
                                  if (_terminalCursorBottom == cursorBottom) {
                                    return;
                                  }
                                  setState(() {
                                    _terminalCursorBottom = cursorBottom;
                                  });
                                },
                              )
                            else
                              ConnectHint(
                                status: _status.isEmpty
                                    ? AppPreferences.of(
                                        context,
                                      ).t('app.notConnected')
                                    : _status,
                                hasDevice: _activeDevice != null,
                                onConnect: () => _connect(),
                              ),
                            if (_hasShownTerminal &&
                                showHostSyncOverlay &&
                                !_terminalUploadLoading &&
                                !_terminalBufferLoading)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: AppColors.bgBase.withValues(
                                        alpha: 0.58,
                                      ),
                                    ),
                                    child: Center(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.secondary,
                                            ),
                                          ),
                                          const SizedBox(width: AppSpacing.s),
                                          Text(
                                            _connectionStatusText,
                                            style: const TextStyle(
                                              color: AppColors.textSecondary,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_hasShownTerminal &&
                                _workspaceMode == 'terminal' &&
                                (showUploadOverlay || showHistoryOverlay))
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: AppColors.bgBase.withValues(
                                        alpha: 0.72,
                                      ),
                                    ),
                                    child: Center(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.secondary,
                                            ),
                                          ),
                                          const SizedBox(width: AppSpacing.s),
                                          Text(
                                            showUploadOverlay
                                                ? _terminalUploadStatus
                                                : _t('terminal.loadingHistory'),
                                            style: const TextStyle(
                                              color: AppColors.textSecondary,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            FadeTransition(
                              opacity: _maskOpacity,
                              child: const TerminalTransitionMask(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (showTerminalToolbar)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: toolbarBottom,
                    child: Toolbar(
                      onSendKey: _sendTerminalKey,
                      keyboardVisible: _keyboardVisible,
                      bottomInset: 0,
                      onToggleKeyboard: _toggleTerminalKeyboard,
                      uploading: _terminalUploadLoading,
                      onPaste: _pasteToTerminal,
                      onCopy: _copyTerminalSelection,
                      onUpload: _chooseUploadForTerminal,
                      onVoiceInput: _startVoiceInput,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );

    return Column(
      children: [
        TerminalHeader(
          topInset: topInset,
          latencyMs: _isConnected ? _latencyMs : null,
          connected: _isConnected,
          activeMode: _workspaceMode,
          onTerminal: _showTerminalMode,
          onStats: _requestAIStats,
          onFiles: _showFilesMode,
          onBack: () => setState(() {
            _showTerminal = false;
            _workspaceMode = 'terminal';
          }),
          onEditProject: _requestProjectEdit,
          onAddProject: _requestProjectAdd,
          onRemoveProject: _requestProjectRemove,
        ),
        ProjectTabBar(
          projects: _projects,
          selectedId: _selectedProjectId,
          loading: _isConnected && !_projectListLoaded,
          terminals: _currentProjectTerminals(),
          activeTerminalId: _sessionId,
          onSelect: _onProjectSelected,
          onSelectTerminal: _selectTerminal,
          onRefresh: _refreshLists,
          onCreateTerminal: _createCurrentProjectTerminal,
          onCloseTerminal: _currentTerminal() != null
              ? _closeCurrentTerminal
              : null,
          onRebuild: _rebuildCurrentTerminal,
          onOpenSwitcher: _openTerminalSwitcher,
        ),
        Expanded(
          child: _workspaceMode == 'stats'
              ? AIStatsPanel(
                  stats: _currentAIStats,
                  loading: _aiStatsLoading,
                  onRefresh: _requestAIStats,
                )
              : _workspaceMode == 'files'
              ? ProjectFilesPanel(
                  path: _projectFilesPath,
                  parent: _projectFilesParent,
                  entries: _projectFileEntries,
                  loading: _projectFilesLoading,
                  onOpenPath: _requestProjectFiles,
                  onOpenFile: _requestFileRead,
                  onRefresh: () => _requestProjectFiles(_projectFilesPath),
                  onOpenHome: () =>
                      _openFileLocation(_selectedProject?.path ?? ''),
                  onOpenRoot: () => _openFileLocation('/'),
                  onOpenVolumes: () => _openFileLocation('/Volumes'),
                  onRename: _renameProjectFile,
                  onCopyPath: _copyProjectFilePath,
                  onDelete: _deleteProjectFile,
                )
              : terminalBody,
        ),
      ],
    );
  }
}

class _PendingTerminalInput {
  _PendingTerminalInput({
    required this.inputId,
    required this.sessionId,
    required this.data,
    required this.source,
  });

  final String inputId;
  final String sessionId;
  final String data;
  final String source;
  int attempt = 0;
  Timer? retryTimer;
}

class _WorktreeCreateDraft {
  const _WorktreeCreateDraft({required this.baseBranch, required this.name});

  final String baseBranch;
  final String name;
}

class _WorktreeCreateDialog extends StatefulWidget {
  const _WorktreeCreateDialog({
    required this.title,
    required this.baseBranchLabel,
    required this.nameLabel,
    required this.cancelLabel,
    required this.createLabel,
    required this.branchOptions,
    required this.initialBaseBranch,
    required this.initialName,
  });

  final String title;
  final String baseBranchLabel;
  final String nameLabel;
  final String cancelLabel;
  final String createLabel;
  final List<String> branchOptions;
  final String initialBaseBranch;
  final String initialName;

  @override
  State<_WorktreeCreateDialog> createState() => _WorktreeCreateDialogState();
}

class _WorktreeCreateDialogState extends State<_WorktreeCreateDialog> {
  late final TextEditingController _nameController;
  late String _baseBranch;

  @override
  void initState() {
    super.initState();
    _baseBranch = widget.initialBaseBranch;
    _nameController = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return AlertDialog(
      backgroundColor: AppColors.bgSurface,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: widget.branchOptions.contains(_baseBranch)
                ? _baseBranch
                : null,
            items: [
              for (final branch in widget.branchOptions)
                DropdownMenuItem(value: branch, child: Text(branch)),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _baseBranch = value);
            },
            decoration: InputDecoration(labelText: widget.baseBranchLabel),
          ),
          const SizedBox(height: AppSpacing.m),
          TextField(
            controller: _nameController,
            autofocus: true,
            decoration: InputDecoration(labelText: widget.nameLabel),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
          onPressed: () => Navigator.pop(context),
          child: _IconTextLabel(
            icon: Icons.close_rounded,
            label: widget.cancelLabel,
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: accent),
          onPressed: () {
            Navigator.pop(
              context,
              _WorktreeCreateDraft(
                baseBranch: _baseBranch.trim(),
                name: _nameController.text.trim(),
              ),
            );
          },
          child: _IconTextLabel(
            icon: Icons.add_rounded,
            label: widget.createLabel,
          ),
        ),
      ],
    );
  }
}

String _defaultWorktreeName() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

class _IconTextLabel extends StatelessWidget {
  const _IconTextLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 17), const SizedBox(width: 6), Text(label)],
    );
  }
}

class _AvailableUpdate {
  const _AvailableUpdate({required this.version, required this.url});

  final String version;
  final String url;
}
