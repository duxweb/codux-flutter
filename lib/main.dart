import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:codux_native_terminal/codux_native_terminal.dart';
import 'i18n.dart';
import 'models/remote_models.dart';
import 'screens/scanner_screen.dart';
import 'screens/settings_screen.dart';
import 'services/e2e_crypto.dart';
import 'services/log_service.dart';
import 'services/relay_service.dart';
import 'services/storage_service.dart';
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
import 'widgets/terminal_header.dart';
import 'widgets/terminal_transition_mask.dart';
import 'widgets/toolbar.dart';

typedef RelaySocketFactory = dynamic Function(StoredDevice device);

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
    with TickerProviderStateMixin {
  final _storage = StorageService();
  final _imagePicker = ImagePicker();
  final _settingsNameController = TextEditingController();
  final _fileEditorController = CodeEditingController();
  final _projectNameController = TextEditingController();
  final _projectPathController = TextEditingController();

  late final AnimationController _maskController;
  late final Animation<double> _maskOpacity;
  CoduxNativeTerminalController? _nativeTerminalController;
  String _pendingTerminalOutput = '';
  double _terminalCursorBottom = 0;
  int? _lastTerminalCols;
  int? _lastTerminalRows;
  int? _pendingTerminalCols;
  int? _pendingTerminalRows;
  bool _keyboardVisible = false;
  String? _lastInputData;
  DateTime? _lastInputAt;

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
  final Set<String> _ownedTerminalIds = {};
  bool _showSettings = false;
  bool _showScanner = false;
  PairingPayload? _pendingPairing;
  bool _pairingInFlight = false;
  bool _pairingCancelled = false;
  String? _pairingError;
  bool _showTerminal = false;
  bool _terminalReady = false;
  bool _terminalListLoaded = false;
  bool _backgroundConnect = false;
  bool _shouldReconnect = true;
  bool _relayReady = false;
  bool _hasShownTerminal = false;
  bool _aiStatsLoading = false;
  bool _showProjectForm = false;
  bool _showFilePicker = false;
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
  String _lastBufferedSessionId = '';

  WebSocketSinkLike? _socket;
  int _sendSeq = 0;
  int _receiveSeq = 0;
  Future<void> _sendChain = Future<void>.value();
  Future<void> _receiveChain = Future<void>.value();
  StreamSubscription? _socketSubscription;
  Timer? _reconnectTimer;
  Timer? _healthTimer;
  Timer? _toastTimer;
  Timer? _filePickerTimeoutTimer;

  bool get _isConnected => _socket != null && _relayReady;
  String _t(String key, {Map<String, String>? params}) =>
      AppPreferences.of(context).t(key, params: params);

  ProjectInfo? get _selectedProject {
    for (final project in _projects) {
      if (project.id == _selectedProjectId) return project;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _maskController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _maskOpacity = CurvedAnimation(
      parent: _maskController,
      curve: Curves.easeOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _healthTimer?.cancel();
    _toastTimer?.cancel();
    _filePickerTimeoutTimer?.cancel();
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

  Future<void> _bootstrap() async {
    final initialDevices = widget.initialDevices;
    if (initialDevices != null) {
      if (!mounted) return;
      setState(() {
        _devices = initialDevices;
        _activeDevice = initialDevices.isNotEmpty ? initialDevices.first : null;
        _showTerminal = false;
      });
      if (initialDevices.isNotEmpty) _connect(initialDevices.first, true);
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
    if (devices.isNotEmpty) _connect(devices.first, true);
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
    _shouldReconnect = true;
    _backgroundConnect = background;
    _reconnectTimer?.cancel();
    _healthTimer?.cancel();
    _socketSubscription?.cancel();
    _socket?.close();
    _sendSeq = 0;
    _receiveSeq = 0;
    _sendChain = Future<void>.value();
    _receiveChain = Future<void>.value();
    RemoteE2ECrypto.clearCache();
    if (!background) _clearTerminal();
    setState(() {
      _relayReady = false;
      if (!background) {
        _status = _t('app.connecting');
        _projects = [];
        _terminals = [];
        _terminalListLoaded = false;
        _selectedProjectId = null;
        _sessionId = null;
        _lastBufferedSessionId = '';
        _ownedTerminalIds.clear();
      }
      _activeDevice = target;
    });
    try {
      final channel = (widget.relaySocketFactory ?? createRelaySocket)(target);
      final socket = _WebSocketSink(channel);
      _socket = socket;
      _socketSubscription = channel.stream.listen(
        (event) => _handleSocketMessage(event, target, socket),
        onDone: () => _handleSocketClosed(target, socket),
        onError: (error) {
          if (_socket != socket) return;
          if (!_backgroundConnect) {
            setState(() => _status = _t('app.connectError'));
          }
          _handleSocketClosed(target, socket);
        },
      );
      channel.ready.catchError((error) {
        if (_socket != socket) return null;
        if (!_backgroundConnect && mounted) {
          setState(() => _status = _t('connection.failedRetry'));
        }
        _handleSocketClosed(target, socket);
        return null;
      });
      _healthTimer = Timer(const Duration(seconds: 6), () {
        if (_socket == socket && !_relayReady) socket.close();
      });
    } catch (error) {
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
  ) {
    if (_socket != closedSocket) return;
    _healthTimer?.cancel();
    _healthTimer = null;
    _socketSubscription?.cancel();
    _socketSubscription = null;
    if (_socket != null) {
      _socket = null;
      setState(() {
        _relayReady = false;
        _status = _t('app.reconnecting');
      });
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
    _reconnectTimer = Timer(delay, () => _connect(target, true));
  }

  void _sendInitialRelayRequests({bool force = false}) {
    if (force) {
      _lastBufferedSessionId = '';
    }
    _send(const RelayEnvelope(type: 'host.info'));
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
    _send(const RelayEnvelope(type: 'project.list'));
    _send(const RelayEnvelope(type: 'terminal.list'));
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
    if (message.type.startsWith('terminal.')) {
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
            setState(() {
              _relayReady = true;
              _hasShownTerminal = true;
              if (!_backgroundConnect) _status = _t('app.connected');
            });
            _sendInitialRelayRequests(force: true);
          }
        case 'host.offline':
          final payload = message.payload;
          final messageText = payload is Map
              ? '${payload['message'] ?? _t('connection.macDisconnected')}'
              : _t('connection.macDisconnected');
          setState(() {
            _relayReady = false;
            _showTerminal = false;
            _workspaceMode = 'terminal';
            _projects = [];
            _terminals = [];
            _terminalListLoaded = false;
            _selectedProjectId = null;
            _sessionId = null;
            _status = messageText;
          });
          _scheduleReconnect(target);
        case 'secure.required':
          setState(() {
            _status = _t('pair.repairRequired');
          });
        case 'host.info':
          final payload = message.payload;
          if (payload is Map && payload['name'] != null) {
            _updateDevice(target.deviceId, hostName: '${payload['name']}');
          }
        case 'project.list':
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
          _ensureTerminalForSelectedProject();
        case 'terminal.list':
          final payload = message.payload;
          final list = payload is Map
              ? (payload['terminals'] as List<dynamic>? ?? [])
              : <dynamic>[];
          final next = list
              .map(
                (item) => TerminalInfo.fromJson(item as Map<String, dynamic>),
              )
              .toList();
          setState(() {
            _terminals = next;
            for (final terminal in next) {
              if (_hasCurrentDeviceOwner(terminal)) {
                _ownedTerminalIds.add(terminal.id);
              }
            }
            _terminalListLoaded = true;
            if (_sessionId != null &&
                !next.any(
                  (item) =>
                      item.id == _sessionId && _isOwnedByCurrentDevice(item),
                )) {
              _sessionId = null;
              _lastBufferedSessionId = '';
            }
          });
          _ensureTerminalForSelectedProject();
          if (_showTerminal && _sessionId != null) {
            _lastBufferedSessionId = '';
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
              _ownedTerminalIds.add(terminal.id);
              _terminals = [
                terminal,
                ..._terminals.where((item) => item.id != terminal.id),
              ];
              _sessionId = terminal.id;
              _selectedProjectId = terminal.projectId;
              _creatingTerminalProjectId = null;
              _lastBufferedSessionId = '';
            });
            _clearTerminal();
            _flushPendingTerminalResize(force: true);
            _requestBufferIfReady();
          }
        case 'terminal.closed':
          final closedSessionId = message.sessionId;
          final closedActiveSession =
              closedSessionId != null && _sessionId == closedSessionId;
          setState(() {
            _terminals = _terminals
                .where((item) => item.id != closedSessionId)
                .toList();
            if (closedSessionId != null) {
              _ownedTerminalIds.remove(closedSessionId);
            }
            if (closedActiveSession) {
              _sessionId = null;
              _lastBufferedSessionId = '';
              _terminalCursorBottom = 0;
            }
            _creatingTerminalProjectId = null;
          });
          if (closedActiveSession) _clearTerminal();
        case 'terminal.output':
          final payload = message.payload;
          if (payload is Map && payload['data'] != null) {
            if (message.sessionId == null || message.sessionId != _sessionId) {
              CoduxLog.debug(
                '[codux-flutter-output] skip inactive session=${message.sessionId ?? ''} active=${_sessionId ?? ''}',
              );
              return;
            }
            final raw = '${payload['data']}';
            final isBuffer = payload['buffer'] == true;
            CoduxLog.debug(
              '[codux-flutter-output] bytes=${raw.codeUnits.length} buffer=$isBuffer session=${message.sessionId ?? ''} data=${_debugTerminalSnippet(raw)}',
            );
            if (isBuffer) _clearTerminal();
            if (raw.isNotEmpty) {
              _writeTerminalData(raw, replayingBuffer: isBuffer);
            }
          }
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
          final payload = message.payload;
          if (payload is Map && payload['path'] != null) {
            final inserted = payload['inserted'] == true;
            final mode = payload['mode']?.toString();
            final tool = payload['tool']?.toString();
            if (!inserted) {
              final path = '${payload['path']}';
              _sendInput('$path ');
            }
            setState(
              () => _status = mode == 'clipboard'
                  ? _t(
                      'upload.imageSentTool',
                      params: {'tool': tool ?? _t('upload.aiTool')},
                    )
                  : _t('upload.imageSentPath'),
            );
          }
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

  void _requestBufferIfReady({bool force = false}) {
    final id = _sessionId;
    if (!_terminalReady ||
        id == null ||
        (!force && _lastBufferedSessionId == id)) {
      return;
    }
    _lastBufferedSessionId = id;
    _send(RelayEnvelope(type: 'terminal.buffer', sessionId: id));
  }

  void _clearTerminal() {
    CoduxLog.debug(
      '[codux-flutter-terminal] clear session=${_sessionId ?? ''}',
    );
    _pendingTerminalOutput = '';
    _nativeTerminalController?.clear();
  }

  void _writeTerminalData(String data, {required bool replayingBuffer}) {
    final displayData = data;
    if (displayData.isEmpty) return;
    final controller = _nativeTerminalController;
    if (controller == null) {
      CoduxLog.debug(
        '[codux-flutter-output] pending bytes=${displayData.codeUnits.length} replay=$replayingBuffer data=${_debugTerminalSnippet(displayData)}',
      );
      _pendingTerminalOutput += displayData;
      return;
    }
    CoduxLog.debug(
      '[codux-flutter-output] write-native bytes=${displayData.codeUnits.length} replay=$replayingBuffer data=${_debugTerminalSnippet(displayData)}',
    );
    controller.write(displayData);
  }

  void _sendTerminalResize(int cols, int rows) {
    final id = _sessionId;
    if (cols <= 0 || rows <= 0) return;
    _pendingTerminalCols = cols;
    _pendingTerminalRows = rows;
    if (id == null) return;
    final nextRows = _keyboardVisible ? (_lastTerminalRows ?? rows) : rows;
    if (_lastTerminalCols == cols && _lastTerminalRows == nextRows) {
      return;
    }
    _lastTerminalCols = cols;
    _lastTerminalRows = nextRows;
    _send(
      RelayEnvelope(
        type: 'terminal.resize',
        sessionId: id,
        payload: {'cols': cols, 'rows': nextRows},
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
    if (!force && _lastTerminalCols == cols && _lastTerminalRows == rows) {
      return;
    }
    _lastTerminalCols = cols;
    _lastTerminalRows = rows;
    _send(
      RelayEnvelope(
        type: 'terminal.resize',
        sessionId: id,
        payload: {'cols': cols, 'rows': rows},
      ),
    );
  }

  void _sendInput(String data) {
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
    final now = DateTime.now();
    final lastAt = _lastInputAt;
    if (data.length == 1 &&
        _lastInputData == data &&
        lastAt != null &&
        now.difference(lastAt).inMilliseconds < 35) {
      return;
    }
    _lastInputData = data;
    _lastInputAt = now;
    _nativeTerminalController?.requestResize();
    CoduxLog.debug(
      '[codux-flutter-input] send bytes=${data.codeUnits.length} session=$id data=${_debugTerminalData(data)}',
    );
    _send(
      RelayEnvelope(
        type: 'terminal.input',
        sessionId: id,
        payload: {'data': data},
      ),
    );
  }

  String _debugTerminalData(String data) {
    return data
        .replaceAll('\u001b', '<ESC>')
        .replaceAll('\r', '<CR>')
        .replaceAll('\n', '<LF>')
        .replaceAll('\t', '<TAB>');
  }

  String _debugTerminalSnippet(String data) {
    const maxLength = 160;
    final text = data.length > maxLength
        ? '${data.substring(0, maxLength)}…'
        : data;
    return _debugTerminalData(text);
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

  bool _isOwnedByCurrentDevice(TerminalInfo terminal) {
    if (_ownedTerminalIds.contains(terminal.id)) return true;
    return _hasCurrentDeviceOwner(terminal);
  }

  bool _hasCurrentDeviceOwner(TerminalInfo terminal) {
    final ownerDeviceId = terminal.ownerDeviceId;
    final activeDeviceId = _activeDevice?.deviceId;
    return activeDeviceId != null &&
        ownerDeviceId != null &&
        ownerDeviceId.isNotEmpty &&
        ownerDeviceId == activeDeviceId;
  }

  void _refreshLists() {
    _send(const RelayEnvelope(type: 'project.list'));
    _send(const RelayEnvelope(type: 'terminal.list'));
  }

  void _rebuildCurrentTerminal() {
    final projectId = _selectedProjectId;
    if (projectId == null) {
      _showToast(_t('project.selectFirst'));
      return;
    }
    String? closingSessionId;
    for (final terminal in _terminals) {
      if (terminal.projectId != projectId ||
          !_isOwnedByCurrentDevice(terminal)) {
        continue;
      }
      closingSessionId = terminal.id;
      if (terminal.id == _sessionId) break;
    }
    setState(() {
      if (closingSessionId != null) {
        _terminals = _terminals
            .where((item) => item.id != closingSessionId)
            .toList();
        _ownedTerminalIds.remove(closingSessionId);
      }
      _sessionId = null;
      _lastBufferedSessionId = '';
      _creatingTerminalProjectId = null;
      _terminalCursorBottom = 0;
    });
    _clearTerminal();
    if (closingSessionId != null) {
      _send(RelayEnvelope(type: 'terminal.close', sessionId: closingSessionId));
    }
    _createTerminal(projectId);
    _showToast(_t('terminal.rebuilding'));
  }

  void _ensureTerminalForSelectedProject() {
    if (!_showTerminal || _workspaceMode != 'terminal') return;
    final projectId = _selectedProjectId;
    if (projectId == null) return;
    if (!_terminalListLoaded) {
      _send(const RelayEnvelope(type: 'terminal.list'));
      return;
    }
    if (_sessionId != null &&
        _terminals.any(
          (item) =>
              item.id == _sessionId &&
              item.projectId == projectId &&
              _isOwnedByCurrentDevice(item),
        )) {
      return;
    }
    final existing = _terminals.where(
      (item) => item.projectId == projectId && _isOwnedByCurrentDevice(item),
    );
    if (existing.isNotEmpty) {
      final terminal = existing.first;
      setState(() {
        _sessionId = terminal.id;
        _lastBufferedSessionId = '';
        _creatingTerminalProjectId = null;
        _terminalCursorBottom = 0;
      });
      _clearTerminal();
      _flushPendingTerminalResize(force: true);
      _requestBufferIfReady(force: true);
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
            _isOwnedByCurrentDevice(item),
      );
      if (current) return;
    }
    setState(() {
      _sessionId = null;
      _lastBufferedSessionId = '';
    });
    if (requestListIfMissing) {
      _ensureTerminalForSelectedProject();
    }
  }

  void _showTerminalMode() {
    setState(() => _workspaceMode = 'terminal');
    _syncTerminalToSelectedProject();
    _requestBufferIfReady(force: true);
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
    }
    await _saveDevices(next);
    if (next.isEmpty) {
      setState(() => _showTerminal = false);
    }
  }

  void _openDeviceTerminal(StoredDevice device) {
    if (device.deviceId != _activeDevice?.deviceId || !_isConnected) return;
    setState(() {
      _showTerminal = true;
      _workspaceMode = 'terminal';
    });
    _lastBufferedSessionId = '';
    _sendInitialRelayRequests(force: true);
    _requestBufferIfReady(force: true);
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
        _lastBufferedSessionId = '';
        _creatingTerminalProjectId = null;
        _terminalCursorBottom = 0;
      }
    });
    if (_workspaceMode == 'stats') {
      _requestAIStats();
      return;
    }
    if (_workspaceMode == 'files') {
      _requestProjectFiles(project.path);
      return;
    }
    if (resetTerminal) {
      _clearTerminal();
      _ensureTerminalForSelectedProject();
      return;
    }
    final current = _terminals.any(
      (item) =>
          item.id == _sessionId &&
          item.projectId == project.id &&
          _isOwnedByCurrentDevice(item),
    );
    if (!current) {
      _ensureTerminalForSelectedProject();
    }
  }

  Future<void> _pasteToTerminal() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text?.isNotEmpty == true) {
      _sendInput(data!.text!);
    }
  }

  Future<void> _copyTerminalSelection() async {
    final prefs = AppPreferences.of(context);
    final copied = await _nativeTerminalController?.copySelection() ?? false;
    _showSnack(
      copied ? prefs.t('toolbar.copyDone') : prefs.t('toolbar.copyEmpty'),
    );
  }

  Future<void> _uploadImageToTerminal() async {
    final id = _sessionId;
    if (id == null) {
      setState(() => _status = _t('terminal.createOrSelectFirst'));
      return;
    }
    final image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 88,
    );
    if (image == null) return;
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty) return;
    setState(() => _status = _t('upload.imageUploading'));
    _send(
      RelayEnvelope(
        type: 'terminal.upload',
        sessionId: id,
        payload: {
          'name': image.name,
          'mime': image.mimeType ?? 'image/*',
          'data': base64Encode(bytes),
        },
      ),
    );
  }

  Future<void> _checkUpdate() async {
    setState(() {
      _status = _t('update.checking');
      _blockingLoadingMessage = _t('update.loading');
    });
    try {
      final info = await PackageInfo.fromPlatform();
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
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _showToast(
          _t('update.httpFailed', params: {'status': '${response.statusCode}'}),
        );
        return;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = '${json['tag_name'] ?? ''}'.trim();
      final url = '${json['html_url'] ?? ''}'.trim();
      if (tag.isEmpty) {
        _showToast(_t('update.noVersion'));
        return;
      }
      final hasUpdate = _compareVersion(tag, info.version) > 0;
      if (!hasUpdate) {
        _showToast(_t('update.latest', params: {'version': info.version}));
        return;
      }
      if (!mounted) return;
      final accent = Theme.of(context).colorScheme.secondary;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgSurface,
          title: Text(_t('update.foundTitle', params: {'version': tag})),
          content: Text(
            _t('update.foundBody', params: {'version': info.version}),
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
                if (url.isNotEmpty) _openUrl(url);
              },
              child: Text(_t('common.openGithub')),
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
        connected: _isConnected,
        status: _status.isEmpty ? prefs.t('app.notConnected') : _status,
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
    const terminalPadding = EdgeInsets.fromLTRB(8, 6, 8, 6);

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
                                final pending = _pendingTerminalOutput;
                                _pendingTerminalOutput = '';
                                if (pending.isNotEmpty) {
                                  controller.write(pending);
                                }
                                controller.requestResize();
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (!mounted) return;
                                  _requestBufferIfReady(force: true);
                                });
                              },
                              onInput: _sendInput,
                              onTerminalResponse: (data) {
                                CoduxLog.debug(
                                  '[codux-flutter-response] local bytes=${data.codeUnits.length} data=${_debugTerminalSnippet(data)}',
                                );
                              },
                              onResize: (cols, rows) {
                                final firstResize = !_terminalReady;
                                _terminalReady = true;
                                _sendTerminalResize(cols, rows);
                                if (firstResize) {
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (!mounted) return;
                                    _requestBufferIfReady(force: true);
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
                          FadeTransition(
                            opacity: _maskOpacity,
                            child: const TerminalTransitionMask(),
                          ),
                        ],
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
                      onSendKey: _sendInput,
                      keyboardVisible: _keyboardVisible,
                      bottomInset: 0,
                      onToggleKeyboard: _toggleTerminalKeyboard,
                      onPaste: _pasteToTerminal,
                      onCopy: _copyTerminalSelection,
                      onUpload: _uploadImageToTerminal,
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
          onSelect: _onProjectSelected,
          onRefresh: _refreshLists,
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

class _WebSocketSink implements WebSocketSinkLike {
  _WebSocketSink(this.channel);
  final dynamic channel;
  @override
  void add(String data) => channel.sink.add(data);
  @override
  void close() => channel.sink.close();
}
