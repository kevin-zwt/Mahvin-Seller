import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/data/flipkart_template_service.dart';
import 'package:flutter_app/data/models/product_link_data.dart';
import 'package:flutter_app/data/xls_reader.dart';

void main() {
  const service = FlipkartTemplateService();
  final file = File('flipkart template file/plant-seed-FlipkartTemplate.xls');

  group('Flipkart template', () {
    test('reads every sheet of a binary .xls workbook', () {
      if (!file.existsSync()) return;
      final bytes = file.readAsBytesSync();
      expect(isXlsFile(bytes), isTrue);
      final sheets = readXls(bytes);
      final listing = sheets.firstWhere((s) => s.name == 'plant_seed');
      expect(listing.rows.first[6], 'Seller SKU ID');
      expect(listing.rows.first[11], 'Your selling price (INR)');
      expect(listing.rows[4][6], 'dummy_1');
      final countries = sheets.firstWhere(
        (s) => s.name == 'DropDownValuesForColumn26',
      );
      expect(countries.rows.first.first, 'India');
      expect(countries.rows.length, 247);
    });

    test('fills the listing sheet of the .xls in place', () {
      if (!file.existsSync()) return;
      final original = file.readAsBytesSync();
      final product = _product();
      final template = service.analyze(
        original,
        fileName: 'plant.xls',
        product: product,
      );
      expect(template.sheetName, 'plant_seed');
      expect(template.headerRowNumber, 1);
      expect(template.dataRowNumber, 5);
      expect(service.keepsFileName(template), isTrue);

      final byHeader = {for (final c in template.columns) c.header: c};
      expect(byHeader['Your selling price (INR)']!.fieldKey, 'price');
      expect(byHeader['MRP (INR)']!.fieldKey, 'mrp');
      expect(byHeader['Country Of Origin']!.options, contains('India'));
      expect(byHeader['Flipkart Product Link']!.editable, isFalse);

      final bytes = service.fill(template, product);
      // Still a binary .xls with every sheet of the original.
      expect(isXlsFile(bytes), isTrue);
      final before = readXls(original);
      final after = readXls(bytes);
      expect(after.map((s) => s.name), before.map((s) => s.name));
      for (var i = 0; i < before.length; i++) {
        if (before[i].name == 'plant_seed') continue;
        expect(after[i].rows, before[i].rows, reason: before[i].name);
      }
      final row = after.firstWhere((s) => s.name == 'plant_seed').rows[4];
      // The SKU and image link the template already holds are kept.
      expect(row[6], 'dummy_1');
      expect(row[43], startsWith('https://fkmpimages.flixcart.com/'));
      // Source-store images are never copied.
      expect(row[44], '');
      expect(row[11], '149');
      expect(row[10], '373');
      expect(row[15], '10');
      expect(row[26], 'India');
      // The seller enters their own approved brand.
      expect(row[34], '');
      expect(row[60], 'Nice seeds');
      expect(row[61], 'seed::flower');
    });

    test('user edits win over the product and the template', () {
      if (!file.existsSync()) return;
      final product = _product();
      final template = service.analyze(
        file.readAsBytesSync(),
        fileName: 'plant.xls',
        product: product,
      );
      final bytes = service.fill(template, product, edits: {6: 'MY-SKU'});
      final row = readXls(bytes).firstWhere((s) => s.name == 'plant_seed').rows[4];
      expect(row[6], 'MY-SKU');
    });

    test('an .xlsx template is rebuilt as .xlsx', () {
      final excel = Excel.createExcel();
      final sheet = excel['Listing'];
      void put(int column, int row, String text) => sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: row))
          .value = TextCellValue(text);
      put(0, 0, 'Seller SKU ID');
      put(1, 0, 'Your selling price (INR)');
      put(1, 1, 'Single - Positive_integer');
      final product = _product();
      final template = service.analyze(
        Uint8List.fromList(excel.encode()!),
        fileName: 'listing.xlsx',
        product: product,
      );
      expect(service.keepsFileName(template), isFalse);
      final filled = Excel.decodeBytes(service.fill(template, product));
      final row = filled.tables['Listing']!.rows[template.dataRowIndex];
      expect(row[1]?.value?.toString(), '149');
    });

    test('rejects a workbook without Flipkart headers', () {
      final excel = Excel.createExcel();
      excel['Sheet1']
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
          .value = TextCellValue(
        'Nothing',
      );
      expect(
        () => service.analyze(
          Uint8List.fromList(excel.encode()!),
          fileName: 'x.xlsx',
          product: _product(),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}

ProductLinkData _product() {
  return ProductLinkData(
    sourceUrl: 'https://example.com/p/1',
    siteName: 'Demo Store',
    title: 'Marigold seeds',
    description: 'Nice seeds',
    brand: 'Acme',
    sku: 'SKU9',
    price: '₹149',
    keywords: const ['seed', 'flower'],
    photos: const [
      ProductPhoto(url: 'https://cdn.example.com/1.jpg'),
      ProductPhoto(url: 'https://cdn.example.com/2.jpg'),
    ],
    fetchedAt: DateTime(2026, 1, 1),
  );
}
