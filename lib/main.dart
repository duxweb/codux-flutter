import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:codux_native_terminal/codux_native_terminal.dart';
import 'i18n.dart';
import 'models/remote_models.dart';
import 'screens/scanner_screen.dart';
import 'screens/settings_screen.dart';
import 'services/e2e_crypto.dart';
import 'services/log_service.dart';
import 'services/local_voice_recognition_service.dart';
import 'services/relay_service.dart';
import 'services/p2p_health_monitor.dart';
import 'services/p2p_terminal_transport.dart';
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
import 'widgets/terminal_transition_mask.dart';
import 'widgets/toolbar.dart';

typedef RelaySocketFactory = dynamic Function(StoredDevice device);

const String _remoteProtocolVersion = 'v1.0';

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
  const CoduxFlutterApp({
    super.key,
    this.relaySocketFactory,
    this.initialDevices,
  });

  final RelaySocketFactory? relaySocketFactory;
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
          relaySocketFactory: widget.relaySocketFactory,
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
    this.relaySocketFactory,
    this.initialDevices,
  });

  final ValueChanged<AccentOption> onChangeAccent;
  final ValueChanged<LocaleOption> onChangeLocale;
  final RelaySocketFactory? relaySocketFactory;
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
  late final TerminalBufferRetryCoordinator _terminalBufferRetry;
  late final TerminalInputBatcher _terminalInputBatcher;
  late final TerminalUploadSender _terminalUploadSender;
  late final P2PTerminalTransport _p2pTransport;
  late final P2PHealthMonitor _p2pHealth;
  late final LocalVoiceRecognitionService _voiceService;
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
  StoredDevice? _activeDevice;
  MobileSettings _settings = const MobileSettings(localName: '');
  String _detectedDeviceName = 'Codux Mobile';
  String _status = '';
  String? _selectedProjectId;
  String? _sessionId;
  String? _creatingTerminalProjectId;
  bool _showSettings = false;
  bool _showScanner = false;
  PairingPayload? _pendingPairing;
  bool _pairingInFlight = false;
  bool _pairingCancelled = false;
  String? _pairingError;
  bool _showTerminal = false;
  bool _terminalReady = false;
  bool _terminalBufferLoading = false;
  bool _terminalUploadLoading = false;
  String _terminalUploadStatus = '';
  bool _terminalListLoaded = false;
  bool _projectListLoaded = false;
  bool _backgroundConnect = false;
  bool _shouldReconnect = true;
  bool _relayReady = false;
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
  bool _fileEditorLoading = false;
  bool _fileEditorSaving = false;
  bool _fileEditorEditing = false;
  bool _fileEditorEditable = true;
  int _reconnectAttempt = 0;
  bool _appInForeground = true;

  WebSocketSinkLike? _socket;
  int _socketGeneration = 0;
  int _sendSeq = 0;
  int _receiveSeq = 0;
  Future<void> _sendChain = Future<void>.value();
  Future<void> _receiveChain = Future<void>.value();
  StreamSubscription? _socketSubscription;
  Timer? _reconnectTimer;
  Timer? _healthTimer;
  Timer? _toastTimer;
  Timer? _filePickerTimeoutTimer;
  Timer? _projectListRetryTimer;
  Timer? _terminalListRetryTimer;
  Timer? _hostResponseTimer;
  Timer? _latencyProbeTimer;
  int _projectListRetryAttempt = 0;
  int _terminalListRetryAttempt = 0;
  String _lastTransportState = 'relay';
  DateTime? _lastConnectedAt;
  DateTime? _connectionGraceUntil;
  DateTime? _hostInfoProbeSentAt;
  int? _latencyMs;
  Timer? _connectionGraceTimer;

  bool get _isConnected => _socket != null && _relayReady;
  bool get _isP2PHealthy => _p2pTransport.isOpen && _p2pHealth.stable;
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

  bool get _isDeviceListConnected => _isHostReady || _isRecoveringConnection;

  String _t(String key, {Map<String, String>? params}) =>
      AppPreferences.of(context).t(key, params: params);

  String get _connectionStatusText {
    if (!_isConnected) {
      if (_isRecoveringConnection) return _lastTransportStatusText;
      return _status.isEmpty ? _t('app.notConnected') : _status;
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
    if (_isP2PHealthy) {
      return _t('transport.p2p');
    }
    return _t('transport.relay');
  }

  String get _lastTransportStatusText {
    if (_lastTransportState == 'p2p') {
      return _t('transport.p2p');
    }
    return _t('transport.relay');
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
      '[codux-flutter-ws] grace reason=$reason until=${_connectionGraceUntil!.toIso8601String()} transport=$_lastTransportState lastConnectedAt=${_lastConnectedAt?.toIso8601String() ?? 'null'}',
    );
    _connectionGraceTimer = Timer(duration, () {
      if (!mounted || _disposing) return;
      if (_connectionGraceUntil == null) return;
      if (DateTime.now().isBefore(_connectionGraceUntil!)) return;
      setState(() {
        _connectionGraceUntil = null;
      });
      CoduxLog.info('[codux-flutter-ws] grace expired reason=$reason');
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
    final socket = _socket;
    if (!_relayReady || socket == null || device == null) return;
    _cancelHostResponseProbe();
    CoduxLog.info(
      '[codux-flutter-ws] host probe start reason=$reason timeoutMs=${duration.inMilliseconds}',
    );
    _hostResponseTimer = Timer(duration, () {
      if (!mounted || _disposing || !_appInForeground) return;
      if (_socket != socket || !_relayReady || _hostResponsive) return;
      _failHostConnection(device, socket, 'host_response_timeout:$reason');
    });
  }

  bool _isCompatibleRemoteProtocol(Object? payload) {
    if (payload is! Map) return false;
    return payload['protocolVersion'] == _remoteProtocolVersion;
  }

  void _markRemoteProtocolReady({bool force = false}) {
    if (_remoteProtocolReady && !force) return;
    _remoteProtocolReady = true;
    _sendInitialRelayRequests(force: force);
  }

  void _failRemoteProtocol(
    StoredDevice target,
    WebSocketSinkLike socket,
    Object? payload,
  ) {
    if (_socket != socket) return;
    final version = payload is Map ? '${payload['protocolVersion'] ?? ''}' : '';
    CoduxLog.warn(
      '[codux-flutter-ws] incompatible protocol expected=$_remoteProtocolVersion received=$version host=${target.hostId} device=${target.deviceId}',
    );
    _shouldReconnect = false;
    final shouldPrompt = _protocolBlockedHostIds.add(target.hostId);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cancelHostResponseProbe();
    _clearConnectionGrace();
    _clearLatencyProbe();
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket = null;
    socket.close();
    unawaited(_p2pTransport.close());
    _terminalInputBatcher.reset();
    _clearPendingTerminalInputs();
    final message = _t('connection.upgradeRequired');
    setState(() {
      _relayReady = false;
      _remoteProtocolReady = false;
      _hostResponsive = false;
      _backgroundConnect = false;
      _showTerminal = false;
      _workspaceMode = 'terminal';
      _projects = [];
      _projectListLoaded = false;
      _terminals = [];
      _terminalListLoaded = false;
      _projectListRetryTimer?.cancel();
      _terminalListRetryTimer?.cancel();
      _projectListRetryAttempt = 0;
      _terminalListRetryAttempt = 0;
      _selectedProjectId = null;
      _sessionId = null;
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
    _markTransportConnected(
      transport ?? (_p2pTransport.isOpen ? 'p2p' : 'relay'),
    );
    if (!wasResponsive) {
      CoduxLog.info('[codux-flutter-ws] host responsive source=$source');
    }
  }

  void _clearLatencyProbe() {
    _latencyProbeTimer?.cancel();
    _latencyProbeTimer = null;
    _hostInfoProbeSentAt = null;
    _latencyMs = null;
  }

  void _recordHostInfoLatency() {
    final sentAt = _hostInfoProbeSentAt;
    if (sentAt == null) return;
    final nextLatency = DateTime.now().difference(sentAt).inMilliseconds;
    _hostInfoProbeSentAt = null;
    if (_isP2PHealthy) return;
    if (nextLatency <= 0 || nextLatency > 60000) return;
    if (_latencyMs == nextLatency) return;
    setState(() => _latencyMs = nextLatency);
  }

  void _sendHostInfoProbe() {
    if (!_relayReady || _socket == null) return;
    _hostInfoProbeSentAt = DateTime.now();
    _send(const RelayEnvelope(type: 'host.info'));
  }

  void _startLatencyProbe() {
    if (_latencyProbeTimer != null) return;
    _latencyProbeTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _sendHostInfoProbe(),
    );
  }

  void _failHostConnection(
    StoredDevice target,
    WebSocketSinkLike socket,
    String reason,
  ) {
    if (_socket != socket) return;
    CoduxLog.warn(
      '[codux-flutter-ws] host unavailable reason=$reason host=${target.hostId} device=${target.deviceId}',
    );
    _cancelHostResponseProbe();
    _clearConnectionGrace();
    _lastConnectedAt = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    _clearLatencyProbe();
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket = null;
    socket.close();
    unawaited(_p2pTransport.close());
    _terminalInputBatcher.reset();
    _clearPendingTerminalInputs();
    setState(() {
      _relayReady = false;
      _remoteProtocolReady = false;
      _hostResponsive = false;
      _backgroundConnect = false;
      _status = _t('connection.failedRetry');
      _terminalBufferRetry.reset();
      _terminalBufferLoading = false;
    });
    if (_appSuspended || !_appInForeground) {
      CoduxLog.info(
        '[codux-flutter-ws] reconnect deferred reason=$reason appSuspended=$_appSuspended',
      );
      return;
    }
    _scheduleReconnect(target);
  }

  void _recoverForegroundState() {
    if (!_relayReady) {
      final device = _activeDevice;
      if (device != null) _connect(device, true);
      return;
    }
    _backgroundConnect = false;
    setState(() => _hostResponsive = false);
    _requestProjectList(resetRetry: true);
    _requestTerminalList(resetRetry: true);
    _send(const RelayEnvelope(type: 'host.info'));
    _ensureP2PStarted();
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
    _p2pTransport = P2PTerminalTransport(
      sendSignal: _send,
      onEnvelope: _handleP2PEnvelope,
      onState: (state) {
        CoduxLog.info('[codux-flutter-p2p] state=$state');
        if (!mounted || _disposing) return;
        setState(() {
          if (state == 'connected') {
            _hostResponsive = true;
          } else if ((state == 'failed' || state == 'disconnected') &&
              _relayReady) {
            _lastTransportState = 'relay';
          }
        });
        if (state == 'connected') {
          _p2pHealth.start();
          _flushPendingTerminalResize(force: true);
          _requestBufferIfReady();
          _terminalInputBatcher.flush();
        } else {
          _p2pHealth.reset(notify: true);
        }
        if (state == 'failed') {
          unawaited(_p2pTransport.close());
          if (_relayReady) {
            Timer(const Duration(seconds: 2), () {
              if (!mounted || _disposing || !_relayReady) return;
              _ensureP2PStarted();
            });
          }
        }
      },
    );
    _p2pTransport.setPreferDomesticStun(
      _preferDomesticStunForLocale(_settings.localeId),
    );
    _p2pHealth = P2PHealthMonitor(
      isOpen: () => _p2pTransport.isOpen,
      sendPing: (id) => _p2pTransport.sendEnvelope(
        RelayEnvelope(type: 'p2p.ping', payload: {'id': id}),
      ),
      onStableChanged: (_) {
        if (!mounted || _disposing) return;
        setState(() {});
      },
    );
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
    _p2pHealth.dispose();
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
    unawaited(_p2pTransport.close());
    _socketSubscription?.cancel();
    _socket?.close();
    _nativeTerminalController?.dispose();
    _settingsNameController.dispose();
    _fileEditorController.dispose();
    _projectNameController.dispose();
    _projectPathController.dispose();
    _maskController.dispose();
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
      if (_socket != null) {
        CoduxLog.info(
          '[codux-flutter-lifecycle] resume keep existing socket host=${device.hostId} device=${device.deviceId}',
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
    _p2pTransport.setPreferDomesticStun(
      _preferDomesticStunForLocale(next.localeId),
    );
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
          _activeDevice?.server != device.server ||
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
      await claimPairing(payload, name);
      if (_pairingCancelled) throw const PairingCancelledException();
      setState(() => _status = _t('pair.waiting'));
      final confirmed = await waitPairingConfirmed(
        payload,
        name,
        isCancelled: () => _pairingCancelled,
      );
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

  Future<void> _saveSettings() async {
    final next = _settings.copyWith(
      localName: _settingsNameController.text.trim().isEmpty
          ? _detectedDeviceName
          : _settingsNameController.text.trim(),
    );
    await _storage.saveSettings(next);
    setState(() {
      _settings = next;
      _showSettings = false;
      _status = _t('settings.saved');
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
    final generation = ++_socketGeneration;
    CoduxLog.info(
      '[codux-flutter-ws] connect start gen=$generation background=$background host=${target.hostId} device=${target.deviceId}',
    );
    _cancelHostResponseProbe();
    _reconnectTimer?.cancel();
    _healthTimer?.cancel();
    _clearLatencyProbe();
    _socketSubscription?.cancel();
    _socket?.close();
    _sendSeq = DateTime.now().microsecondsSinceEpoch;
    _receiveSeq = 0;
    _sendChain = Future<void>.value();
    _receiveChain = Future<void>.value();
    RemoteE2ECrypto.clearCache();
    unawaited(_p2pTransport.close());
    if (background && _lastConnectedAt != null) {
      _startConnectionGrace(reason: 'background_connect');
    }
    if (!background) _clearTerminal();
    if (!background) _terminalInputBatcher.reset();
    setState(() {
      _relayReady = false;
      _remoteProtocolReady = false;
      _hostResponsive = false;
      if (!background) {
        _status = _t('app.connecting');
        _projects = [];
        _projectListLoaded = false;
        _terminals = [];
        _terminalListLoaded = false;
        _projectListRetryTimer?.cancel();
        _terminalListRetryTimer?.cancel();
        _projectListRetryAttempt = 0;
        _terminalListRetryAttempt = 0;
        _selectedProjectId = null;
        _sessionId = null;
        _terminalBufferRetry.reset();
        _terminalBufferLoading = false;
      }
      _activeDevice = target;
    });
    unawaited(_restoreCachedProjects(target));
    try {
      final channel = (widget.relaySocketFactory ?? createRelaySocket)(target);
      final socket = _WebSocketSink(channel);
      _socket = socket;
      _socketSubscription = channel.stream.listen(
        (event) => _handleSocketMessage(event, target, socket),
        onDone: () => _handleSocketClosed(target, socket, 'stream_done'),
        onError: (error) {
          if (_socket != socket) return;
          CoduxLog.warn(
            '[codux-flutter-ws] stream error gen=$generation error=$error',
          );
          if (!_backgroundConnect) {
            setState(() => _status = _t('app.connectError'));
          }
          _handleSocketClosed(target, socket, 'stream_error');
        },
      );
      channel.ready.catchError((error) {
        if (_socket != socket) return null;
        CoduxLog.warn(
          '[codux-flutter-ws] ready failed gen=$generation error=$error',
        );
        if (!_backgroundConnect && mounted) {
          setState(() => _status = _t('connection.failedRetry'));
        }
        _handleSocketClosed(target, socket, 'ready_failed');
        return null;
      });
      _healthTimer = Timer(const Duration(seconds: 6), () {
        if (_socket == socket && !_relayReady) {
          CoduxLog.warn('[codux-flutter-ws] hello timeout gen=$generation');
          _handleSocketClosed(target, socket, 'hello_timeout');
          socket.close();
        }
      });
    } catch (error) {
      CoduxLog.warn(
        '[codux-flutter-ws] connect failed gen=$generation error=$error',
      );
      if (!background) {
        setState(
          () => _status = _t(
            'connection.failedWithReason',
            params: {'reason': '$error'},
          ),
        );
      }
      _scheduleReconnect(target);
    }
  }

  void _handleSocketClosed(
    StoredDevice target,
    WebSocketSinkLike closedSocket,
    String reason,
  ) {
    if (_socket != closedSocket) return;
    CoduxLog.info(
      '[codux-flutter-ws] closed reason=$reason host=${target.hostId} device=${target.deviceId} transport=$_lastTransportState lastConnectedAt=${_lastConnectedAt?.toIso8601String() ?? 'null'}',
    );
    _healthTimer?.cancel();
    _healthTimer = null;
    _cancelHostResponseProbe();
    _socketSubscription?.cancel();
    _socketSubscription = null;
    if (_socket != null) {
      _socket = null;
      unawaited(_p2pTransport.close());
      setState(() {
        _relayReady = false;
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
      if (_appSuspended || !_appInForeground) {
        CoduxLog.info(
          '[codux-flutter-ws] reconnect deferred reason=$reason appSuspended=$_appSuspended',
        );
        return;
      }
      _scheduleReconnect(target);
    }
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
      '[codux-flutter-ws] reconnect scheduled host=${target.hostId} device=${target.deviceId} attempt=$_reconnectAttempt delayMs=${delay.inMilliseconds}',
    );
    _reconnectTimer = Timer(delay, () => _connect(target, true));
  }

  void _sendInitialRelayRequests({bool force = false}) {
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
    if (!_relayReady || _projectListLoaded) return;
    _projectListRetryTimer?.cancel();
    if (_projectListRetryAttempt >= 6) return;
    final delay = Duration(
      milliseconds: (800 * (1 << _projectListRetryAttempt)).clamp(800, 5000),
    );
    _projectListRetryTimer = Timer(delay, () {
      if (!mounted || !_relayReady || _projectListLoaded) return;
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

  void _scheduleTerminalListRetry() {
    if (!_relayReady || _terminalListLoaded) return;
    _terminalListRetryTimer?.cancel();
    if (_terminalListRetryAttempt >= 6) return;
    final delay = Duration(
      milliseconds: (800 * (1 << _terminalListRetryAttempt)).clamp(800, 5000),
    );
    _terminalListRetryTimer = Timer(delay, () {
      if (!mounted || !_relayReady || _terminalListLoaded) return;
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

  bool _send(RelayEnvelope message, [WebSocketSinkLike? target]) {
    final sink = target ?? _socket;
    if (sink == null) {
      setState(() => _status = _t('app.wsNotConnected'));
      CoduxLog.warn(
        '[codux-flutter-relay] drop type=${message.type} reason=no_socket',
      );
      return false;
    }
    if (CoduxLog.isDebugEnabled && message.type.startsWith('terminal.')) {
      CoduxLog.debug(
        '[codux-flutter-relay] send type=${message.type} session=${message.sessionId ?? ''} payload=${message.payload ?? ''}',
      );
    }
    final activeDevice = _activeDevice;
    final seq = activeDevice == null ? null : ++_sendSeq;
    final previous = _sendChain.catchError((_) {});
    final task = previous
        .then((_) async {
          if (target == null && _socket != sink) return;
          if (activeDevice == null) {
            sink.add(encodeEnvelope(message));
            return;
          }
          final encrypted = await RemoteE2ECrypto.encryptEnvelope(
            inner: message,
            device: activeDevice,
            seq: seq!,
          );
          if (target == null && _socket != sink) return;
          sink.add(encodeEnvelope(encrypted));
        })
        .catchError((Object error) {
          CoduxLog.error('[codux-flutter-e2e] encrypt failed: $error');
          if (mounted) setState(() => _status = _t('pair.repairRequired'));
        });
    _sendChain = task;
    return true;
  }

  bool _sendTerminalEnvelope(RelayEnvelope message) {
    if (_p2pTransport.isOpen) {
      final sent = _p2pTransport.sendEnvelope(message);
      if (sent) {
        CoduxLog.debug(
          '[codux-flutter-terminal] p2p send type=${message.type} session=${message.sessionId ?? ''}',
        );
        return true;
      }
    }
    _ensureP2PStarted();
    CoduxLog.debug(
      '[codux-flutter-terminal] fallback relay type=${message.type} reason=p2p-not-open',
    );
    return _send(message);
  }

  Future<bool> _sendTerminalEnvelopeReliable(
    RelayEnvelope message, {
    Duration p2pOpenTimeout = const Duration(milliseconds: 1500),
  }) async {
    if (_p2pTransport.isOpen) {
      final sent = await _p2pTransport.sendEnvelopeWithBackpressure(message);
      if (sent) {
        CoduxLog.debug(
          '[codux-flutter-terminal] p2p send type=${message.type} session=${message.sessionId ?? ''}',
        );
        return true;
      }
      CoduxLog.debug(
        '[codux-flutter-terminal] fallback relay type=${message.type} reason=p2p-send-failed',
      );
    } else {
      _ensureP2PStarted();
      if (await _p2pTransport.waitUntilOpen(timeout: p2pOpenTimeout)) {
        final sent = await _p2pTransport.sendEnvelopeWithBackpressure(message);
        if (sent) {
          CoduxLog.debug(
            '[codux-flutter-terminal] p2p send type=${message.type} session=${message.sessionId ?? ''}',
          );
          return true;
        }
      }
      CoduxLog.debug(
        '[codux-flutter-terminal] fallback relay type=${message.type} reason=p2p-not-open',
      );
    }
    return _send(message);
  }

  Future<bool> _sendTerminalUploadEnvelopeReliable(
    RelayEnvelope message,
  ) async {
    if (!_isP2PHealthy || !_p2pTransport.isUploadOpen) {
      _ensureP2PStarted();
      CoduxLog.debug(
        '[codux-flutter-upload] block type=${message.type} reason=upload-channel-not-ready',
      );
      return false;
    }
    final sent = await _p2pTransport.sendEnvelopeWithBackpressure(message);
    if (sent) {
      CoduxLog.debug(
        '[codux-flutter-upload] p2p send type=${message.type} session=${message.sessionId ?? ''}',
      );
      return true;
    }
    CoduxLog.debug(
      '[codux-flutter-upload] block type=${message.type} reason=p2p-send-failed',
    );
    return false;
  }

  void _ensureP2PStarted() {
    if (!_relayReady || _socket == null) return;
    unawaited(_p2pTransport.ensureStarted());
  }

  void _handleSocketMessage(
    Object event,
    StoredDevice target,
    WebSocketSinkLike sourceSocket,
  ) {
    if (_socket != sourceSocket) return;
    final previous = _receiveChain.catchError((_) {});
    final task = previous
        .then((_) {
          if (_socket != sourceSocket) return Future<void>.value();
          return _handleSocketMessageAsync(event, target);
        })
        .catchError((Object error) {
          CoduxLog.error('[codux-flutter-e2e] receive queue failed: $error');
        });
    _receiveChain = task;
  }

  Future<void> _handleSocketMessageAsync(
    Object event,
    StoredDevice target,
  ) async {
    try {
      var message = RelayEnvelope.fromJson(
        jsonDecode('$event') as Map<String, dynamic>,
      );
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
      switch (message.type) {
        case 'hello':
          if (!_relayReady) {
            _reconnectAttempt = 0;
            CoduxLog.info('[codux-flutter-ws] hello received');
            setState(() {
              _relayReady = true;
              _hasShownTerminal = true;
              if (!_backgroundConnect) _status = _t('app.connected');
            });
            _markTransportConnected('relay');
            _sendHostInfoProbe();
            _startHostResponseProbe(reason: 'hello');
          }
        case 'host.offline':
          final payload = message.payload;
          final messageText = payload is Map
              ? '${payload['message'] ?? _t('connection.macDisconnected')}'
              : _t('connection.macDisconnected');
          _terminalInputBatcher.reset();
          _clearPendingTerminalInputs();
          unawaited(_p2pTransport.close());
          _clearLatencyProbe();
          setState(() {
            _relayReady = false;
            _remoteProtocolReady = false;
            _hostResponsive = false;
            _showTerminal = false;
            _workspaceMode = 'terminal';
            _projects = [];
            _projectListLoaded = false;
            _terminals = [];
            _terminalListLoaded = false;
            _projectListRetryTimer?.cancel();
            _terminalListRetryTimer?.cancel();
            _projectListRetryAttempt = 0;
            _terminalListRetryAttempt = 0;
            _selectedProjectId = null;
            _sessionId = null;
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
          _recordHostInfoLatency();
          if (!_isCompatibleRemoteProtocol(message.payload)) {
            final socket = _socket;
            if (socket != null) {
              _failRemoteProtocol(target, socket, message.payload);
            }
            return;
          }
          _markHostResponsive('host.info', transport: 'relay');
          final payload = message.payload;
          if (payload is Map && payload['name'] != null) {
            _updateDevice(target.deviceId, hostName: '${payload['name']}');
          }
          _markRemoteProtocolReady(
            force: !_projectListLoaded || !_terminalListLoaded,
          );
          _startLatencyProbe();
        case 'p2p.answer':
          final payload = message.payload;
          if (payload is Map) {
            unawaited(_p2pTransport.handleAnswer(payload));
          }
        case 'p2p.candidate':
          final payload = message.payload;
          if (payload is Map) {
            unawaited(_p2pTransport.handleCandidate(payload));
          }
        case 'p2p.state':
          final payload = message.payload;
          if (payload is Map) {
            _p2pTransport.handleState(payload);
          }
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
            _ensureP2PStarted();
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

  void _handleP2PEnvelope(RelayEnvelope message) {
    switch (message.type) {
      case 'terminal.output':
        _handleTerminalOutput(message);
      case 'terminal.uploaded':
        _handleTerminalUploaded(message);
      case 'terminal.upload.ack':
        _terminalUploadSender.handleAck(message);
      case 'terminal.input.ack':
        _handleTerminalInputAck(message);
      case 'p2p.pong':
        _handleP2PPong(message);
      case 'error':
        final payload = message.payload;
        setState(() {
          _terminalBufferLoading = false;
          _status =
              message.error ??
              (payload is Map
                  ? '${payload['message'] ?? _t('remote.error')}'
                  : _t('remote.error'));
        });
      default:
        CoduxLog.debug('[codux-flutter-p2p] ignore type=${message.type}');
    }
  }

  void _handleP2PPong(RelayEnvelope message) {
    final payload = message.payload;
    if (payload is! Map) return;
    final id = payload['id']?.toString();
    final rtt = _p2pHealth.handlePong(id);
    if (rtt == null) return;
    _markHostResponsive('p2p.pong', transport: 'p2p');
    if (!mounted) return;
    setState(() {
      if (rtt > 0 && rtt < 60000) _latencyMs = rtt;
    });
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
    _ensureP2PStarted();
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
            p2pOpenTimeout: const Duration(milliseconds: 700),
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

  void _createTerminal([String? projectId]) {
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
        payload: {'projectId': target, 'command': ''},
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
    _ensureP2PStarted();
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

  void _closeCurrentTerminal() {
    final terminal = _currentTerminal();
    if (terminal == null || !_isAccessibleTerminal(terminal)) return;
    _terminalInputBatcher.reset();
    setState(() {
      _terminals = _terminals.where((item) => item.id != terminal.id).toList();
      _terminalOutputCache.remove(terminal.id);
      _terminalBufferLengths.remove(terminal.id);
      _terminalOutputSeqBySession.remove(terminal.id);
      _lastTerminalIdByProject.removeWhere(
        (_, terminalId) => terminalId == terminal.id,
      );
      if (_sessionId == terminal.id) {
        _sessionId = null;
        _terminalBufferRetry.reset();
        _terminalBufferLoading = false;
        _terminalCursorBottom = 0;
      }
    });
    _clearTerminal();
    _send(RelayEnvelope(type: 'terminal.close', sessionId: terminal.id));
  }

  void _refreshLists() {
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
      _ensureP2PStarted();
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
      _ensureP2PStarted();
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
    _ensureP2PStarted();
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
      _socket?.close();
      _socket = null;
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
    setState(() {
      _showTerminal = true;
      _workspaceMode = 'terminal';
      _terminalBufferLoading = false;
      if (terminal != null) {
        _lastTerminalIdByProject[terminal.projectId] = terminal.id;
      }
    });
    _sendInitialRelayRequests(force: true);
    _requestBufferIfReady(force: true, full: true);
    _focusTerminalViewSoon();
  }

  Future<void> _editDevice(StoredDevice device) async {
    final accent = Theme.of(context).colorScheme.secondary;
    final nameController = TextEditingController(
      text: device.hostName?.isNotEmpty == true ? device.hostName : device.name,
    );
    final serverController = TextEditingController(text: device.server);
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
            const SizedBox(height: AppSpacing.m),
            TextField(
              controller: serverController,
              cursorColor: accent,
              decoration: InputDecoration(
                labelText: _t('device.serverLabel'),
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
                  server: serverController.text.trim().isEmpty
                      ? device.server
                      : serverController.text.trim(),
                ),
              );
            },
            child: Text(_t('common.save')),
          ),
        ],
      ),
    );
    nameController.dispose();
    serverController.dispose();
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
    if (!_isP2PHealthy || !_p2pTransport.isUploadOpen) {
      _ensureP2PStarted();
      _showSnack(_t('upload.p2pRequired'));
      setState(() => _status = _t('upload.p2pRequired'));
      return;
    }
    final source = await showModalBottomSheet<_TerminalUploadSource>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      barrierColor: AppColors.backdrop,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (context) {
        final prefs = AppPreferences.of(context);
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
      setState(() => _showSettings = false);
      return;
    }
    if (_pendingPairing != null) {
      _cancelPairing();
      return;
    }
    if (_showTerminal) {
      setState(() {
        _showTerminal = false;
        _workspaceMode = 'terminal';
      });
      return;
    }
    _showToast(_t('device.alreadyInList'));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.viewPadding.top;
    final bottomInset = media.viewPadding.bottom;
    _keyboardVisible = media.viewInsets.bottom > bottomInset + 8.0;

    final prefs = AppPreferences.of(context);
    Widget body;
    if (_showSettings) {
      body = SettingsScreen(
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
          _p2pTransport.setPreferDomesticStun(
            _preferDomesticStunForLocale(next.id),
          );
          setState(() => _settings = _settings.copyWith(localeId: next.id));
        },
        onUseDetectedName: () =>
            setState(() => _settingsNameController.text = _detectedDeviceName),
        onSave: _saveSettings,
        onBack: () => setState(() => _showSettings = false),
      );
    } else if (!_showTerminal) {
      body = DeviceHomeScreen(
        devices: _devices,
        activeDeviceId: _activeDevice?.deviceId,
        connected: _isDeviceListConnected,
        status: _connectionStatusText,
        latencyMs: _isDeviceListConnected ? _latencyMs : null,
        topInset: topInset,
        bottomInset: bottomInset,
        onOpen: _openDeviceTerminal,
        onConnect: (device) => _connect(device),
        onAdd: () => setState(() => _showScanner = true),
        onEdit: _editDevice,
        onDelete: _confirmRemoveDevice,
        onSettings: () => setState(() => _showSettings = true),
        onCheckUpdate: _checkUpdate,
        onAbout: _showAboutDialogNow,
      );
    } else {
      body = _buildWorkspace(topInset, bottomInset);
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

  bool _preferDomesticStunForLocale(String localeId) {
    final option = LocaleChoices.byId(localeId);
    if (option.id == 'simplifiedChinese' || option.id == 'traditionalChinese') {
      return true;
    }
    if (option.id != 'system') return false;
    return ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase() ==
        'zh';
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

abstract class WebSocketSinkLike {
  void add(String data);
  void close();
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

class _AvailableUpdate {
  const _AvailableUpdate({required this.version, required this.url});

  final String version;
  final String url;
}

class _WebSocketSink implements WebSocketSinkLike {
  _WebSocketSink(this.channel);
  final dynamic channel;
  @override
  void add(String data) => channel.sink.add(data);
  @override
  void close() => channel.sink.close();
}
