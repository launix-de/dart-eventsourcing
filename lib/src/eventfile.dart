part of eventsourcing;

/**
 *  Liest die Datei ein und generiert einen String, der die enthaltenen Events enthält.
 *  Da yield in Dart aktuell synchron implementiert ist, wird die Datei nur so schnell
 *  eingelesen, wie die Daten aus dem Stream entnommen werden.
 *  Dateiformat: UINT16 (BE) Eventlänge n gefolgt von UTF8-kodiertem JSON-String mit dem Event (n Bytes) */
Stream<Map> readEventFile(File eventFile) async* {
  final Stream<List<int>> data = eventFile.openRead();
  List<int> list = [];

  final Uint8List tlist = new Uint8List(2);
  final ByteData bytes = new ByteData.view(tlist.buffer);

  await for (List<int> chunk in data) {
    list.addAll(chunk);

    while (list.length > 2) {
      tlist[0] = list[0];
      tlist[1] = list[1];

      final int len = bytes.getUint16(0);
      assert(len > 0);

      // Check, ob das komplette Event schon aus der Datei gelesen wurde
      if (list.length < 2 + len) break;

      final String eventstring = UTF8.decode(list.sublist(2, 2 + len));
      yield JSON.decode(eventstring);
      list = list.sublist(2 + len);
    }
  }

  assert(list.length == 0);
}

/**
 *  Gibt einen StreamController zurück, in den neue Events geschrieben werden können.
 *  Neue Events werden an [eventFile] angehängt.
 */

class EventFileWriter {
  final File eventFile;
  IOSink _file;

  EventFileWriter(File this.eventFile) {
    _file = eventFile.openWrite(mode: FileMode.APPEND);
  }

  Future add(Map m) async {
    final Uint8List tlist = new Uint8List(2);
    final ByteData bytes = new ByteData.view(tlist.buffer);

    final List<int> eventstring = UTF8.encode(JSON.encode(m));

    bytes.setUint16(0, eventstring.length);
    _file..add(tlist)..add(eventstring);

    await _file.flush();
  }

  Future close() async {
    await _file.close();
  }
}

class EventBackupFileWriter {
  final File eventFile;
  final File backupFile;

  RandomAccessFile _eventFileReader;
  RandomAccessFile _backupFileWriter;
  EventBackupFileWriter(this.eventFile, this.backupFile);

  bool _updateRunning = false;
  bool _updateRequested = false;

  Future onFailure(e) async {
    print("[!] Backup handling error $e; retrying...");

    await close();
    await new Future.delayed(const Duration(seconds: 1));

    return initialize();
  }

  Future initialize() async {
    _updateRunning = false;
    _updateRequested = false;

    try {
      _eventFileReader = await eventFile.open();
      _backupFileWriter = await backupFile.open(mode: FileMode.APPEND);
    } catch (e) {
      return onFailure(e);
    }

    await update();
  }

  Future update() async {
    if (!_updateRunning) {
      _updateRunning = true;
      try {
        await _update();
      } catch (e) {
        return onFailure(e);
      } finally {
        _updateRunning = false;
      }
      if (_updateRequested) {
        _updateRequested = false;
        return update();
      }
    } else {
      _updateRequested = true;
    }
  }

  Future _update() async {
    const MAX_CHUNK_SIZE = 4096;

    final int evlen = await eventFile.length();
    final int blen = await backupFile.length();

    int pos = blen;
    int writtenCount = 0;
    while (pos < evlen) {
      await _eventFileReader.setPosition(pos);
      final int newDataCount =
          evlen - pos > MAX_CHUNK_SIZE ? MAX_CHUNK_SIZE : evlen - pos;
      final List<int> newData = await _eventFileReader.read(newDataCount);
      await _backupFileWriter.writeFrom(newData);
      pos += newDataCount;
      writtenCount += newDataCount;
    }

    print("Backup updated with ${writtenCount} bytes");
  }

  Future close() async {
    try {
      await _eventFileReader.close();
    } catch (e) {
      print("Failed to close event file reader");
    }
    try {
      await _backupFileWriter.close();
    } catch (e) {
      print("Failed to close backup file writer");
    }
  }
}
