part of eventsourcing;

/// Parameter in einem SQL-Query
final RegExp _sqlToken = new RegExp(r"::(\w+)::");

/**
 * Gibt einen [EventHandler] zurück, der bei Aufruf einen SQL-Query ausführt.
 * Bei Ausführung des [EventHandler]s werden dabei die Platzhalter in [sql] nach dem Format "::EINTRAG::"
 * durch den jeweiligen Eventparameter EINTRAG ersetzt.
 * [ResultHandler] gibt an, was der EventHandler letztendlich zurückgibt.
 * */
BaseHandler prepareSQLSub(String sql, ResultHandler sub) {
  final List<String> fieldNames =
      _sqlToken.allMatches(sql).map((m) => m.group(1)).toList();
  final String rawQuery = sql.replaceAll(_sqlToken, "?");

  // Cache für PreparedStatements
  final Map<ConnectionPool, Query> preparedCache = {};

  return (Map event, QueriableConnection conn) async {
    // Benötigte Parameter: Werte, die als Queryparameter vorkommen (::Benutzername::)
    fieldNames
        .where((f) => !event.containsKey(f))
        .forEach((f) => throw "Parameter $f fehlt.");

    final List<String> parameters = fieldNames.map((f) => event[f]).toList();

    Results result;

    // Wenn der SQL-Query auf dem [ConnectionPool] ausgeführt werden soll, kann er bei der ersten Ausführung als prepared
    // Statement gecached werden (relevant dann für Queries)
    if (conn is ConnectionPool) {
      final Query q = preparedCache.containsKey(conn)
          ? preparedCache[conn]
          : await conn.prepare(rawQuery);
      preparedCache[conn] = q;

      if (preparedCache.length > 10) {
        for (QueriableConnection c in preparedCache.keys) {
          if (c != conn) {
            preparedCache.remove(c);
            break;
          }
        }
      }

      result = await q.execute(parameters);
    } else {
      // Für Transaktionen (Events) kann vorläufig nicht mit prepared Statements gearbeitet werden (sqljocky-Klassenhierarchie)
      result = await conn.prepareExecute(rawQuery, parameters);
    }

    // Ungenutze Parameter aus der event-Map rauslöschen
    event.keys
        .where((k) => !fieldNames.contains(k))
        .toList()
        .forEach((k) => event.remove(k));

    return await sub(result);
  };
}

/**
 * Gibt einen [EventHandler] zurück, der bei Aufruf den Query ausführt, Platzhalter darin ersetzt
 * und ansonsten kein Ergebnis zurückliefert.
 * */
EventHandler prepareSQL(String sql) {
  return prepareSQLSub(sql, (Results r) async => {});
}

/**
 * Gibt einen [QueryHandler] zurück, der bei Aufruf den Query ausführt, Platzhalter darin ersetzt
 * und die erste Ergebniszeile zurückliefert. Enthält die Antwort vom SQL-Server
 * keine oder mehr als eine Zeilen, wird eine Exception geworfen.
 * */
QueryHandler prepareSQLDetail(String sql) {
  return prepareSQLSub(sql, (Results r) async => await resultsToMap(r).first);
}

QueryHandler prepareSQLDetailRenamed(String sql, List<String> outputNames) {
  return prepareSQLSub(
      sql, (Results r) async => await resultsToMap(r, outputNames).first);
}

/**
 * Gibt einen [QueryHandler] zurück, der bei Aufruf den Query ausführt, Platzhalter darin ersetzt
 * und eine Liste mit den Ergebniszeilen zurückliefert (Eintrag [fieldName] in der Map).
 * */
QueryHandler prepareSQLList(String sql, [String fieldName = "result"]) {
  return prepareSQLSub(
      sql, (Results r) async => {fieldName: await resultsToMap(r).toList()});
}

/**
 * Gibt einen [QueryHandler] zurück, der bei Aufruf den Query ausführt, Platzhalter darin ersetzt
 * und eine Liste mit den Ergebniszeilen zurückliefert (Eintrag [fieldName] in der Map).
 * Die
 * */
QueryHandler prepareSQLListRenamed(
    String sql, String fieldName, List<String> outputNames) {
  return prepareSQLSub(
      sql,
      (Results r) async =>
          {fieldName: await resultsToMap(r, outputNames).toList()});
}

/**
 * Gibt einen Validator zurück, der eine Exception [error] wirft, wenn die Antwort auf den Query in [sql]
 * leer ist. Platzhalter in [sql] werden ersetzt.
 * */
Validator validatorSQLReturnsAtLeastOneLine(String sql,
    [String error = "Kein leeres Ergebnis erwartet"]) {
  final QueryHandler handler = prepareSQLList(sql);

  return (Map data, QueriableConnection conn) async {
    if ((await handler(data, conn))["result"].isEmpty) throw error;
  };
}

/**
 * Gibt einen Validator zurück, der eine Exception [error] wirft, wenn die Antwort auf den Query in [sql]
 * nicht leer ist. Platzhalter in [sql] werden ersetzt.
 * */
Validator validatorSQLReturnsEmptyResult(String sql,
    [String error = "Leeres Ergebnis erwartet"]) {
  final QueryHandler handler = prepareSQLList(sql);

  return (Map data, QueriableConnection conn) async {
    final r = (await handler(data, conn))["result"];

    if (r.isNotEmpty) {
      throw error;
    }
  };
}
