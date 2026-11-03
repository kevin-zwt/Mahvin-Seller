import 'dart:convert';
import 'dart:typed_data';

import 'ole_file.dart';

/// The text and numbers of one worksheet, row by row ("" for empty cells).
class XlsSheet {
  const XlsSheet({required this.name, required this.rows});

  final String name;
  final List<List<String>> rows;
}

class XlsFormatException implements Exception {
  const XlsFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// True when [bytes] start with the OLE2 signature of a binary .xls file.
bool isXlsFile(Uint8List bytes) => OleFile.matches(bytes);

/// Reads the cell values of every sheet of a BIFF8 (Excel 97-2003) workbook.
/// Formulas give their last stored result; styles and validations are ignored.
List<XlsSheet> readXls(Uint8List bytes) {
  try {
    final ole = OleFile.parse(bytes);
    final stream = ole.readStream('Workbook') ?? ole.readStream('Book');
    if (stream == null) {
      throw const XlsFormatException('No workbook found in this .xls file.');
    }
    return _BiffReader(stream).read();
  } on OleFormatException catch (error) {
    throw XlsFormatException(error.message);
  }
}

// ---------------------------------------------------------------------------
// BIFF8 records

class _Record {
  const _Record(this.id, this.start, this.length);

  final int id;
  final int start;
  final int length;
}

class _BiffReader {
  _BiffReader(this.data) : view = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData view;

  List<String> _strings = const [];

  List<_Record> _records(int from) {
    final records = <_Record>[];
    var pos = from;
    while (pos + 4 <= data.length) {
      final id = view.getUint16(pos, Endian.little);
      final length = view.getUint16(pos + 2, Endian.little);
      if (pos + 4 + length > data.length) break;
      records.add(_Record(id, pos + 4, length));
      pos += 4 + length;
    }
    return records;
  }

  List<XlsSheet> read() {
    final all = _records(0);
    final sheets = <(String, int)>[];
    final sstParts = <_Record>[];
    var inSst = false;
    for (final record in all) {
      if (record.id == 0x00FC) {
        sstParts
          ..clear()
          ..add(record);
        inSst = true;
      } else if (record.id == 0x003C && inSst) {
        sstParts.add(record);
      } else {
        if (record.id != 0x003C) inSst = false;
        if (record.id == 0x0085) {
          final offset = view.getUint32(record.start, Endian.little);
          final nameLength = data[record.start + 6];
          final wide = data[record.start + 7] & 1 == 1;
          final nameStart = record.start + 8;
          final name = wide
              ? _utf16(nameStart, nameLength)
              : latin1.decode(data.sublist(nameStart, nameStart + nameLength));
          sheets.add((name, offset));
        }
      }
      // The workbook-level records end at the first sheet's BOF.
      if (record.id == 0x000A && sheets.isNotEmpty) break;
    }
    if (sstParts.isNotEmpty) _strings = _readSst(sstParts);

    final result = <XlsSheet>[];
    for (final (name, offset) in sheets) {
      result.add(XlsSheet(name: name, rows: _readSheet(offset)));
    }
    return result;
  }

  String _utf16(int start, int chars) {
    final units = <int>[
      for (var i = 0; i < chars; i++)
        view.getUint16(start + i * 2, Endian.little),
    ];
    return String.fromCharCodes(units);
  }

  // The shared string table continues across CONTINUE records, and each
  // continuation of a split string restarts with its own encoding flag.
  List<String> _readSst(List<_Record> parts) {
    var part = 0;
    var pos = parts[0].start + 8;
    var end = parts[0].start + parts[0].length;
    final total = view.getUint32(parts[0].start + 4, Endian.little);

    bool advance() {
      part++;
      if (part >= parts.length) return false;
      pos = parts[part].start;
      end = pos + parts[part].length;
      return true;
    }

    int readByte() {
      if (pos >= end && !advance()) throw const XlsFormatException('SST');
      return data[pos++];
    }

    int readUint16() {
      final low = readByte();
      return low | (readByte() << 8);
    }

    int readUint32() {
      final low = readUint16();
      return low | (readUint16() << 16);
    }

    final strings = <String>[];
    try {
      for (var i = 0; i < total; i++) {
        final length = readUint16();
        final flags = readByte();
        var wide = flags & 1 == 1;
        final hasRich = flags & 8 != 0;
        final hasPhonetic = flags & 4 != 0;
        final runs = hasRich ? readUint16() : 0;
        final phonetic = hasPhonetic ? readUint32() : 0;
        final buffer = StringBuffer();
        var remaining = length;
        while (remaining > 0) {
          if (pos >= end) {
            if (!advance()) throw const XlsFormatException('SST');
            wide = data[pos++] & 1 == 1;
          }
          final unit = wide ? 2 : 1;
          final available = (end - pos) ~/ unit;
          final take = remaining < available ? remaining : available;
          if (take == 0) {
            // A character split over the boundary cannot happen in BIFF8.
            if (!advance()) throw const XlsFormatException('SST');
            wide = data[pos++] & 1 == 1;
            continue;
          }
          if (wide) {
            buffer.write(_utf16(pos, take));
          } else {
            buffer.write(latin1.decode(data.sublist(pos, pos + take)));
          }
          pos += take * unit;
          remaining -= take;
        }
        var skip = runs * 4 + phonetic;
        while (skip > 0) {
          if (pos >= end && !advance()) break;
          final step = skip < end - pos ? skip : end - pos;
          pos += step;
          skip -= step;
        }
        strings.add(buffer.toString());
      }
    } on XlsFormatException {
      // Keep what was read.
    }
    return strings;
  }

  List<List<String>> _readSheet(int offset) {
    final cells = <int, Map<int, String>>{};
    var maxColumn = -1;

    void put(int row, int column, String value) {
      if (value.isEmpty) return;
      cells.putIfAbsent(row, () => {})[column] = value;
      if (column > maxColumn) maxColumn = column;
    }

    String number(double value) {
      if (value == value.roundToDouble() && value.abs() < 1e15) {
        return value.toInt().toString();
      }
      return value.toString();
    }

    var pos = offset;
    var depth = 0;
    int? pendingRow;
    int? pendingColumn;
    while (pos + 4 <= data.length) {
      final id = view.getUint16(pos, Endian.little);
      final length = view.getUint16(pos + 2, Endian.little);
      final start = pos + 4;
      pos = start + length;
      if (pos > data.length) break;
      switch (id) {
        case 0x0809: // BOF
          depth++;
        case 0x000A: // EOF
          depth--;
          if (depth <= 0) return _grid(cells, maxColumn);
        case 0x00FD: // LABELSST
          final index = view.getUint32(start + 6, Endian.little);
          put(
            view.getUint16(start, Endian.little),
            view.getUint16(start + 2, Endian.little),
            index < _strings.length ? _strings[index] : '',
          );
        case 0x0204: // LABEL
          final chars = view.getUint16(start + 6, Endian.little);
          final wide = data[start + 8] & 1 == 1;
          put(
            view.getUint16(start, Endian.little),
            view.getUint16(start + 2, Endian.little),
            wide
                ? _utf16(start + 9, chars)
                : latin1.decode(data.sublist(start + 9, start + 9 + chars)),
          );
        case 0x0203: // NUMBER
          put(
            view.getUint16(start, Endian.little),
            view.getUint16(start + 2, Endian.little),
            number(view.getFloat64(start + 6, Endian.little)),
          );
        case 0x027E: // RK
          put(
            view.getUint16(start, Endian.little),
            view.getUint16(start + 2, Endian.little),
            number(_rk(view.getUint32(start + 6, Endian.little))),
          );
        case 0x00BD: // MULRK
          final row = view.getUint16(start, Endian.little);
          final first = view.getUint16(start + 2, Endian.little);
          final last = view.getUint16(start + length - 2, Endian.little);
          for (var column = first; column <= last; column++) {
            final at = start + 4 + (column - first) * 6;
            put(
              row,
              column,
              number(_rk(view.getUint32(at + 2, Endian.little))),
            );
          }
        case 0x0205: // BOOLERR
          if (data[start + 7] == 0) {
            put(
              view.getUint16(start, Endian.little),
              view.getUint16(start + 2, Endian.little),
              data[start + 6] == 0 ? 'FALSE' : 'TRUE',
            );
          }
        case 0x0006: // FORMULA
          final row = view.getUint16(start, Endian.little);
          final column = view.getUint16(start + 2, Endian.little);
          if (view.getUint16(start + 12, Endian.little) == 0xFFFF) {
            final kind = data[start + 6];
            if (kind == 0) {
              pendingRow = row;
              pendingColumn = column;
            } else if (kind == 1) {
              put(row, column, data[start + 8] == 0 ? 'FALSE' : 'TRUE');
            }
          } else {
            put(row, column, number(view.getFloat64(start + 6, Endian.little)));
          }
        case 0x0207: // STRING (result of the previous formula)
          if (pendingRow != null && pendingColumn != null) {
            final chars = view.getUint16(start, Endian.little);
            final wide = data[start + 2] & 1 == 1;
            put(
              pendingRow,
              pendingColumn,
              wide
                  ? _utf16(start + 3, chars)
                  : latin1.decode(data.sublist(start + 3, start + 3 + chars)),
            );
            pendingRow = null;
            pendingColumn = null;
          }
      }
    }
    return _grid(cells, maxColumn);
  }

  double _rk(int raw) {
    double value;
    if (raw & 2 != 0) {
      value = (raw >> 2).toSigned(30).toDouble();
    } else {
      final bits = ByteData(8)..setUint32(4, raw & 0xFFFFFFFC, Endian.little);
      value = bits.getFloat64(0, Endian.little);
    }
    return raw & 1 != 0 ? value / 100 : value;
  }

  List<List<String>> _grid(Map<int, Map<int, String>> cells, int maxColumn) {
    if (cells.isEmpty) return const [];
    final lastRow = cells.keys.reduce((a, b) => a > b ? a : b);
    return [
      for (var row = 0; row <= lastRow; row++)
        [
          for (var column = 0; column <= maxColumn; column++)
            cells[row]?[column] ?? '',
        ],
    ];
  }
}
