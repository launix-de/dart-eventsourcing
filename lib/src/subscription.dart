part of eventsourcing;

/**
 * Eine Subscription ist ein Abonnement einer bestimmten Anfrage (Aktion "subscribe" statt "query"
 * mit ansonsten identischen Parametern). Der Server antwortet zunächst wie auf die entsprechende "query"-Anfrage.
 * Anschließend prüft er bei jedem eingehenden Kommando (Aktion "push") und bei sonstigen
 * Zustandsänderungen des Systems, ob sich die angefragten Daten geändert haben.
 * In diesem Fall wird die aktualisierte Antwort geschickt. Die Subscription kann
 * jederzeit durch den Client mit der Aktion "unsubscribe" gelöst werden.
 */
class Subscription {
  /// Eine Subscription gehört immer zu genau einer WebSocket-Verbindung
  final WebSocketConnection conn;

  /// Vom Client ursprünglich gestellte Anfrage
  final Map querydata;

  /// Tracking-Nummer (JSON-Parameter "track"), die der Client bei der Anfrage mitgeschickt hat.
  /// Die Zuordnung der Subscription (in Bezug auf Kündigung und Antwort) erfolgt durch diese Nummer.
  final int trackId;

  /// Zuletzt geschickte Antwort, zum Abgleich bei Eingang eines neuen Kommandos
  int _lastResponseChecksum = -1;

  /// Wird bei Eingang eines neuen Kommandos am Server aufgerufen (nachdem das Kommando
  /// erfolgreich ausgeführt wurde). Führt die Anfrage an der Datenbank erneut aus
  /// und schickt ggf. eine neue Antwort an den Client.
  Future update() async {
    final Map result = await conn.router.submitQuery(querydata, conn.user);
    result["track"] = trackId;
    final String resultJSON = JSON.encode(result);

    final int checksum = CRC32.compute(resultJSON);
    if (checksum != _lastResponseChecksum) {
      conn.ws.add(resultJSON);
      _lastResponseChecksum = checksum;

      // Loggen
      if (!querydata["action"].startsWith("eventsourcing_actions")) {
        conn.router.logAction(
            eventid: 0,
            user: conn.user,
            parameters: JSON.encode(querydata),
            action: querydata.containsKey("action") ? querydata["action"] : "",
            type: "subscribeupdate",
            source: "wsapi",
            result: resultJSON,
            success: true);
      }
    }
  }

  /// Löst die Subscription
  void remove() {
    conn.subscriptions.remove(trackId);
    print("${conn.username} entfernt Subscription auf ${querydata['action']}");
  }

  /// Erstellt eine neue Subscription und schickt die erste Antwort
  Subscription(this.conn, this.querydata, this.trackId) {
    print(
        "Neue Subscription von ${conn.username}: ${querydata['action']}, TrackId $trackId");
    update();
  }
}
