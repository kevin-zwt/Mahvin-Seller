import 'dart:typed_data';

Future<bool> downloadBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  return false;
}

/// Saves [bytes] under exactly [fileName], letting the user overwrite an
/// existing file. Not available outside the browser.
Future<bool> saveFileReplacing(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) => downloadBytes(bytes, fileName, mimeType: mimeType);
