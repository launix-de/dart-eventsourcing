part of eventsourcing;

/**
 *  Hauptklasse, die für eine Instanz des EventSourcing-Systems steht.
 *  Integriert Datenbankzugriff (MySQL mit sqljocky), Eventsourcing in der Datei [eventsFile]
 *  und einen Webserver mit speziellem WebSocket-Protokoll (siehe [WebSocketClient])
 *  sowie Auslieferung von statischen Dateien in "html".
 *  Bei Start wird die aktuelle EventQueue in [eventFile] in eine neue Datei in
 *  [backupDirectory] gesichert. Zum Aufbau des Dateiformats siehe [readEventFile].
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

  /// Authenticator used to check user credentials
  final Authenticator authenticator;

  /// Active web socket connections
  final List<WebSocketConnection> connections = [];

  /// Eventfile sink
  EventFileWriter _eventQueueSink = null;

  /// Additional handlers to be executed for each *new* incoming event (not replayed ones)
  final List<EventHandler> pushHooks = [];

  /// Handlers that handle incoming http requests, defined by path prefix
  final Map<String, HttpHandler> httpHandler;

  /// Handlers that handle incoming websocket requests, defined by action parameter
  final Map<String, WebsocketHandler> wsHandler;

  final EventHandler logActionQuery = prepareSQL(
      "INSERT INTO eventsourcing_actions(eventid, user, timestamp, parameters, action, type, source, result, track, success) VALUES(::eventid::, ::user::, ::timestamp::, ::parameters::, ::action::, ::type::, ::source::, ::result::, ::track::, ::success::)");

  /// Saves the current EventQueue in [eventFile] in a new gzipped file in [backupDirectory] ("events_milliSecondsSinceEpoch.dat")
  Future backupEvents() async {
    final File tempEventFile = new File(backupDirectory.path + "/tmp.dat");
    await tempEventFile.create(recursive: true);
    final Stream<List<int>> eventsFile = eventFile.openRead();
    final IOSink tmpFile = tempEventFile.openWrite();

    await eventsFile.transform(GZIP.encoder).pipe(tmpFile);
    await tempEventFile.rename(backupDirectory.path +
        "/events_${new DateTime.now().millisecondsSinceEpoch}.dat");
  }

  Future logAction({int eventid: 0, int user: 0, int timestamp: -1, String parameters, String action, String type, String source, String result, bool success, int track: 0}) async {
      final logTransaction = await db.startTransaction();

      try {
        await logActionQuery({
          "eventid": eventid,
          "user": user,
          "timestamp": timestamp == -1 ? new DateTime.now().millisecondsSinceEpoch : timestamp,
          "parameters": parameters,
          "action": action,
          "type": type,
          "source": source,
          "result": result,
          "success": success ? 1 : 0,
          "track": track
        }, logTransaction);
        await logTransaction.commit();
      } catch (e) {
        print("Log error: $e");
        await logTransaction.rollback();
      }
  }

  /**
   * Spielt ein Event neu ab. Dabei werden Ausführungsfehler in einzelnen [EventHandler]n ignoriert
   * und das Ergebnis der anderen Handler trotzdem verwendet und in die Datenbank gesichert.
   * Die EventHandler werden alle *nacheinander* in *einer* Transaktion ausgeführt.
   * Unbekannte Events lösen eine Exception aus. Jedes Event sollte die Felder "action", "id" und "timestamp"
   * definieren.
   * */
  Future replayEvent(Map e) async {
    if (e.containsKey("id") && e["id"] >= _biggestKnownEventId)
      _biggestKnownEventId = e["id"];

    if (!eventHandler.containsKey(e["action"]))
      throw "Keine Verarbeitung für ${e["action"]} hinterlegt";

    final List<EventHandler> handlers = eventHandler[e["action"]];
    final Transaction trans = await db.startTransaction();
    final List<String> errors = [];

    try {
      for (EventHandler h in handlers) {
        final Map ep = new Map.from(e);

        try {
          await h(ep, trans);
        } catch (err) {
          errors.add(err);

          // Beim Abspielen der Events Fehler ignorieren
          print(
              "$_eventCount Events verarbeitet; Eventfehler bei ${new DateTime.fromMillisecondsSinceEpoch(e["timestamp"])} von ${e.containsKey("user") ? e["user"] : "Unbekannt"}, ${e["action"]}: $err");
        }
      }
      await trans.commit();

      if(errors.isEmpty){
        logAction(eventid: e.containsKey("id") ? e["id"] : 0, user: e.containsKey("user") ? e["user"] : 0, parameters: JSON.encode(e),
        action: e.containsKey("action") ? e["action"] : "", type: "push", source: "replay", result: "", success: true);
      } else {
        logAction(eventid: e.containsKey("id") ? e["id"] : 0, user: e.containsKey("user") ? e["user"] : 0, parameters: JSON.encode(e),
          action: e.containsKey("action") ? e["action"] : "", type: "push", source: "replay", result: JSON.encode({"error": errors}), success: false);
      }
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
      throw "Keine Verarbeitung für ${q["action"]} hinterlegt";

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

  int getNewEventId() => ++_biggestKnownEventId;

  /**
   * Spielt ein Event neu ab. Die EventHandler werden alle *nacheinander* in *einer* Transaktion ausgeführt.
   * Wirft einer der [EventHandler] eine Exception, wird ein Rollback ausgeführt und eine Map mit {"error": "msg"}
   * zurückgegeben.
   * Unbekannte Events lösen eine Exception aus. Jedes Event sollte das Feld "action" definieren.
   * **NOTE**: This method does not check auth.
   * */
  Future<Map> submitEvent(Map e, Map hookData, int user) async {
    if (!eventHandler.containsKey(e["action"]))
      throw new Exception("No event handlers defined for ${e["action"]}");

    final List<EventHandler> handlers = eventHandler[e["action"]];
    final Map finalInput = {
      "timestamp": new DateTime.now().millisecondsSinceEpoch,
      "id": getNewEventId(),
      "user": user
    };
    e.addAll(finalInput);
    final Transaction trans = await db.startTransaction(consistent: true);

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
      await trans.rollback();
      print("Eventerror: $e");
      return {"error": e.toString()};
    }
  }

  EventRouter._EventRouter(
      this.httpHandler,
      this.wsHandler,
      this.eventHandler,
      this.queryHandler,
      this.eventFile,
      this.backupDirectory,
      this.authenticator)
      : db = new ConnectionPool(
            host: 'localhost',
            port: 3307,
            user: 'event',
            password: 'event',
            db: 'event',
            max: 50) {}

  /**
   * Erstellt einen neuen [EventRouter] mit den angegeben [EventHandler]n und
   * [QueryHandler]n.
   * */
  static Future<EventRouter> create(
      httpHandlers, wsHandlers, eventHandler, queryHandler,
      {String eventFilePath: 'data/events.dat',
      String backupPath: 'data/backup',
      String databaseSchemaPath: 'lib/schema.sql',
      Authenticator authenticator}) async {
    // Instanz anlegen
    final EventRouter es = new EventRouter._EventRouter(
        httpHandlers,
        wsHandlers,
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
        new WebSocketConnection(ws, es, info);
      }
    }

    final staticFiles = new VirtualDirectory("html")..jailRoot = true;
    staticFiles.directoryHandler = (dir, request) {
      final indexUri = new Uri.file(dir.path).resolve('index.html');
      staticFiles.serveFile(new File(indexUri.toFilePath()), request);
    };
    final server = await HttpServer.bind(InternetAddress.ANY_IP_V4, 8338);
    server.forEach((HttpRequest req) async {
      try {
        String path = req.uri.path;
        final String pathWithoutSlash =
            path.startsWith("/") ? path.substring(1) : path;

        if (path.startsWith("/wsapi")) {
          final WebSocket ws = await WebSocketTransformer.upgrade(req);
          handleWs(ws, req.connectionInfo);
        } else {
          // Check if there is a http handler registered
          for (String prefix in es.httpHandler.keys) {
            if (pathWithoutSlash.startsWith(prefix)) {
              await es.httpHandler[prefix](es, req);

              return;
            }
          }

          // Static file
          if (path == "/" || path.isEmpty) path = "/index.html";
          path = path.replaceAll("..", "");
          staticFiles.serveFile(
              new File(Path.join("html", path.substring(1))), req);
        }
      } catch (e, st) {
        print(
            "Error handling HTTP-Request from ${req.connectionInfo.remoteAddress.host}: $e");
        print(st);
        try {
          req.response
            ..headers.contentType = ContentType.JSON
            ..statusCode = HttpStatus.INTERNAL_SERVER_ERROR;
        } catch (e) {}

        try {
          req.response
            ..write(JSON.encode({"error": e}))
            ..close();
        } catch (e) {}
      }
    });

    // Datenbank zurücksetzen (falls noch was drin ist)
    // await resetDatabase(new File(databaseSchemaPath), es.db);
    await backupFuture;

    int startTime = 0;
    int endTime = new DateTime.now().millisecondsSinceEpoch;

    // Alte Events einspielen
    await for (Map m in readEventFile(new File(eventFilePath))) {
      if (startTime == 0 && m.containsKey("timestamp")) {
        startTime = m["timestamp"];
      }

      // await es.replayEvent(m);

      if (m.containsKey("timestamp")) {
        replayProgress = (m["timestamp"] - startTime) / (endTime - startTime);
      }
    }

    replayProgress = 1.0;
    print("Events erfolgreich eingespielt.");
    es._biggestKnownEventId = 1000000;

    es._eventQueueSink = new EventFileWriter(new File(eventFilePath));

    return es;
  }
}
