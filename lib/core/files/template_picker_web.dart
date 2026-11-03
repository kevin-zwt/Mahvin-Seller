import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class PickedTemplateFile {
  const PickedTemplateFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

Future<PickedTemplateFile?> pickExcelTemplate() {
  final completer = Completer<PickedTemplateFile?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept =
        '.xlsx,.xls,application/vnd.ms-excel,'
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    ..style.display = 'none';

  var finished = false;
  void finish([PickedTemplateFile? file]) {
    if (finished) return;
    finished = true;
    input.remove();
    if (!completer.isCompleted) completer.complete(file);
  }

  input.onchange = ((web.Event event) {
    final file = input.files?.item(0);
    if (file == null) {
      finish();
      return;
    }
    file
        .arrayBuffer()
        .toDart
        .then<void>((buffer) {
          finish(
            PickedTemplateFile(
              name: file.name,
              bytes: Uint8List.view(buffer.toDart),
            ),
          );
        })
        .catchError((Object _) {
          finish();
        });
  }.toJS);
  input.oncancel = ((web.Event event) {
    finish();
  }.toJS);

  web.document.body?.appendChild(input);
  input.click();
  return completer.future;
}
