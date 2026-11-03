import 'dart:convert';
import 'dart:typed_data';

import 'ole_file.dart';

/// A value to write into one cell of an existing .xls sheet.
class XlsCellValue {
  const XlsCellValue.text(String this.text) : number = null;
  const XlsCellValue.number(double this.number) : text = null;

  final String? text;
  final double? number;
}

class XlsPatchException implements Exception {
  const XlsPatchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Writes [edits] (row index -> column index -> value) into the sheet called
/// [sheetName] of a binary .xls file and returns the new file. Everything else
/// in the workbook (other sheets, styles, validations, hidden state) is kept
/// as it was; only the stored positions that the extra bytes shift are fixed.
Uint8List patchXlsCells(
  Uint8List file,
  String sheetName,
  Map<int, Map<int, XlsCellValue>> edits,
) {
  final ole = OleFile.parse(file);
  final workbook = ole.readStream('Workbook') ?? ole.readStream('Book');
  if (workbook == null) {
    throw const XlsPatchException('No workbook found in this .xls file.');
  }
  final patched = _patchWorkbook(workbook, sheetName, edits);
  return ole.replaceStream(
    ole.readStream('Workbook') != null ? 'Workbook' : 'Book',
    patched,
  );
}

/// The workbook stream with [edits] applied (exposed for tests).
Uint8List patchWorkbookStream(
  Uint8List workbook,
  String sheetName,
  Map<int, Map<int, XlsCellValue>> edits,
) => _patchWorkbook(workbook, sheetName, edits);

// BIFF record ids used here.
const _bof = 0x0809;
const _eof = 0x000A;
const _boundSheet = 0x0085;
const _index = 0x020B;
const _row = 0x0208;
const _dbCell = 0x00D7;
const _blank = 0x0201;
const _mulBlank = 0x00BE;
const _labelSst = 0x00FD;
const _number = 0x0203;
const _rk = 0x027E;
const _label = 0x0204;
const _mulRk = 0x00BD;
const _formula = 0x0006;
const _boolErr = 0x0205;
const _cellIds = {
  _blank,
  _mulBlank,
  _labelSst,
  _number,
  _rk,
  _label,
  _mulRk,
  _formula,
  _boolErr,
};
// Records that belong to the formula cell right before them.
const _formulaTrailers = {0x0207, 0x04BC, 0x0221, 0x0236};

class _Rec {
  _Rec(this.id, this.body);

  final int id;
  Uint8List body;

  int get size => 4 + body.length;

  Uint8List toBytes() {
    final out = Uint8List(size);
    final view = ByteData.sublistView(out);
    view.setUint16(0, id, Endian.little);
    view.setUint16(2, body.length, Endian.little);
    out.setRange(4, size, body);
    return out;
  }

  ByteData get view => ByteData.sublistView(body);
}

List<_Rec> _parse(Uint8List data) {
  final view = ByteData.sublistView(data);
  final out = <_Rec>[];
  var pos = 0;
  while (pos + 4 <= data.length) {
    final id = view.getUint16(pos, Endian.little);
    final length = view.getUint16(pos + 2, Endian.little);
    if (pos + 4 + length > data.length) {
      throw const XlsPatchException('Damaged workbook stream.');
    }
    out.add(_Rec(id, Uint8List.sublistView(data, pos + 4, pos + 4 + length)));
    pos += 4 + length;
  }
  return out;
}

Uint8List _serialize(List<_Rec> records) {
  final out = BytesBuilder(copy: false);
  for (final record in records) {
    out.add(record.toBytes());
  }
  return out.toBytes();
}

Uint8List _patchWorkbook(
  Uint8List workbook,
  String sheetName,
  Map<int, Map<int, XlsCellValue>> edits,
) {
  final records = _parse(workbook);

  // Sheet table: name -> stream offset of its BOF.
  final starts = <int>[];
  final names = <String>[];
  for (final record in records) {
    if (record.id != _boundSheet) continue;
    starts.add(record.view.getUint32(0, Endian.little));
    final length = record.body[6];
    final wide = record.body[7] & 1 == 1;
    names.add(
      wide
          ? String.fromCharCodes([
              for (var i = 0; i < length; i++)
                record.view.getUint16(8 + i * 2, Endian.little),
            ])
          : latin1.decode(record.body.sublist(8, 8 + length)),
    );
  }
  final sheetIndex = names.indexOf(sheetName);
  if (sheetIndex < 0) {
    throw XlsPatchException('Sheet $sheetName is missing.');
  }

  // Locate the sheet's records by stream offset.
  final offsets = <int>[];
  var position = 0;
  for (final record in records) {
    offsets.add(position);
    position += record.size;
  }
  final sheetStart = starts[sheetIndex];
  final first = offsets.indexOf(sheetStart);
  if (first < 0 || records[first].id != _bof) {
    throw const XlsPatchException('Could not find the sheet in the file.');
  }
  var depth = 0;
  var last = first;
  for (var i = first; i < records.length; i++) {
    if (records[i].id == _bof) depth++;
    if (records[i].id == _eof) {
      depth--;
      if (depth == 0) {
        last = i;
        break;
      }
    }
  }
  final oldSheetSize =
      offsets[last] + records[last].size - offsets[first];
  var sheet = records.sublist(first, last + 1);

  for (final entry in edits.entries) {
    sheet = _editRow(sheet, entry.key, entry.value);
  }
  _fixDbCells(sheet, sheetStart);

  final newSheetSize = sheet.fold<int>(0, (sum, r) => sum + r.size);
  final delta = newSheetSize - oldSheetSize;

  final before = records.sublist(0, first);
  final after = records.sublist(last + 1);
  if (delta != 0) {
    for (final record in before) {
      if (record.id != _boundSheet) continue;
      final at = record.view.getUint32(0, Endian.little);
      if (at > sheetStart) {
        record.view.setUint32(0, at + delta, Endian.little);
      }
    }
    // Later sheets store absolute positions of their row blocks.
    for (final record in after) {
      if (record.id != _index || record.body.length < 16) continue;
      final view = record.view;
      final defColumnWidth = view.getUint32(12, Endian.little);
      if (defColumnWidth != 0) {
        view.setUint32(12, defColumnWidth + delta, Endian.little);
      }
      for (var at = 16; at + 4 <= record.body.length; at += 4) {
        view.setUint32(at, view.getUint32(at, Endian.little) + delta, Endian.little);
      }
    }
  }
  return _serialize([...before, ...sheet, ...after]);
}

int _cellRow(_Rec record) => record.view.getUint16(0, Endian.little);

/// First and last column a cell record covers.
(int, int) _span(_Rec record) {
  final view = record.view;
  final first = view.getUint16(2, Endian.little);
  if (record.id == _mulBlank || record.id == _mulRk) {
    return (first, view.getUint16(record.body.length - 2, Endian.little));
  }
  return (first, first);
}

_Rec _newCell(int row, int column, int xf, XlsCellValue value) {
  final text = value.text;
  if (text == null) {
    final body = Uint8List(14);
    final view = ByteData.sublistView(body)
      ..setUint16(0, row, Endian.little)
      ..setUint16(2, column, Endian.little)
      ..setUint16(4, xf, Endian.little)
      ..setFloat64(6, value.number!, Endian.little);
    assert(view.lengthInBytes == 14);
    return _Rec(_number, body);
  }
  var content = text;
  if (content.length > 4000) content = content.substring(0, 4000);
  final wide = content.codeUnits.any((unit) => unit > 0xFF);
  final bytes = wide ? content.length * 2 : content.length;
  final body = Uint8List(9 + bytes);
  final view = ByteData.sublistView(body)
    ..setUint16(0, row, Endian.little)
    ..setUint16(2, column, Endian.little)
    ..setUint16(4, xf, Endian.little)
    ..setUint16(6, content.length, Endian.little);
  body[8] = wide ? 1 : 0;
  for (var i = 0; i < content.length; i++) {
    if (wide) {
      view.setUint16(9 + i * 2, content.codeUnitAt(i), Endian.little);
    } else {
      body[9 + i] = content.codeUnitAt(i);
    }
  }
  return _Rec(_label, body);
}

_Rec _blankRun(int row, int first, List<int> xfs) {
  if (xfs.length == 1) {
    final body = Uint8List(6);
    ByteData.sublistView(body)
      ..setUint16(0, row, Endian.little)
      ..setUint16(2, first, Endian.little)
      ..setUint16(4, xfs.first, Endian.little);
    return _Rec(_blank, body);
  }
  final body = Uint8List(4 + xfs.length * 2 + 2);
  final view = ByteData.sublistView(body)
    ..setUint16(0, row, Endian.little)
    ..setUint16(2, first, Endian.little);
  for (var i = 0; i < xfs.length; i++) {
    view.setUint16(4 + i * 2, xfs[i], Endian.little);
  }
  view.setUint16(4 + xfs.length * 2, first + xfs.length - 1, Endian.little);
  return _Rec(_mulBlank, body);
}

_Rec _rkRun(int row, int first, List<(int, int)> cells) {
  if (cells.length == 1) {
    final body = Uint8List(10);
    ByteData.sublistView(body)
      ..setUint16(0, row, Endian.little)
      ..setUint16(2, first, Endian.little)
      ..setUint16(4, cells.first.$1, Endian.little)
      ..setUint32(6, cells.first.$2, Endian.little);
    return _Rec(_rk, body);
  }
  final body = Uint8List(4 + cells.length * 6 + 2);
  final view = ByteData.sublistView(body)
    ..setUint16(0, row, Endian.little)
    ..setUint16(2, first, Endian.little);
  for (var i = 0; i < cells.length; i++) {
    view.setUint16(4 + i * 6, cells[i].$1, Endian.little);
    view.setUint32(6 + i * 6, cells[i].$2, Endian.little);
  }
  view.setUint16(4 + cells.length * 6, first + cells.length - 1, Endian.little);
  return _Rec(_mulRk, body);
}

/// The cells of [sheet] row [row] with [values] written in (column order).
List<_Rec> _editRow(
  List<_Rec> sheet,
  int row,
  Map<int, XlsCellValue> values,
) {
  // Find the row's block of cell records (plus formula trailers).
  var firstIndex = -1;
  var lastIndex = -1;
  for (var i = 0; i < sheet.length; i++) {
    final record = sheet[i];
    if (_cellIds.contains(record.id) && _cellRow(record) == row) {
      if (firstIndex < 0) firstIndex = i;
      lastIndex = i;
      while (lastIndex + 1 < sheet.length &&
          _formulaTrailers.contains(sheet[lastIndex + 1].id)) {
        lastIndex++;
      }
    } else if (firstIndex >= 0 && !_formulaTrailers.contains(record.id)) {
      break;
    }
  }
  if (firstIndex < 0) {
    // No cells yet: they go after the last cell of the previous rows of the
    // same block, or after the ROW records when this is the block's first row.
    final rowIndex = sheet.indexWhere(
      (r) => r.id == _row && r.view.getUint16(0, Endian.little) == row,
    );
    if (rowIndex < 0) {
      throw XlsPatchException('Row ${row + 1} is not in the sheet.');
    }
    var at = rowIndex + 1;
    while (at < sheet.length && sheet[at].id == _row) {
      at++;
    }
    while (at < sheet.length &&
        (_cellIds.contains(sheet[at].id) || _formulaTrailers.contains(sheet[at].id)) &&
        _cellRow(sheet[at]) < row) {
      at++;
    }
    final created = [
      for (final column in values.keys.toList()..sort())
        _newCell(row, column, 15, values[column]!),
    ];
    return [...sheet.sublist(0, at), ...created, ...sheet.sublist(at)];
  }

  final pending = values.keys.toList()..sort();
  final out = <_Rec>[];

  void flushBefore(int column) {
    while (pending.isNotEmpty && pending.first < column) {
      final c = pending.removeAt(0);
      out.add(_newCell(row, c, 15, values[c]!));
    }
  }

  for (var i = firstIndex; i <= lastIndex; i++) {
    final record = sheet[i];
    if (!_cellIds.contains(record.id)) {
      out.add(record);
      continue;
    }
    final (c0, c1) = _span(record);
    flushBefore(c0);
    final hit = [for (final c in pending) if (c >= c0 && c <= c1) c];
    if (hit.isEmpty) {
      out.add(record);
      continue;
    }
    if (record.id == _formula) {
      // Template formulas are kept; edits to them are skipped.
      pending.removeWhere(hit.contains);
      out.add(record);
      continue;
    }
    if (record.id == _mulBlank || record.id == _mulRk) {
      final isBlank = record.id == _mulBlank;
      final view = record.view;
      final step = isBlank ? 2 : 6;
      // (xf, rk) per column; rk is unused for blanks.
      final cells = <(int, int)>[
        for (var c = c0; c <= c1; c++)
          (
            view.getUint16(4 + (c - c0) * step, Endian.little),
            isBlank ? 0 : view.getUint32(6 + (c - c0) * step, Endian.little),
          ),
      ];
      var runStart = c0;
      void emitRun(int from, int to) {
        if (to < from) return;
        final part = cells.sublist(from - c0, to - c0 + 1);
        out.add(
          isBlank
              ? _blankRun(row, from, [for (final cell in part) cell.$1])
              : _rkRun(row, from, part),
        );
      }

      for (final c in hit) {
        emitRun(runStart, c - 1);
        out.add(_newCell(row, c, cells[c - c0].$1, values[c]!));
        pending.remove(c);
        runStart = c + 1;
      }
      emitRun(runStart, c1);
      continue;
    }
    // A single-cell record at an edited column: the new value takes its style.
    final xf = record.view.getUint16(4, Endian.little);
    out.add(_newCell(row, c0, xf, values[c0]!));
    pending.remove(c0);
  }
  flushBefore(0x10000);
  return [...sheet.sublist(0, firstIndex), ...out, ...sheet.sublist(lastIndex + 1)];
}

/// Recomputes every DBCELL (row block index) and the sheet's INDEX record for
/// the current record order.
void _fixDbCells(List<_Rec> sheet, int sheetStart) {
  final positions = <int>[];
  var position = sheetStart;
  for (final record in sheet) {
    positions.add(position);
    position += record.size;
  }

  final dbCellPositions = <int>[];
  var i = 0;
  while (i < sheet.length) {
    if (sheet[i].id != _row) {
      i++;
      continue;
    }
    final firstRow = i;
    var lastRow = i;
    while (lastRow + 1 < sheet.length && sheet[lastRow + 1].id == _row) {
      lastRow++;
    }
    final rowNumbers = [
      for (var r = firstRow; r <= lastRow; r++)
        sheet[r].view.getUint16(0, Endian.little),
    ];
    // Cells run until the block's DBCELL.
    var end = lastRow + 1;
    while (end < sheet.length && sheet[end].id != _dbCell) {
      end++;
    }
    if (end >= sheet.length) break;
    final firstCellPositions = <int, int>{};
    for (var c = lastRow + 1; c < end; c++) {
      if (!_cellIds.contains(sheet[c].id)) continue;
      firstCellPositions.putIfAbsent(_cellRow(sheet[c]), () => positions[c]);
    }
    final dbCell = sheet[end];
    final offsets = <int>[];
    int? previous;
    for (final row in rowNumbers) {
      final at = firstCellPositions[row];
      if (at == null) continue;
      offsets.add(
        previous == null
            ? at - (positions[firstRow] + sheet[firstRow].size)
            : at - previous,
      );
      previous = at;
    }
    final body = Uint8List(4 + offsets.length * 2);
    final view = ByteData.sublistView(body)
      ..setUint32(0, positions[end] - positions[firstRow], Endian.little);
    for (var k = 0; k < offsets.length; k++) {
      view.setUint16(4 + k * 2, offsets[k], Endian.little);
    }
    dbCell.body = body;
    dbCellPositions.add(positions[end]);
    i = end + 1;
  }

  for (final record in sheet) {
    if (record.id != _index) continue;
    final view = record.view;
    var at = 16;
    for (final dbCell in dbCellPositions) {
      if (at + 4 > record.body.length) break;
      view.setUint32(at, dbCell, Endian.little);
      at += 4;
    }
  }
}
