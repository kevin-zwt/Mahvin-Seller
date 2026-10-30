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
  });

  final int columnIndex;
  final String header;
  final String? fieldKey;
  final String? fieldLabel;
  final String preview;

  bool get isMapped => fieldKey != null && fieldLabel != null;
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
        final columns = <MeeshoTemplateColumn>[];
        for (final cell in rows[rowIndex]) {
          if (cell == null) continue;
          final header = _headerText(_cellText(cell.value));
          if (header.isEmpty) continue;
          final mapping = _mappingFor(header, product);
          columns.add(
            MeeshoTemplateColumn(
              columnIndex: cell.columnIndex,
              header: header,
              fieldKey: mapping?.key,
              fieldLabel: mapping?.label,
              preview: mapping == null
                  ? ''
                  : _previewValue(mapping.key, product),
            ),
          );
        }
        final mappedCount = columns.where((column) => column.isMapped).length;
        final score = mappedCount == 0 ? 0 : mappedCount * 2 + sheetBonus;
        if (best == null || score > best.score) {
          best = _HeaderCandidate(
            sheetName: entry.key,
            headerRowIndex: rowIndex,
            dataRowIndex: _dataRowFor(sheet, rowIndex),
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

    return MeeshoTemplate(
      fileName: fileName,
      bytes: bytes,
      sheetName: best.sheetName,
      headerRowIndex: best.headerRowIndex,
      dataRowIndex: best.dataRowIndex,
      columns: best.columns,
    );
  }

  /// Full (untruncated) product value for every matched column, by column.
  Map<int, String> defaultValues(
    MeeshoTemplate template,
    ProductLinkData product,
  ) {
    return {
      for (final column in template.mappedColumns)
        column.columnIndex: _valueFor(column.fieldKey!, product),
    };
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
      final edited = edits[column.columnIndex]?.trim();
      if (edited == null && !column.isMapped) continue;
      final value = edited ?? _valueFor(column.fieldKey!, product);
      if (value.isEmpty) continue;
      final key = column.fieldKey;
      values[column.columnIndex] = _NewCell(
        value,
        numeric: key != null && _numericKeys.contains(key)
            ? _numericText(key, value)
            : edited == null
            ? null
            : _plainNumber(value),
        force: edited != null,
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
      if (cell.numeric != null) {
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
      'title' => product.title,
      'description' =>
        product.description.isNotEmpty
            ? product.description
            : product.keyFeatures.join('\n'),
      'brand' => product.brand,
      'category' => product.category,
      'price' => product.price,
      'mrp' => _mrpFor(product),
      'discount' => _calculatedDiscount(product),
      'sku' => product.sku,
      'seller' => product.seller,
      'availability' => product.availability,
      'rating' => product.rating,
      'reviews' => product.reviewCount,
      'keywords' => product.keywords.join(', '),
      'features' => product.keyFeatures.join('\n'),
      'specs' =>
        product.specs.map((spec) => '${spec.label}: ${spec.value}').join('\n'),
      'sourceUrl' => product.sourceUrl,
      'photos' => product.photos.map((photo) => photo.url).join('\n'),
      _ => _valueForIndexed(key, product),
    };
    return value.trim();
  }

  String _valueForIndexed(String key, ProductLinkData product) {
    if (key.startsWith('photo:')) {
      final index = int.tryParse(key.substring(6)) ?? 0;
      if (index < 1 || index > product.photos.length) return '';
      return product.photos[index - 1].url;
    }
    if (key.startsWith('spec:')) {
      final label = key.substring(5);
      for (final spec in product.specs) {
        if (_normalize(spec.label) == label) return spec.value;
      }
      for (final spec in product.specs) {
        final normalized = _normalize(spec.label);
        if (normalized.length < 4) continue;
        if (normalized.contains(label) || label.contains(normalized)) {
          return spec.value;
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

  /// MRP is always the Meesho price plus [_mrpMargin]; the scraped MRP is only
  /// used when the price itself is unavailable.
  String _mrpFor(ProductLinkData product) {
    final price = _number(product.price);
    if (price == null) return product.mrp;
    final mrp = price + _mrpMargin;
    return mrp == mrp.roundToDouble() ? mrp.toInt().toString() : '$mrp';
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
  r'^(?:error status|error message|fields description|field names?|field type.*)$',
);

/// Headers that end in a generic word ("name", "price") but describe a
/// different field, so only an exact alias match may map them.
final _ambiguousHeader = RegExp(
  r'\b(?:manufacturer|packer|importer|generic|wrong|defective|returns?|'
  r'group|hsn|gst|weight|pincode|address|country|origin|net quantity)\b',
);

const _mrpMargin = 200;
const _numericKeys = {'price', 'mrp', 'discount', 'rating', 'reviews'};
