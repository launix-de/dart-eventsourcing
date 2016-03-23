part of eventsourcing;

/**
 *  Hauptklasse, die für eine Instanz des EventSourcing-Systems steht.
 *  Integriert Datenbankzugriff (MySQL mit sqljocky), Eventsourcing in der Datei [eventsFile]
 *  und einen Webserver mit speziellem WebSocket-Protokoll (siehe [WebSocketClient])
 *  sowie Auslieferung von statischen Dateien in "html".
 *  Bei Start wird die aktuelle EventQueue in [eventFile] in eine neue Datei in
 *  [backupDirectory] gesichert.
 *  */
class EventRouter {
  /// Pool an SQL-Verbindungen (Standardmaximum 50)
  final ConnectionPool db;

  /// EventQueue, in der die verarbeiteten Events gespeichert werden
  final File eventFile;

  /// Ordner, in den die alte EventQueue bei Start gesichert wird
  final Directory backupDirectory;

  /// Bekannte [EventHandler], die bei Ausführung eines bestimmten Events ausgeführt werden sollen
  final Map<String, List<EventHandler>> eventHandler;

  /// Bekannte [QueryHandler], die bei Ausführung eines bestimmten Queries ausgeführt werden sollen
  final Map<String, List<QueryHandler>> queryHandler;

  /// Höchste EventID, die bereits benutzt wurde. Neue Events erhalten eine höhere Nummer.
  int _biggestKnownEventId = 0;

  int _eventCount = 0;

  final Authenticator authenticator;

  final List<WebSocketConnection> connections = [];

  /// Sink für die Events
  EventFileWriter _eventQueueSink = null;

  /// Werden zusätzlich ausgeführt, wenn *neue* Events eingehen
  final List<EventHandler> pushHooks = [];

  /// Sichert die aktuelle EventQueue in [eventFile] in eine neue Datei in [backupDirectory] ("events_milliSecondsSinceEpoch.dat")
  Future backupEvents() async {
    final File tempEventFile = new File(backupDirectory.path + "/tmp.dat");
    await tempEventFile.create(recursive: true);
    final Stream<List<int>> eventsFile = eventFile.openRead();
    final IOSink tmpFile = tempEventFile.openWrite();

    await eventsFile.transform(GZIP.encoder).pipe(tmpFile);
    await tempEventFile.rename(backupDirectory.path +
        "/events_${new DateTime.now().millisecondsSinceEpoch}.dat");
  }

  /**
   * Spielt ein Event neu ab. Dabei werden Ausführungsfehler in einzelnen [EventHandler]n ignoriert
   * und das Ergebnis der anderen Handler trotzdem verwendet und in die Datenbank gesichert.
   * Die EventHandler werden alle *nacheinander* in *einer* Transaktion ausgeführt.
   * Unbekannte Events lösen eine Exception aus. Jedes Event sollte die Felder "action", "id" und "timestamp"
   * definieren.
   * */
  Future replayEvent(Map e) async {
    assert(e.containsKey("action") &&
        e.containsKey("id") &&
        e.containsKey("timestamp"));
    if (e.containsKey("id") && e["id"] >= _biggestKnownEventId)
      _biggestKnownEventId = e["id"];

    if (!eventHandler.containsKey(e["action"]))
      throw "Keine Verarbeitung für ${e["action"]} hinterlegt";

    final List<EventHandler> handlers = eventHandler[e["action"]];
    final Transaction trans = await db.startTransaction();

    try {
      for (EventHandler h in handlers) {
        final Map ep = new Map.from(e);

        try {
          await h(ep, trans);
        } catch (err) {
          // Beim Abspielen der Events Fehler ignorieren
          print(
              "$_eventCount Events verarbeitet; Eventfehler bei ${new DateTime.fromMillisecondsSinceEpoch(e["timestamp"])} von ${e.containsKey("user") ? e["user"] : "Unbekannt"}, ${e["action"]}: $err");
        }
      }
      await trans.commit();
    } catch (e) {
      await trans.rollback();
      rethrow;
    } finally {
      _eventCount++;
    }
  }

  /**
   * Führt eine Query aus. Löst ein [QueryHandler] eine Exception aus, wird eine Map mit {"error": "msg"}
   * zurückgegeben.
   * Aktuell werden die QueryHandler in einer konsistenten Transaction *parallel* ausgeführt.
   * */
  Future<Map> submitQuery(Map q, int user) async {
    if (!queryHandler.containsKey(q["action"]))
      throw new Exception("Keine Verarbeitung für ${q["action"]} hinterlegt");

    final List<QueryHandler> handlers = queryHandler[q["action"]];
    final Map finalOutput = {};
    q["timestamp"] = new DateTime.now().millisecondsSinceEpoch;
    q["user"] = user;

    // final Transaction trans = await db.startTransaction(consistent: true);

    final Iterable<Future> handlerRunners = handlers.map((h) async {
      var qo;
      try {
        qo = await h(new Map.from(q), db);
      } catch (e) {
        rethrow;
      }

      if (qo is Map) qo.forEach((k, v) => finalOutput[k] = v);
    });

    await Future.wait(handlerRunners, eagerError: true);

    // FinalOutput enthält alle Ausgaben (return to sender)
    return finalOutput;
  }

  /**
   * Spielt ein Event neu ab. Die EventHandler werden alle *nacheinander* in *einer* Transaktion ausgeführt.
   * Wirft einer der [EventHandler] eine Exception, wird ein Rollback ausgeführt und eine Map mit {"error": "msg"}
   * zurückgegeben.
   * Unbekannte Events lösen eine Exception aus. Jedes Event sollte die Felder "action", "id" und "timestamp"
   * definieren.
   * TODO: Die Events dürfen ja eigentlich auch parallel ausgeführt werden, da sie voneinander unabhängig sind
   * */
  Future<Map> submitEvent(Map e, Map hookData, int user) async {
    if (!eventHandler.containsKey(e["action"]))
      throw new Exception("Keine Verarbeitung für ${e["action"]} hinterlegt");

    final List<EventHandler> handlers = eventHandler[e["action"]];
    final Map finalInput = {
      "timestamp": new DateTime.now().millisecondsSinceEpoch,
      "id": ++_biggestKnownEventId,
      "user": user
    };
    e.addAll(finalInput);
    final Transaction trans = await db.startTransaction();

    try {
      for (EventHandler h in handlers) {
        await h(new Map.from(e), trans);
      }

      for (EventHandler hook in pushHooks) {
        final Map p = new Map.from(e);
        p.addAll(hookData);

        await hook(p, trans);
      }

      // FinalOutput enthält alle Ausgaben (return to sender)
      await trans.commit();

      // Erst nach Speichern an den Client bestätigen!
      await _eventQueueSink.add(e);

      for (WebSocketConnection conn in connections) {
        for (Subscription sub in conn.subscriptions.values) {
          // Subscriptionupdate anstoßen, aber nicht warten
          sub.update();
        }
      }

      return {"id": finalInput["id"]};
    } catch (e) {
      print("Eventerror: $e");
      await trans.rollback();
      return {"error": e.toString()};
    }
  }

  EventRouter._EventRouter(this.eventHandler, this.queryHandler, this.eventFile,
      this.backupDirectory, this.authenticator)
      : db = new ConnectionPool(
            host: 'localhost',
            port: 3306,
            user: 'event',
            password: 'event',
            db: 'event',
            max: 50) {}

  /**
   * Erstellt einen neuen [EventRouter] mit den angegeben [EventHandler]n und
   * [QueryHandler]n.
   * */
  static Future<EventRouter> create(eventHandler, queryHandler,
      {String eventFilePath: 'data/events.dat',
      String backupPath: 'data/backup',
      String databaseSchemaPath: 'lib/schema.sql',
      Authenticator authenticator}) async {
    // Instanz anlegen
    final EventRouter es = new EventRouter._EventRouter(
        eventHandler,
        queryHandler,
        new File(eventFilePath),
        new Directory(backupPath),
        authenticator);

    // Backup
    Future backupFuture = es.backupEvents();

    // Webserver aktivieren
    //  final frontendHandler =
    //      shelfstatic.createStaticHandler('html', defaultDocument: 'index.html');

    //  final shelfrouter = shelfroute.router();

    // Von 0 bis 1, wie weit das Einspielen der Events fortgeschritten ist
    double replayProgress = 0.0;

    void handleWs(WebSocket ws, HttpConnectionInfo info) {
      if (replayProgress < 1) {
        ws.close(
            4600 + (replayProgress * 100).floor(), "Events werden abgespielt");
      } else {
        acceptWs(ws, es, info);
      }
    }

    //shelfrouter
    //  ..get('/wsapi', wsHandler)
    //  ..add('/', ['GET'], frontendHandler, exactMatch: false); */

    final staticFiles = new VirtualDirectory("html")..jailRoot = true;
    staticFiles.directoryHandler = (dir, request) {
      final indexUri = new Uri.file(dir.path).resolve('index.html');
      staticFiles.serveFile(new File(indexUri.toFilePath()), request);
    };
    final server = await HttpServer.bind(InternetAddress.ANY_IP_V4, 8338);
    server.forEach((HttpRequest req) async {
      try {
        String path = req.uri.path;

        if (path.startsWith("/wsapi")) {
          final WebSocket ws = await WebSocketTransformer.upgrade(req);
          handleWs(ws, req.connectionInfo);
        } else {
          // Static file
          if (path == "/" || path.isEmpty) path = "/index.html";
          path = path.replaceAll("..", "");
          staticFiles.serveFile(
              new File(Path.join("html", path.substring(1))), req);
        }
      } catch (e) {
        print(
            "Verarbeitungsfehler bei HTTP-Request von ${req.connectionInfo.remoteAddress.host}");
        try {
          req.response.statusCode = 500;
          req.response.close();
        } catch (e) {}
      }
    });

    // Datenbank zurücksetzen (falls noch was drin ist)
    await resetDatabase(new File(databaseSchemaPath), es.db);
    await backupFuture;

    int startTime = 0;
    int endTime = new DateTime.now().millisecondsSinceEpoch;

    // Alte Events einspielen
    await for (Map m in readEventFile(new File(eventFilePath))) {
      if (startTime == 0 && m.containsKey("timestamp")) {
        startTime = m["timestamp"];
      }

      await es.replayEvent(m);

      if (m.containsKey("timestamp")) {
        replayProgress = (m["timestamp"] - startTime) / (endTime - startTime);
      }
    }

    replayProgress = 1.0;
    print("Events erfolgreich eingespielt.");

    es._eventQueueSink = new EventFileWriter(new File(eventFilePath));

    return es;
  }
}
