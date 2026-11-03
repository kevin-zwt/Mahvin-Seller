import 'dart:typed_data';

class OleFormatException implements Exception {
  const OleFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _freeSector = 0xFFFFFFFF;
const _endOfChain = 0xFFFFFFFE;
const _fatSector = 0xFFFFFFFD;
const _maxRegular = 0xFFFFFFFA;

/// An OLE2 compound file (the container of a binary .xls workbook): streams
/// can be read, and one regular stream can be replaced while every other byte
/// of the file is kept.
class OleFile {
  OleFile._(
    Uint8List data,
    this._sectorSize,
    this._miniSize,
    this._miniCutoff,
    this._fat,
    this._fatSectorIds,
    this._dirStart,
    this._miniFatStart,
    this._miniFatCount,
  ) : _data = data;

  final Uint8List _data;
  final int _sectorSize;
  final int _miniSize;
  final int _miniCutoff;
  final List<int> _fat;
  final List<int> _fatSectorIds;
  final int _dirStart;
  final int _miniFatStart;
  final int _miniFatCount;

  static bool matches(Uint8List bytes) {
    const signature = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    if (bytes.length < 512) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  factory OleFile.parse(Uint8List data) {
    if (!matches(data)) throw const OleFormatException('Not an OLE2 file.');
    final view = ByteData.sublistView(data);
    final sectorSize = 1 << view.getUint16(30, Endian.little);
    final miniSize = 1 << view.getUint16(32, Endian.little);
    final fatCount = view.getUint32(44, Endian.little);
    final dirStart = view.getUint32(48, Endian.little);
    final miniCutoff = view.getUint32(56, Endian.little);
    final miniFatStart = view.getUint32(60, Endian.little);
    final miniFatCount = view.getUint32(64, Endian.little);
    var difatStart = view.getUint32(68, Endian.little);
    final difatCount = view.getUint32(72, Endian.little);

    Uint8List sectorBytes(int sector) {
      final start = (sector + 1) * sectorSize;
      if (start < 0 || start + sectorSize > data.length) {
        throw const OleFormatException('Damaged file.');
      }
      return Uint8List.sublistView(data, start, start + sectorSize);
    }

    final fatIds = <int>[];
    for (var i = 0; i < 109 && fatIds.length < fatCount; i++) {
      final id = view.getUint32(76 + i * 4, Endian.little);
      if (id < _maxRegular) fatIds.add(id);
    }
    for (var d = 0; d < difatCount && difatStart < _maxRegular; d++) {
      final sector = ByteData.sublistView(sectorBytes(difatStart));
      final per = sectorSize ~/ 4 - 1;
      for (var i = 0; i < per && fatIds.length < fatCount; i++) {
        final id = sector.getUint32(i * 4, Endian.little);
        if (id < _maxRegular) fatIds.add(id);
      }
      difatStart = sector.getUint32(per * 4, Endian.little);
    }
    final fat = <int>[];
    for (final id in fatIds) {
      final sector = ByteData.sublistView(sectorBytes(id));
      for (var i = 0; i < sectorSize ~/ 4; i++) {
        fat.add(sector.getUint32(i * 4, Endian.little));
      }
    }
    return OleFile._(
      data,
      sectorSize,
      miniSize,
      miniCutoff,
      fat,
      fatIds,
      dirStart,
      miniFatStart,
      miniFatCount,
    );
  }

  Uint8List _sector(int sector) {
    final start = (sector + 1) * _sectorSize;
    if (start < 0 || start + _sectorSize > _data.length) {
      throw const OleFormatException('Damaged file.');
    }
    return Uint8List.sublistView(_data, start, start + _sectorSize);
  }

  List<int> _chain(int start) {
    final out = <int>[];
    var sector = start;
    while (sector < _maxRegular && out.length <= _fat.length) {
      out.add(sector);
      if (sector >= _fat.length) break;
      sector = _fat[sector];
    }
    return out;
  }

  Uint8List _readChain(int start, [int? size]) {
    final out = BytesBuilder(copy: false);
    for (final sector in _chain(start)) {
      out.add(_sector(sector));
    }
    final all = out.toBytes();
    return size == null || size > all.length
        ? all
        : Uint8List.sublistView(all, 0, size);
  }

  /// Directory entries as (offset in directory bytes, name).
  List<(int, String)> _entries(Uint8List dir) {
    final view = ByteData.sublistView(dir);
    final entries = <(int, String)>[];
    for (var offset = 0; offset + 128 <= dir.length; offset += 128) {
      final nameLength = view.getUint16(offset + 64, Endian.little);
      if (nameLength < 2) continue;
      final units = <int>[
        for (var i = 0; i < (nameLength - 2) ~/ 2; i++)
          view.getUint16(offset + i * 2, Endian.little),
      ];
      entries.add((offset, String.fromCharCodes(units)));
    }
    return entries;
  }

  /// The bytes of the stream called [name], or null when there is none.
  Uint8List? readStream(String name) {
    final dir = _readChain(_dirStart);
    final view = ByteData.sublistView(dir);
    for (final (offset, entryName) in _entries(dir)) {
      if (entryName != name) continue;
      final start = view.getUint32(offset + 116, Endian.little);
      final size = view.getUint32(offset + 120, Endian.little);
      if (size >= _miniCutoff) return _readChain(start, size);
      final miniStream = _readChain(
        view.getUint32(116, Endian.little),
        view.getUint32(120, Endian.little),
      );
      final miniFat = ByteData.sublistView(
        _readChain(_miniFatStart, _miniFatCount * _sectorSize),
      );
      final out = BytesBuilder(copy: false);
      var sector = start;
      var guard = 0;
      while (sector < _maxRegular && guard++ < 1 << 20) {
        final at = sector * _miniSize;
        if (at + _miniSize > miniStream.length) break;
        out.add(Uint8List.sublistView(miniStream, at, at + _miniSize));
        if (sector * 4 + 4 > miniFat.lengthInBytes) break;
        sector = miniFat.getUint32(sector * 4, Endian.little);
      }
      final all = out.toBytes();
      return Uint8List.sublistView(all, 0, size.clamp(0, all.length));
    }
    return null;
  }

  /// A copy of the file in which the regular (not mini) stream [name] holds
  /// [content]; all other streams and the directory are unchanged.
  Uint8List replaceStream(String name, Uint8List content) {
    if (content.length < _miniCutoff) {
      throw const OleFormatException('Stream is too small to replace.');
    }
    final dir = Uint8List.fromList(_readChain(_dirStart));
    final dirView = ByteData.sublistView(dir);
    int? entryOffset;
    for (final (offset, entryName) in _entries(dir)) {
      if (entryName == name) entryOffset = offset;
    }
    if (entryOffset == null) {
      throw OleFormatException('No stream called $name.');
    }
    final oldSize = dirView.getUint32(entryOffset + 120, Endian.little);
    if (oldSize < _miniCutoff) {
      throw const OleFormatException('Stream is stored in the mini stream.');
    }
    final oldChain = _chain(dirView.getUint32(entryOffset + 116, Endian.little));

    final sectorsNeeded = (content.length + _sectorSize - 1) ~/ _sectorSize;
    final fat = List<int>.of(_fat);
    final fatSectorIds = List<int>.of(_fatSectorIds);
    var totalSectors = (_data.length ~/ _sectorSize) - 1;
    final appended = <int, Uint8List>{};

    int allocate() => totalSectors++;

    final chain = <int>[...oldChain.take(sectorsNeeded)];
    for (final freed in oldChain.skip(sectorsNeeded)) {
      fat[freed] = _freeSector;
    }
    while (chain.length < sectorsNeeded) {
      chain.add(allocate());
    }
    // Make sure the FAT can describe every sector, adding FAT sectors (placed
    // at the end of the file) when it cannot.
    while (totalSectors > fat.length) {
      final id = allocate();
      fatSectorIds.add(id);
      for (var i = 0; i < _sectorSize ~/ 4; i++) {
        fat.add(_freeSector);
      }
    }
    for (final id in fatSectorIds) {
      if (id >= fat.length) {
        throw const OleFormatException('FAT does not cover itself.');
      }
      fat[id] = _fatSector;
    }
    for (var i = 0; i < chain.length; i++) {
      fat[chain[i]] = i == chain.length - 1 ? _endOfChain : chain[i + 1];
    }
    if (fatSectorIds.length > 109) {
      throw const OleFormatException('Workbook is too large to update.');
    }

    // Header.
    final header = Uint8List.fromList(Uint8List.sublistView(_data, 0, 512));
    final headerView = ByteData.sublistView(header);
    headerView.setUint32(44, fatSectorIds.length, Endian.little);
    for (var i = 0; i < 109; i++) {
      headerView.setUint32(
        76 + i * 4,
        i < fatSectorIds.length ? fatSectorIds[i] : _freeSector,
        Endian.little,
      );
    }
    dirView.setUint32(entryOffset + 116, chain.first, Endian.little);
    dirView.setUint32(entryOffset + 120, content.length, Endian.little);

    // Sector payloads that change.
    final replaced = <int, Uint8List>{};
    for (var i = 0; i < chain.length; i++) {
      final piece = Uint8List(_sectorSize);
      final from = i * _sectorSize;
      final to = (from + _sectorSize).clamp(0, content.length);
      piece.setRange(0, to - from, content, from);
      replaced[chain[i]] = piece;
    }
    final dirChain = _chain(_dirStart);
    for (var i = 0; i < dirChain.length; i++) {
      replaced[dirChain[i]] = Uint8List.sublistView(
        dir,
        i * _sectorSize,
        (i + 1) * _sectorSize,
      );
    }
    for (var f = 0; f < fatSectorIds.length; f++) {
      final piece = Uint8List(_sectorSize);
      final view = ByteData.sublistView(piece);
      for (var i = 0; i < _sectorSize ~/ 4; i++) {
        view.setUint32(i * 4, fat[f * (_sectorSize ~/ 4) + i], Endian.little);
      }
      replaced[fatSectorIds[f]] = piece;
    }
    appended.addAll(replaced);

    final out = BytesBuilder(copy: false)..add(header);
    if (_sectorSize > 512) out.add(Uint8List(_sectorSize - 512));
    for (var sector = 0; sector < totalSectors; sector++) {
      final piece = appended[sector];
      if (piece != null) {
        out.add(piece);
      } else if ((sector + 1) * _sectorSize + _sectorSize <= _data.length) {
        out.add(_sector(sector));
      } else {
        out.add(Uint8List(_sectorSize));
      }
    }
    return out.toBytes();
  }
}
