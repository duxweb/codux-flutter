import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef CoduxRemoteIrohEnvelopeHandler =
    void Function(Map<String, dynamic> envelope);
typedef CoduxRemoteIrohStateHandler = void Function(String state);

typedef _ConnectNative = ffi.Uint64 Function(ffi.Pointer<ffi.Char>);
typedef _AddNodeAddrNative =
    ffi.Bool Function(ffi.Uint64, ffi.Pointer<ffi.Char>);
typedef _SendNative = ffi.Bool Function(ffi.Uint64, ffi.Pointer<ffi.Char>);
typedef _PollNative = ffi.Pointer<ffi.Char> Function(ffi.Uint64);
typedef _CloseNative = ffi.Void Function(ffi.Uint64);
typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<ffi.Char>);

typedef _ConnectDart = int Function(ffi.Pointer<ffi.Char>);
typedef _AddNodeAddrDart = bool Function(int, ffi.Pointer<ffi.Char>);
typedef _SendDart = bool Function(int, ffi.Pointer<ffi.Char>);
typedef _PollDart = ffi.Pointer<ffi.Char> Function(int);
typedef _CloseDart = void Function(int);
typedef _FreeStringDart = void Function(ffi.Pointer<ffi.Char>);

class CoduxRemoteIroh {
  CoduxRemoteIroh({CoduxRemoteIrohBridge? bridge}) : _bridge = bridge;

  CoduxRemoteIrohBridge? _bridge;
  Timer? _pollTimer;
  int _handle = 0;

  CoduxRemoteIrohEnvelopeHandler? onEnvelope;
  CoduxRemoteIrohStateHandler? onState;

  bool get isConnected => _handle != 0;

  Future<void> connect({required Map<String, dynamic> nodeAddr}) async {
    await close();
    final handle = _bridgeOrLoad().connect({'nodeAddr': nodeAddr});
    if (handle == 0) {
      throw StateError('Iroh transport failed to start');
    }
    _handle = handle;
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _drainEvents(),
    );
    _drainEvents();
  }

  Future<bool> send(Map<String, dynamic> envelope) async {
    final handle = _handle;
    if (handle == 0) return false;
    return _bridgeOrLoad().send(handle, envelope);
  }

  Future<bool> addNodeAddr(Map<String, dynamic> nodeAddr) async {
    final handle = _handle;
    if (handle == 0) return false;
    return _bridgeOrLoad().addNodeAddr(handle, nodeAddr);
  }

  Future<void> close() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final handle = _handle;
    _handle = 0;
    if (handle != 0) {
      _bridgeOrLoad().close(handle);
    }
  }

  void _drainEvents() {
    final handle = _handle;
    if (handle == 0) return;
    for (var index = 0; index < 64; index += 1) {
      final event = _bridgeOrLoad().pollEvent(handle);
      if (event == null) return;
      _handleEvent(event);
    }
  }

  CoduxRemoteIrohBridge _bridgeOrLoad() {
    return _bridge ??= CoduxRemoteIrohBridge.load();
  }

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'state':
        final state = '${event['state'] ?? ''}';
        final detail = switch (state) {
          'path' => _formatPathState(event),
          'resolving' => _formatResolvingState(event),
          _ => '${event['error'] ?? ''}'.trim(),
        };
        if (state == 'closed' || state == 'failed') {
          _pollTimer?.cancel();
          _pollTimer = null;
          _handle = 0;
        }
        onState?.call(detail.isEmpty ? state : '$state:$detail');
      case 'envelope':
        final envelope = event['envelope'];
        if (envelope is Map) {
          onEnvelope?.call(Map<String, dynamic>.from(envelope));
        }
    }
  }

  String _formatPathState(Map<String, dynamic> event) {
    final path = '${event['path'] ?? ''}'.trim();
    final detail = '${event['detail'] ?? ''}'.trim();
    if (path.isEmpty) return detail;
    return detail.isEmpty ? 'path=$path' : 'path=$path;detail=$detail';
  }

  String _formatResolvingState(Map<String, dynamic> event) {
    final nodeId = '${event['nodeId'] ?? ''}'.trim();
    final relayUrl = '${event['relayUrl'] ?? ''}'.trim();
    final directAddressCount = event['directAddressCount'];
    return [
      if (nodeId.isNotEmpty) 'nodeId=$nodeId',
      if (relayUrl.isNotEmpty) 'relay=$relayUrl',
      if (directAddressCount != null) 'direct=$directAddressCount',
    ].join(';');
  }
}

abstract interface class CoduxRemoteIrohBridge {
  factory CoduxRemoteIrohBridge.load() = _NativeCoduxRemoteIrohBridge.load;

  int connect(Map<String, dynamic> config);
  bool addNodeAddr(int handle, Map<String, dynamic> nodeAddr);
  bool send(int handle, Map<String, dynamic> envelope);
  Map<String, dynamic>? pollEvent(int handle);
  void close(int handle);
}

class _NativeCoduxRemoteIrohBridge implements CoduxRemoteIrohBridge {
  _NativeCoduxRemoteIrohBridge._(ffi.DynamicLibrary library)
    : _connect = library.lookupFunction<_ConnectNative, _ConnectDart>(
        'codux_iroh_connect',
      ),
      _send = library.lookupFunction<_SendNative, _SendDart>('codux_iroh_send'),
      _addNodeAddr = library
          .lookupFunction<_AddNodeAddrNative, _AddNodeAddrDart>(
            'codux_iroh_add_node_addr',
          ),
      _poll = library.lookupFunction<_PollNative, _PollDart>(
        'codux_iroh_poll_event',
      ),
      _close = library.lookupFunction<_CloseNative, _CloseDart>(
        'codux_iroh_close',
      ),
      _freeString = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
        'codux_iroh_free_string',
      );

  factory _NativeCoduxRemoteIrohBridge.load() {
    if (Platform.isIOS) {
      return _NativeCoduxRemoteIrohBridge._(ffi.DynamicLibrary.process());
    }
    if (Platform.isAndroid) {
      return _NativeCoduxRemoteIrohBridge._(
        ffi.DynamicLibrary.open('libcodux_remote_iroh_bridge.so'),
      );
    }
    return _NativeCoduxRemoteIrohBridge._(
      ffi.DynamicLibrary.open('libcodux_remote_iroh_bridge.dylib'),
    );
  }

  final _ConnectDart _connect;
  final _AddNodeAddrDart _addNodeAddr;
  final _SendDart _send;
  final _PollDart _poll;
  final _CloseDart _close;
  final _FreeStringDart _freeString;

  @override
  int connect(Map<String, dynamic> config) {
    final json = jsonEncode(config);
    final pointer = json.toNativeUtf8().cast<ffi.Char>();
    try {
      return _connect(pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  bool send(int handle, Map<String, dynamic> envelope) {
    final json = jsonEncode(envelope);
    final pointer = json.toNativeUtf8().cast<ffi.Char>();
    try {
      return _send(handle, pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  bool addNodeAddr(int handle, Map<String, dynamic> nodeAddr) {
    final json = jsonEncode(nodeAddr);
    final pointer = json.toNativeUtf8().cast<ffi.Char>();
    try {
      return _addNodeAddr(handle, pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  Map<String, dynamic>? pollEvent(int handle) {
    final pointer = _poll(handle);
    if (pointer == ffi.nullptr) return null;
    try {
      final text = pointer.cast<Utf8>().toDartString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } finally {
      _freeString(pointer);
    }
  }

  @override
  void close(int handle) => _close(handle);
}
