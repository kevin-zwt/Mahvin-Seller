import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<bool> downloadBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  try {
    if (bytes.isEmpty) return false;
    final blob = web.Blob(
      <web.BlobPart>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
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

/// Saves [bytes] under exactly [fileName] through the browser's save dialog,
/// where picking the existing file replaces it (a plain download would be
/// renamed to "name (1)"). Falls back to a normal download in browsers
/// without the File System Access API. Returns false when the user cancels.
Future<bool> saveFileReplacing(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  final window = web.window as JSObject;
  if (!window.has('showSaveFilePicker')) {
    return downloadBytes(bytes, fileName, mimeType: mimeType);
  }
  try {
    if (bytes.isEmpty) return false;
    final dot = fileName.lastIndexOf('.');
    final extension = dot < 0 ? '' : fileName.substring(dot);
    final options = <String, Object?>{
      'suggestedName': fileName,
      if (extension.isNotEmpty)
        'types': [
          {
            'description': 'Excel file',
            'accept': {
              mimeType: [extension],
            },
          },
        ],
    }.jsify();
    final handle =
        await (window.callMethod<JSPromise<JSObject>>(
                  'showSaveFilePicker'.toJS,
                  options,
                ))
            .toDart;
    final writable =
        await (handle.callMethod<JSPromise<JSObject>>('createWritable'.toJS))
            .toDart;
    final blob = web.Blob(
      <web.BlobPart>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    await (writable.callMethod<JSPromise>('write'.toJS, blob)).toDart;
    await (writable.callMethod<JSPromise>('close'.toJS)).toDart;
    return true;
  } catch (_) {
    // Cancelled by the user (AbortError) or the browser refused.
    return false;
  }
}
