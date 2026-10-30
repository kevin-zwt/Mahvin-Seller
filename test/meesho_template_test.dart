import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/data/meesho_template_service.dart';
import 'package:flutter_app/data/models/product_link_data.dart';

void main() {
  const service = MeeshoTemplateService();

  group('Meesho template service', () {
    test('detects headers, skips the example row, and fills product data', () {
      final bytes = _templateBytes();
      final product = _product();
      final template = service.analyze(
        bytes,
        fileName: 'meesho-template.xlsx',
        product: product,
      );

      expect(template.sheetName, 'Sheet1');
      expect(template.headerRowNumber, 1);
      expect(template.dataRowNumber, 3);
      expect(template.mappedColumnCount, greaterThanOrEqualTo(10));
      expect(
        template.mappedColumns.map((column) => column.header),
        containsAll(<String>[
          'Product Name',
          'MRP',
          'Selling Price',
          'Color',
          'Image 1',
          'Image 2',
          'Product URL',
        ]),
      );

      final filled = service.fill(template, product);
      final workbook = Excel.decodeBytes(filled);
      final row = workbook.tables['Sheet1']!.rows[2];

      expect(_text(row[0]?.value), 'Cotton Kurti');
      expect(_text(row[2]?.value), 'DemoBrand');
      expect(_text(row[3]?.value), '999');
      expect(_text(row[4]?.value), '799');
      expect(_text(row[5]?.value), 'Blue');
      expect(_text(row[6]?.value), 'https://cdn.example.com/1.jpg');
      expect(_text(row[7]?.value), 'https://cdn.example.com/2.jpg');
      expect(_text(row[8]?.value), 'kurti, cotton');
      expect(_text(row[9]?.value), 'Soft fabric');
      expect(_text(row[10]?.value), 'https://example.com/p/1');
      expect(_text(row[11]?.value), 'KEEP');
    });

    test('handles the real Meesho Tshirts template without altering it', () {
      final file = File(
        'meesho template file/'
        'Tshirts-10000-EXTERNAL-MeeshoTemplate2PricesGSTIN.xlsx',
      );
      if (!file.existsSync()) return;
      final bytes = file.readAsBytesSync();
      final product = _product();
      final template = service.analyze(
        bytes,
        fileName: 'tshirts.xlsx',
        product: product,
      );

      expect(template.sheetName, 'Tshirts-Fill this');
      expect(template.headerRowNumber, 3);
      expect(template.dataRowNumber, 5);
      final byHeader = {for (final c in template.columns) c.header: c.fieldKey};
      expect(byHeader['Product Name'], 'title');
      expect(byHeader['Meesho Price'], 'price');
      expect(byHeader['MRP'], 'mrp');
      expect(byHeader['Color'], 'spec:color');
      expect(byHeader['Image 1 (Front)'], 'photo:1');
      expect(byHeader['Image 2'], 'photo:2');
      expect(byHeader['Brand Name'], 'brand');
      expect(byHeader['Manufacturer Name'], isNull);
      expect(byHeader['Packer Name'], isNull);
      expect(byHeader['Generic Name'], isNull);
      expect(byHeader['Wrong/Defective Returns Price'], isNull);

      final filled = service.fill(template, product);
      final row = Excel.decodeBytes(filled)
          .tables['Tshirts-Fill this']!
          .rows[4];
      expect(_text(row[3]?.value), 'Cotton Kurti');
      expect(_text(row[5]?.value), '799');
      expect(_text(row[7]?.value), '999');
      expect(_text(row[22]?.value), 'Blue');
      expect(_text(row[35]?.value), 'https://cdn.example.com/1.jpg');
      expect(_text(row[13]?.value), '');
      expect(row[6]?.value, isA<FormulaCellValue>());

      // Everything except the filled row and shared strings is untouched.
      final before = ZipDecoder().decodeBytes(bytes);
      final after = ZipDecoder().decodeBytes(filled);
      for (final name in [
        'xl/styles.xml',
        'xl/workbook.xml',
        'xl/worksheets/sheet3.xml',
        'xl/worksheets/sheet4.xml',
      ]) {
        expect(
          after.findFile(name)!.content,
          before.findFile(name)!.content,
          reason: name,
        );
      }
    });

    test('applies user edits to matched and unmatched columns', () {
      final product = _product();
      final template = service.analyze(
        _templateBytes(),
        fileName: 'meesho-template.xlsx',
        product: product,
      );
      final hsn = template.columns.firstWhere((c) => c.header == 'HSN');
      final color = template.columns.firstWhere((c) => c.header == 'Color');
      final defaults = service.defaultValues(template, product);
      expect(defaults[color.columnIndex], 'Blue');

      final filled = service.fill(
        template,
        product,
        edits: {hsn.columnIndex: '6109', color.columnIndex: 'Red'},
      );
      final row = Excel.decodeBytes(filled).tables['Sheet1']!.rows[2];
      expect(_text(row[hsn.columnIndex]?.value), '6109');
      expect(_text(row[color.columnIndex]?.value), 'Red');
      expect(_text(row[0]?.value), 'Cotton Kurti');
    });

    test('rejects a workbook without Meesho headers', () {
      final excel = Excel.createExcel();
      excel['Sheet1'].appendRow([TextCellValue('Some instructions')]);
      final bytes = Uint8List.fromList(excel.encode()!);

      expect(
        () => service.analyze(
          bytes,
          fileName: 'template.xlsx',
          product: _product(),
        ),
        throwsA(isA<MeeshoTemplateException>()),
      );
    });

    test('matches common header variations and computes discount', () {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow([
        TextCellValue('Product Title'),
        TextCellValue('SP'),
        TextCellValue('MRP (In Rs)'),
        TextCellValue('Discount Percentage'),
        TextCellValue('Image URL 1'),
        TextCellValue('Product Image 2'),
      ]);
      final bytes = Uint8List.fromList(excel.encode()!);

      final template = service.analyze(
        bytes,
        fileName: 'template.xlsx',
        product: _product(),
      );
      final filled = service.fill(template, _product());
      final row = Excel.decodeBytes(filled).tables['Sheet1']!.rows[1];

      expect(_text(row[0]?.value), 'Cotton Kurti');
      expect(_text(row[1]?.value), '799');
      expect(_text(row[2]?.value), '999');
      expect(_text(row[3]?.value), '20');
      expect(_text(row[4]?.value), 'https://cdn.example.com/1.jpg');
      expect(_text(row[5]?.value), 'https://cdn.example.com/2.jpg');
    });
  });
}

Uint8List _templateBytes() {
  final excel = Excel.createExcel();
  final sheet = excel['Sheet1'];
  sheet.appendRow([
    TextCellValue('Product Name'),
    TextCellValue('Product Description'),
    TextCellValue('Brand'),
    TextCellValue('MRP'),
    TextCellValue('Selling Price'),
    TextCellValue('Color'),
    TextCellValue('Image 1'),
    TextCellValue('Image 2'),
    TextCellValue('Keywords'),
    TextCellValue('Key Features'),
    TextCellValue('Product URL'),
    TextCellValue('HSN'),
  ]);
  sheet.appendRow([
    TextCellValue('Example product'),
    TextCellValue('Example description'),
  ]);
  sheet.cell(CellIndex.indexByColumnRow(columnIndex: 11, rowIndex: 2)).value =
      TextCellValue('KEEP');
  return Uint8List.fromList(excel.encode()!);
}

ProductLinkData _product() {
  return ProductLinkData(
    sourceUrl: 'https://example.com/p/1',
    siteName: 'Demo Store',
    title: 'Cotton Kurti',
    description: 'Soft cotton kurti for daily wear.',
    brand: 'DemoBrand',
    price: '₹799',
    mrp: '₹1,299',
    keywords: const ['kurti', 'cotton'],
    keyFeatures: const ['Soft fabric'],
    photos: const [
      ProductPhoto(url: 'https://cdn.example.com/1.jpg'),
      ProductPhoto(url: 'https://cdn.example.com/2.jpg'),
    ],
    specs: const [ProductSpec(label: 'Color', value: 'Blue')],
    fetchedAt: DateTime(2026, 1, 1),
  );
}

String _text(CellValue? value) {
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
