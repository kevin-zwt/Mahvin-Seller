import 'dart:typed_data';

import 'package:excel/excel.dart';

import 'meesho_template_service.dart';
import 'models/product_link_data.dart';
import 'xls_patcher.dart';
import 'xls_reader.dart';

/// Fills a Flipkart seller listing template (.xls or .xlsx) from a product and
/// writes the result as an .xlsx file.
///
/// The analysis result reuses the Meesho template types so the same field
/// editor works for both marketplaces.
class FlipkartTemplateService {
  const FlipkartTemplateService();

  MeeshoTemplate analyze(
    Uint8List bytes, {
    required String fileName,
    required ProductLinkData product,
  }) {
    final sheets = _readSheets(bytes);
    _Candidate? best;
    for (final sheet in sheets) {
      if (_isReferenceSheet(sheet.name)) continue;
      final limit = sheet.rows.length < 20 ? sheet.rows.length : 20;
      for (var rowIndex = 0; rowIndex < limit; rowIndex++) {
        final row = sheet.rows[rowIndex];
        if (!row.any((cell) => _normalize(cell) == 'seller sku id')) continue;
        final dataRow = _dataRowFor(sheet.rows, rowIndex);
        final columns = <MeeshoTemplateColumn>[];
        for (var column = 0; column < row.length; column++) {
          final header = _headerText(row[column]);
          if (header.isEmpty) continue;
          columns.add(
            _columnFor(sheet, column, header, rowIndex, dataRow, sheets, product),
          );
        }
        final mapped = columns.where((c) => c.isMapped).length;
        if (best == null || mapped > best.mapped) {
          best = _Candidate(sheet.name, rowIndex, dataRow, columns, mapped);
        }
      }
    }
    if (best == null || best.mapped < 2) {
      throw const MeeshoTemplateException(
        'No Flipkart listing headers found. Use the original Flipkart '
        'template with its "Seller SKU ID" header row intact.',
      );
    }
    return MeeshoTemplate(
      fileName: fileName,
      bytes: bytes,
      sheetName: best.sheetName,
      headerRowIndex: best.headerRow,
      dataRowIndex: best.dataRow,
      columns: best.columns,
    );
  }

  /// Flipkart only accepts its template under the name it was issued with, so
  /// a binary .xls keeps its file name.
  bool keepsFileName(MeeshoTemplate template) => isXlsFile(template.bytes);

  Map<int, String> defaultValues(
    MeeshoTemplate template,
    ProductLinkData product,
  ) {
    return {
      for (final column in template.mappedColumns)
        column.columnIndex: _keepsTemplateValue(column)
            ? column.existing
            : _defaultFor(column, product),
    };
  }

  /// The SKU and image links the uploaded template already holds stay as they
  /// are; everything else comes from the product.
  bool _keepsTemplateValue(MeeshoTemplateColumn column) {
    final key = column.fieldKey;
    return column.prefilled &&
        key != null &&
        (key == 'sku' || key.startsWith('photo:'));
  }

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

  /// A new .xlsx with every sheet of the template and the product written into
  /// the data row. Values the template already holds are kept unless edited.
  Uint8List fill(
    MeeshoTemplate template,
    ProductLinkData product, {
    Map<int, String> edits = const {},
  }) {
    final sheets = _readSheets(template.bytes);
    final target = sheets.where((s) => s.name == template.sheetName).toList();
    if (target.isEmpty) {
      throw const MeeshoTemplateException(
        'The template sheet is missing. Upload it again.',
      );
    }
    final listing = target.first;
    final header = listing.rows[template.headerRowIndex];
    final width = header.length;
    while (listing.rows.length <= template.dataRowIndex) {
      listing.rows.add(List.filled(width, ''));
    }
    final dataRow = listing.rows[template.dataRowIndex];
    while (dataRow.length < width) {
      dataRow.add('');
    }

    final defaults = defaultValues(template, product);
    final changes = <int, String>{};
    for (final column in template.columns) {
      final edited = edits[column.columnIndex]?.trim();
      final String value;
      if (edited != null) {
        value = column.options.isEmpty
            ? edited
            : (column.matchOption(edited) ?? '');
      } else {
        if (!column.isMapped || _keepsTemplateValue(column)) continue;
        value = defaults[column.columnIndex] ?? '';
      }
      if (value.isEmpty && edited == null) continue;
      dataRow[column.columnIndex] = value;
      changes[column.columnIndex] = value;
    }

    final types = template.headerRowIndex + 1 < listing.rows.length
        ? listing.rows[template.headerRowIndex + 1]
        : const <String>[];

    // A binary .xls is edited in place so the file stays exactly as Flipkart
    // issued it (sheets, styles, dropdowns), with only the new cells added.
    if (isXlsFile(template.bytes)) {
      final cells = <int, XlsCellValue>{};
      changes.forEach((column, value) {
        final numeric =
            column < types.length &&
            _numericType.hasMatch(types[column].toLowerCase());
        final number = numeric ? double.tryParse(value.replaceAll(',', '')) : null;
        cells[column] = number == null
            ? XlsCellValue.text(value)
            : XlsCellValue.number(number);
      });
      try {
        return patchXlsCells(template.bytes, template.sheetName, {
          template.dataRowIndex: cells,
        });
      } on Exception {
        throw const MeeshoTemplateException(
          'Could not write into this .xls template. Upload the original '
          'Flipkart file again.',
        );
      }
    }
    final excel = Excel.createExcel();
    for (final sheet in sheets) {
      final out = excel[sheet.name];
      final isListing = identical(sheet, listing);
      for (var r = 0; r < sheet.rows.length; r++) {
        final row = sheet.rows[r];
        for (var c = 0; c < row.length; c++) {
          final text = row[c];
          if (text.isEmpty) continue;
          final numeric =
              isListing &&
              r >= template.dataRowIndex &&
              c < types.length &&
              _numericType.hasMatch(types[c].toLowerCase());
          final number = numeric ? num.tryParse(text.replaceAll(',', '')) : null;
          out
              .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
              .value = number == null
              ? TextCellValue(text)
              : (number is int
                    ? IntCellValue(number)
                    : DoubleCellValue(number.toDouble()));
        }
      }
    }
    final defaultSheet = 'Sheet1';
    if (!sheets.any((s) => s.name == defaultSheet)) {
      excel.delete(defaultSheet);
    }
    final encoded = excel.encode();
    if (encoded == null) {
      throw const MeeshoTemplateException(
        'Could not create the filled Excel file. Try another template.',
      );
    }
    return Uint8List.fromList(encoded);
  }

  // ---------------------------------------------------------------------

  List<XlsSheet> _readSheets(Uint8List bytes) {
    if (isXlsFile(bytes)) {
      try {
        // Copy the rows so the caller can edit them.
        return [
          for (final sheet in readXls(bytes))
            XlsSheet(
              name: sheet.name,
              rows: [for (final row in sheet.rows) List<String>.of(row)],
            ),
        ];
      } on XlsFormatException {
        throw const MeeshoTemplateException(
          'Could not read this .xls file. Upload the original Flipkart '
          'template.',
        );
      }
    }
    try {
      final excel = Excel.decodeBytes(bytes);
      return [
        for (final entry in excel.tables.entries)
          XlsSheet(
            name: entry.key,
            rows: [
              for (final row in entry.value.rows)
                [for (final cell in row) _cellText(cell?.value)],
            ],
          ),
      ];
    } catch (_) {
      throw const MeeshoTemplateException(
        'Could not read this file. Upload a Flipkart .xls or .xlsx template.',
      );
    }
  }

  String _cellText(CellValue? value) {
    return switch (value) {
      null => '',
      TextCellValue() => value.value.toString(),
      IntCellValue() => value.value.toString(),
      DoubleCellValue() => value.value == value.value.roundToDouble()
          ? value.value.toInt().toString()
          : value.value.toString(),
      BoolCellValue() => value.value ? 'TRUE' : 'FALSE',
      _ => value.toString(),
    };
  }

  bool _isReferenceSheet(String name) {
    return RegExp(
      r'^(?:dropdownvalues|summary|index|listing faq|image guide|matching|'
      r'variant|template_version)',
      caseSensitive: false,
    ).hasMatch(name.trim());
  }

  /// The first row after the header's description rows ("To be filled by
  /// Flipkart" marks the last one).
  int _dataRowFor(List<List<String>> rows, int headerRow) {
    var last = headerRow;
    for (var r = headerRow + 1; r < rows.length && r <= headerRow + 6; r++) {
      final first = rows[r]
          .take(3)
          .map((c) => c.trim().toLowerCase())
          .any((c) => c.startsWith('to be filled'));
      if (first) last = r;
    }
    return last + 1;
  }

  String _headerText(String raw) {
    for (final line in raw.split(RegExp(r'[\r\n]+'))) {
      final text = line.trim();
      if (text.isNotEmpty) return text.length > 80 ? text.substring(0, 80) : text;
    }
    return '';
  }

  String _normalize(String text) => _headerText(text)
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  MeeshoTemplateColumn _columnFor(
    XlsSheet sheet,
    int column,
    String header,
    int headerRow,
    int dataRow,
    List<XlsSheet> sheets,
    ProductLinkData product,
  ) {
    final normalized = _normalize(header);
    final key = _keyFor(normalized, product);
    final existing = dataRow < sheet.rows.length &&
            column < sheet.rows[dataRow].length
        ? sheet.rows[dataRow][column].trim()
        : '';
    final options = _optionsFor(sheets, column, normalized);
    final system = _systemColumn.hasMatch(normalized);
    final base = MeeshoTemplateColumn(
      columnIndex: column,
      header: header,
      fieldKey: system ? null : key?.$1,
      fieldLabel: system ? null : key?.$2,
      editable: !system,
      required: _requiredHeaders.contains(normalized) ||
          (key != null && (key.$1 == 'price' || key.$1 == 'mrp')),
      prefilled: existing.isNotEmpty,
      existing: existing,
      options: options,
    );
    final value = base.isMapped
        ? (_keepsTemplateValue(base) ? existing : _defaultFor(base, product))
        : '';
    return MeeshoTemplateColumn(
      columnIndex: column,
      header: header,
      fieldKey: base.fieldKey,
      fieldLabel: base.fieldLabel,
      preview: value.length <= 70 ? value : '${value.substring(0, 67)}...',
      editable: base.editable,
      required: base.required,
      prefilled: base.prefilled,
      existing: existing,
      options: options,
    );
  }

  List<String> _optionsFor(List<XlsSheet> sheets, int column, String header) {
    for (final sheet in sheets) {
      if (sheet.name.toLowerCase() != 'dropdownvaluesforcolumn$column') {
        continue;
      }
      return [
        for (final row in sheet.rows)
          if (row.isNotEmpty && row.first.trim().isNotEmpty) row.first.trim(),
      ];
    }
    return _indexOptions(sheets)[header] ??
        (header == 'hsn' ? _seedHsnCodes : const []);
  }

  /// Allowed values listed on the template's "Index" sheet: attribute names in
  /// the row under the sub-category name, their values underneath.
  Map<String, List<String>> _indexOptions(List<XlsSheet> sheets) {
    final index = sheets.where((s) => s.name.toLowerCase() == 'index');
    if (index.isEmpty) return const {};
    final rows = index.first.rows;
    final result = <String, List<String>>{};
    for (var r = 1; r < rows.length; r++) {
      if (rows[r].isEmpty || rows[r].first.trim().isEmpty) continue;
      final header = rows[r];
      for (var c = 1; c < header.length; c++) {
        final name = _normalize(header[c]);
        if (name.isEmpty) continue;
        final values = <String>[];
        for (var v = r + 1; v < rows.length; v++) {
          if (rows[v].isNotEmpty && rows[v].first.trim().isNotEmpty) break;
          if (c < rows[v].length && rows[v][c].trim().isNotEmpty) {
            values.add(rows[v][c].trim());
          }
        }
        if (values.isNotEmpty) result[name] = values;
      }
    }
    return result;
  }

  (String, String)? _keyFor(String header, ProductLinkData product) {
    switch (header) {
      case 'seller sku id':
        return ('sku', 'SKU');
      case 'mrp inr':
      case 'mrp':
        return ('mrp', 'MRP');
      case 'your selling price inr':
      case 'selling price inr':
        return ('price', 'Selling price');
      case 'stock':
        return ('stock', 'Stock');
      case 'procurement sla day':
        return ('sla', 'Procurement SLA');
      case 'local handling fee inr':
      case 'zonal handling fee inr':
      case 'national handling fee inr':
        return ('fee', 'Handling fee');
      case 'model id':
        return ('model', 'Model ID');
      case 'quantity':
        return ('quantity', 'Quantity');
      case 'organic':
        return ('organic', 'Organic');
      case 'length cm':
        return ('length', 'Package length');
      case 'breadth cm':
        return ('breadth', 'Package breadth');
      case 'height cm':
        return ('height', 'Package height');
      case 'weight kg':
        return ('weight', 'Package weight');
      case 'country of origin':
        return ('country', 'Country of origin');
      case 'manufacturer details':
      case 'packer details':
      case 'importer details':
        return ('maker', 'Maker details');
      case 'brand':
        return ('brand', 'Brand');
      case 'description':
      case 'product description':
        return ('description', 'Description');
      case 'title':
      case 'product title':
      case 'product name':
        return ('title', 'Title');
      case 'search keywords':
        return ('keywords', 'Keywords');
      case 'key features':
        return ('features', 'Key features');
      case 'main image url':
        return ('photo:1', 'Main image');
    }
    final other = RegExp(r'^other image url (\d+)$').firstMatch(header);
    if (other != null) {
      final index = int.parse(other.group(1)!) + 1;
      return ('photo:$index', 'Image $index');
    }
    for (final spec in product.specs) {
      final label = _normalize(spec.label);
      if (label.length >= 3 && label == header) {
        return ('spec:$label', 'Spec: ${spec.label}');
      }
    }
    return null;
  }

  String _defaultFor(MeeshoTemplateColumn column, ProductLinkData product) {
    final key = column.fieldKey;
    if (key == null) return '';
    final raw = _valueFor(key, product).trim();
    if (column.options.isEmpty || raw.isEmpty) return raw;
    return column.matchOption(raw) ?? '';
  }

  String _valueFor(String key, ProductLinkData product) {
    switch (key) {
      case 'sku':
        return product.sku;
      case 'price':
        return _number(product.price)?.toString().replaceFirst(
              RegExp(r'\.0$'),
              '',
            ) ??
            '';
      case 'mrp':
        return _mrpFor(product);
      case 'stock':
        return '10';
      case 'length':
      case 'breadth':
      case 'height':
        return '10';
      case 'weight':
        return '0.2';
      case 'country':
        return 'India';
      case 'maker':
        return 'Mahvin Enterprise, Ahmedabad - 382350';
      case 'brand':
        // The source store's brand needs Flipkart approval, so the seller
        // enters their own approved brand.
        return '';
      case 'sla':
        return '2';
      case 'fee':
        return '0';
      case 'model':
        // Flipkart rejects a model name that contains a brand name, so the
        // source brand is left out of it.
        return product.sku.isNotEmpty
            ? product.sku
            : _withoutBrand(product).split(' ').take(4).join(' ');
      case 'quantity':
        return RegExp(
              r'(\d[\d,]*)\s*(?:seeds?|pcs|pieces|pack)\b',
              caseSensitive: false,
            ).firstMatch(product.title)?.group(1)?.replaceAll(',', '') ??
            '1';
      case 'organic':
        return 'No';
      case 'title':
        return product.title;
      case 'description':
        return product.description.isNotEmpty
            ? product.description
            : product.keyFeatures.join('\n');
      case 'keywords':
        return product.keywords.join('::');
      case 'features':
        return product.keyFeatures.join('::');
    }
    // Image links of the source store are never copied into the listing.
    if (key.startsWith('photo:')) return '';
    if (key.startsWith('spec:')) {
      final label = key.substring(5);
      for (final spec in product.specs) {
        if (_normalize(spec.label) == label) return spec.value;
      }
    }
    return '';
  }

  String _cleanTitle(String title) =>
      title.replaceFirst(RegExp(r'^\s*buy\s+', caseSensitive: false), '').trim();

  /// The title without the source brand (its brand field and the first title
  /// word, which is the brand on most marketplace titles).
  String _withoutBrand(ProductLinkData product) {
    final words = _cleanTitle(product.title).split(RegExp(r'\s+'));
    final brands = {
      ...product.brand.toLowerCase().split(RegExp(r'\s+')),
      if (words.isNotEmpty) words.first.toLowerCase(),
    };
    return words.where((w) => !brands.contains(w.toLowerCase())).join(' ');
  }

  /// The price is 40% of the MRP, as in the Meesho listing.
  String _mrpFor(ProductLinkData product) {
    final price = _number(product.price);
    if (price == null) return product.mrp;
    return '${(price * 100 / 40).ceil()}';
  }

  double? _number(String raw) {
    final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(raw.replaceAll(',', ''));
    return double.tryParse(match?.group(0) ?? '');
  }
}

/// Columns Flipkart fills itself.
final _systemColumn = RegExp(
  r'^(?:flipkart serial number|catalog qc status|qc failed reason.*|'
  r'flipkart product link|product data status|disapproval reason.*)$',
);

final _numericType = RegExp(r'integer|number|decimal');

/// HSN codes for seeds and plants, offered when the template has no list:
/// 1209 seeds for sowing (120930 flower, 120991 vegetable, 120999 other) and
/// 0602 other live plants.
const _seedHsnCodes = ['1209', '120930', '120991', '120999', '0602'];

/// Columns Flipkart rejects a listing for when they are empty.
const _requiredHeaders = {
  'brand',
  'model id',
  'common name',
  'items included',
  'quantity',
  'suitable for',
  'organic',
  'type of seed',
  'procurement sla day',
  'local handling fee inr',
  'zonal handling fee inr',
  'national handling fee inr',
  'hsn',
  'tax code',
};

class _Candidate {
  const _Candidate(
    this.sheetName,
    this.headerRow,
    this.dataRow,
    this.columns,
    this.mapped,
  );

  final String sheetName;
  final int headerRow;
  final int dataRow;
  final List<MeeshoTemplateColumn> columns;
  final int mapped;
}
