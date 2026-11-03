import 'dart:convert';
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
      // The source store's brand is never copied into the listing.
      expect(_text(row[2]?.value), '');
      expect(_text(row[3]?.value), '1998');
      expect(_text(row[4]?.value), '799');
      expect(_text(row[5]?.value), 'Blue');
      expect(_text(row[6]?.value), '');
      expect(_text(row[7]?.value), '');
      expect(_text(row[8]?.value), 'kurti, cotton');
      expect(_text(row[9]?.value), 'Soft fabric');
      // Links to another marketplace are never written.
      expect(_text(row[10]?.value), '');
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
      expect(byHeader['Inventory'], 'inventory');
      expect(byHeader['Net Weight (gms)'], 'weight');
      expect(byHeader['Manufacturer Name'], 'makerName');
      expect(byHeader['Packer Pincode'], 'makerPincode');
      expect(byHeader['Manufacturer Address'], 'makerAddress');
      expect(byHeader['Importer Name'], 'makerName');
      expect(byHeader['Country of Origin'], 'country');

      expect(byHeader['Generic Name'], isNull);
      expect(byHeader['Wrong/Defective Returns Price'], isNull);
      // The auto-calculated returns price is not offered for editing.
      final returns = template.columns.firstWhere(
        (c) => c.header == 'Wrong/Defective Returns Price',
      );
      expect(returns.editable, isFalse);
      // It is shown read-only in the app, recalculated from the price.
      final calculated = service.calculatedFields(template, product);
      expect(calculated.single.header, 'Wrong/Defective Returns Price');
      expect(calculated.single.value, '777');
      expect(
        service
            .calculatedFields(template, product, edits: {5: '1000'})
            .single
            .value,
        '978',
      );

      final filled = service.fill(template, product);
      final row = Excel.decodeBytes(filled)
          .tables['Tshirts-Fill this']!
          .rows[4];
      expect(_text(row[3]?.value), 'Cotton Kurti');
      expect(_text(row[5]?.value), '799');
      expect(_text(row[7]?.value), '1998');
      expect(_text(row[22]?.value), 'Blue');
      expect(_text(row[35]?.value), '');
      expect(_text(row[13]?.value), 'Mahvin Enterprise');
      expect(_text(row[16]?.value), 'Mahvin Enterprise');
      expect(_text(row[15]?.value), '382350');
      expect(_text(row[18]?.value), '382350');
      expect(_text(row[14]?.value), 'Ahmedabad');
      expect(_text(row[17]?.value), 'Ahmedabad');
      expect(_text(row[12]?.value), 'India');
      expect(_text(row[19]?.value), 'Mahvin Enterprise');
      expect(_text(row[20]?.value), 'Ahmedabad');
      expect(_text(row[21]?.value), '382350');
      expect(_text(row[10]?.value), '200');
      expect(_text(row[11]?.value), '10');
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

      final cleared = service.fill(
        template,
        product,
        edits: {color.columnIndex: ''},
      );
      final clearedRow = Excel.decodeBytes(cleared).tables['Sheet1']!.rows[2];
      expect(_text(clearedRow[color.columnIndex]?.value), '');
    });

    test('reads the template dropdown lists and keeps only valid choices', () {
      final file = File(
        'meesho template file/'
        'Tshirts-10000-EXTERNAL-MeeshoTemplate2PricesGSTIN.xlsx',
      );
      if (!file.existsSync()) return;
      final product = _product();
      final template = service.analyze(
        file.readAsBytesSync(),
        fileName: 'tshirts.xlsx',
        product: product,
      );
      MeeshoTemplateColumn column(String header) =>
          template.columns.firstWhere((c) => c.header == header);

      expect(column('GST %').options, isNotEmpty);
      expect(column('Country of Origin').options, contains('India'));
      expect(column('Color').options.length, greaterThan(5));
      expect(column('Product Name').options, isEmpty);
      expect(column('Color').matchOption('blue'), isNotNull);

      // "Blue" (a product spec) is a real choice; an unknown colour is not.
      expect(
        service.defaultValues(template, product)[column('Color').columnIndex],
        'Blue',
      );
      final odd = ProductLinkData(
        sourceUrl: 'https://x',
        siteName: 's',
        title: 'T',
        fetchedAt: DateTime(2026),
        specs: const [ProductSpec(label: 'Color', value: 'Zzz Unknown')],
      );
      final oddTemplate = service.analyze(
        file.readAsBytesSync(),
        fileName: 'tshirts.xlsx',
        product: odd,
      );
      expect(
        service.defaultValues(oddTemplate, odd)[column('Color').columnIndex],
        '',
      );
    });

    test('takes attribute columns from the product specifications', () {
      final file = File(
        'meesho template file/'
        'Tshirts-10000-EXTERNAL-MeeshoTemplate2PricesGSTIN.xlsx',
      );
      if (!file.existsSync()) return;
      final product = ProductLinkData(
        sourceUrl: 'https://x',
        siteName: 's',
        title: 'Brand Full Sleeve Solid Men Polo Neck T-Shirt',
        fetchedAt: DateTime(2026),
        specs: const [
          ProductSpec(label: 'Fabric', value: 'Cotton Blend'),
          ProductSpec(label: 'Neck Type', value: 'Polo Neck'),
          ProductSpec(label: 'Sleeve', value: 'Full Sleeve'),
          ProductSpec(label: 'Pattern', value: 'Solid'),
          ProductSpec(label: 'Pack of', value: '2'),
          ProductSpec(label: 'Fit', value: 'Regular'),
        ],
      );
      final template = service.analyze(
        file.readAsBytesSync(),
        fileName: 'tshirts.xlsx',
        product: product,
      );
      final defaults = service.defaultValues(template, product);
      final found = <String, String>{};
      for (final column in template.columns) {
        final value = defaults[column.columnIndex] ?? '';
        found[column.header] = value;
        // Dropdown columns only ever get one of the template's own choices.
        if (column.options.isNotEmpty && value.isNotEmpty) {
          expect(column.options, contains(value), reason: column.header);
        }
      }
      expect(found['Neck'], isNotEmpty);
      expect(found['Sleeve Length'], isNotEmpty);
      expect(found['Pattern'], isNotEmpty);
      expect(found['Net Quantity (N)'], '2');
      // Never guessed from unrelated specifications.
      expect(found['Length'], '');
      expect(found['Sleeve Styling'], '');
    });

    test('fills "Enter Meesho Price" under a grouped price header', () {
      // [enterColumn, customerColumn, customerFormula]
      for (final layout in [
        [1, 2, 'IF(B3>22,B3-22,"")'],
        [2, 1, 'C3+22'],
      ]) {
        final enter = layout[0] as int;
        final customer = layout[1] as int;
        final excel = Excel.createExcel();
        final sheet = excel['Sheet1'];
        void put(int column, int row, CellValue value) =>
            sheet
                    .cell(
                      CellIndex.indexByColumnRow(
                        columnIndex: column,
                        rowIndex: row,
                      ),
                    )
                    .value =
                value;
        put(0, 0, TextCellValue('Product Name'));
        put(1, 0, TextCellValue('Meesho Price'));
        put(enter, 1, TextCellValue('Enter Meesho Price'));
        put(customer, 1, TextCellValue('Customer Price'));
        put(customer, 2, FormulaCellValue(layout[2] as String));
        final template = service.analyze(
          Uint8List.fromList(excel.encode()!),
          fileName: 'template.xlsx',
          product: _product(),
        );

        expect(template.dataRowNumber, 3, reason: '$layout');
        final byHeader = {
          for (final c in template.columns) c.header: c.fieldKey,
        };
        expect(byHeader['Enter Meesho Price'], 'price', reason: '$layout');
        expect(byHeader['Customer Price'], isNull, reason: '$layout');
        final shown = service.calculatedFields(template, _product());
        expect(shown.single.header, 'Customer Price', reason: '$layout');
        expect(shown.single.value, customer == 2 ? '777' : '821');

        final filled = service.fill(template, _product());
        final xml = utf8.decode(
          ZipDecoder()
                  .decodeBytes(filled)
                  .findFile('xl/worksheets/sheet1.xml')!
                  .content
              as List<int>,
        );
        final enterRef = '${'ABC'[enter]}3';
        final customerRef = '${'ABC'[customer]}3';
        expect(xml, contains('<c r="$enterRef"><v>799</v></c>'));
        // The auto-calculated price keeps its formula and gets its result.
        final expected = customer == 2 ? '777' : '821';
        expect(
          RegExp('<c r="$customerRef"[^>]*><f>[^<]*</f><v>$expected</v></c>')
              .hasMatch(xml),
          isTrue,
          reason: '$layout $xml',
        );
      }
    });

    test('recalculates a formula that ships with a stale cached 0', () {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow([
        TextCellValue('Product Name'),
        TextCellValue('Meesho Price'),
        TextCellValue('Wrong/Defective Returns Price'),
      ]);
      sheet.appendRow([
        TextCellValue(''),
        TextCellValue(''),
        FormulaCellValue('IF(B2>12,B2-12,"")'),
      ]);
      // Excel can leave a cached 0 and attributes on the formula tag.
      final archive = ZipDecoder().decodeBytes(excel.encode()!);
      final output = Archive();
      for (final file in archive.files) {
        var bytes = file.content as List<int>;
        if (file.name == 'xl/worksheets/sheet1.xml') {
          bytes = utf8.encode(
            utf8
                .decode(bytes)
                .replaceAll('<f>', '<f aca="false">')
                .replaceAll('<v></v>', '<v>0</v>'),
          );
        }
        output.addFile(ArchiveFile(file.name, bytes.length, bytes));
      }
      final template = service.analyze(
        Uint8List.fromList(ZipEncoder().encode(output)!),
        fileName: 'template.xlsx',
        product: _product(),
      );
      final filled = service.fill(template, _product());
      final xml = utf8.decode(
        ZipDecoder()
                .decodeBytes(filled)
                .findFile('xl/worksheets/sheet1.xml')!
                .content
            as List<int>,
      );
      expect(
        RegExp('<c r="C2"[^>]*><f[^>]*>[^<]*</f><v>787</v></c>').hasMatch(xml),
        isTrue,
        reason: xml,
      );
    });

    test('replaces hint text such as "Enter Meesho Price" in the data row', () {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow([
        TextCellValue('Product Name'),
        TextCellValue('Enter Meesho Price'),
        TextCellValue('HSN Code'),
      ]);
      sheet.appendRow([
        TextCellValue('Enter product name'),
        TextCellValue('Enter Meesho Price'),
        TextCellValue('Select HSN code'),
      ]);
      final template = service.analyze(
        Uint8List.fromList(excel.encode()!),
        fileName: 'template.xlsx',
        product: _product(),
      );
      expect(template.dataRowNumber, 2);
      expect(template.columns[1].fieldKey, 'price');
      expect(template.columns[1].prefilled, isFalse);

      final row = Excel.decodeBytes(service.fill(template, _product()))
          .tables['Sheet1']!
          .rows[1];
      expect(_text(row[0]?.value), 'Cotton Kurti');
      expect(_text(row[1]?.value), '799');
      // Leftover hints are cleared rather than uploaded as values.
      expect(_text(row[2]?.value), '');
    });

    test('finds the selling price under common header wordings', () {
      for (final header in [
        'Meesho Price',
        '* Meesho Price (In Rs)',
        'MEESHO PRICE (Inclusive of GST)',
        'Selling Price incl. GST',
      ]) {
        final excel = Excel.createExcel();
        excel['Sheet1'].appendRow([
          TextCellValue('Product Name'),
          TextCellValue(header),
          TextCellValue('Wrong/Defective Returns Price'),
        ]);
        final template = service.analyze(
          Uint8List.fromList(excel.encode()!),
          fileName: 'template.xlsx',
          product: _product(),
        );
        final byHeader = {
          for (final c in template.columns) c.header: c.fieldKey,
        };
        expect(byHeader[template.columns[1].header], 'price', reason: header);
        expect(byHeader['Wrong/Defective Returns Price'], isNull);
        final row = Excel.decodeBytes(service.fill(template, _product()))
            .tables['Sheet1']!
            .rows[1];
        expect(_text(row[1]?.value), '799', reason: header);
      }
    });

    test('removes store brand, marketplace names and links from the text', () {
      final file = File(
        'meesho template file/'
        'Tshirts-10000-EXTERNAL-MeeshoTemplate2PricesGSTIN.xlsx',
      );
      if (!file.existsSync()) return;
      final product = ProductLinkData(
        sourceUrl: 'https://www.flipkart.com/tripr-full-sleeve-solid-men-sweatshirt/p/itm1?pid=P',
        siteName: 'Flipkart',
        title:
            'TRIPR Full Sleeve Solid Men Sweatshirt - Buy TRIPR Full Sleeve '
            'Solid Men Sweatshirt Online at Best Prices in India',
        description:
            'Buy TRIPR Full Sleeve Solid Men Sweatshirt for ₹466 online. '
            'Soft cotton sweatshirt for daily wear. Free Shipping. '
            'Cash on Delivery! Only on Flipkart.com',
        price: '₹466',
        fetchedAt: DateTime(2026),
      );
      final template = service.analyze(
        file.readAsBytesSync(),
        fileName: 'tshirts.xlsx',
        product: product,
      );
      final filled = service.fill(template, product);
      final row = Excel.decodeBytes(filled)
          .tables['Tshirts-Fill this']!
          .rows[4];

      expect(_text(row[3]?.value), 'Full Sleeve Solid Men Sweatshirt');
      final description = _text(row[43]?.value);
      expect(description, 'Soft cotton sweatshirt for daily wear.');
      for (final cell in row) {
        final text = _text(cell?.value).toLowerCase();
        expect(text, isNot(contains('tripr')));
        expect(text, isNot(contains('flipkart')));
      }
      expect(_text(row[5]?.value), '466');

      // Formulas carry their computed result: Returns Price = price - 22.
      final sheet = ZipDecoder()
          .decodeBytes(filled)
          .findFile('xl/worksheets/sheet5.xml')!;
      final xml = utf8.decode(sheet.content as List<int>);
      expect(xml, contains('F5-22,"")</f><v>444</v>'));
    });

    test('reports compulsory columns that would be left empty', () {
      final file = File(
        'meesho template file/'
        'Tshirts-10000-EXTERNAL-MeeshoTemplate2PricesGSTIN.xlsx',
      );
      if (!file.existsSync()) return;
      final product = _product();
      final template = service.analyze(
        file.readAsBytesSync(),
        fileName: 'tshirts.xlsx',
        product: product,
      );

      final missing = service.missingRequired(template, product);
      expect(missing, containsAll(['GST %', 'HSN ID', 'Fit/Shape']));
      // Filled from the product or defaults, or computed by the template.
      expect(missing, isNot(contains('Product Name')));
      expect(missing, isNot(contains('Fabric')));
      expect(missing, isNot(contains('Inventory')));
      expect(missing, isNot(contains('Importer Name')));
      // Optional columns never block.
      expect(missing, isNot(contains('Image 2')));
      expect(missing, isNot(contains('Wrong/Defective Returns Price')));

      final edits = {
        for (final column in template.columns)
          if (missing.contains(column.header)) column.columnIndex: 'x',
      };
      expect(service.missingRequired(template, product, edits: edits), isEmpty);
    });

    test('fills default inventory, weight and package size', () {
      final excel = Excel.createExcel();
      excel['Sheet1'].appendRow([
        TextCellValue('Product Name'),
        TextCellValue('Inventory'),
        TextCellValue('Weight (gms)'),
        TextCellValue('Package Length (cm)'),
        TextCellValue('Package Breadth (cm)'),
        TextCellValue('Package Height (cm)'),
      ]);
      final template = service.analyze(
        Uint8List.fromList(excel.encode()!),
        fileName: 'template.xlsx',
        product: _product(),
      );
      final row = Excel.decodeBytes(service.fill(template, _product()))
          .tables['Sheet1']!
          .rows[1];
      expect(
        [for (var i = 1; i <= 5; i++) _text(row[i]?.value)],
        ['10', '200', '10', '10', '10'],
      );
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
      expect(_text(row[2]?.value), '1998');
      expect(_text(row[3]?.value), '60');
      expect(_text(row[4]?.value), '');
      expect(_text(row[5]?.value), '');
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
