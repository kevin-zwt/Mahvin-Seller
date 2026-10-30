import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Fetches the photo and downloads it with the browser's save dialog.
Future<bool> downloadImage(String url, String fileName) async {
  try {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) return false;

    final blob = web.Blob(
      <web.BlobPart>[response.bodyBytes.toJS].toJS,
      web.BlobPropertyBag(type: _contentType(url)),
    );
    final objectUrl = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = objectUrl
      ..download = fileName
      ..style.display = 'none';
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(objectUrl);
    return true;
  } catch (_) {
    return false;
  }
}

String _contentType(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('.png')) return 'image/png';
  if (lower.contains('.webp')) return 'image/webp';
  if (lower.contains('.gif')) return 'image/gif';
  return 'image/jpeg';
}
