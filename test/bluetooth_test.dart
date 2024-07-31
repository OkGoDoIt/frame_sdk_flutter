import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'dart:typed_data';

import 'package:frame_sdk_flutter/bluetooth.dart';
import 'package:frame_sdk_flutter/frame_sdk_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('Bluetooth Tests', () {
    Bluetooth bluetooth = Bluetooth();
    Frame frame = Frame();

    setUp(() {
      bluetooth = Bluetooth();
    });

    test('connect and disconnect', () async {
      expect(await bluetooth.isConnected(), false);

      await bluetooth.connect();
      expect(await bluetooth.isConnected(), true);

      await bluetooth.disconnect();
      expect(await bluetooth.isConnected(), false);
    });

    test('send Lua', () async {
      await frame.session((f) async {
        expect(
            await f.bluetooth.sendLua("print('hi')", awaitPrint: true), "hi");
        expect(await f.bluetooth.sendLua("print('hi')"), null);
      });
    });

    test('send data', () async {
      await frame.session((f) async {
        expect(
            await f.bluetooth
                .sendData(Uint8List.fromList([1, 2, 3]), awaitData: true),
            Uint8List.fromList([1, 2, 3]));
        expect(await f.bluetooth.sendData(Uint8List.fromList([1, 2, 3])), null);
      });
    });

    test('MTU', () async {
      await frame.session((f) async {
        expect(await f.bluetooth.maxLuaPayload(), greaterThan(0));
        expect(await f.bluetooth.maxDataPayload(), greaterThan(0));
      });
    });

    test('long send', () async {
      await frame.session((f) async {
        String script =
            "a = 0;${List.generate(32, (i) => "a = a + 1;").join(" ")}print(a)";
        expect(await f.runLua(script, awaitPrint: true), "32");

        script =
            "a = 0;${List.generate(250, (i) => "a = a + 1;").join(" ")}print(a)";
        expect(await f.runLua(script, awaitPrint: true), "250");
      });
    });

    test('long receive', () async {
      await frame.session((f) async {
        expect(await f.runLua("prntLng('hi')", awaitPrint: true), "hi");

        String msg = "hello world! ";
        msg = msg + msg;
        msg = msg + msg;
        msg = msg + msg;
        msg = msg + msg;
        msg = msg + msg;
        await bluetooth.sendLua(
            "msg = \"hello world! \";msg = msg .. msg;msg = msg .. msg;msg = msg .. msg;msg = msg .. msg;msg = msg .. msg",
            awaitPrint: false);
        expect(
            await bluetooth.sendLua(
                "print('about to send '..tostring(string.len(msg))..' characters.')",
                awaitPrint: true),
            "about to send 416 characters.");
        expect(await bluetooth.sendLua("msg"), msg);
      });
    });

    test('long send and receive', () async {
      await frame.session((f) async {
        int aCount = 2;
        String message = List.generate(aCount, (i) => "and #$i, ").join();
        String script =
            "message = \"\";${List.generate(aCount, (i) => "message = message .. \"and #$i, \"; ").join()}print(message)";
        expect(await f.runLua(script, awaitPrint: true), message);

        aCount = 50;
        message = List.generate(aCount, (i) => "and #$i, ").join();
        script =
            "message = \"\";${List.generate(aCount, (i) => "message = message .. \"and #$i, \"; ").join()}print(message)";
        expect(await f.runLua(script, awaitPrint: true), message);
      });
    });

    test('battery', () async {
      await frame.session((f) async {
        expect(await f.getBatteryLevel(), greaterThan(0));
        expect(await f.getBatteryLevel(), lessThanOrEqualTo(100));
        expect(await f.getBatteryLevel(), closeTo(50, 15));
      });
    });
  });
}
