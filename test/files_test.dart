import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'dart:convert';

import 'package:frame_sdk_flutter/frame_sdk_flutter.dart';

void main() {
  group('Files Tests', () {
    Frame frame = Frame();

    test('write long file', () async {
      await frame.session((f) async {
        String content = "Testing:\n${"test1... " * 200}\nTesting 2:\n${"test2\n" * 100}";
        Uint8List contentBytes = Uint8List.fromList(utf8.encode(content));
        
        await f.files.writeFile("test.txt", contentBytes, checked: true);
        
        Uint8List actualContent = await f.files.readFile("test.txt");
        expect(utf8.decode(actualContent).trim(), content.trim());
        
        actualContent = await f.files.readFile("test.txt");
        expect(actualContent, contentBytes.sublist(0, contentBytes.length - (contentBytes.last == 0x0A ? 1 : 0)));
        
        await f.files.deleteFile("test.txt");
      });
    });

    test('write raw file', () async {
      await frame.session((f) async {
        Uint8List content = Uint8List.fromList(List.generate(254, (i) => i + 1));
        
        await f.files.writeFile("test.dat", content, checked: true);
        
        Uint8List actualContent = await f.files.readFile("test.dat");
        expect(actualContent, content);
        
        actualContent = await f.files.readFile("test.dat");
        expect(actualContent, content);
        
        await f.files.writeFile("test.dat", content, checked: true);
        
        actualContent = await f.files.readFile("test.dat");
        expect(actualContent, content);
        
        actualContent = await f.files.readFile("test.dat");
        expect(actualContent, content);
        
        await f.files.deleteFile("test.dat");
      });
    });
  });
}