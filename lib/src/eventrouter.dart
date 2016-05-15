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
  final bool skipplayback;

  /// Pool an SQL-Verbindungen (Standardmaximum 50)
  ConnectionPool db;

  final String dbhost, dbuser, dbpassword, dbname;

  Future _connectDb() async {
    try {
      db = new ConnectionPool(
          host: dbhost,
          port: 3306,
          user: dbuser,
          password: dbpassword,
          db: dbname,
          max: 50);
      await db.ping();
    } finally {
      try {
        db.closeConnectionsNow();
      } catch (e) {}
    }
  }

  /// EventQueue, in der die verarbeiteten Events gespeichert werden
  final File eventFile;

  /// Ordner, in den die alte EventQueue bei Start gesichert wird
  final Directory backupDirectory;

  final Directory uploadDirectory;

  final File backupFile;

  /// Eventfile sink
  EventFileWriter _eventFileSink = null;

  /// Eventfile mirror sink
  EventBackupFileWriter _eventFileBackup = null;

  /// Bekannte [EventHandler], die bei Ausführung eines bestimmten Events ausgeführt werden sollen
  final Map<String, List<EventHandler>> eventHandler;

  /// Bekannte [QueryHandler], die bei Ausführung eines bestimmten Queries ausgeführt werden sollen
  final Map<String, List<QueryHandler>> queryHandler;

  /// Höchste EventID, die bereits benutzt wurde. Neue Events erhalten eine höhere Nummer.
  int _biggestKnownEventId = 0;

  int _eventCount = 0;

  /// Authenticator used to check user credentials
  final Authoriser authenticator;

  /// Active web socket connections
  final List<WebSocketConnection> connections = [];

  /// Additional handlers to be executed for each *new* incoming event (not replayed ones)
  final List<EventHandler> pushHooks = [];

  /// Handlers that handle incoming http requests, defined by path prefix
  final Map<String, HttpHandler> httpHandler;

  /// Handlers that handle incoming websocket requests
  final List<WebSocketHandler> webSocketProviders = [];

  final EventHandler logActionInsertQuery = prepareSQL(
      "INSERT INTO eventsourcing_actions(eventid, user, timestamp, parameters, action, type, source, result, track, success) VALUES(::eventid::, ::user::, ::timestamp::, ::parameters::, ::action::, ::type::, ::source::, ::result::, ::track::, ::success::)");

  final QueryHandler logActionSelectQuery = prepareSQLDetailRenamed(
      "SELECT count(*) FROM eventsourcing_actions", ["count"]);

  final EventHandler logActionRemoveQuery = prepareSQL(
      "DELETE FROM eventsourcing_actions ORDER BY timestamp LIMIT 1");

  Future logAction(
      {int eventid: 0,
      int user: 0,
      int timestamp: -1,
      String parameters,
      String action,
      String type,
      String source,
      String result,
      bool success,
      int track: 0}) async {
    final logTransaction = await db.startTransaction();

    try {
      await logActionInsertQuery({
        "eventid": eventid,
        "user": user,
        "timestamp": timestamp == -1
            ? new DateTime.now().millisecondsSinceEpoch
            : timestamp,
        "parameters": parameters,
        "action": action,
        "type": type,
        "source": source,
        "result": result,
        "success": success ? 1 : 0,
        "track": track
      }, logTransaction);

      if ((await logActionSelectQuery({}, db))["count"] > 500) {
        await logActionRemoveQuery({}, logTransaction);
      }

      await logTransaction.commit();

      // Update subscriptions to eventsourcing_actions
      updateSubscriptions((s) =>
          s.querydata.containsKey("action") &&
          s.querydata["action"].startsWith("eventsourcing_actions"));
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
          errors.add(err.toString());

          // Beim Abspielen der Events Fehler ignorieren
          print(
              "$_eventCount Events verarbeitet; Eventfehler bei ${new DateTime.fromMillisecondsSinceEpoch(e["timestamp"])} von ${e.containsKey("user") ? e["user"] : "Unbekannt"}, ${e["action"]}: $err");
        }
      }
      await trans.commit();

      if (errors.isEmpty) {
        /* logAction(
            eventid: e.containsKey("id") ? e["id"] : 0,
            user: e.containsKey("user") ? e["user"] : 0,
            parameters: JSON.encode(e),
            action: e.containsKey("action") ? e["action"] : "",
            type: "push",
            source: "replay",
            result: "",
            success: true); */
      } else {
        logAction(
            eventid: e.containsKey("id") ? e["id"] : 0,
            user: e.containsKey("user") ? e["user"] : 0,
            parameters: JSON.encode(e),
            action: e.containsKey("action") ? e["action"] : "",
            type: "push",
            source: "replay",
            result: JSON.encode({"error": errors}),
            success: false);
      }
    } catch (e) {
      try {
        await trans.rollback();
      } catch (e) {}
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

  Future updateSubscriptions([bool f(Subscription s)]) async {
    final List<Future> updates = [];

    for (WebSocketConnection conn in connections) {
      if (f != null) {
        conn.subscriptions.values
            .where(f)
            .forEach((s) => updates.add(s.update()));
      } else {
        conn.subscriptions.values.forEach((s) => updates.add(s.update()));
      }
    }

    return Future.wait(updates);
  }

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
      final Map logged = new Map.from(e);
      if (logged.containsKey("type")) logged.remove("type");
      await _eventFileSink.add(logged);
      _eventFileBackup.update();

      updateSubscriptions();

      return {"id": finalInput["id"]};
    } catch (e) {
      try {
        await trans.rollback();
      } catch (e) {}
      print("Eventerror: $e");
      return {"error": e.toString()};
    }
  }

  EventRouter._EventRouter(
      this.httpHandler,
      this.eventHandler,
      this.queryHandler,
      this.eventFile,
      this.backupDirectory,
      this.backupFile,
      this.authenticator,
      this.skipplayback,
      this.dbhost,
      this.dbuser,
      this.dbpassword,
      this.dbname,
      this.uploadDirectory);

  /**
   * Erstellt einen neuen [EventRouter] mit den angegeben [EventHandler]n und
   * [QueryHandler]n.
   * */
  static Future<EventRouter> create(httpHandlers, eventHandler, queryHandler,
      {String eventFilePath,
      String backupPath,
      String backupFilePath,
      String databaseSchemaPath: 'lib/schema.sql',
      Authoriser authenticator,
      bool skipplayback: false,
      String dbHost,
      String dbUser,
      String dbPassword,
      String dbName,
      String uploadPath}) async {
    // Instanz anlegen
    final EventRouter es = new EventRouter._EventRouter(
        httpHandlers,
        eventHandler,
        queryHandler,
        new File(eventFilePath),
        new Directory(backupPath),
        new File(backupFilePath),
        authenticator,
        skipplayback,
        dbHost,
        dbUser,
        dbPassword,
        dbName,
        new Directory(uploadPath));

    await retry(es._connectDb,
        interval: new Duration(seconds: 5), tryLimit: 20);

    if (skipplayback)
      print("WARNING: Skipping eventqueue and database initialization");

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
    final server = await HttpServer.bind(InternetAddress.ANY_IP_V4, 8080);
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
    if (!skipplayback) await resetDatabase(new File(databaseSchemaPath), es);
    ;

    int startTime = 0;
    int endTime = new DateTime.now().millisecondsSinceEpoch;

    // Alte Events einspielen
    await for (Map m in readEventFile(new File(eventFilePath))) {
      if (startTime == 0 && m.containsKey("timestamp")) {
        startTime = m["timestamp"];
      }

      if (m.containsKey("id") && m["id"] >= es._biggestKnownEventId)
        es._biggestKnownEventId = m["id"];

      try {
        if (!skipplayback) await es.replayEvent(m);
      } catch (e) {
        print("Failed to play back event: $e");
      }

      if (m.containsKey("timestamp")) {
        replayProgress = (m["timestamp"] - startTime) / (endTime - startTime);
      }
    }

    replayProgress = 1.0;
    print("Successfully read events.");

    es._eventFileSink = new EventFileWriter(es.eventFile);
    es._eventFileBackup =
        new EventBackupFileWriter(es.eventFile, es.backupFile);
    await es._eventFileBackup.initialize();

    return es;
  }
}
