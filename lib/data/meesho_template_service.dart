import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

import 'models/product_link_data.dart';

class MeeshoTemplateException implements Exception {
  const MeeshoTemplateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MeeshoTemplateColumn {
  const MeeshoTemplateColumn({
    required this.columnIndex,
    required this.header,
    this.fieldKey,
    this.fieldLabel,
    this.preview = '',
    this.required = false,
    this.editable = true,
    this.prefilled = false,
    this.placeholder = false,
    this.existing = '',
    this.options = const [],
    this.inferred = '',
    this.formula = '',
  });

  MeeshoTemplateColumn withOptions(List<String> options) {
    return MeeshoTemplateColumn(
      columnIndex: columnIndex,
      header: header,
      fieldKey: fieldKey,
      fieldLabel: fieldLabel,
      preview: preview,
      required: required,
      editable: editable,
      prefilled: prefilled,
      placeholder: placeholder,
      existing: existing,
      options: options,
      inferred: inferred,
      formula: formula,
    );
  }

  /// A column with no direct product field whose value was worked out from the
  /// product's specifications or title.
  MeeshoTemplateColumn withInferred(String value) {
    return MeeshoTemplateColumn(
      columnIndex: columnIndex,
      header: header,
      fieldKey: _inferredKey,
      fieldLabel: 'Product details',
      preview: value,
      required: required,
      editable: editable,
      prefilled: prefilled,
      placeholder: placeholder,
      existing: existing,
      options: options,
      inferred: value,
      formula: formula,
    );
  }

  /// Value worked out from the product for an otherwise unmatched column.
  final String inferred;

  /// The template's formula for this column's data cell, if it has one.
  final String formula;

  /// Dropdown choices defined by the template; empty for free-text columns.
  final List<String> options;

  /// The template's own spelling of [value] if it is one of [options].
  String? matchOption(String value) {
    final wanted = value.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    for (final option in options) {
      if (option.trim().toLowerCase() == wanted) return option;
    }
    return null;
  }

  final int columnIndex;
  final String header;
  final String? fieldKey;
  final String? fieldLabel;
  final String preview;

  /// Marked compulsory by the template (a "*" header or a "Compulsory" label
  /// above it).
  final bool required;

  /// False for system columns (error status, field descriptions).
  final bool editable;

  /// The template's data row already holds a value or formula here.
  final bool prefilled;

  /// The data row holds hint text here ("Enter Meesho Price"), not a value.
  final bool placeholder;

  /// The value the uploaded template already holds in the data row.
  final String existing;

  bool get isMapped => fieldKey != null && fieldLabel != null;
}

/// A price the template calculates itself (returns price, customer price),
/// shown read-only in the app.
class MeeshoCalculatedField {
  const MeeshoCalculatedField({required this.header, required this.value});

  final String header;

  /// The result, or empty when it can't be worked out yet.
  final String value;
}

class MeeshoTemplate {
  const MeeshoTemplate({
    required this.fileName,
    required this.bytes,
    required this.sheetName,
    required this.headerRowIndex,
    required this.dataRowIndex,
    required this.columns,
  });

  final String fileName;
  final Uint8List bytes;
  final String sheetName;
  final int headerRowIndex;
  final int dataRowIndex;
  final List<MeeshoTemplateColumn> columns;

  List<MeeshoTemplateColumn> get mappedColumns =>
      columns.where((column) => column.isMapped).toList(growable: false);

  int get mappedColumnCount => mappedColumns.length;

  int get headerRowNumber => headerRowIndex + 1;

  int get dataRowNumber => dataRowIndex + 1;
}

class MeeshoTemplateService {
  const MeeshoTemplateService();

  MeeshoTemplate analyze(
    Uint8List bytes, {
    required String fileName,
    required ProductLinkData product,
  }) {
    late final Excel excel;
    try {
      excel = Excel.decodeBytes(bytes);
    } catch (_) {
      throw const MeeshoTemplateException(
        'Could not read this file. Upload a Meesho .xlsx template.',
      );
    }

    _HeaderCandidate? best;
    for (final entry in excel.tables.entries) {
      if (_isReferenceSheet(entry.key)) continue;
      final sheet = entry.value;
      final rows = sheet.rows;
      final rowLimit = rows.length < 60 ? rows.length : 60;
      final sheetBonus = _normalize(entry.key).contains('fill') ? 1 : 0;
      for (var rowIndex = 0; rowIndex < rowLimit; rowIndex++) {
        // Some templates put sub-headers ("Enter Meesho Price", "Customer
        // Price") in the row under a grouped header.
        final subIndex = _subHeaderRow(rows, rowIndex);
        final dataRowIndex = _dataRowFor(sheet, subIndex ?? rowIndex);
        final labelRow = rowIndex > 0 ? rows[rowIndex - 1] : const <Data?>[];
        final dataRow = dataRowIndex < rows.length
            ? rows[dataRowIndex]
            : const <Data?>[];
        final byIndex = <int, MeeshoTemplateColumn>{};
        for (final cell in rows[rowIndex]) {
          if (cell == null) continue;
          final raw = _cellText(cell.value);
          if (_headerText(raw).isEmpty) continue;
          byIndex[cell.columnIndex] = _columnFor(
            cell.columnIndex,
            raw,
            labelRow,
            dataRow,
            product,
          );
        }
        if (subIndex != null) {
          for (final cell in rows[subIndex]) {
            if (cell == null) continue;
            final raw = _cellText(cell.value);
            if (_headerText(raw).isEmpty) continue;
            if (_isTutorialText(raw.toLowerCase())) continue;
            byIndex[cell.columnIndex] = _columnFor(
              cell.columnIndex,
              raw,
              labelRow,
              dataRow,
              product,
              required: byIndex[cell.columnIndex]?.required,
            );
          }
        }
        final columns = [
          for (final index in byIndex.keys.toList()..sort()) byIndex[index]!,
        ];
        final mappedCount = columns.where((column) => column.isMapped).length;
        final score = mappedCount == 0 ? 0 : mappedCount * 2 + sheetBonus;
        if (best == null || score > best.score) {
          best = _HeaderCandidate(
            sheetName: entry.key,
            headerRowIndex: rowIndex,
            dataRowIndex: dataRowIndex,
            score: score,
            columns: columns,
          );
        }
      }
    }

    if (best == null || best.columns.where((c) => c.isMapped).length < 2) {
      throw const MeeshoTemplateException(
        'No Meesho listing headers found. Use the original Meesho Excel '
        'template with its header row intact.',
      );
    }

    final options = _listOptions(
      bytes,
      excel,
      best.sheetName,
      best.dataRowIndex + 1,
    );
    return MeeshoTemplate(
      fileName: fileName,
      bytes: bytes,
      sheetName: best.sheetName,
      headerRowIndex: best.headerRowIndex,
      dataRowIndex: best.dataRowIndex,
      columns: [
        for (final column in best.columns)
          _withInferred(
            options[column.columnIndex] == null
                ? column
                : column.withOptions(options[column.columnIndex]!),
            product,
          ),
      ],
    );
  }

  MeeshoTemplateColumn _columnFor(
    int index,
    String raw,
    List<Data?> labelRow,
    List<Data?> dataRow,
    ProductLinkData product, {
    bool? required,
  }) {
    final header = _headerText(raw);
    final mapping = _mappingFor(header, product);
    final label = index < labelRow.length
        ? _cellText(labelRow[index]?.value).toLowerCase()
        : '';
    final existing = index < dataRow.length ? dataRow[index]?.value : null;
    final existingText = _cellText(existing);
    return MeeshoTemplateColumn(
      columnIndex: index,
      header: header,
      fieldKey: mapping?.key,
      fieldLabel: mapping?.label,
      preview: mapping == null ? '' : _previewValue(mapping.key, product),
      // Unmapped formula columns (such as the auto-calculated returns price)
      // are worked out from the price, so they are not offered for editing.
      editable:
          !_ignoredHeader.hasMatch(_normalize(header)) &&
          !(mapping == null && existing is FormulaCellValue),
      required:
          required ??
          (raw.trim().startsWith('*') ||
              (label.contains('compulsory') || label.contains('mandatory')) &&
                  !label.contains('optional')),
      prefilled:
          existing != null &&
          existingText.trim().isNotEmpty &&
          !_isPlaceholder(existingText),
      placeholder: existing != null && _isPlaceholder(existingText),
      formula: existing is FormulaCellValue
          ? existing.formula.replaceFirst(RegExp(r'^='), '')
          : '',
      existing: existing != null && !_isPlaceholder(existingText)
          ? existingText.trim()
          : '',
    );
  }

  /// The row under [headerRowIndex] when it holds sub-headers, such as
  /// "Enter Meesho Price" next to "Customer Price": a short row mixing hint
  /// text with plain labels, and not an example or tutorial row.
  int? _subHeaderRow(List<List<Data?>> rows, int headerRowIndex) {
    final next = headerRowIndex + 1;
    if (next >= rows.length) return null;
    var hints = 0;
    var labels = 0;
    for (final cell in rows[next]) {
      final text = _cellText(cell?.value).trim();
      if (text.isEmpty) continue;
      final lower = text.toLowerCase();
      if (text.length > 60 ||
          lower.contains('example') ||
          lower.contains('sample') ||
          lower.contains('instruction')) {
        return null;
      }
      // "Tutorial Link" / "Watch Explainer Video" label the row itself.
      if (_isTutorialText(lower)) continue;
      _isPlaceholder(text) ? hints++ : labels++;
    }
    return hints > 0 && labels > 0 ? next : null;
  }

  bool _isTutorialText(String lower) =>
      lower.contains('tutorial') ||
      lower.contains('explainer') ||
      lower.startsWith('watch ');

  MeeshoTemplateColumn _withInferred(
    MeeshoTemplateColumn column,
    ProductLinkData product,
  ) {
    if (column.isMapped || !column.editable) return column;
    final value = _inferValue(column, product);
    return value.isEmpty ? column : column.withInferred(value);
  }

  /// Fills a column from the product's specifications (by related label) and,
  /// for a few attribute columns, the title, always limited to the template's
  /// dropdown choices when it has them.
  String _inferValue(MeeshoTemplateColumn column, ProductLinkData product) {
    final header = _normalize(column.header);
    if (_noInference.hasMatch(header)) return '';
    final labels = _specSynonyms[header];
    if (labels == null) return '';

    for (final spec in product.specs) {
      final label = _normalize(spec.label);
      final related = labels.any(
        (word) => label == word || label.split(' ').contains(word),
      );
      if (!related) continue;
      final value = _fitToColumn(column, spec.value);
      if (value.isNotEmpty) return value;
    }
    if (_titleAttributes.contains(header)) {
      return _fitToColumn(column, product.title, scanOnly: true);
    }
    return '';
  }

  /// [value] as the column accepts it: a dropdown choice (exact or contained in
  /// the text) or, for a free-text column, the value itself.
  String _fitToColumn(
    MeeshoTemplateColumn column,
    String value, {
    bool scanOnly = false,
  }) {
    final text = value.trim();
    if (text.isEmpty) return '';
    if (column.options.isEmpty) return scanOnly ? '' : text;
    final wording = _templateWording(column, text);
    return column.matchOption(wording) ??
        _findOption(column.options, wording) ??
        '';
  }

  /// The longest dropdown choice whose words appear together in [text].
  String? _findOption(List<String> options, String text) {
    if (options.length > 150) return null;
    final words = _stems(text);
    String? best;
    var bestWords = 0;
    for (final option in options) {
      final wanted = _stems(option);
      if (wanted.isEmpty || !option.contains(RegExp('[A-Za-z]'))) continue;
      if (wanted.join().length < 3) continue;
      for (var i = 0; i + wanted.length <= words.length; i++) {
        var all = true;
        for (var j = 0; j < wanted.length; j++) {
          if (words[i + j] != wanted[j]) {
            all = false;
            break;
          }
        }
        if (all) {
          if (wanted.length > bestWords ||
              (wanted.length == bestWords &&
                  option.length > (best?.length ?? 0))) {
            best = option;
            bestWords = wanted.length;
          }
          break;
        }
      }
    }
    return best;
  }

  List<String> _stems(String text) => [
    for (final word in _normalize(text).split(' '))
      if (word.isNotEmpty)
        word.length > 3 && word.endsWith('s')
            ? word.substring(0, word.length - 1)
            : word,
  ];

  /// Dropdown lists of the data row, from the sheet's list data validations
  /// (inline `"a,b"` lists or ranges such as `'Validation Sheet'!$E$3:$E$24`).
  Map<int, List<String>> _listOptions(
    Uint8List bytes,
    Excel excel,
    String sheetName,
    int rowNumber,
  ) {
    final result = <int, List<String>>{};
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = <String, List<int>>{
        for (final file in archive.files)
          if (file.isFile) file.name: file.content as List<int>,
      };
      final path = _sheetPath(files, sheetName);
      final sheetBytes = path == null ? null : files[path];
      if (sheetBytes == null) return result;
      final xml = utf8.decode(sheetBytes);
      final validations = RegExp(
        r'<dataValidation\s[^>]*?type="list"[^>]*>.*?</dataValidation>',
        dotAll: true,
      );
      for (final match in validations.allMatches(xml)) {
        final tag = match.group(0)!;
        final formula = RegExp(
          r'<formula1>(.*?)</formula1>',
          dotAll: true,
        ).firstMatch(tag)?.group(1);
        final columnIndex = _validationColumn(_attr(tag, 'sqref'), rowNumber);
        if (formula == null || columnIndex == null) continue;
        final choices = _choicesFrom(_unescape(formula), excel);
        if (choices.isNotEmpty) result.putIfAbsent(columnIndex, () => choices);
      }
    } catch (_) {
      // Without the lists the columns simply stay free-text.
    }
    return result;
  }

  /// The single column a validation range applies to on [rowNumber].
  int? _validationColumn(String? sqref, int rowNumber) {
    if (sqref == null) return null;
    final cell = RegExp(r'^([A-Z]+)(\d+)(?::([A-Z]+)(\d+))?$');
    for (final part in sqref.split(' ')) {
      final match = cell.firstMatch(part);
      if (match == null) continue;
      final first = int.parse(match.group(2)!);
      final last = int.parse(match.group(4) ?? match.group(2)!);
      final column = match.group(1)!;
      if ((match.group(3) ?? column) != column) continue;
      if (rowNumber >= first && rowNumber <= last) return _columnIndex(column);
    }
    return null;
  }

  List<String> _choicesFrom(String formula, Excel excel) {
    final values = <String>[];
    if (formula.startsWith('"')) {
      final inline = formula.endsWith('"') && formula.length > 1
          ? formula.substring(1, formula.length - 1)
          : formula.substring(1);
      values.addAll(inline.split(','));
    } else {
      final ref = RegExp(
        r"^(?:'((?:[^']|'')+)'|([^!]+))!\$?([A-Z]+)\$?(\d+)(?::\$?([A-Z]+)\$?(\d+))?$",
      ).firstMatch(formula.trim());
      if (ref == null) return const [];
      final name = (ref.group(1)?.replaceAll("''", "'") ?? ref.group(2))!;
      final rows = excel.tables[name]?.rows;
      if (rows == null) return const [];
      final firstColumn = _columnIndex(ref.group(3)!);
      final lastColumn = _columnIndex(ref.group(5) ?? ref.group(3)!);
      final firstRow = int.parse(ref.group(4)!) - 1;
      final lastRow = int.parse(ref.group(6) ?? ref.group(4)!) - 1;
      for (var r = firstRow; r <= lastRow && r < rows.length; r++) {
        for (var c = firstColumn; c <= lastColumn && c < rows[r].length; c++) {
          final value = rows[r][c]?.value;
          values.add(switch (value) {
            DoubleCellValue() when value.value == value.value.roundToDouble() =>
              value.value.toInt().toString(),
            _ => _cellText(value),
          });
        }
      }
    }
    final seen = <String>{};
    return [
      for (final value in values)
        if (value.trim().isNotEmpty && seen.add(value.trim())) value.trim(),
    ];
  }

  /// Headers of compulsory columns that would be left empty. Columns the
  /// template already fills itself (values or formulas) don't count.
  List<String> missingRequired(
    MeeshoTemplate template,
    ProductLinkData product, {
    Map<int, String> edits = const {},
  }) {
    final defaults = defaultValues(template, product);
    return [
      for (final column in template.columns)
        if (column.required &&
            column.editable &&
            !column.prefilled &&
            (edits[column.columnIndex] ?? defaults[column.columnIndex] ?? '')
                .trim()
                .isEmpty)
          column.header,
    ];
  }

  /// The template's own price formulas (such as the wrong/defective returns
  /// price and the customer price), worked out for the current values.
  List<MeeshoCalculatedField> calculatedFields(
    MeeshoTemplate template,
    ProductLinkData product, {
    Map<int, String> edits = const {},
  }) {
    final defaults = defaultValues(template, product);
    final rowNumber = template.dataRowNumber;
    final byRef = <String, Object?>{};
    for (final column in template.columns) {
      if (column.formula.isNotEmpty) continue;
      final text =
          (edits[column.columnIndex] ??
                  defaults[column.columnIndex] ??
                  column.existing)
              .trim();
      final key = column.fieldKey;
      final shown = key != null && _numericKeys.contains(key)
          ? _numericText(key, text) ?? text
          : text;
      byRef['${_columnLetters(column.columnIndex)}$rowNumber'] =
          double.tryParse(shown) ?? shown;
    }
    // Price formulas build on helper formulas (such as shipping charges) that
    // sit further right, so run them in a few passes.
    final computed = <int, String>{};
    for (var pass = 0; pass < 4; pass++) {
      for (final column in template.columns) {
        if (column.formula.isEmpty || column.isMapped) continue;
        try {
          final result = _Formula(column.formula).run((ref) {
            if (!RegExp('^[A-Z]+$rowNumber\$').hasMatch(ref)) {
              throw const FormatException('reference outside the data row');
            }
            return byRef[ref];
          });
          final value = switch (result) {
            double number when number == number.roundToDouble() =>
              number.toInt().toString(),
            final Object? other => other?.toString() ?? '',
          };
          computed[column.columnIndex] = value;
          byRef['${_columnLetters(column.columnIndex)}$rowNumber'] =
              double.tryParse(value) ?? value;
        } catch (_) {}
      }
    }
    final fields = <MeeshoCalculatedField>[
      for (final column in template.columns)
        if (column.formula.isNotEmpty &&
            !column.isMapped &&
            _normalize(column.header).contains('price'))
          MeeshoCalculatedField(
            header: column.header,
            value: computed[column.columnIndex] ?? '',
          ),
    ];
    return fields;
  }

  /// Full (untruncated) product value for every matched column, by column.
  Map<int, String> defaultValues(
    MeeshoTemplate template,
    ProductLinkData product,
  ) {
    return {
      for (final column in template.mappedColumns)
        column.columnIndex: _isPhotoColumn(column) && column.existing.isNotEmpty
            ? column.existing
            : _defaultFor(column, product),
    };
  }

  bool _isPhotoColumn(MeeshoTemplateColumn column) {
    final key = column.fieldKey;
    return key == 'photos' || (key != null && key.startsWith('photo:'));
  }

  /// The product value for a matched column. For a dropdown column it must be
  /// one of the template's choices, otherwise it is left for the user to pick.
  String _defaultFor(MeeshoTemplateColumn column, ProductLinkData product) {
    if (column.fieldKey == _inferredKey) return column.inferred;
    final value = _valueFor(column.fieldKey!, product);
    if (column.options.isEmpty || value.isEmpty) return value;
    final header = _normalize(column.header);
    return column.matchOption(value) ??
        _findOption(column.options, _templateWording(column, value)) ??
        (_titleAttributes.contains(header)
            ? _findOption(
                column.options,
                _templateWording(column, product.title),
              )
            : null) ??
        '';
  }

  /// Fills the template's data row. [edits] holds user-typed values by column
  /// index and wins over the product value; an empty edit leaves the cell blank.
  Uint8List fill(
    MeeshoTemplate template,
    ProductLinkData product, {
    Map<int, String> edits = const {},
  }) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(template.bytes);
    } catch (_) {
      throw const MeeshoTemplateException(
        'Could not read the saved template. Upload it again.',
      );
    }

    final files = <String, List<int>>{
      for (final file in archive.files)
        if (file.isFile) file.name: file.content as List<int>,
    };
    final sheetPath = _sheetPath(files, template.sheetName);
    final sheetBytes = sheetPath == null ? null : files[sheetPath];
    if (sheetPath == null || sheetBytes == null) {
      throw const MeeshoTemplateException(
        'The template sheet is missing. Upload it again.',
      );
    }

    final sstBytes = files['xl/sharedStrings.xml'];
    String? sst = sstBytes == null ? null : utf8.decode(sstBytes);
    var sstCount = sst == null
        ? 0
        : RegExp(r'<si[\s>/]').allMatches(sst).length;
    var added = 0;
    var refs = 0;
    final newStrings = <String, int>{};
    var xml = utf8.decode(sheetBytes);
    final columnStyles = _columnStyles(xml);

    final values = <int, _NewCell>{};
    for (final column in template.columns) {
      var edited = edits[column.columnIndex]?.trim();
      if (edited != null && column.options.isNotEmpty) {
        edited = column.matchOption(edited) ?? '';
      }
      if (edited == null && !column.isMapped) continue;
      final value = edited ?? _defaultFor(column, product);
      if (value.isEmpty && edited == null) continue;
      final key = column.fieldKey;
      values[column.columnIndex] = _NewCell(
        value,
        numeric: key != null && _numericKeys.contains(key)
            ? _numericText(key, value)
            : edited == null
            ? null
            : _plainNumber(value),
        force: edited != null || (key != null && _forcedKeys.contains(key)),
      );
    }

    final rowNumber = template.dataRowNumber;
    final rowMatch = RegExp('<row\\s+r="$rowNumber"([^>]*?)(/>|>)')
        .firstMatch(xml);

    String openTag;
    final cells = <int, String>{};
    int rowStart;
    int rowEnd;
    if (rowMatch == null) {
      openTag = '<row r="$rowNumber">';
      final later = RegExp('<row\\s+r="(\\d+)"')
          .allMatches(xml)
          .where((m) => int.parse(m.group(1)!) > rowNumber);
      rowStart = rowEnd = later.isNotEmpty
          ? later.first.start
          : xml.indexOf('</sheetData>');
      if (rowStart < 0) throw _badSheet;
    } else {
      openTag = '<row r="$rowNumber"${rowMatch.group(1)}>';
      rowStart = rowMatch.start;
      if (rowMatch.group(2) == '/>') {
        rowEnd = rowMatch.end;
      } else {
        final close = xml.indexOf('</row>', rowMatch.end);
        if (close < 0) throw _badSheet;
        rowEnd = close + '</row>'.length;
        final inner = xml.substring(rowMatch.end, close);
        final cellPattern = RegExp(r'<c\s[^>]*?(?:/>|>.*?</c>)', dotAll: true);
        for (final cell in cellPattern.allMatches(inner)) {
          final text = cell.group(0)!;
          final ref = _attr(text, 'r');
          if (ref == null) continue;
          cells[_columnIndex(ref)] = text;
        }
      }
    }

    values.forEach((columnIndex, cell) {
      final existing = cells[columnIndex];
      // Meesho templates pre-fill some cells with formulas; keep them.
      if (existing != null && existing.contains('<f') && !cell.force) return;
      final ref = '${_columnLetters(columnIndex)}$rowNumber';
      final style = existing == null
          ? columnStyles[columnIndex]
          : _attr(existing, 's');
      final styleAttr = style == null ? '' : ' s="$style"';
      if (cell.text.isEmpty) {
        cells[columnIndex] = '<c r="$ref"$styleAttr/>';
      } else if (cell.numeric != null) {
        cells[columnIndex] = '<c r="$ref"$styleAttr><v>${cell.numeric}</v></c>';
      } else if (sst != null) {
        var index = newStrings[cell.text];
        if (index == null) {
          index = sstCount++;
          newStrings[cell.text] = index;
          sst = sst!.replaceFirst(
            '</sst>',
            '<si><t xml:space="preserve">${_escape(cell.text)}</t></si></sst>',
          );
          added++;
        }
        refs++;
        cells[columnIndex] = '<c r="$ref"$styleAttr t="s"><v>$index</v></c>';
      } else {
        cells[columnIndex] =
            '<c r="$ref"$styleAttr t="inlineStr"><is>'
            '<t xml:space="preserve">${_escape(cell.text)}</t></is></c>';
      }
    });

    // Hint text such as "Enter Meesho Price" is not a value; leaving it in
    // the row makes Meesho read it as the cell's content.
    for (final column in template.columns) {
      if (!column.placeholder || values.containsKey(column.columnIndex)) {
        continue;
      }
      final existing = cells[column.columnIndex];
      if (existing != null && existing.contains('<f')) continue;
      final style = existing == null
          ? columnStyles[column.columnIndex]
          : _attr(existing, 's');
      cells[column.columnIndex] =
          '<c r="${_columnLetters(column.columnIndex)}$rowNumber"'
          '${style == null ? '' : ' s="$style"'}/>';
    }

    // The template's formulas ship without a stored result, and Meesho reads
    // the stored result when validating, so compute the simple ones here.
    final byRef = <String, Object?>{};
    cells.forEach((index, text) {
      final ref = '${_columnLetters(index)}$rowNumber';
      final number = RegExp(r'<v>([^<]*)</v>').firstMatch(text)?.group(1);
      if (!text.contains(' t="') && number != null) {
        byRef[ref] = double.tryParse(number);
      }
    });
    values.forEach((index, cell) {
      byRef['${_columnLetters(index)}$rowNumber'] = cell.numeric != null
          ? double.tryParse(cell.numeric!)
          : cell.text;
    });
    // Run twice so a formula can use the result of another one.
    for (var pass = 0; pass < 2; pass++) {
      for (final entry in cells.entries.toList()) {
        final text = entry.value;
        if (!RegExp(r'<f[\s>]').hasMatch(text)) continue;
        // Any stored result is stale once the row's values change (templates
        // often ship a cached 0), so formulas are always recalculated.
        final computed = _computeFormula(text, byRef, rowNumber);
        if (computed == null) continue;
        cells[entry.key] = computed;
        final value = RegExp(r'<v>([^<]*)</v>').firstMatch(computed)?.group(1);
        byRef['${_columnLetters(entry.key)}$rowNumber'] =
            double.tryParse(value ?? '') ?? value;
      }
    }

    final columns = cells.keys.toList()..sort();
    final row = '$openTag${columns.map((c) => cells[c]).join()}</row>';
    xml = xml.replaceRange(rowStart, rowEnd, row);
    files[sheetPath] = utf8.encode(xml);

    if (sst != null && added > 0) {
      sst = sst!.replaceFirstMapped(RegExp(r'<sst\b[^>]*>'), (match) {
        var tag = match.group(0)!;
        final increments = {'count': refs, 'uniqueCount': added};
        increments.forEach((name, by) {
          tag = tag.replaceFirstMapped(RegExp('\\b$name="(\\d+)"'), (m) {
            return '$name="${int.parse(m.group(1)!) + by}"';
          });
        });
        return tag;
      });
      files['xl/sharedStrings.xml'] = utf8.encode(sst!);
    }

    // Every other part of the template is written back unchanged.
    final output = Archive();
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final bytes = files[file.name]!;
      output.addFile(ArchiveFile(file.name, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(output);
    if (encoded == null || encoded.isEmpty) {
      throw const MeeshoTemplateException(
        'Could not create the filled Excel file. Try another template.',
      );
    }
    return Uint8List.fromList(encoded);
  }

  /// The cell XML with its formula result stored, or null when the formula
  /// can't be worked out (it is then left exactly as the template has it).
  /// Meesho reads stored results, and Excel-made templates ship without them.
  String? _computeFormula(
    String cell,
    Map<String, Object?> values,
    int rowNumber,
  ) {
    final formula = RegExp(
      r'<f(?:\s[^>]*)?>(.*?)</f>',
      dotAll: true,
    ).firstMatch(cell);
    if (formula == null) return null;
    final Object? result;
    try {
      result = _Formula(_unescape(formula.group(1)!)).run((ref) {
        // Only this row's values are known; anything else can't be worked out.
        if (!RegExp('^[A-Z]+$rowNumber\$').hasMatch(ref)) {
          throw const FormatException('reference outside the data row');
        }
        return values[ref];
      });
    } catch (_) {
      return null;
    }
    final open = RegExp(r'<c\s[^>]*?>').firstMatch(cell);
    if (open == null || open.group(0)!.endsWith('/>')) return null;
    final String text;
    final bool isText;
    switch (result) {
      case double number:
        if (number.isNaN || number.isInfinite) return null;
        text = number == number.roundToDouble()
            ? number.toInt().toString()
            : number.toString();
        isText = false;
      case String string:
        text = string;
        isText = true;
      case null:
        text = '';
        isText = true;
      default:
        return null;
    }
    final tag = open
        .group(0)!
        .replaceAll(RegExp(r'\st="[^"]*"'), '')
        .replaceFirst('>', isText ? ' t="str">' : '>');
    return '$tag${formula.group(0)}<v>${_escape(text)}</v></c>';
  }

  static const _badSheet = MeeshoTemplateException(
    'The template sheet is not in the expected format. Upload it again.',
  );

  String? _sheetPath(Map<String, List<int>> files, String sheetName) {
    final workbook = files['xl/workbook.xml'];
    final rels = files['xl/_rels/workbook.xml.rels'];
    if (workbook == null || rels == null) return null;
    String? relId;
    for (final tag in RegExp(
      r'<sheet\s[^>]*>',
    ).allMatches(utf8.decode(workbook))) {
      final name = _attr(tag.group(0)!, 'name');
      if (name != null && _unescape(name) == sheetName) {
        relId = _attr(tag.group(0)!, 'r:id');
        break;
      }
    }
    if (relId == null) return null;
    for (final tag in RegExp(
      r'<Relationship\s[^>]*>',
    ).allMatches(utf8.decode(rels))) {
      if (_attr(tag.group(0)!, 'Id') != relId) continue;
      final target = _attr(tag.group(0)!, 'Target');
      if (target == null) return null;
      return target.startsWith('/')
          ? target.substring(1)
          : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}';
    }
    return null;
  }

  /// Default style index per column, from the sheet's `<col style="..">`.
  Map<int, String> _columnStyles(String xml) {
    final styles = <int, String>{};
    for (final match in RegExp(r'<col\s[^>]*>').allMatches(xml)) {
      final tag = match.group(0)!;
      final style = _attr(tag, 'style');
      final min = int.tryParse(_attr(tag, 'min') ?? '');
      final max = int.tryParse(_attr(tag, 'max') ?? '');
      if (style == null || min == null || max == null || max - min > 200) {
        continue;
      }
      for (var c = min; c <= max; c++) {
        styles[c - 1] = style;
      }
    }
    return styles;
  }

  String? _attr(String tag, String name) {
    final end = tag.indexOf('>');
    final head = end < 0 ? tag : tag.substring(0, end);
    final match = RegExp('\\s${RegExp.escape(name)}="([^"]*)"')
        .firstMatch(head);
    return match?.group(1);
  }

  int _columnIndex(String ref) {
    var index = 0;
    for (final unit in ref.codeUnits) {
      if (unit < 65 || unit > 90) break;
      index = index * 26 + (unit - 64);
    }
    return index - 1;
  }

  String _columnLetters(int columnIndex) {
    var n = columnIndex + 1;
    var letters = '';
    while (n > 0) {
      letters = String.fromCharCode(65 + (n - 1) % 26) + letters;
      n = (n - 1) ~/ 26;
    }
    return letters;
  }

  String _escape(String value) {
    return value
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  String _unescape(String value) {
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  bool _isReferenceSheet(String name) {
    final normalized = _normalize(name);
    return normalized.contains('validation') ||
        normalized.contains('example') ||
        normalized.contains('sample') ||
        normalized.contains('instruction') ||
        normalized.contains('return reason');
  }

  /// Header cells in Meesho templates hold the field name on the first line
  /// followed by a long description, and may start with a "*" marker.
  String _headerText(String raw) {
    for (final line in raw.split(RegExp(r'[\r\n]+'))) {
      final text = line.trim().replaceFirst(RegExp(r'^\*+\s*'), '');
      if (text.isNotEmpty) {
        return text.length > 80 ? text.substring(0, 80) : text;
      }
    }
    return '';
  }

  int _dataRowFor(Sheet sheet, int headerRowIndex) {
    final rows = sheet.rows;
    var next = headerRowIndex + 1;
    while (next < rows.length && next <= headerRowIndex + 6) {
      String? first;
      for (final cell in rows[next]) {
        final text = _cellText(cell?.value).trim().toLowerCase();
        if (text.isNotEmpty) {
          first = text;
          break;
        }
      }
      if (first != null &&
          (first.contains('example') ||
              first.contains('sample') ||
              first.contains('tutorial') ||
              first.contains('instruction'))) {
        next++;
        continue;
      }
      break;
    }
    return next;
  }

  _Mapping? _mappingFor(String header, ProductLinkData product) {
    final normalized = _normalize(header);
    if (normalized.isEmpty) return null;
    if (_ignoredHeader.hasMatch(normalized)) return null;

    // "Meesho Price", "Meesho Price (In Rs)", "Selling Price incl. GST" ...
    if (_sellingPrice.hasMatch(normalized) &&
        !_notSellingPrice.hasMatch(normalized)) {
      return const _Mapping('price', 'Selling price');
    }

    for (final field in _fields) {
      if (field.aliases.contains(normalized)) {
        return _Mapping(field.key, field.label);
      }
    }
    if (!_ambiguousHeader.hasMatch(normalized)) {
      for (final field in _fields) {
        if (_matchesAlias(normalized, field.aliases)) {
          return _Mapping(field.key, field.label);
        }
      }
    }

    final photoIndex = _photoIndex(normalized);
    if (photoIndex != null) {
      if (photoIndex <= 0) return const _Mapping('photos', 'Product images');
      return _Mapping('photo:$photoIndex', 'Image $photoIndex');
    }

    for (final spec in product.specs) {
      final label = _normalize(spec.label);
      if (label.length < 3) continue;
      if (normalized == label) {
        return _Mapping('spec:$label', 'Spec: ${spec.label}');
      }
    }
    for (final spec in product.specs) {
      final label = _normalize(spec.label);
      if (label.length < 4) continue;
      if (normalized.contains(label) || label.contains(normalized)) {
        return _Mapping('spec:$label', 'Spec: ${spec.label}');
      }
    }

    return null;
  }

  bool _matchesAlias(String header, List<String> aliases) {
    for (final alias in aliases) {
      if (header == alias) return true;
      if (alias.length >= 3 && header.startsWith('$alias ')) return true;
      if (alias.length >= 4 && header.endsWith(' $alias')) return true;
    }
    return false;
  }

  int? _photoIndex(String header) {
    if (header == 'images' ||
        header == 'product images' ||
        header == 'image urls' ||
        header == 'image links' ||
        header == 'photo urls' ||
        header == 'photo links' ||
        header == 'photos') {
      return 0;
    }
    if (header == 'image' ||
        header == 'product image' ||
        header == 'main image' ||
        header == 'primary image' ||
        header == 'image url' ||
        header == 'image link' ||
        header == 'photo' ||
        header == 'product photo') {
      return 1;
    }
    final match = RegExp(
      r'^(?:product |main |primary )?(?:image|images|photo|photos|img)(?: url| link)? ?(\d+)(?: url| link)?(?: (?:front|back|side|top|detail|closeup|close up|other))*$',
    ).firstMatch(header);
    if (match == null) return null;
    final index = int.tryParse(match.group(1) ?? '') ?? 0;
    if (index < 1 || index > 20) return null;
    return index;
  }

  String _valueFor(String key, ProductLinkData product) {
    final value = switch (key) {
      'title' => _clean(product, product.title),
      'description' => _description(product),
      // The source store's brand would trip Meesho's brand check.
      'brand' => '',
      'category' => product.category,
      'price' => product.price,
      'mrp' => _mrpFor(product),
      'discount' => _calculatedDiscount(product),
      'sku' => product.sku,
      'makerName' => _makerName,
      'makerAddress' => _makerAddress,
      'country' => _defaultCountry,
      'makerPincode' => _makerPincode,
      'inventory' => _defaultInventory,
      'weight' => _defaultWeightGrams,
      'packageLength' ||
      'packageWidth' ||
      'packageHeight' => _defaultPackageSizeCm,
      'seller' => product.seller,
      'availability' => product.availability,
      'rating' => product.rating,
      'reviews' => product.reviewCount,
      'keywords' => _clean(product, product.keywords.join(', ')),
      'features' => _clean(product, product.keyFeatures.join('\n')),
      'specs' => _clean(
        product,
        product.specs.map((spec) => '${spec.label}: ${spec.value}').join('\n'),
      ),
      // Links to another marketplace are prohibited in a Meesho listing.
      'sourceUrl' => '',
      'photos' => product.photos.map((photo) => photo.url).join('\n'),
      _ => _valueForIndexed(key, product),
    };
    return value.trim();
  }

  /// [text] made safe for a Meesho listing (no brand, marketplace names or
  /// links), for text that did not come straight from the product page.
  String cleanText(ProductLinkData product, String text) =>
      _clean(product, text);

  String _description(ProductLinkData product) {
    final text = _clean(product, product.description);
    return text.isNotEmpty
        ? text
        : _clean(product, product.keyFeatures.join('\n'));
  }

  /// Brand names the source product carries (its own brand, or the first word
  /// of a Flipkart link's slug, which is always the brand).
  Set<String> _brandWords(ProductLinkData product) {
    final words = <String>{};
    if (product.brand.trim().length > 1) words.add(product.brand.trim());
    final uri = Uri.tryParse(product.sourceUrl);
    if (uri != null && uri.host.contains('flipkart.')) {
      final slug = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
      final first = slug.split('-').first;
      if (first.length > 1 && !RegExp(r'^\d+$').hasMatch(first)) {
        words.add(first);
      }
    }
    return words;
  }

  /// Text made safe for a Meesho listing: no marketplace names or links, no
  /// store promo text and no source brand (Meesho rejects these keywords).
  String _clean(ProductLinkData product, String text) {
    var value = text.replaceFirst(
      RegExp(r'\s*[-–|]\s*buy\b.*$', caseSensitive: false, dotAll: true),
      '',
    );
    final lines = <String>[];
    for (final line in value.split(RegExp(r'[\r\n]+'))) {
      final kept = line
          .split(RegExp(r'(?<=[.!?])\s+'))
          .where((part) => !_storeText.hasMatch(part))
          .join(' ');
      if (kept.trim().isNotEmpty) lines.add(kept);
    }
    value = lines.join('\n');
    for (final brand in _brandWords(product)) {
      value = value.replaceAll(
        RegExp('\\b${RegExp.escape(brand)}\\b', caseSensitive: false),
        '',
      );
    }
    return value
        .replaceAll(_marketplaceName, '')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'^[\s,.:;-]+', multiLine: true), '')
        .trim();
  }

  String _valueForIndexed(String key, ProductLinkData product) {
    if (key.startsWith('photo:')) return '';
    if (key.startsWith('spec:')) {
      final label = key.substring(5);
      for (final spec in product.specs) {
        if (_normalize(spec.label) == label) return _clean(product, spec.value);
      }
      for (final spec in product.specs) {
        final normalized = _normalize(spec.label);
        if (normalized.length < 4) continue;
        if (normalized.contains(label) || label.contains(normalized)) {
          return _clean(product, spec.value);
        }
      }
    }
    return '';
  }

  String _previewValue(String key, ProductLinkData product) {
    final value = _valueFor(key, product);
    if (value.length <= 70) return value;
    return '${value.substring(0, 67)}...';
  }

  /// MRP is set so the Meesho price is [_mrpDiscountPercent] percent off it
  /// (rounded up to a whole rupee). The scraped MRP is only used when the price
  /// itself is unavailable.
  String _mrpFor(ProductLinkData product) {
    final price = _number(product.price);
    if (price == null) return product.mrp;
    return '${(price * 100 / (100 - _mrpDiscountPercent)).ceil()}';
  }

  String _calculatedDiscount(ProductLinkData product) {
    final price = _number(product.price);
    final mrp = _number(_mrpFor(product));
    if (price == null || mrp == null || mrp <= 0 || price >= mrp) return '';
    final percent = ((mrp - price) / mrp * 100).round();
    return '$percent% off';
  }

  /// Whole numbers and decimals without leading zeros (so HSN or pincode codes
  /// like 0123 stay text) are written as numbers.
  String? _plainNumber(String value) {
    return RegExp(r'^(?:[1-9]\d{0,14}|0)(?:\.\d+)?$').hasMatch(value)
        ? value
        : null;
  }

  String? _numericText(String key, String value) {
    if (!_numericKeys.contains(key)) return null;
    final number = _number(value);
    if (number == null) return null;
    return number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toString();
  }

  double? _number(String raw) {
    final cleaned = raw.replaceAll(',', '');
    final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(cleaned);
    return double.tryParse(match?.group(0) ?? '');
  }

  String _cellText(CellValue? value) {
    return switch (value) {
      null => '',
      TextCellValue() => value.value.toString(),
      IntCellValue() => value.value.toString(),
      DoubleCellValue() => value.value.toString(),
      BoolCellValue() => value.value.toString(),
      DateCellValue() => value.toString(),
      DateTimeCellValue() => value.toString(),
      TimeCellValue() => value.toString(),
      FormulaCellValue() => value.formula,
    };
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _HeaderCandidate {
  const _HeaderCandidate({
    required this.sheetName,
    required this.headerRowIndex,
    required this.dataRowIndex,
    required this.score,
    required this.columns,
  });

  final String sheetName;
  final int headerRowIndex;
  final int dataRowIndex;
  final int score;
  final List<MeeshoTemplateColumn> columns;
}

class _NewCell {
  const _NewCell(this.text, {this.numeric, this.force = false});

  final String text;
  final String? numeric;

  /// A value typed by the user replaces even a pre-filled formula cell.
  final bool force;
}

class _Mapping {
  const _Mapping(this.key, this.label);

  final String key;
  final String label;
}

class _FieldAliases {
  const _FieldAliases(this.key, this.label, this.aliases);

  final String key;
  final String label;
  final List<String> aliases;
}

const _fields = [
  _FieldAliases('title', 'Product name', [
    'product name',
    'product title',
    'listing title',
    'name',
    'title',
  ]),
  _FieldAliases('description', 'Description', [
    'product description',
    'description',
    'product details',
    'details',
  ]),
  _FieldAliases('brand', 'Brand', ['brand', 'brand name']),
  _FieldAliases('category', 'Category', [
    'product category',
    'category',
    'category name',
    'sub category',
    'subcategory',
  ]),
  _FieldAliases('price', 'Selling price', [
    'selling price',
    'sale price',
    'your price',
    'price',
    'sp',
  ]),
  _FieldAliases('mrp', 'MRP', [
    'mrp',
    'maximum retail price',
    'list price',
    'strike price',
  ]),
  _FieldAliases('discount', 'Discount', [
    'discount percentage',
    'discount percent',
    'discount',
  ]),
  _FieldAliases('sku', 'SKU', [
    'seller sku',
    'product sku',
    'product id',
    'style id',
    'sku',
  ]),
  _FieldAliases('seller', 'Seller', [
    'seller name',
    'supplier name',
    'seller',
    'supplier',
  ]),
  _FieldAliases('availability', 'Availability', [
    'stock status',
    'availability',
    'in stock',
  ]),
  _FieldAliases('rating', 'Rating', ['product rating', 'rating']),
  _FieldAliases('reviews', 'Review count', [
    'number of reviews',
    'ratings count',
    'review count',
    'reviews',
  ]),
  // Not on the product page; filled with the fixed defaults below.
  _FieldAliases('inventory', 'Inventory', [
    'inventory',
    'stock',
    'stock quantity',
    'available quantity',
    'quantity in stock',
  ]),
  _FieldAliases('weight', 'Weight (gms)', [
    'net weight gms',
    'net weight gm',
    'net weight g',
    'net weight grams',
    'net weight',
    'weight gms',
    'weight gm',
    'weight in gms',
    'weight in grams',
    'weight',
    'product weight',
    'package weight',
    'package weight gms',
    'shipping weight',
  ]),
  _FieldAliases('packageLength', 'Package length', [
    'package length',
    'package length cm',
    'package length in cm',
    'packaging length',
    'parcel length',
  ]),
  _FieldAliases('packageWidth', 'Package width', [
    'package width',
    'package width cm',
    'package width in cm',
    'package breadth',
    'package breadth cm',
    'package breadth in cm',
    'packaging width',
    'parcel width',
  ]),
  _FieldAliases('packageHeight', 'Package height', [
    'package height',
    'package height cm',
    'package height in cm',
    'packaging height',
    'parcel height',
  ]),
  _FieldAliases('makerName', 'Manufacturer / packer name', [
    'manufacturer name',
    'packer name',
    'importer name',
  ]),
  _FieldAliases('makerAddress', 'Manufacturer / packer address', [
    'manufacturer address',
    'packer address',
    'importer address',
  ]),
  _FieldAliases('country', 'Country of origin', [
    'country of origin',
    'origin country',
  ]),
  _FieldAliases('makerPincode', 'Manufacturer / packer pincode', [
    'manufacturer pincode',
    'packer pincode',
    'importer pincode',
  ]),
  _FieldAliases('keywords', 'Keywords', [
    'search keywords',
    'search terms',
    'keywords',
    'tags',
  ]),
  _FieldAliases('features', 'Key features', [
    'product highlights',
    'key highlights',
    'bullet points',
    'key features',
    'features',
    'highlights',
  ]),
  _FieldAliases('specs', 'Specifications', [
    'product specifications',
    'technical details',
    'specifications',
    'specs',
  ]),
  _FieldAliases('sourceUrl', 'Product URL', [
    'product url',
    'product link',
    'source url',
    'source link',
    'url',
    'link',
  ]),
];

/// System columns that must never be filled.
final _ignoredHeader = RegExp(
  r'^(?:error status|error message|fields description|field names?|field type.*|.*system generated.*)$',
);

/// Headers that end in a generic word ("name", "price") but describe a
/// different field, so only an exact alias match may map them.
final _ambiguousHeader = RegExp(
  r'\b(?:manufacturer|packer|importer|generic|wrong|defective|returns?|'
  r'group|hsn|gst|weight|pincode|address|country|origin|net quantity|'
  r'customer)\b',
);

const _mrpDiscountPercent = 60;
const _makerName = 'Mahvin Enterprise';
const _makerPincode = '382350';
const _makerAddress = 'Ahmedabad';
const _defaultCountry = 'India';
// Maker columns the template pre-fills with a formula (importer details) are
// overwritten with the defaults.
const _forcedKeys = {'makerName', 'makerAddress', 'makerPincode'};
const _defaultInventory = '10';
const _defaultWeightGrams = '200';
const _defaultPackageSizeCm = '10';
const _numericKeys = {
  'price',
  'mrp',
  'discount',
  'rating',
  'reviews',
  'inventory',
  'weight',
  'packageLength',
  'packageWidth',
  'packageHeight',
  'makerPincode',
};

const _inferredKey = 'inferred';

/// Columns that product data must never be guessed into.
final _noInference = RegExp(
  r'^(?:variation|brand|group id|hsn id|gst|ean upc|product id style id|'
  r'sku id|chest size|length size|shoulder size|length|style|hemline|'
  r'character|sleeve styling)\b',
);

/// Related specification labels (words) for template attribute columns.
const _specSynonyms = {
  'color': ['color', 'colour'],
  'fabric': ['fabric', 'material'],
  'fit shape': ['fit', 'shape'],
  'neck': ['neck', 'collar'],
  'sleeve length': ['sleeve'],
  'pattern': ['pattern'],
  'print or pattern type': ['print', 'pattern'],
  'occasion': ['occasion'],
  'net quantity n': ['pack', 'quantity', 'contents'],
  'number of pockets': ['pockets', 'pocket'],
};

/// Attribute columns that can also be read from the product title.
const _titleAttributes = {
  'color',
  'neck',
  'pattern',
  'print or pattern type',
  'fabric',
  'sleeve length',
  'fit shape',
};

/// Store wording that Meesho's lists spell differently.
String _templateWording(MeeshoTemplateColumn column, String text) {
  if (!column.header.toLowerCase().contains('sleeve length')) return text;
  return text
      .replaceAll(
        RegExp(r'\b(?:full|long)[\s-]*sleeves?\b', caseSensitive: false),
        'Long Sleeves',
      )
      .replaceAll(
        RegExp(r'\b(?:half|short)[\s-]*sleeves?\b', caseSensitive: false),
        'Short Sleeves',
      )
      .replaceAll(
        RegExp(
          r'\b(?:3/4|three[\s-]*quarter)[\s-]*sleeves?\b',
          caseSensitive: false,
        ),
        'Three-Quarter Sleeves',
      )
      .replaceAll(
        RegExp(r'\bsleeve[\s-]*less\b', caseSensitive: false),
        'Sleeveless',
      );
}

final _marketplaceName = RegExp(
  r'\b(?:flipkart|amazon|myntra|ajio|snapdeal|nykaa|meesho)(?:\.(?:com|in))?\b',
  caseSensitive: false,
);

/// Sentences that come from the source store, not the product.
final _storeText = RegExp(
  r'https?://|www\.|\.(?:com|in)\b|₹|\brs\.?\s*\d|free (?:shipping|delivery)|'
  r'cash on delivery|\bcod\b|best price|buy .* online|add to cart|'
  r'\b(?:flipkart|amazon|myntra|ajio|snapdeal|nykaa)\b',
  caseSensitive: false,
);

/// Headers for the price the product is sold at.
final _sellingPrice = RegExp(r'\b(?:meesho|selling|sale|your|final) price\b');

/// Price-like headers that are a different price.
final _notSellingPrice = RegExp(
  r'\b(?:wrong|defective|returns?|mrp|bulk|shipping|discount|cost|customer|'
  r'purchase|buying|base)\b',
);

/// Hint text a template puts in a cell to tell the seller what to type.
bool _isPlaceholder(String text) {
  return RegExp(
    r'^(?:enter|select|choose|type|fill|provide|add)\b|^e\.?g\.?\b',
    caseSensitive: false,
  ).hasMatch(text.trim());
}

/// A spreadsheet error value (#DIV/0!, #VALUE! ...) while evaluating.
class _FormulaError {
  const _FormulaError();
}

/// Evaluates the small spreadsheet formulas Meesho templates use: numbers,
/// text, cell references, + - * / & comparisons and IF / ROUND / MAX / MIN /
/// AND / OR / NOT / ABS / IFERROR. Anything else throws and the caller leaves
/// the cell alone.
class _Formula {
  _Formula(this._text);

  final String _text;
  var _pos = 0;
  late Object? Function(String ref) _lookup;

  Object? run(Object? Function(String ref) lookup) {
    _lookup = lookup;
    final value = _comparison();
    _space();
    if (_pos != _text.length) throw const FormatException('trailing text');
    if (value is _FormulaError) throw const FormatException('error');
    return value;
  }

  void _space() {
    while (_pos < _text.length && _text[_pos] == ' ') {
      _pos++;
    }
  }

  bool _take(String token) {
    _space();
    if (_text.startsWith(token, _pos)) {
      _pos += token.length;
      return true;
    }
    return false;
  }

  Object? _comparison() {
    var left = _concat();
    while (true) {
      String? op;
      for (final candidate in const ['<>', '<=', '>=', '=', '<', '>']) {
        if (_take(candidate)) {
          op = candidate;
          break;
        }
      }
      if (op == null) return left;
      left = _compare(left, _concat(), op);
    }
  }

  Object? _concat() {
    var left = _sum();
    while (_take('&')) {
      final right = _sum();
      left = '${_str(left)}${_str(right)}';
    }
    return left;
  }

  Object? _sum() {
    var left = _product();
    while (true) {
      if (_take('+')) {
        left = _arith(left, _product(), (a, b) => a + b);
      } else if (_take('-')) {
        left = _arith(left, _product(), (a, b) => a - b);
      } else {
        return left;
      }
    }
  }

  Object? _product() {
    var left = _unary();
    while (true) {
      if (_take('*')) {
        left = _arith(left, _unary(), (a, b) => a * b);
      } else if (_take('/')) {
        left = _arith(
          left,
          _unary(),
          (a, b) => b == 0 ? double.nan : a / b,
          errorOnNaN: true,
        );
      } else {
        return left;
      }
    }
  }

  Object? _unary() {
    if (_take('-')) return _arith(0.0, _unary(), (a, b) => a - b);
    if (_take('+')) return _unary();
    return _primary();
  }

  Object? _primary() {
    _space();
    if (_take('(')) {
      final value = _comparison();
      if (!_take(')')) throw const FormatException('missing )');
      return value;
    }
    final number = RegExp(r'\d+(?:\.\d+)?').matchAsPrefix(_text, _pos);
    if (number != null) {
      _pos = number.end;
      return double.parse(number.group(0)!);
    }
    if (_pos < _text.length && _text[_pos] == '"') {
      final buffer = StringBuffer();
      _pos++;
      while (_pos < _text.length) {
        if (_text[_pos] == '"') {
          if (_pos + 1 < _text.length && _text[_pos + 1] == '"') {
            buffer.write('"');
            _pos += 2;
            continue;
          }
          _pos++;
          return buffer.toString();
        }
        buffer.write(_text[_pos++]);
      }
      throw const FormatException('unterminated text');
    }
    final name = RegExp(r'\$?[A-Za-z]+\$?\d*').matchAsPrefix(_text, _pos);
    if (name == null) throw const FormatException('unexpected');
    final word = name.group(0)!;
    final afterName = name.end;
    if (afterName < _text.length && _text[afterName] == '(') {
      _pos = afterName + 1;
      return _call(word.toUpperCase(), _arguments());
    }
    _pos = afterName;
    final upper = word.replaceAll(r'$', '').toUpperCase();
    if (upper == 'TRUE') return true;
    if (upper == 'FALSE') return false;
    if (!RegExp(r'^[A-Z]+\d+$').hasMatch(upper)) {
      throw const FormatException('unknown name');
    }
    if (_pos < _text.length && _text[_pos] == ':') {
      throw const FormatException('ranges are not supported');
    }
    return _lookup(upper);
  }

  List<Object?> _arguments() {
    final args = <Object?>[];
    if (_take(')')) return args;
    do {
      args.add(_comparison());
    } while (_take(','));
    if (!_take(')')) throw const FormatException('missing )');
    return args;
  }

  Object? _call(String name, List<Object?> a) {
    switch (name) {
      case 'IF':
        if (a.length < 2) throw const FormatException('IF');
        final test = a[0];
        if (test is _FormulaError) return test;
        return _truthy(test) ? a[1] : (a.length > 2 ? a[2] : false);
      case 'IFERROR':
        return a[0] is _FormulaError ? a[1] : a[0];
      case 'ISBLANK':
        return a[0] == null || a[0] == '';
      case 'AND':
        return a.every(_truthy);
      case 'OR':
        return a.any(_truthy);
      case 'NOT':
        return !_truthy(a[0]);
      case 'ABS':
        return _arith(a[0], 0.0, (x, _) => x.abs());
      case 'MAX':
        return a
            .map(_num)
            .whereType<double>()
            .fold<double?>(null, (m, v) => m == null || v > m ? v : m);
      case 'MIN':
        return a
            .map(_num)
            .whereType<double>()
            .fold<double?>(null, (m, v) => m == null || v < m ? v : m);
      case 'ROUND':
      case 'ROUNDUP':
      case 'ROUNDDOWN':
        final value = _num(a[0]);
        final digits = a.length > 1 ? (_num(a[1]) ?? 0).toInt() : 0;
        if (value == null) return const _FormulaError();
        final scale = _pow10(digits);
        final scaled = value * scale;
        final rounded = switch (name) {
          'ROUND' => scaled.roundToDouble(),
          'ROUNDUP' =>
            scaled < 0 ? scaled.floorToDouble() : scaled.ceilToDouble(),
          _ => scaled < 0 ? scaled.ceilToDouble() : scaled.floorToDouble(),
        };
        return rounded / scale;
    }
    throw FormatException('unsupported function $name');
  }

  double _pow10(int digits) {
    var scale = 1.0;
    for (var i = 0; i < digits.abs(); i++) {
      scale *= 10;
    }
    return digits >= 0 ? scale : 1 / scale;
  }

  /// Blank is 0 in arithmetic; text that isn't a number is an error.
  double? _num(Object? value) {
    if (value == null) return 0;
    if (value is double) return value;
    if (value is bool) return value ? 1 : 0;
    if (value is String) {
      if (value.isEmpty) return 0;
      return double.tryParse(value);
    }
    return null;
  }

  String _str(Object? value) {
    if (value == null) return '';
    if (value is double) {
      return value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();
    }
    return '$value';
  }

  bool _truthy(Object? value) {
    if (value is bool) return value;
    if (value is double) return value != 0;
    if (value is String) return value.toLowerCase() == 'true';
    return false;
  }

  Object? _arith(
    Object? a,
    Object? b,
    double Function(double, double) op, {
    bool errorOnNaN = false,
  }) {
    if (a is _FormulaError) return a;
    if (b is _FormulaError) return b;
    final x = _num(a);
    final y = _num(b);
    if (x == null || y == null) return const _FormulaError();
    final result = op(x, y);
    return errorOnNaN && result.isNaN ? const _FormulaError() : result;
  }

  Object? _compare(Object? a, Object? b, String op) {
    if (a is _FormulaError) return a;
    if (b is _FormulaError) return b;
    int order;
    if (a is String || b is String) {
      order = _str(a).toLowerCase().compareTo(_str(b).toLowerCase());
    } else {
      final x = _num(a) ?? 0;
      final y = _num(b) ?? 0;
      order = x.compareTo(y);
    }
    return switch (op) {
      '=' => order == 0,
      '<>' => order != 0,
      '<' => order < 0,
      '>' => order > 0,
      '<=' => order <= 0,
      _ => order >= 0,
    };
  }
}
