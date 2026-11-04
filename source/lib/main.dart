import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
    const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
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
  String _mode = 'PHOTO';
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
    if (mounted) {
      setState(() {
        _armed = false;
        _heldKeys.clear();
        _movementKeys.clear();
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
        _showMessage('Hubungkan Bridge dan tekan ARM sebelum mengaktifkan gyro.');
        return;
      }
      try {
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
          _gyroMessage = 'Gyro aktif · tahan HP stabil lalu kalibrasi';
          _lastGyroTime = null;
        });
      } catch (error) {
        _showMessage('Gagal mengaktifkan gyro: $error');
      }
    } else {
      _stopGyro();
    }
  }

  void _stopGyro() {
    _gyroSub?.cancel();
    _gyroSub = null;
    if (mounted) {
      setState(() {
        _gyroEnabled = false;
        _calibrating = false;
        _lastGyroTime = null;
        _gyroMessage = 'Gyro nonaktif';
      });
    }
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
      if (_gyroSamples >= 60) {
        _gyroBiasX = _gyroSumX / _gyroSamples;
        _gyroBiasY = _gyroSumY / _gyroSamples;
        if (mounted) {
          setState(() {
            _calibrating = false;
            _gyroMessage = 'Kalibrasi selesai';
          });
        }
      }
      return;
    }

    if (previous == null || !_gyroEnabled || !_armed) return;
    final dt = now.difference(previous).inMicroseconds / 1000000.0;
    if (dt <= 0 || dt > 0.08) return;

    // Landscape mapping: device X/Y angular velocity is converted to relative mouse movement.
    final yaw = (event.x - _gyroBiasX) * (_invertX ? -1 : 1);
    final pitch = (event.y - _gyroBiasY) * (_invertY ? -1 : 1);
    final dx = yaw * dt * 260 * _gyroSensitivity;
    final dy = -pitch * dt * 260 * _gyroSensitivity;
    final ix = dx.round().clamp(-120, 120);
    final iy = dy.round().clamp(-120, 120);

    if (ix != 0 || iy != 0) {
      _send({'cmd': 'mouse_move', 'dx': ix, 'dy': iy});
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
    final inputEnabled = _connected && _armed;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 10, child: _buildMovementPanel(inputEnabled)),
                    const SizedBox(width: 10),
                    Expanded(flex: 12, child: _buildCameraPanel(inputEnabled)),
                    const SizedBox(width: 10),
                    Expanded(flex: 8, child: _buildActionsPanel(inputEnabled)),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final isConnected = _connected;
    final statusColor = _armed ? green : (isConnected ? accent : red);

    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(0xFF173657),
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.camera_alt_rounded, color: Colors.white),
        ),
        const SizedBox(width: 9),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FORZA MOBILE CAM',
                style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2),
              ),
              Text(
                'WIRELESS CAMERA CONTROLLER · STAGE 2',
                style: TextStyle(fontSize: 9, color: muted, letterSpacing: .7),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(.12),
            border: Border.all(color: statusColor.withOpacity(.55)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                _connectionText,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _connecting
              ? null
              : (isConnected ? () => _disconnect() : _showConnectionDialog),
          icon: Icon(isConnected ? Icons.link_off : Icons.link, size: 16),
          label: Text(isConnected ? 'DISCONNECT' : 'CONNECT'),
        ),
        const SizedBox(width: 6),
        FilledButton.icon(
          onPressed: isConnected && !_armed ? _arm : null,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF176344)),
          icon: const Icon(Icons.power_settings_new, size: 16),
          label: const Text('ARM'),
        ),
        const SizedBox(width: 6),
        FilledButton.icon(
          onPressed: isConnected ? _emergencyStop : null,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8A2934)),
          icon: const Icon(Icons.stop_circle_outlined, size: 16),
          label: const Text('STOP'),
        ),
      ],
    );
  }

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(12)}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: line),
      ),
      child: child,
    );
  }

  Widget _sectionTitle(String title, {String? trailing}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: .7,
            ),
          ),
        ),
        if (trailing != null)
          Text(trailing, style: const TextStyle(color: muted, fontSize: 10)),
      ],
    );
  }

  Widget _buildMovementPanel(bool inputEnabled) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('MOVEMENT', trailing: 'WASD'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 5,
            children: [
              _modeChip('PHOTO'),
              _modeChip('COCKPIT'),
              _modeChip('DRONE'),
            ],
          ),
          const SizedBox(height: 7),
          Expanded(
            child: Center(
              child: AnalogJoystick(
                enabled: inputEnabled,
                onChanged: _updateMovement,
                size: 164,
              ),
            ),
          ),
          const Text(
            'LEFT STICK · MOVE CAMERA',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 9, letterSpacing: .8),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: HoldButton(
                  label: 'E  UP',
                  icon: Icons.keyboard_arrow_up,
                  enabled: inputEnabled,
                  onDown: () => _keyDown('E'),
                  onUp: () => _keyUp('E'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: HoldButton(
                  label: 'Q  DOWN',
                  icon: Icons.keyboard_arrow_down,
                  enabled: inputEnabled,
                  onDown: () => _keyDown('Q'),
                  onUp: () => _keyUp('Q'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeChip(String mode) {
    final selected = _mode == mode;
    return ChoiceChip(
      label: Text(mode, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() => _mode = mode),
      selectedColor: const Color(0xFF1D5A91),
      backgroundColor: bg,
      side: BorderSide(color: selected ? accent : line),
      labelStyle: TextStyle(color: selected ? Colors.white : muted),
    );
  }

  Widget _buildCameraPanel(bool inputEnabled) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('CAMERA LOOK', trailing: 'MOUSE RELATIVE'),
          const SizedBox(height: 8),
          Expanded(
            child: CameraTouchpad(
              enabled: inputEnabled,
              onDelta: _mouseMove,
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              const Icon(Icons.tune, size: 15, color: muted),
              const SizedBox(width: 6),
              const Text('Mouse sensitivity', style: TextStyle(fontSize: 10, color: muted)),
              Expanded(
                child: Slider(
                  value: _mouseSensitivity,
                  min: .25,
                  max: 3,
                  divisions: 11,
                  onChanged: (v) => setState(() => _mouseSensitivity = v),
                ),
              ),
              SizedBox(
                width: 32,
                child: Text('${_mouseSensitivity.toStringAsFixed(1)}x',
                    style: const TextStyle(fontSize: 10, color: muted)),
              ),
            ],
          ),
          const Divider(color: line, height: 10),
          Row(
            children: [
              const Icon(Icons.screen_rotation_alt, size: 17, color: accent),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('GYROSCOPE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              Switch.adaptive(
                value: _gyroEnabled,
                activeColor: green,
                onChanged: _toggleGyro,
              ),
              IconButton(
                tooltip: 'Calibrate gyro',
                onPressed: _gyroEnabled ? _startCalibration : null,
                icon: const Icon(Icons.center_focus_strong, size: 19),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(_gyroMessage, style: const TextStyle(color: muted, fontSize: 9)),
              ),
              TextButton(
                onPressed: _gyroEnabled ? () => setState(() => _invertX = !_invertX) : null,
                child: Text('INV X ${_invertX ? "ON" : "OFF"}', style: const TextStyle(fontSize: 9)),
              ),
              TextButton(
                onPressed: _gyroEnabled ? () => setState(() => _invertY = !_invertY) : null,
                child: Text('INV Y ${_invertY ? "ON" : "OFF"}', style: const TextStyle(fontSize: 9)),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Gyro gain', style: TextStyle(color: muted, fontSize: 9)),
              Expanded(
                child: Slider(
                  value: _gyroSensitivity,
                  min: .3,
                  max: 4,
                  divisions: 18,
                  onChanged: (v) => setState(() => _gyroSensitivity = v),
                ),
              ),
              SizedBox(
                width: 30,
                child: Text('${_gyroSensitivity.toStringAsFixed(1)}x',
                    style: const TextStyle(color: muted, fontSize: 9)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionsPanel(bool inputEnabled) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('QUICK ACTIONS'),
          const SizedBox(height: 9),
          _actionButton('OPEN PHOTO MODE', Icons.camera, inputEnabled, () => _keyTap('P')),
          const SizedBox(height: 6),
          _actionButton('RESET / RECENTER', Icons.center_focus_weak, inputEnabled, () => _keyTap('R')),
          const SizedBox(height: 6),
          _actionButton('CAPTURE PHOTO', Icons.photo_camera, inputEnabled, () => _keyTap('ENTER')),
          const SizedBox(height: 6),
          _actionButton('HIDE / SHOW UI', Icons.visibility_off, inputEnabled, () => _keyTap('F1')),
          const SizedBox(height: 6),
          _actionButton('EXIT MODE', Icons.close, inputEnabled, () => _keyTap('ESC')),
          const Divider(color: line, height: 18),
          _sectionTitle('ZOOM'),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: _roundAction(
                  icon: Icons.remove,
                  label: 'OUT',
                  enabled: inputEnabled,
                  onTap: () => _mouseWheel(-120),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _roundAction(
                  icon: Icons.add,
                  label: 'IN',
                  enabled: inputEnabled,
                  onTap: () => _mouseWheel(120),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          HoldButton(
            label: 'HOLD SHIFT · SLOW',
            icon: Icons.slow_motion_video,
            enabled: inputEnabled,
            onDown: () => _keyDown('SHIFT'),
            onUp: () => _keyUp('SHIFT'),
          ),
          const SizedBox(height: 7),
          HoldButton(
            label: 'HOLD RIGHT MOUSE',
            icon: Icons.mouse,
            enabled: inputEnabled,
            onDown: () => _mouseButtonDown('right'),
            onUp: () => _mouseButtonUp('right'),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: line),
            ),
            child: Text(
              _mode == 'PHOTO'
                  ? 'Photo Mode: aktifkan mode kamera di game, lalu gunakan joystick dan touchpad.'
                  : _mode == 'COCKPIT'
                      ? 'Cockpit: aktifkan Mouse Free Look di game. Gyro dapat digunakan untuk look-around.'
                      : 'Drone: aktifkan Drone Mode di game terlebih dahulu. Mapping perlu diuji pada instalasi kamu.',
              style: const TextStyle(color: muted, fontSize: 9, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    String label,
    IconData icon,
    bool enabled,
    VoidCallback onTap,
  ) {
    return SizedBox(
      height: 39,
      child: OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _roundAction({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return OutlinedButton(
      onPressed: enabled ? onTap : null,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 8),
        side: const BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 17),
          Text(label, style: const TextStyle(fontSize: 9)),
        ],
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
          _armed ? 'INPUT ENABLED' : 'INPUT DISARMED',
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

class AnalogJoystick extends StatefulWidget {
  const AnalogJoystick({
    super.key,
    required this.enabled,
    required this.onChanged,
    this.size = 160,
  });

  final bool enabled;
  final ValueChanged<Offset> onChanged;
  final double size;

  @override
  State<AnalogJoystick> createState() => _AnalogJoystickState();
}

class _AnalogJoystickState extends State<AnalogJoystick> {
  Offset _value = Offset.zero;

  void _update(Offset local, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final delta = local - center;
    final maxRadius = math.min(size.width, size.height) * .36;
    final distance = delta.distance;
    final clamped = distance > maxRadius
        ? delta / distance * maxRadius
        : delta;
    setState(() => _value = clamped / maxRadius);
    widget.onChanged(_value);
  }

  void _reset() {
    setState(() => _value = Offset.zero);
    widget.onChanged(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.enabled ? 1 : .4,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            onPanStart: widget.enabled
                ? (details) => _update(details.localPosition, constraints.biggest)
                : null,
            onPanUpdate: widget.enabled
                ? (details) => _update(details.localPosition, constraints.biggest)
                : null,
            onPanEnd: widget.enabled ? (_) => _reset() : null,
            onPanCancel: widget.enabled ? _reset : null,
            child: CustomPaint(
              painter: JoystickPainter(value: _value),
            ),
          ),
        ),
      ),
    );
  }
}

class JoystickPainter extends CustomPainter {
  JoystickPainter({required this.value});
  final Offset value;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * .44;
    final outer = Paint()..color = const Color(0xFF1B2B41);
    final border = Paint()
      ..color = const Color(0xFF49617F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final guide = Paint()
      ..color = const Color(0xFF31455F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, radius, outer);
    canvas.drawCircle(center, radius, border);
    canvas.drawCircle(center, radius * .66, guide);
    canvas.drawLine(Offset(center.dx - radius, center.dy),
        Offset(center.dx + radius, center.dy), guide);
    canvas.drawLine(Offset(center.dx, center.dy - radius),
        Offset(center.dx, center.dy + radius), guide);

    final knobCenter = center + value * radius * .72;
    final knobPaint = Paint()..color = accent;
    final knobShadow = Paint()..color = Colors.black.withOpacity(.35);
    canvas.drawCircle(knobCenter.translate(0, 3), radius * .31, knobShadow);
    canvas.drawCircle(knobCenter, radius * .30, knobPaint);
    canvas.drawCircle(
      knobCenter,
      radius * .30,
      Paint()
        ..color = const Color(0xFFB9DCFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant JoystickPainter oldDelegate) =>
      oldDelegate.value != value;
}

class CameraTouchpad extends StatelessWidget {
  const CameraTouchpad({
    super.key,
    required this.enabled,
    required this.onDelta,
  });

  final bool enabled;
  final void Function(double dx, double dy) onDelta;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : .4,
      child: GestureDetector(
        onPanUpdate: enabled
            ? (details) => onDelta(details.delta.dx * 2.0, details.delta.dy * 2.0)
            : null,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: const Color(0xFF536D8C), style: BorderStyle.solid),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF14243A), Color(0xFF0D1726)],
            ),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.threed_rotation, size: 30, color: accent),
              SizedBox(height: 7),
              Text('DRAG TO LOOK', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1, fontSize: 11)),
              SizedBox(height: 4),
              Text('RIGHT TOUCHPAD', style: TextStyle(color: muted, fontSize: 9)),
            ],
          ),
        ),
      ),
    );
  }
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
