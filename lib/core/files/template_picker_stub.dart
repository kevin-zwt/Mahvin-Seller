import 'dart:typed_data';

class PickedTemplateFile {
  const PickedTemplateFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

Future<PickedTemplateFile?> pickExcelTemplate() async {
  return null;
}
