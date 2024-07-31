library frame_sdk_flutter;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'bluetooth.dart';
import 'files.dart';
import 'library_functions.dart';
import 'package:logging/logging.dart';

class Frame {
  final Bluetooth bluetooth;
  late final Files files;
  final Logger logger = Logger('Frame');

  Frame() : bluetooth = Bluetooth() {
    files = Files(this);
  }

  Future<void> session(Future<void> Function(Frame frame) action, {bool? debugMode}) async {
    try {
      await ensureConnected(debugMode: debugMode);
      await action(this);
    } finally {
      await bluetooth.disconnect();
    }
  }

  Future<void> ensureConnected({bool? debugMode}) async {
    if (!await bluetooth.isConnected()) {
      await bluetooth.connect();
      bluetooth.printDebugging = debugMode ?? false;
      await bluetooth.sendBreakSignal();
      await injectAllLibraryFunctions();
      await runLua(
          "frame.time.utc(${DateTime.now().millisecondsSinceEpoch ~/ 1000});frame.time.zone('${DateTime.now().timeZoneOffset.inHours}:${DateTime.now().timeZoneOffset.inMinutes % 60}')",
          checked: true);
    }
  }

  Future<String> evaluate(String luaExpression) async {
    await ensureConnected();
    return await runLua("prntLng(tostring($luaExpression))",
            awaitPrint: true) ??
        "";
  }

  Future<String?> runLua(String luaString,
      {bool awaitPrint = false,
      bool checked = false,
      Duration? timeout}) async {
    await ensureConnected();
    luaString =
        luaString.replaceAllMapped(RegExp(r'\bprint\('), (match) => 'prntLng(');

    if (luaString.length <= await bluetooth.maxLuaPayload()) {
      if (checked && !awaitPrint) {
        luaString += ";print(\"+\")";
        if (luaString.length <= await bluetooth.maxLuaPayload()) {
          final result = await bluetooth.sendLua(luaString,
              awaitPrint: true, timeout: timeout);
          if (result != "+") {
            throw Exception("Lua did not run successfully: $result");
          }
          return null;
        }
      } else {
        return await bluetooth.sendLua(luaString,
            awaitPrint: awaitPrint, timeout: timeout);
      }
    }

    return await sendLongLua(luaString,
        awaitPrint: awaitPrint, checked: checked, timeout: timeout);
  }

  Future<String?> sendLongLua(String string,
      {bool awaitPrint = false,
      bool checked = false,
      Duration? timeout}) async {
    await ensureConnected();

    final randomName = String.fromCharCodes(
        List.generate(4, (_) => Random().nextInt(26) + 97));

    await files.writeFile("/$randomName.lua", utf8.encode(string),
        checked: true);
    String? response;
    if (awaitPrint) {
      response = await bluetooth.sendLua("require(\"$randomName\")",
          awaitPrint: true, timeout: timeout);
    } else if (checked) {
      response = await bluetooth.sendLua(
          "require(\"$randomName\");print('done')",
          awaitPrint: true,
          timeout: timeout);
      if (response != "done") {
        throw Exception("require() did not return 'done': $response");
      }
      response = null;
    } else {
      response = await bluetooth.sendLua("require(\"$randomName\")");
    }
    await files.deleteFile("/$randomName.lua");
    return response;
  }

  Future<int> getBatteryLevel() async {
    await ensureConnected();
    final response = await bluetooth.sendLua("print(frame.battery_level())",
        awaitPrint: true);
    return int.parse(response ?? "-1");
  }

  Future<void> sleep(double? seconds) async {
    await ensureConnected();
    if (seconds == null) {
      await runLua("frame.sleep()");
    } else {
      await runLua("frame.sleep($seconds)");
    }
  }

  Future<void> stayAwake(bool value) async {
    await ensureConnected();
    await runLua("frame.stay_awake(${value.toString().toLowerCase()})",
        checked: true);
  }

  Future<void> injectLibraryFunction(
      String name, String function, String version) async {
    await ensureConnected();

    final exists =
        await bluetooth.sendLua("print($name ~= nil)", awaitPrint: true);
    if (bluetooth.printDebugging) {
      logger.info("Function $name exists: $exists");
    }
    if (exists != "true") {
      final fileExists = await files.fileExists("/lib-$version/$name.lua");
      if (bluetooth.printDebugging) {
        logger.info("File /lib-$version/$name.lua exists: $fileExists");
      }

      if (fileExists) {
        final response = await bluetooth.sendLua(
            "require(\"lib-$version/$name\");print(\"l\")",
            awaitPrint: true);
        if (response == "l") {
          return;
        }
      }

      if (bluetooth.printDebugging) {
        logger.info("Writing file /lib-$version/$name.lua");
      }
      await files.writeFile("/lib-$version/$name.lua", utf8.encode(function),
          checked: true);

      if (bluetooth.printDebugging) {
        logger.info("Requiring lib-$version/$name");
      }
      final response = await bluetooth.sendLua(
          "require(\"lib-$version/$name\");print(\"l\")",
          awaitPrint: true);
      if (response != "l") {
        throw Exception("Error injecting library function: $response");
      }
    }
  }

  Future<void> injectAllLibraryFunctions() async {
    final libraryVersion =
        libraryFunctions.hashCode.toRadixString(35).substring(0, 6);

    await ensureConnected();
    final response = await bluetooth.sendLua(
        "frame.file.mkdir(\"lib-$libraryVersion\");print(\"c\")",
        awaitPrint: true);
    if (response == "c") {
      if (bluetooth.printDebugging) {
        logger.info("Created lib directory");
      }
    } else {
      if (bluetooth.printDebugging) {
        logger.info("Did not create lib directory: $response");
      }
    }
    await injectLibraryFunction("prntLng", libraryFunctions, libraryVersion);
  }

  String escapeLuaString(String string) {
    return string
        .replaceAll("\\", "\\\\")
        .replaceAll("\n", "\\n")
        .replaceAll("\r", "\\r")
        .replaceAll("\t", "\\t")
        .replaceAll("\"", "\\\"")
        .replaceAll("[", "[")
        .replaceAll("]", "]");
  }

  Future<void> runOnWake({String? luaScript, void Function()? callback}) async {
    if (callback != null) {
      bluetooth.registerDataResponseHandler(
          _FRAME_WAKE_PREFIX, (data) => callback());
    } else {
      bluetooth.registerDataResponseHandler(_FRAME_WAKE_PREFIX, null);
    }

    if (luaScript != null && callback != null) {
      await files.writeFile("main.lua",
          "frame.bluetooth.send('\\x${_FRAME_WAKE_PREFIX.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join('\\x')}')",
          checked: true);
    } else if (luaScript == null && callback != null) {
      await files.writeFile("main.lua",
          "frame.bluetooth.send('\\x${_FRAME_WAKE_PREFIX.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join('\\x')}')",
          checked: true);
    } else if (luaScript != null && callback == null) {
      await files.writeFile("main.lua", utf8.encode(luaScript), checked: true);
    } else {
      await files.deleteFile("main.lua");
    }
  }

  int getCharCodeFromStringAtPos(String string, int pos) {
    return string.codeUnitAt(pos);
  }
}

const _FRAME_WAKE_PREFIX = '\x03';