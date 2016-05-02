part of eventsourcing;

/**
 * Mirrors an event file (possibly written by an [EventFileWriter]) to a backup
 * file. After an event has been appended to the original event file, the [update]
 * method should be called. The EventBackupFileWriter instance then copies
 * over the new data. It will retry this infinitely in case of an error.
 */
class EventBackupFileWriter {
  /// Event file that should be mirrored
  final File eventFile;

  /// File the event file should be mirrored to
  final File backupFile;

  /// Internal reader for the original event file
  RandomAccessFile _eventFileReader;

  /// Internal writer for the mirrored event file
  RandomAccessFile _backupFileWriter;

  /// Creates a new EventBackupFileWriter that will mirror eventFile to backupFile.
  /// After instanciation, [initialize] has to be called, followed by [update]
  /// after new events have been written to [eventFile]
  EventBackupFileWriter(this.eventFile, this.backupFile);

  /// True if the file is currently updated asynchronously. Used internally for
  /// mutual exclusion.
  bool _updateRunning = false;

  /// True if [update] was called while an update was taking place. In this case,
  /// [update] will be called again automatically afterwards.
  bool _updateRequested = false;

  /// Called if an update of the mirrored file has failed. Waits one second
  /// and then tries again.
  Future onFailure(e) async {
    print("[!] Backup handling error $e; retrying...");

    await close();
    await new Future.delayed(const Duration(seconds: 1));

    return initialize();
  }

  /// (Re-)Initialises the EventBackupFileWriter and opens the original event
  /// file in read mode, the mirrored file in append mode. The mirrored file
  /// is created if inexistent. Calls [update] afterwards.
  Future initialize() async {
    // Reset update status
    _updateRunning = false;
    _updateRequested = false;

    // Open files; On failure, try again
    try {
      _eventFileReader = await eventFile.open();
      _backupFileWriter = await backupFile.open(mode: FileMode.APPEND);
    } catch (e) {
      return onFailure(e);
    }

    // Create mirrored file if it doesn't exist yet
    final bool fileExists = await backupFile.exists();
    if (!fileExists) {
      await backupFile.create();
      print("Created backup file ${backupFile.path}");
    }

    await update();
  }

  /// Updates the mirrored file; Checks the size of both files. If the original
  /// file is longer than the mirrored file, the additional data is copied
  /// over asynchronously.
  /// If [update] is called while this copy is still underway, update will
  /// be called again automatically after the first copy has been finished,
  /// to check again.
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

  /// Internal implementation of [update].
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

  /// Closes the original event file and the mirrored one, if opened.
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
