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
