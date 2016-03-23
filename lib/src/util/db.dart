part of eventsourcing;

/**
 * Konvertiert ein [Results]-Objekt der [sqljocky]-Bibliothek (Stream von SQL-Ergebniszeilen)
 * in einen Stream von Maps.
 * */
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

Future resetDatabase(File schemaFile, ConnectionPool db) async {
  assert(await schemaFile.exists());

  final Iterable<String> sql = (await schemaFile.readAsString()).split(";");

  final Iterable<String> tables =
      (await (await db.query("SHOW FULL TABLES WHERE TABLE_TYPE != 'VIEW'"))
              .toList())
          .map((r) => r[0]);

  final Iterable<String> views =
      (await (await db.query("SHOW FULL TABLES WHERE TABLE_TYPE LIKE 'VIEW'"))
              .toList())
          .map((r) => r[0]);

  final Transaction trans = await db.startTransaction();

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
      if (s.trim().isNotEmpty) await db.query(s.replaceAll("::", ";"));
    }

    await trans.commit();
    print("Neues Schema erfolgreich eingespielt.");
  } catch (e) {
    await trans.rollback();
    rethrow;
  }
}
