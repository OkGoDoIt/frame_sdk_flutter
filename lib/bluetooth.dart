import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:logging/logging.dart';

final _log = Logger("Bluetooth");

const _allowedDeviceNames = ["Frame", "Frame Update", "DFUTarg"];

const _frameDataPrefix = 1;
const _frameLongTextPrefix = 10;
const _frameLongTextEndPrefix = 11;
const _frameLongDataPrefix = 1;
const _frameLongDataEndPrefix = 2;

const _frameTapPrefix = [0x04];
const _frameMicDataPrefix = [0x05];

class BrilliantBluetoothException implements Exception {
  final String msg;
  const BrilliantBluetoothException(this.msg);
  @override
  String toString() => 'BrilliantBluetoothException: $msg';
}

enum BrilliantConnectionState {
  connected,
  dfuConnected,
  disconnected,
}

class BrilliantScannedDevice {
  BluetoothDevice device;
  int? rssi;

  BrilliantScannedDevice({
    required this.device,
    required this.rssi,
  });
}

class Bluetooth {
  static final Guid _SERVICE_UUID =
      Guid("7a230001-5475-a6a4-654c-8431f6ad49c4");
  static final Guid _TX_CHARACTERISTIC_UUID =
      Guid("7a230002-5475-a6a4-654c-8431f6ad49c4");
  static final Guid _RX_CHARACTERISTIC_UUID =
      Guid("7a230003-5475-a6a4-654c-8431f6ad49c4");

  bool printDebugging = false;
  Duration defaultTimeout = const Duration(seconds: 10);

  BluetoothDevice? _btleClient;
  BluetoothCharacteristic? _txCharacteristic;
  Function()? _userDisconnectHandler = () {};
  final int _maxReceiveBuffer = 10 * 1024 * 1024;

  String _lastPrintResponse = "";
  Uint8List? _ongoingPrintResponse;
  int? _ongoingPrintResponseChunkCount;
  late Completer<void> _printResponseEvent;
  Function(String)? _userPrintResponseHandler;

  Uint8List _lastDataResponse = Uint8List(0);
  Uint8List? _ongoingDataResponse;
  int? _ongoingDataResponseChunkCount;
  late Completer<void> _dataResponseEvent;
  final Map<List<int>?, Function(Uint8List)> _userDataResponseHandlers = {};

  Bluetooth() {
    _printResponseEvent = Completer<void>();
    _dataResponseEvent = Completer<void>();
  }

  void _disconnectHandler() {
    _userDisconnectHandler?.call();
    _reset();
  }

  void _reset() {
    _btleClient = null;
    _txCharacteristic = null;
    _userDisconnectHandler = () {};
    _ongoingPrintResponse = null;
    _ongoingPrintResponseChunkCount = null;
    _ongoingDataResponse = null;
    _ongoingDataResponseChunkCount = null;
  }

  Future<void> _notificationHandler(Uint8List data) async {
    if (data[0] == _frameLongTextPrefix) {
      if (_ongoingPrintResponse == null ||
          _ongoingPrintResponseChunkCount == null) {
        _ongoingPrintResponse = Uint8List(0);
        _ongoingPrintResponseChunkCount = 0;
        if (printDebugging) {
          _log.info("Starting receiving new long printed string");
        }
      }
      _ongoingPrintResponse =
          Uint8List.fromList(_ongoingPrintResponse! + data.sublist(1));
      _ongoingPrintResponseChunkCount = _ongoingPrintResponseChunkCount! + 1;
      if (printDebugging) {
        _log.info(
            "Received chunk #$_ongoingPrintResponseChunkCount: ${utf8.decode(data.sublist(1))}");
      }
      if (_ongoingPrintResponse!.length > _maxReceiveBuffer) {
        throw BrilliantBluetoothException(
            "Buffered received long printed string is more than $_maxReceiveBuffer bytes");
      }
    } else if (data[0] == _frameLongTextEndPrefix) {
      final totalExpectedChunkCount = int.parse(utf8.decode(data.sublist(1)));
      if (printDebugging) {
        _log.info(
            "Received final string chunk count: $totalExpectedChunkCount");
      }
      if (_ongoingPrintResponseChunkCount != totalExpectedChunkCount) {
        throw BrilliantBluetoothException(
            "Chunk count mismatch in long received string (expected $totalExpectedChunkCount, got $_ongoingPrintResponseChunkCount)");
      }
      _lastPrintResponse = utf8.decode(_ongoingPrintResponse!);
      _printResponseEvent.complete();
      _printResponseEvent = Completer<void>(); // Re-initialize Completer
      _ongoingPrintResponse = null;
      _ongoingPrintResponseChunkCount = null;
      if (printDebugging) {
        _log.info(
            "Finished receiving long printed string: $_lastPrintResponse");
      }
      _userPrintResponseHandler?.call(_lastPrintResponse);
    } else if (data[0] == _frameDataPrefix &&
        data[1] == _frameLongDataPrefix) {
      if (_ongoingDataResponse == null ||
          _ongoingDataResponseChunkCount == null) {
        _ongoingDataResponse = Uint8List(0);
        _ongoingDataResponseChunkCount = 0;
        _lastDataResponse = Uint8List(0);
        if (printDebugging) {
          _log.info("Starting receiving new long raw data");
        }
      }
      _ongoingDataResponse =
          Uint8List.fromList(_ongoingDataResponse! + data.sublist(2));
      _ongoingDataResponseChunkCount = _ongoingDataResponseChunkCount! + 1;
      if (printDebugging) {
        _log.info(
            "Received data chunk #$_ongoingDataResponseChunkCount: ${data.sublist(2).length} bytes");
      }
      if (_ongoingDataResponse!.length > _maxReceiveBuffer) {
        throw BrilliantBluetoothException(
            "Buffered received long raw data is more than $_maxReceiveBuffer bytes");
      }
    } else if (data[0] == _frameDataPrefix &&
        data[1] == _frameLongDataEndPrefix) {
      final totalExpectedChunkCount = int.parse(utf8.decode(data.sublist(2)));
      if (printDebugging) {
        _log.info("Received final data chunk count: $totalExpectedChunkCount");
      }
      if (_ongoingDataResponseChunkCount != totalExpectedChunkCount) {
        throw BrilliantBluetoothException(
            "Chunk count mismatch in long received data (expected $totalExpectedChunkCount, got $_ongoingDataResponseChunkCount)");
      }
      _lastDataResponse = Uint8List.fromList(_ongoingDataResponse!);
      _dataResponseEvent.complete();
      _dataResponseEvent = Completer<void>(); // Re-initialize Completer
      _ongoingDataResponse = null;
      _ongoingDataResponseChunkCount = null;
      if (printDebugging) {
        _log.info(
            "Finished receiving long raw data: ${_lastDataResponse.length} bytes");
      }
      _callDataResponseHandlers(_lastDataResponse);
    } else if (data[0] == _frameDataPrefix) {
      if (printDebugging) {
        _log.info("Received data: ${data.sublist(1).length} bytes");
      }
      _lastDataResponse = data.sublist(1);
      _dataResponseEvent.complete();
      _dataResponseEvent = Completer<void>(); // Re-initialize Completer
      _callDataResponseHandlers(data.sublist(1));
    } else {
      _lastPrintResponse = utf8.decode(data);
      if (printDebugging) {
        _log.info("Received printed string: $_lastPrintResponse");
      }
      _printResponseEvent.complete();
      _printResponseEvent = Completer<void>(); // Re-initialize Completer
      _userPrintResponseHandler?.call(_lastPrintResponse);
    }
  }

  void registerDataResponseHandler(
      String? prefix, Function(Uint8List)? handler) {
    if (handler == null) {
      _userDataResponseHandlers.remove(prefix);
    } else {
      if (prefix != null) {
        _userDataResponseHandlers[utf8.encode(prefix)] = handler;
      } else {
        _userDataResponseHandlers[Uint8List(0)] = handler;
      }
    }
  }

  void _callDataResponseHandlers(Uint8List data) {
    for (var entry in _userDataResponseHandlers.entries) {
      if (entry.key == null || _startsWith(data, entry.key!)) {
        entry.value(data.sublist(entry.key?.length ?? 0));
      }
    }
  }

  bool _startsWith(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }

  Future<void> connect(
      {bool printDebugging = false,
      Duration defaultTimeout = const Duration(seconds: 10)}) async {
    this.printDebugging = printDebugging;
    this.defaultTimeout = defaultTimeout;
    await FlutterBluePlus.startScan(
      withServices: [_SERVICE_UUID],
      timeout: defaultTimeout,
    );

    final Completer<List<ScanResult>> completer = Completer();
    final subscription = FlutterBluePlus.scanResults.listen((results) {
      if (results.isNotEmpty) {
        final filteredList = results
        .where((d) => d.advertisementData.serviceUuids.contains(_SERVICE_UUID) && _allowedDeviceNames.contains(d.advertisementData.advName))
        .toList();
        if (filteredList.isNotEmpty) {
          completer.complete(filteredList);
        }
      }
    });

    final devices = await completer.future;
    await subscription.cancel();

    devices.sort((a, b) => b.rssi.compareTo(a.rssi));

    if (devices.isEmpty) {
      throw const BrilliantBluetoothException("No Frame devices found");
    }

    final device = devices.first.device;
    _btleClient = device;

    await device.connect();
    await device.discoverServices();

    if (Platform.isAndroid) {
      await device.requestMtu(512);
    }


    final service =
        device.servicesList.firstWhere((s) => s.uuid == _SERVICE_UUID);
    _txCharacteristic = service.characteristics
        .firstWhere((c) => c.uuid == _TX_CHARACTERISTIC_UUID);

    final rxCharacteristic = service.characteristics
        .firstWhere((c) => c.uuid == _RX_CHARACTERISTIC_UUID);
    await rxCharacteristic.setNotifyValue(true);
    rxCharacteristic.onValueReceived
        .listen((data) => _notificationHandler(Uint8List.fromList(data)));
  }

  Future<void> disconnect() async {
    await _btleClient?.disconnect();
    _disconnectHandler();
  }

  Future<bool> isConnected() async {
    return await _btleClient?.connectionState.first == BluetoothConnectionState.connected;
  }
  Future<int> maxLuaPayload() async {
    final mtu = await _btleClient?.mtu.first ?? 0;
    return mtu - 3;
  }

  Future<int> maxDataPayload() async {
    final mtu = await _btleClient?.mtu.first ?? 0;
    return mtu - 4;
  }

  Future<void> _transmit(Uint8List data) async {
    if (printDebugging) {
      _log.info(data.toString());
    }
    final mtu = await maxLuaPayload();
    if (data.length > mtu) {
      throw BrilliantBluetoothException(
          "Payload length is too large: ${data.length} > $mtu");
    }

    await _txCharacteristic?.write(data, withoutResponse: true);
  }

  Future<String?> sendLua(String string,
      {bool awaitPrint = false, Duration? timeout}) async {
    if (awaitPrint) {
      _printResponseEvent = Completer<void>(); // Re-initialize Completer
    }

    await _transmit(Uint8List.fromList(utf8.encode(string)));

    if (awaitPrint) {
      return await waitForPrint(timeout);
    }
    return null;
  }

  Future<String> waitForPrint(Duration? timeout) async {
    timeout ??= defaultTimeout;

    try {
      await _printResponseEvent.future.timeout(timeout);
    } on TimeoutException {
      throw BrilliantBluetoothException(
          "Frame didn't respond with printed data (from print() or prntLng()) within ${timeout.inSeconds} seconds");
    }

    _printResponseEvent = Completer<void>(); // Re-initialize Completer
    return _lastPrintResponse;
  }

  Future<Uint8List> waitForData([Duration? timeout]) async {
    timeout ??= defaultTimeout;

    try {
      await _dataResponseEvent.future.timeout(timeout);
    } on TimeoutException {
      throw BrilliantBluetoothException(
          "Frame didn't respond with data (from frame.bluetooth.send(data)) within ${timeout.inSeconds} seconds");
    }

    _dataResponseEvent = Completer<void>(); // Re-initialize Completer
    return _lastDataResponse;
  }

  Future<Uint8List?> sendData(Uint8List data, {bool awaitData = false}) async {
    if (awaitData) {
      _dataResponseEvent = Completer<void>(); // Re-initialize Completer
    }

    await _transmit(Uint8List.fromList([_frameDataPrefix] + data));

    if (awaitData) {
      return await waitForData();
    }
    return null;
  }

  Future<void> sendResetSignal() async {
    if (!await isConnected()) {
      await connect();
    }
    await _transmit(Uint8List.fromList([0x04]));
  }

  Future<void> sendBreakSignal() async {
    if (!await isConnected()) {
      await connect();
    }
    await _transmit(Uint8List.fromList([0x03]));
  }

  static Future<void> requestPermission() async {
    try {
      await FlutterBluePlus.startScan();
      await FlutterBluePlus.stopScan();
    } catch (error) {
      _log.warning("Couldn't obtain Bluetooth permission. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Stream<BrilliantScannedDevice> scan() async* {
    try {
      _log.info("Starting to scan for devices");

      await FlutterBluePlus.startScan(
        withServices: [
          Guid('7a230001-5475-a6a4-654c-8431f6ad49c4'),
          Guid('fe59'),
        ],
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 2),
      );
    } catch (error) {
      _log.warning("Scanning failed. $error");
      throw BrilliantBluetoothException(error.toString());
    }

    yield* FlutterBluePlus.scanResults
        .where((results) => results.isNotEmpty)
        // filter by name: "Frame", "Frame Update", "Monocle" & "DFUTarg"
        .map((results) {
      ScanResult? nearestDevice;
      for (int i = 0; i < results.length; i++) {
        if (results[i].device.platformName.contains("Frame") ||
            results[i].device.platformName.contains("Monocle") ||
            results[i].device.platformName.contains("DFUTarg")) {
          if (results[i].rssi > (nearestDevice?.rssi ?? -1)) {
            nearestDevice = results[i];
          }
        }
      }

      if (nearestDevice == null) {
        throw const BrilliantBluetoothException("No Frame devices found");
      }

      _log.fine(
          "Found ${nearestDevice.device.advName} rssi: ${nearestDevice.rssi}");

      return BrilliantScannedDevice(
        device: nearestDevice.device,
        rssi: nearestDevice.rssi,
      );
    });
  }

  static Future<void> stopScan() async {
    try {
      _log.info("Stopping scan for devices");
      await FlutterBluePlus.stopScan();
    } catch (error) {
      _log.warning("Couldn't stop scanning. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }
}
