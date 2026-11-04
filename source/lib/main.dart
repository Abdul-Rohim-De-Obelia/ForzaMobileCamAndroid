import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const Color bg = Color(0xFF0A101B);
const Color panel = Color(0xFF141F2F);
const Color panel2 = Color(0xFF1B2A40);
const Color line = Color(0xFF2A3B53);
const Color accent = Color(0xFF58A6FF);
const Color green = Color(0xFF38D39F);
const Color red = Color(0xFFFF626D);
const Color muted = Color(0xFF9DAFC7);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(
    const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
  );
  runApp(const ForzaMobileCamApp());
}

class ForzaMobileCamApp extends StatelessWidget {
  const ForzaMobileCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Forza Mobile Cam',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: green,
          surface: panel,
          error: red,
        ),
        useMaterial3: true,
        sliderTheme: const SliderThemeData(
          activeTrackColor: accent,
          thumbColor: Colors.white,
          inactiveTrackColor: line,
          overlayColor: Color(0x3358A6FF),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: bg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: accent),
          ),
          labelStyle: const TextStyle(color: muted),
        ),
      ),
      home: const ControllerScreen(),
    );
  }
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen>
    with WidgetsBindingObserver {
  final TextEditingController _hostController =
      TextEditingController(text: '192.168.1.10');
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '8765');

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  bool _connected = false;
  bool _armed = false;
  bool _connecting = false;
  bool _gyroEnabled = false;
  bool _calibrating = false;
  bool _invertX = false;
  bool _invertY = false;
  String _connectionText = 'DISCONNECTED';
  String _activeWindow = 'Belum terhubung';
  String _gyroMessage = 'Gyro nonaktif';
  double _mouseSensitivity = 1.0;
  double _gyroSensitivity = 1.5;
  double _gyroBiasX = 0;
  double _gyroBiasY = 0;
  double _gyroSumX = 0;
  double _gyroSumY = 0;
  int _gyroSamples = 0;
  DateTime? _lastGyroTime;
  final Set<String> _heldKeys = <String>{};
  final Set<String> _movementKeys = <String>{};
  final Set<String> _gyroKeys = <String>{};
  String _cameraMode = 'COCKPIT'; // COCKPIT, PHOTO MOUSE, PHOTO KEYS
  bool _gyroMouseHeld = false;
  bool _touchMouseHeld = false;
  double _filteredYaw = 0;
  double _filteredPitch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedHost();
  }

  Future<void> _loadSavedHost() async {
    final prefs = await SharedPreferences.getInstance();
    final savedHost = prefs.getString('bridge_host');
    final savedPort = prefs.getString('bridge_port');
    if (!mounted) return;
    setState(() {
      if (savedHost != null && savedHost.isNotEmpty) {
        _hostController.text = savedHost;
      }
      if (savedPort != null && savedPort.isNotEmpty) {
        _portController.text = savedPort;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _emergencyStop();
      _stopGyro();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    final token = _tokenController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (host.isEmpty || token.isEmpty || port == null || port < 1 || port > 65535) {
      _showMessage('Isi IP PC, port 8765, dan session token dari Bridge.');
      return;
    }

    await _disconnect(showMessage: false);
    setState(() {
      _connecting = true;
      _connectionText = 'CONNECTING';
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bridge_host', host);
      await prefs.setString('bridge_port', port.toString());

      final uri = Uri(scheme: 'ws', host: host, port: port);
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;

      _socketSub = channel.stream.listen(
        _handleSocketMessage,
        onError: (Object error) {
          _handleSocketClosed('Koneksi error: $error');
        },
        onDone: () {
          _handleSocketClosed('Koneksi terputus.');
        },
        cancelOnError: true,
      );

      await channel.ready.timeout(const Duration(seconds: 8));
      channel.sink.add(jsonEncode({'token': token}));

      if (!mounted) return;
      setState(() {
        _connecting = false;
      });
    } catch (error) {
      await _disconnect(showMessage: false);
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connectionText = 'CONNECTION FAILED';
      });
      _showMessage('Gagal terhubung. Periksa IP, port, token, dan Wi-Fi. ($error)');
    }
  }

  void _handleSocketMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'];

      if (type == 'auth_ok') {
        if (!mounted) return;
        setState(() {
          _connected = true;
          _armed = false;
          _connectionText = 'CONNECTED';
          _activeWindow = 'Bridge tersambung';
        });
        _send({'cmd': 'status'});
        _showMessage('Terhubung ke Windows Bridge.');
      } else if (type == 'status') {
        if (!mounted) return;
        setState(() {
          _activeWindow = (data['foreground_window'] ?? 'Unknown').toString();
        });
      } else if (type == 'ack') {
        final cmd = data['cmd'];
        if (cmd == 'arm') {
          if (!mounted) return;
          setState(() {
            _armed = true;
            _connectionText = 'ARMED';
          });
        } else if (cmd == 'emergency_stop' ||
            cmd == 'disarm' ||
            cmd == 'release_all') {
          if (!mounted) return;
          setState(() {
            _armed = false;
            _heldKeys.clear();
            _connectionText = _connected ? 'CONNECTED' : 'DISCONNECTED';
          });
        }
      } else if (type == 'error') {
        final message = (data['message'] ?? 'Bridge error').toString();
        if (message.toLowerCase().contains('disarmed')) {
          if (mounted) setState(() => _armed = false);
        }
        _showMessage(message);
      }
    } catch (_) {
      // Ignore malformed or unexpected messages from the bridge.
    }
  }

  void _handleSocketClosed(String message) {
    if (!mounted) return;
    setState(() {
      _connected = false;
      _armed = false;
      _connecting = false;
      _connectionText = 'DISCONNECTED';
      _activeWindow = message;
      _heldKeys.clear();
      _movementKeys.clear();
    });
    _stopGyro();
  }

  void _send(Map<String, dynamic> message) {
    if (_channel == null || !_connected) return;
    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (_) {
      _handleSocketClosed('Gagal mengirim perintah.');
    }
  }

  Future<void> _disconnect({bool showMessage = true}) async {
    try {
      if (_channel != null && _connected) {
        _channel!.sink.add(jsonEncode({'cmd': 'emergency_stop'}));
      }
      await _channel?.sink.close();
    } catch (_) {}
    await _socketSub?.cancel();
    _socketSub = null;
    _channel = null;
    _stopGyro();
    if (mounted) {
      setState(() {
        _connected = false;
        _armed = false;
        _connecting = false;
        _connectionText = 'DISCONNECTED';
        _heldKeys.clear();
        _movementKeys.clear();
      });
    }
    if (showMessage) _showMessage('Bridge disconnected.');
  }

  void _arm() {
    if (!_connected) return;
    _send({'cmd': 'arm'});
  }

  void _emergencyStop() {
    if (_connected) _send({'cmd': 'emergency_stop'});
    _stopGyro(releaseInputs: false);
    if (mounted) {
      setState(() {
        _armed = false;
        _heldKeys.clear();
        _movementKeys.clear();
        _gyroKeys.clear();
        _gyroMouseHeld = false;
        _touchMouseHeld = false;
      });
    }
  }

  void _keyDown(String key) {
    if (!_connected || !_armed) return;
    if (_heldKeys.add(key)) {
      _send({'cmd': 'key_down', 'key': key});
    }
  }

  void _keyUp(String key) {
    _movementKeys.remove(key);
    if (_heldKeys.remove(key)) {
      _send({'cmd': 'key_up', 'key': key});
    }
  }

  void _keyTap(String key) {
    if (!_connected || !_armed) return;
    _send({'cmd': 'key_tap', 'key': key});
  }

  void _updateMovement(Offset value) {
    if (!_connected || !_armed) return;
    final next = <String>{};
    if (value.dy < -0.35) next.add('W');
    if (value.dy > 0.35) next.add('S');
    if (value.dx < -0.35) next.add('A');
    if (value.dx > 0.35) next.add('D');

    // Keep joystick movement keys separate from momentary buttons such as SHIFT/E/Q.
    final released = _movementKeys.difference(next).toList();
    final pressed = next.difference(_movementKeys).toList();
    for (final key in released) {
      if (_heldKeys.remove(key)) {
        _send({'cmd': 'key_up', 'key': key});
      }
    }
    for (final key in pressed) {
      if (_heldKeys.add(key)) {
        _send({'cmd': 'key_down', 'key': key});
      }
    }
    _movementKeys
      ..clear()
      ..addAll(next);
  }

  void _mouseMove(double dx, double dy) {
    if (!_connected || !_armed) return;
    final x = (dx * _mouseSensitivity).round();
    final y = (dy * _mouseSensitivity).round();
    if (x == 0 && y == 0) return;
    _send({'cmd': 'mouse_move', 'dx': x, 'dy': y});
  }

  void _mouseWheel(int delta) {
    if (!_connected || !_armed) return;
    _send({'cmd': 'mouse_wheel', 'delta': delta});
  }

  void _mouseButtonDown(String button) {
    if (!_connected || !_armed) return;
    _send({'cmd': 'mouse_button_down', 'button': button});
  }

  void _mouseButtonUp(String button) {
    if (!_connected || !_armed) return;
    _send({'cmd': 'mouse_button_up', 'button': button});
  }

  Future<void> _toggleGyro(bool enabled) async {
    if (enabled) {
      if (!_connected || !_armed) {
        _showMessage('Hubungkan Bridge dan tekan ARM sebelum mengaktifkan motion camera.');
        return;
      }
      try {
        _filteredYaw = 0;
        _filteredPitch = 0;
        _lastGyroTime = null;

        // FH6 Cockpit Mouse Free Look requires RMB to remain held while mouse moves.
        if (_cameraMode == 'COCKPIT') {
          _mouseButtonDown('right');
          _gyroMouseHeld = true;
        }

        _gyroSub = gyroscopeEventStream(
          samplingPeriod: SensorInterval.gameInterval,
        ).listen(
          _onGyroEvent,
          onError: (Object error) {
            if (mounted) setState(() => _gyroMessage = 'Sensor gyro tidak tersedia');
            _showMessage('Tidak dapat membaca gyroscope: $error');
          },
        );
        setState(() {
          _gyroEnabled = true;
          _gyroMessage = 'Motion aktif · putar HP perlahan';
        });
      } catch (error) {
        if (_gyroMouseHeld) {
          _mouseButtonUp('right');
          _gyroMouseHeld = false;
        }
        _showMessage('Gagal mengaktifkan gyro: $error');
      }
    } else {
      _stopGyro();
    }
  }

  void _stopGyro({bool releaseInputs = true}) {
    _gyroSub?.cancel();
    _gyroSub = null;
    if (releaseInputs && _connected && _armed) {
      if (_gyroMouseHeld) _mouseButtonUp('right');
      for (final key in _gyroKeys.toList()) {
        _keyUp(key);
      }
    }
    _gyroMouseHeld = false;
    _gyroKeys.clear();
    if (mounted) {
      setState(() {
        _gyroEnabled = false;
        _calibrating = false;
        _lastGyroTime = null;
        _gyroMessage = 'Motion control nonaktif';
      });
    }
  }

  void _syncGyroKeys(Set<String> next) {
    final released = _gyroKeys.difference(next).toList();
    final pressed = next.difference(_gyroKeys).toList();
    for (final key in released) {
      _keyUp(key);
    }
    for (final key in pressed) {
      _keyDown(key);
    }
    _gyroKeys
      ..clear()
      ..addAll(next);
  }

  double _applyDeadzone(double value, double zone) {
    if (value.abs() < zone) return 0;
    return value.sign * (value.abs() - zone);
  }

  void _setCameraMode(String mode) {
    if (_cameraMode == mode) return;
    if (_gyroMouseHeld && _connected && _armed) {
      _mouseButtonUp('right');
      _gyroMouseHeld = false;
    }
    _syncGyroKeys(<String>{});
    setState(() => _cameraMode = mode);
    if (_gyroEnabled && _connected && _armed &&
        (mode == 'COCKPIT')) {
      _mouseButtonDown('right');
      _gyroMouseHeld = true;
    }
  }

  void _cameraGestureStart(int pointerCount) {
    if (!_connected || !_armed) return;
    if (pointerCount == 1 && _cameraMode == 'COCKPIT' && !_gyroMouseHeld) {
      _mouseButtonDown('right');
      _touchMouseHeld = true;
    }
  }

  void _cameraGestureEnd() {
    if (_touchMouseHeld && _connected && _armed) _mouseButtonUp('right');
    _touchMouseHeld = false;
  }

  void _onPinchZoom(int direction) {
    if (_connected && _armed) _mouseWheel(direction * 120);
  }

  void _startCalibration() {
    if (!_gyroEnabled) {
      _showMessage('Aktifkan gyro terlebih dahulu.');
      return;
    }
    setState(() {
      _calibrating = true;
      _gyroSamples = 0;
      _gyroSumX = 0;
      _gyroSumY = 0;
      _gyroMessage = 'Kalibrasi… jangan gerakkan HP';
    });
  }

  void _onGyroEvent(GyroscopeEvent event) {
    final now = DateTime.now();
    final previous = _lastGyroTime;
    _lastGyroTime = now;

    if (_calibrating) {
      _gyroSumX += event.x;
      _gyroSumY += event.y;
      _gyroSamples++;
      if (_gyroSamples >= 70) {
        _gyroBiasX = _gyroSumX / _gyroSamples;
        _gyroBiasY = _gyroSumY / _gyroSamples;
        if (mounted) {
          setState(() {
            _calibrating = false;
            _gyroMessage = 'Center tersimpan · siap digunakan';
          });
        }
      }
      return;
    }

    if (previous == null || !_gyroEnabled || !_armed) return;
    final dt = now.difference(previous).inMicroseconds / 1000000.0;
    if (dt <= 0 || dt > 0.08) return;

    // Portrait mapping: phone yaw (Y axis) pans left/right; pitch (X axis) pans up/down.
    var yaw = (event.y - _gyroBiasY) * (_invertX ? -1 : 1);
    var pitch = (event.x - _gyroBiasX) * (_invertY ? -1 : 1);
    yaw = _applyDeadzone(yaw, 0.018);
    pitch = _applyDeadzone(pitch, 0.018);

    // Light low-pass filter removes sensor jitter while preserving responsive movement.
    _filteredYaw = (_filteredYaw * 0.58) + (yaw * 0.42);
    _filteredPitch = (_filteredPitch * 0.58) + (pitch * 0.42);

    if (_cameraMode == 'PHOTO KEYS') {
      const threshold = 0.045;
      final next = <String>{};
      if (_filteredYaw < -threshold) next.add('LEFT');
      if (_filteredYaw > threshold) next.add('RIGHT');
      if (_filteredPitch < -threshold) next.add('UP');
      if (_filteredPitch > threshold) next.add('DOWN');
      _syncGyroKeys(next);
      return;
    }

    // Mouse Free Look: the app holds RMB automatically in Cockpit mode.
    final dx = (_filteredYaw * dt * 520 * _gyroSensitivity).round();
    final dy = (-_filteredPitch * dt * 520 * _gyroSensitivity).round();
    if (dx != 0 || dy != 0) {
      _send({
        'cmd': 'mouse_move',
        'dx': dx.clamp(-120, 120),
        'dy': dy.clamp(-120, 120),
      });
    }
  }

  Future<void> _showConnectionDialog() async {
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(
        builder: (_) => BridgeConnectionPage(
          initialHost: _hostController.text,
          initialPort: _portController.text,
          initialToken: _tokenController.text,
        ),
      ),
    );

    if (result == null) return;

    _hostController.text = result['host'] ?? '';
    _portController.text = result['port'] ?? '8765';
    _tokenController.text = result['token'] ?? '';
    await _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try {
      if (_channel != null && _connected) {
        _channel!.sink.add(jsonEncode({'cmd': 'emergency_stop'}));
        _channel!.sink.close();
      }
    } catch (_) {}
    _socketSub?.cancel();
    _gyroSub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(15, 8, 15, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildConnectionStrip(),
                    const SizedBox(height: 13),
                    _buildModeSelector(),
                    const SizedBox(height: 12),
                    _buildViewfinder(),
                    const SizedBox(height: 10),
                    _buildZoomBar(),
                    const SizedBox(height: 12),
                    _buildMotionPanel(),
                    const SizedBox(height: 12),
                    _buildQuickActions(),
                    const SizedBox(height: 12),
                    _buildFooter(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final statusColor = _armed ? green : (_connected ? accent : muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 7),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF173657),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.camera_alt_rounded, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FORZA MOBILE CAM', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: .8)),
                SizedBox(height: 2),
                Text('VIRTUAL CAMERA RIG', style: TextStyle(fontSize: 9, color: muted, letterSpacing: 1.4)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(.10),
              border: Border.all(color: statusColor.withOpacity(.5)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(_connectionText, style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(13)}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: line),
      ),
      child: child,
    );
  }

  Widget _buildConnectionStrip() {
    return _card(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      child: Row(
        children: [
          const Icon(Icons.desktop_windows, color: muted, size: 16),
          const SizedBox(width: 7),
          Expanded(child: Text(_activeWindow, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 9))),
          if (!_connected)
            _miniButton(_connecting ? 'WAIT' : 'CONNECT', Icons.link, _connecting ? null : _showConnectionDialog, accent)
          else if (!_armed)
            _miniButton('ARM', Icons.power_settings_new, _arm, green)
          else
            _miniButton('STOP', Icons.stop_circle_outlined, _emergencyStop, red),
          if (_connected)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Disconnect',
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off, color: muted, size: 17),
            ),
        ],
      ),
    );
  }

  Widget _miniButton(String label, IconData icon, VoidCallback? action, Color color) {
    return SizedBox(
      height: 33,
      child: FilledButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 13),
        label: Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800)),
        style: FilledButton.styleFrom(
          backgroundColor: color.withOpacity(.16),
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return _card(
      padding: const EdgeInsets.all(5),
      child: Row(
        children: [
          _modeTab('COCKPIT', 'Cockpit', Icons.directions_car_filled_outlined),
          _modeTab('PHOTO MOUSE', 'Photo · Mouse', Icons.camera_alt_outlined),
          _modeTab('PHOTO KEYS', 'Photo · Keys', Icons.keyboard_alt_outlined),
        ],
      ),
    );
  }

  Widget _modeTab(String value, String label, IconData icon) {
    final selected = _cameraMode == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => _setCameraMode(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF214D75) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: selected ? accent.withOpacity(.7) : Colors.transparent),
          ),
          child: Column(children: [
            Icon(icon, size: 17, color: selected ? Colors.white : muted),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: selected ? Colors.white : muted)),
          ]),
        ),
      ),
    );
  }

  Widget _buildViewfinder() {
    final enabled = _connected && _armed;
    final modeLabel = _cameraMode == 'COCKPIT' ? 'COCKPIT FREE LOOK' : _cameraMode == 'PHOTO KEYS' ? 'PHOTO MODE · ARROW INPUT' : 'PHOTO MODE · MOUSE INPUT';
    return _card(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.crop_free, color: accent, size: 15),
            const SizedBox(width: 7),
            Expanded(child: Text(modeLabel, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .7))),
            Text(enabled ? 'CONTROL READY' : 'DISARMED', style: TextStyle(color: enabled ? green : muted, fontSize: 8, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 9),
          CameraTouchpad(
            enabled: enabled,
            onStart: _cameraGestureStart,
            onEnd: _cameraGestureEnd,
            onPan: _mouseMove,
            onPinch: _onPinchZoom,
          ),
          const SizedBox(height: 8),
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.touch_app_outlined, size: 13, color: muted),
            SizedBox(width: 5),
            Text('1 jari: arah kamera     2 jari: zoom', style: TextStyle(color: muted, fontSize: 9)),
          ]),
        ],
      ),
    );
  }

  Widget _buildZoomBar() {
    return _card(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        const Icon(Icons.zoom_out, color: muted, size: 18),
        const SizedBox(width: 7),
        const Expanded(child: Text('PINCH TO ZOOM', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .8))),
        IconButton(visualDensity: VisualDensity.compact, onPressed: _inputEnabled ? () => _mouseWheel(-120) : null, icon: const Icon(Icons.remove_circle_outline, size: 21)),
        IconButton(visualDensity: VisualDensity.compact, onPressed: _inputEnabled ? () => _mouseWheel(120) : null, icon: const Icon(Icons.add_circle_outline, size: 21)),
      ]),
    );
  }

  Widget _buildMotionPanel() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(color: const Color(0xFF183653), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.screen_rotation_alt, color: accent, size: 18),
            ),
            const SizedBox(width: 9),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('PHONE MOTION', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900)),
              SizedBox(height: 2),
              Text('Putar HP untuk mengarahkan kamera game', style: TextStyle(color: muted, fontSize: 9)),
            ])),
            Switch.adaptive(value: _gyroEnabled, activeColor: green, onChanged: _toggleGyro),
          ]),
          const SizedBox(height: 5),
          Row(children: [
            Expanded(child: Text(_gyroMessage, style: TextStyle(color: _calibrating ? accent : muted, fontSize: 9))),
            OutlinedButton.icon(
              onPressed: _gyroEnabled ? _startCalibration : null,
              icon: const Icon(Icons.center_focus_strong, size: 13),
              label: const Text('RECENTER', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(foregroundColor: accent, side: const BorderSide(color: line), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
            ),
          ]),
          const SizedBox(height: 5),
          Row(children: [
            const Text('SENSITIVITY', style: TextStyle(color: muted, fontSize: 8, fontWeight: FontWeight.bold)),
            Expanded(child: Slider(value: _gyroSensitivity, min: .4, max: 4, divisions: 18, onChanged: (v) => setState(() => _gyroSensitivity = v))),
            SizedBox(width: 31, child: Text('${_gyroSensitivity.toStringAsFixed(1)}x', textAlign: TextAlign.end, style: const TextStyle(color: muted, fontSize: 9))),
          ]),
          if (_cameraMode == 'COCKPIT')
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF10271F), borderRadius: BorderRadius.circular(9), border: Border.all(color: const Color(0xFF24543F))),
              child: const Row(children: [
                Icon(Icons.mouse, color: green, size: 14),
                SizedBox(width: 7),
                Expanded(child: Text('Cockpit: Right Mouse Button ditahan otomatis selama motion control aktif.', style: TextStyle(color: Color(0xFFB7EAD4), fontSize: 8, height: 1.3))),
              ]),
            ),
          if (_cameraMode == 'PHOTO KEYS')
            const Text('Photo Keys: gerakan HP diterjemahkan menjadi tombol panah. Responsnya bertahap, bukan analog.', style: TextStyle(color: muted, fontSize: 8, height: 1.3)),
          const SizedBox(height: 6),
          Row(children: [
            _invertButton('INVERT X', _invertX, () => setState(() => _invertX = !_invertX)),
            const SizedBox(width: 7),
            _invertButton('INVERT Y', _invertY, () => setState(() => _invertY = !_invertY)),
          ]),
        ],
      ),
    );
  }

  Widget _invertButton(String label, bool active, VoidCallback action) {
    return Expanded(child: OutlinedButton(
      onPressed: action,
      style: OutlinedButton.styleFrom(foregroundColor: active ? accent : muted, side: BorderSide(color: active ? accent : line), padding: const EdgeInsets.symmetric(vertical: 6)),
      child: Text('$label ${active ? "ON" : "OFF"}', style: const TextStyle(fontSize: 8)),
    ));
  }

  Widget _buildQuickActions() {
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('CAMERA SHORTCUTS', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .8)),
        const SizedBox(height: 9),
        Row(children: [
          Expanded(child: _actionTile('PHOTO MODE', Icons.camera_alt, 'P')),
          const SizedBox(width: 7),
          Expanded(child: _actionTile('RECENTER', Icons.center_focus_weak, 'R')),
        ]),
        const SizedBox(height: 7),
        Row(children: [
          Expanded(child: _actionTile('CAPTURE', Icons.photo_camera, 'ENTER')),
          const SizedBox(width: 7),
          Expanded(child: _actionTile('HIDE UI', Icons.visibility_off, 'F1')),
        ]),
        const SizedBox(height: 7),
        _actionTile('EXIT CAMERA MODE', Icons.close, 'ESC'),
      ]),
    );
  }

  Widget _actionTile(String label, IconData icon, String key) {
    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: _inputEnabled ? () => _keyTap(key) : null,
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold)),
        style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: Colors.white, side: const BorderSide(color: line), padding: const EdgeInsets.symmetric(horizontal: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
    );
  }

  Widget _buildFooter() {
    return Row(
      children: [
        const Icon(Icons.desktop_windows, size: 12, color: muted),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            _activeWindow,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: muted, fontSize: 9),
          ),
        ),
        Text(
          _armed ? 'CAMERA ACTIVE' : 'SAFE MODE',
          style: TextStyle(
            color: _armed ? green : muted,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: .7,
          ),
        ),
      ],
    );
  }
}


class BridgeConnectionPage extends StatefulWidget {
  const BridgeConnectionPage({
    super.key,
    required this.initialHost,
    required this.initialPort,
    required this.initialToken,
  });

  final String initialHost;
  final String initialPort;
  final String initialToken;

  @override
  State<BridgeConnectionPage> createState() => _BridgeConnectionPageState();
}

class _BridgeConnectionPageState extends State<BridgeConnectionPage> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _token;
  final FocusNode _tokenFocus = FocusNode();
  bool _showToken = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.initialHost);
    _port = TextEditingController(text: widget.initialPort);
    _token = TextEditingController(text: widget.initialToken);

    // Give Android's soft keyboard a normal, full-screen TextField target.
    // Autofocus the token because this is the value most users need to paste.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tokenFocus.requestFocus();
    });
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    if (value == null || value.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard tidak berisi teks token.')),
      );
      return;
    }
    _token.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session token berhasil ditempel.')),
      );
    }
  }

  void _submit() {
    final host = _host.text.trim();
    final port = _port.text.trim();
    final token = _token.text.trim();

    if (host.isEmpty || token.isEmpty || int.tryParse(port) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IP PC, port, dan session token wajib diisi.')),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.of(context).pop({
      'host': host,
      'port': port,
      'token': token,
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: Colors.white,
        title: const Text(
          'CONNECT TO WINDOWS BRIDGE',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 36),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wifi_tethering, size: 42, color: accent),
                      const SizedBox(height: 10),
                      const Text(
                        'Hubungkan HP ke Windows Bridge',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Pastikan HP dan PC berada pada jaringan Wi-Fi yang sama. '
                        'IP dan session token ditampilkan pada jendela Bridge di PC.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted, fontSize: 12, height: 1.45),
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        controller: _host,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'IP address PC',
                          hintText: '192.168.1.10',
                          prefixIcon: Icon(Icons.computer),
                        ),
                        onSubmitted: (_) => _tokenFocus.requestFocus(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'WebSocket port',
                          hintText: '8765',
                          prefixIcon: Icon(Icons.lan),
                        ),
                        onSubmitted: (_) => _tokenFocus.requestFocus(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _token,
                        focusNode: _tokenFocus,
                        autofocus: false,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.done,
                        textCapitalization: TextCapitalization.none,
                        autocorrect: false,
                        enableSuggestions: false,
                        obscureText: !_showToken,
                        decoration: InputDecoration(
                          labelText: 'Session token',
                          hintText: 'Paste token dari jendela Bridge',
                          prefixIcon: const Icon(Icons.key),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Paste token',
                                onPressed: _pasteToken,
                                icon: const Icon(Icons.content_paste),
                              ),
                              IconButton(
                                tooltip: _showToken ? 'Hide token' : 'Show token',
                                onPressed: () => setState(() => _showToken = !_showToken),
                                icon: Icon(
                                  _showToken ? Icons.visibility_off : Icons.visibility,
                                ),
                              ),
                            ],
                          ),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _submit,
                          icon: const Icon(Icons.link),
                          label: const Text(
                            'CONNECT',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('CANCEL'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CameraTouchpad extends StatefulWidget {
  const CameraTouchpad({
    super.key,
    required this.enabled,
    required this.onStart,
    required this.onEnd,
    required this.onPan,
    required this.onPinch,
  });

  final bool enabled;
  final ValueChanged<int> onStart;
  final VoidCallback onEnd;
  final void Function(double dx, double dy) onPan;
  final ValueChanged<int> onPinch;

  @override
  State<CameraTouchpad> createState() => _CameraTouchpadState();
}

class _CameraTouchpadState extends State<CameraTouchpad> {
  double _lastScale = 1.0;
  double _pinchAccumulator = 0;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.enabled ? 1 : .42,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: GestureDetector(
            onScaleStart: widget.enabled ? (details) {
              _lastScale = 1.0;
              _pinchAccumulator = 0;
              widget.onStart(details.pointerCount);
            } : null,
            onScaleUpdate: widget.enabled ? (details) {
              if (details.pointerCount >= 2) {
                _pinchAccumulator += details.scale - _lastScale;
                while (_pinchAccumulator >= .045) {
                  widget.onPinch(1);
                  _pinchAccumulator -= .045;
                }
                while (_pinchAccumulator <= -.045) {
                  widget.onPinch(-1);
                  _pinchAccumulator += .045;
                }
              } else {
                widget.onPan(details.focalPointDelta.dx * 2.0, details.focalPointDelta.dy * 2.0);
              }
              _lastScale = details.scale;
            } : null,
            onScaleEnd: widget.enabled ? (_) => widget.onEnd() : null,
            child: CustomPaint(
              painter: CameraViewfinderPainter(),
              child: Stack(children: [
                Positioned(top: 11, left: 11, child: _tag('CAM', green)),
                Positioned(top: 11, right: 11, child: _tag('2-FINGER ZOOM', accent)),
                const Center(child: Icon(Icons.center_focus_strong, size: 42, color: Color(0xCCFFFFFF))),
                const Positioned(bottom: 13, left: 0, right: 0, child: Text('CAMERA CONTROL SURFACE', textAlign: TextAlign.center, style: TextStyle(color: Color(0xAAFFFFFF), fontSize: 8, letterSpacing: 1.8, fontWeight: FontWeight.w800))),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(color: Colors.black.withOpacity(.45), borderRadius: BorderRadius.circular(5)),
      child: Text(text, style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: .8)),
    );
  }
}

class CameraViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final background = Paint()..shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF1B3048), Color(0xFF0B1523), Color(0xFF14243A)],
    ).createShader(rect);
    canvas.drawRect(rect, background);

    final grid = Paint()..color = Colors.white.withOpacity(.09)..strokeWidth = 1;
    for (int i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final frame = Paint()..color = Colors.white.withOpacity(.2)..style = PaintingStyle.stroke..strokeWidth = 1;
    canvas.drawRect(Rect.fromLTWH(8, 8, size.width - 16, size.height - 16), frame);

    final center = Offset(size.width / 2, size.height / 2);
    final reticle = Paint()..color = Colors.white.withOpacity(.7)..style = PaintingStyle.stroke..strokeWidth = 1.2;
    canvas.drawCircle(center, 22, reticle);
    canvas.drawLine(Offset(center.dx - 34, center.dy), Offset(center.dx - 13, center.dy), reticle);
    canvas.drawLine(Offset(center.dx + 13, center.dy), Offset(center.dx + 34, center.dy), reticle);
    canvas.drawLine(Offset(center.dx, center.dy - 34), Offset(center.dx, center.dy - 13), reticle);
    canvas.drawLine(Offset(center.dx, center.dy + 13), Offset(center.dx, center.dy + 34), reticle);
  }

  @override
  bool shouldRepaint(covariant CameraViewfinderPainter oldDelegate) => false;
}

class HoldButton extends StatelessWidget {
  const HoldButton({
    super.key,
    required this.label,
    required this.enabled,
    required this.onDown,
    required this.onUp,
    this.icon,
  });

  final String label;
  final bool enabled;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : .4,
      child: GestureDetector(
        onTapDown: enabled ? (_) => onDown() : null,
        onTapUp: enabled ? (_) => onUp() : null,
        onTapCancel: enabled ? onUp : null,
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            color: panel2,
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: accent),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
