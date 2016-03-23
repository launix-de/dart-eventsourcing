part of eventsourcing;

enum WebSocketState { UNAUTHENTICATED, OK, CLOSED }

class Subscription {
  final WebSocketConnection conn;
  final Map querydata;
  final int trackId;
  Map lastResponse = {};

  Future update() async {
    final Map result = await conn.router.submitQuery(querydata, conn.user);
    result["track"] = trackId;

    if (!(const DeepCollectionEquality().equals(result, lastResponse))) {
      conn.ws.add(JSON.encode(result));
      lastResponse = result;
    }
  }

  void remove() {
    conn.subscriptions.remove(trackId);
    print("${conn.username} entfernt Subscription auf ${querydata['action']}");
  }

  Subscription(this.conn, this.querydata, this.trackId) {
    print(
        "Neue Subscription von ${conn.username}: ${querydata['action']}, TrackId $trackId");
    update();
  }
}

class WebSocketConnection {
  final WebSocket ws;
  final EventRouter router;
  WebSocketState state = WebSocketState.UNAUTHENTICATED;
  final HttpConnectionInfo info;
  int user = 0;
  String username = "";
  final Map<int, Subscription> subscriptions = {};

  Future onAuthRequest(final Map data) async {
    final String nusername = data["username"];
    final String password = data["password"];

    try {
      user = await router.authenticator(
          nusername, password, info.remoteAddress.address, router.db);
    } catch (e) {
      ws.close(4401);
      print(
          "WebSocket-Login als $nusername an ${info.remoteAddress.host} abgelehnt");
      rethrow;
    }

    state = WebSocketState.OK;
    username = nusername;
    print("$username an ${info.remoteAddress.host} angemeldet");
  }

  Future onData(final String rawData) async {
    try {
      final Map data = JSON.decode(rawData);

      int trackId = -1;
      if (data.containsKey("track")) {
        trackId = data["track"];
        data.remove("track");
      }

      if (state == WebSocketState.UNAUTHENTICATED) await onAuthRequest(data);

      // print(data);

      final String type = data["type"];
      data.remove("type");

      switch (type) {
        case "get":
          try {
            final Map res = await router.submitQuery(new Map.from(data), user);
            res["track"] = trackId;
            ws.add(JSON.encode(res));
          } catch (e) {
            print("WS-Queryfehler bei $username, Aktion ${data["action"]}: $e");
            // print(stacktrace);
            final Map res = {"error": e, "track": trackId};
            ws.add(JSON.encode(res));
          }
          break;

        case "push":
          try {
            if (data.containsKey("username")) data.remove("username");
            if (data.containsKey("password")) data.remove("password");

            final Map res = await router.submitEvent(
                new Map.from(data), {"websocket": this}, user);
            res["track"] = trackId;
            ws.add(JSON.encode(res));
          } catch (e, stacktrace) {
            print("WS-Eventfehler bei $username, Aktion ${data["action"]}: $e");
            print(stacktrace);
            final Map res = {"error": e, "track": trackId};
            ws.add(JSON.encode(res));
          }
          break;

        case "subscribe":
          subscriptions[trackId] =
              new Subscription(this, new Map.from(data), trackId);
          break;

        case "unsubscribe":
          final int unsubtrack = data["unsubtrack"];
          if (subscriptions.containsKey(unsubtrack))
            subscriptions[unsubtrack].remove();
          break;
      }
    } catch (e) {
      // TODO: Mehr Handling
      print("WS-Fehler: $e.");
    }
  }

  void onClose() {
    state = WebSocketState.CLOSED;
    router.connections.remove(this);
    print("WS-Verbindung zu ${info.remoteAddress.host} verloren!");
  }

  WebSocketConnection(this.ws, this.router, this.info) {
    ws.listen((dat) {
      onData(dat);
    }, onDone: onClose);
    router.connections.add(this);
    print("Neue WS-Verbindung zu ${info.remoteAddress.host}!");

    // Verbindung timeouten, wenn kein Login für 5 Minuten
    new Timer(new Duration(minutes: 5), () {
      if (state == WebSocketState.UNAUTHENTICATED) {
        print(
            "WebSocket-Timeout zu ${info.remoteAddress.host} (Keine Authentifizierung in 5 Minuten)");
        ws.close();
      }
    });
  }
}

void acceptWs(WebSocket w, EventRouter router, HttpConnectionInfo info) {
  new WebSocketConnection(w, router, info);
}
