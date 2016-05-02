part of eventsourcing;

/**
 * Converts a [Results] object to a stream of maps, each representing a sql row.
 * A sql row is returned as a map (indexed by field name).
 * [wantedNames] can be used to rename the map keys.
 */
Stream<Map<String, dynamic>> resultsToMap(Results r,
    [Iterable<String> wantedNames = null]) async* {
  List<String> fields;

  if (wantedNames == null) {
    fields = r.fields.map((f) => f.name).toList();
  } else {
    fields = wantedNames.toList();
  }

  await for (final Row row in r) {
    int i = 0;
    final Map data = {};
    for (var col in row) {
      var coldata = col;
      if (col is Blob) coldata = col.toString();
      if (i < fields.length) data[fields[i]] = coldata;
      i++;
    }

    yield data;
  }
}

/// Resets the database opened by [router]. All tables and views are deleted,
/// then [schemaFile] is executed which is expected to contain sql commands
/// that recreate the database structure.
/// Additionally, the table "eventsourcing_actions" and the view
/// "eventsourcing_actionsliste" are created. These are used as a log for
/// events executed by the system.
/// The whole reset is wrapped in a transaction.
Future resetDatabase(File schemaFile, EventRouter router) async {
  assert(await schemaFile.exists());

  final Iterable<String> sql = (await schemaFile.readAsString()).split(";");

  final Iterable<String> tables = (await (await router.db
              .query("SHOW FULL TABLES WHERE TABLE_TYPE != 'VIEW'"))
          .toList())
      .map((r) => r[0]);

  final Iterable<String> views = (await (await router.db
              .query("SHOW FULL TABLES WHERE TABLE_TYPE LIKE 'VIEW'"))
          .toList())
      .map((r) => r[0]);

  final Transaction trans = await router.db.startTransaction();

  if (tables.isNotEmpty)
    print("Lösche ${tables.length} Tabellen und spiele neues Schema ein...");

  try {
    if (tables.isNotEmpty || views.isNotEmpty) {
      await trans.query("SET foreign_key_checks = 0");
      if (views.isNotEmpty) await trans.query("DROP VIEW ${views.join(', ')}");
      if (tables.isNotEmpty)
        await trans.query("DROP TABLE ${tables.join(', ')}");
      await trans.query("SET foreign_key_checks = 1");
    }

    for (String s in sql) {
      if (s.trim().isNotEmpty) await router.db.query(s.replaceAll("::", ";"));
    }

    // Create meta tables
    await trans.query("""CREATE TABLE `eventsourcing_actions` (
      `id` BIGINT(20) NOT NULL AUTO_INCREMENT,
      `eventid` BIGINT(20) NOT NULL,
      `user` BIGINT(20) NOT NULL,
      `timestamp` BIGINT(20) NOT NULL,
      `parameters` TEXT NOT NULL,
      `action` VARCHAR(50) NOT NULL,
      `type` VARCHAR(20) NOT NULL,
      `source` VARCHAR(10) NOT NULL,
      `result` TEXT NOT NULL,
      `track` BIGINT(20) NOT NULL,
      `success` TINYINT(1) NOT NULL,
      PRIMARY KEY (`id`))
    ENGINE = MyISAM;
    """);

    await trans.query("""CREATE
     ALGORITHM = UNDEFINED
     VIEW `eventsourcing_actionsliste`
     AS SELECT e.id AS ID, e.eventid AS eventid, e.user AS user, e.timestamp AS timestamp,
        e.parameters AS parameters, e.action AS action, e.type AS type, e.source AS source,
        e.result AS result, e.track AS track, e.success AS success,
        u.Username AS username, isAdmin AS isAdmin, isQS AS isQS,
        IF(success=0, 'rgb(255,69,0)', IF(isAdmin=1, 'rgb(0,191,255)', 'rgb(255,255,255)')) AS color,
        IF(type="subscribe", (SELECT e2.timestamp FROM eventsourcing_actions e2 WHERE e2.type="unsubscribe" AND e2.track=e.track AND e2.timestamp>=e.timestamp ORDER BY e2.timestamp LIMIT 1), 0) AS unsubscribetimestamp
        FROM eventsourcing_actions e, Users u WHERE e.type!="unsubscribe" AND u.ID=e.user
        ORDER BY timestamp DESC""");

    await trans.commit();
    print("Neues Schema erfolgreich eingespielt.");
  } catch (e) {
    await trans.rollback();
    rethrow;
  }
}
