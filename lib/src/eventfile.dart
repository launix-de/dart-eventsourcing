part of eventsourcing;

/**
 * Reads [eventFile] and returns a stream with the contained events.
 *
 * File format: UINT16 (BE) n (size of following event), UTF8-encoded JSON-String containing the event data (n Bytes) */
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

      if (len == 0) {
        list = list.sublist(2);
        continue;
      }

      // Check whether the event has already been read
      if (list.length < 2 + len) break;

      final String eventstring = UTF8.decode(list.sublist(2, 2 + len));
      yield JSON.decode(eventstring);
      list = list.sublist(2 + len);
    }
  }

  assert(list.length == 0);
}

/**
 * Returns a StreamController that can be used to write new events. New events
 * are appended to [eventFile].
 */
class EventFileWriter {
  /// File events are appended to
  final File eventFile;

  /// File handle for [eventFile]
  IOSink _file;

  /// Creates a new [EventFileWriter] and opens [eventFile] in append mode
  EventFileWriter(File this.eventFile) {
    _file = eventFile.openWrite(mode: FileMode.APPEND);
  }

  /// Adds a new event to the file. The returned future completes after
  /// the file has been flushed.
  Future add(Map m) async {
    final Uint8List tlist = new Uint8List(2);
    final ByteData bytes = new ByteData.view(tlist.buffer);

    final List<int> eventstring = UTF8.encode(JSON.encode(m));
    final List<int> towrite = new List();

    bytes.setUint16(0, eventstring.length);
    towrite.addAll(tlist);
    towrite.addAll(eventstring);
    _file.add(towrite);

    await _file.flush();
  }

  /// Closes the writer and the opened file
  Future close() async {
    await _file.close();
  }
}
