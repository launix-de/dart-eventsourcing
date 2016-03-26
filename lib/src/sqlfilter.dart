part of eventsourcing;

enum QueryFilterMode { AND, OR }

class QueryFilter {
  static final List<String> allowedFilterOperators = [
    "=",
    ">=",
    "<=",
    "<",
    ">",
    "~"
  ];

  static bool hasSpecialChar(String s) {
    return patternCheck.hasMatch(s);
  }

  static final RegExp patternCheck =
      new RegExp("[^a-zA-Z0-9\\säöüÜÖÄß\\-\\./!\\,\\(\\)]");

  final QueryFilterMode mode;
  final List<String> parts = [];

  QueryFilter(this.mode, Map json, List<String> allowedColumns) {
    for (final String column in allowedColumns) {
      if (!json.containsKey(column) || json[column] == null) continue;

      final rawValue = json[column];
      List<String> values = [];

      if (rawValue is List) {
        values = json[column];
      } else {
        values = [rawValue];
      }

      for (String value in values) {
        String tocheck = value;
        bool doUpper = false;
        if (value.startsWith(">=") ||
            value.startsWith("<=") ||
            value.startsWith("!=")) {
          tocheck = value.substring(2);
          value = value.substring(0, 2) + "'" + tocheck + "'";
        } else if (value.startsWith("=")) {
          tocheck = value.substring(1);
          value = value.substring(0, 1) + "UPPER('" + tocheck + "')";
          doUpper = true;
        } else if (value.startsWith(">") || value.startsWith("<")) {
          tocheck = value.substring(1);
          value = value.substring(0, 1) + "'" + tocheck + "'";
        } else if (value.startsWith("~")) {
          tocheck = value.substring(1);
          value = " LIKE UPPER('%" + tocheck + "%')";
          doUpper = true;
        } else if (value == "NULL") {
          value = " IS NULL";
        } else if (value == "!NULL") {
          value = " IS NOT NULL";
        } else {
          // Annehmen, dass = gemeint ist
          value = "=UPPER('" + value + "')";
          doUpper = true;
        }

        if (hasSpecialChar(tocheck)) {
          throw "Filterung ist nicht erlaubt (Sonderzeichen o. ä.)";
        }

        if (doUpper) {
          parts.add("UPPER(" + column + ")" + value);
        } else {
          parts.add(column + value);
        }
      }
    }

    final List<Map> or = json.containsKey("OR")
        ? (json["OR"] is List ? json["OR"] : [json["OR"]])
        : [];
    for (Map value in or) {
      final QueryFilter subFilter =
          new QueryFilter(QueryFilterMode.OR, value, allowedColumns);
      parts.add(subFilter.toString());
    }

    final List<Map> and = json.containsKey("AND")
        ? (json["AND"] is List ? json["AND"] : [json["AND"]])
        : [];
    for (Map value in and) {
      final QueryFilter subFilter =
          new QueryFilter(QueryFilterMode.AND, value, allowedColumns);
      parts.add(subFilter.toString());
    }
  }

  String toString() {
    final StringBuffer builder = new StringBuffer();

    int i = 0;
    for (final String s in parts) {
      if (i > 0) {
        switch (mode) {
          case QueryFilterMode.AND:
            builder.write(" AND ");
            break;
          case QueryFilterMode.OR:
            builder.write(" OR ");
            break;
        }
      }
      builder.write("(");
      builder.write(s);
      builder.write(")");

      i++;
    }

    // System.out.println(builder.toString());
    return builder.toString();
  }
}

/**
 * Dient dem Filtern einer Tabelle / Views aus der Datenbank bzw. der Suche und Sortierung.
 *
 * In der JSON-Anfrage können Listen von möglichen Spaltenwerten angefragt werden:
 * 		{"action": "auftragAuflisten", "list": ["ort","monat"]}
 * 		=> {"result": [...], "list": {"ort": [{"name": "negersdorf", "count": 10}], "monat": [{"name": "januar", count: 5}]
 *
 * Außerdem können Filterwünsche mitgeschickt werden:
 * 		{"action": "auftragAuflisten", "filter": {"kunde": "=3"}, "offset": 0}
 * 		=> {"result": [{"kunde": "3", "ort": "negersdorf"}]}
 * Filterwünsche können mit AND und OR geschachtelt werden:
 * 		filter:{"kunde": "3", "AND": {"zeit": ">=3000", "AND": {"zeit": "<=6000"}}}
 * Das Wurzelfilterobjekt X ({"filter": X} in der Anfrage) wird als AND-verknüpft angenommen.
 * Es kann nur nach alphanumerischen Zeichenketten / Zahlen gesucht werden.
 * Mögliche Operatoren sind <, >, >=, <=, >=, =, ~ (enthält). Wird kein Operator angegeben, wird = angenommen.
 *
 * Ferner ist es möglich, eine Sortierung der Ausgabe anzufordern:
 * 		{"action": "auftragAuflisten", "order": [{"name": "zeit", "order": "ASC"}]}
 *
 */
QueryHandler filterQuery(String viewName) {
  return (Map input, QueriableConnection db) async {
    final Map data = {};
    final QueryHandler columnSelector = prepareSQLListRenamed(
        "SHOW COLUMNS FROM $viewName", "result", ["column"]);
    final Map<String, QueryHandler> columnMap = {};
    ((await columnSelector(new Map.from(input), db))["result"] as List)
        .forEach((col) {
      columnMap[col["column"]] = null;
    });

    final List<String> requestedValuesWanted =
        input.containsKey("list") ? input["list"] : null;
    final Map valuesWanted = {};
    String query = "SELECT * FROM $viewName";
    String countQuery = "SELECT count(*) AS count FROM " + viewName;
    String listQueryWhere = "";
    final Map requestedFilter =
        input.containsKey("filter") ? input["filter"] : null;
    if (requestedFilter != null && requestedFilter.isNotEmpty) {
      final String addon = " WHERE " +
          (new QueryFilter(QueryFilterMode.AND, requestedFilter,
                  columnMap.keys.toList()))
              .toString();

      query += addon;
      countQuery += addon;
      listQueryWhere = addon.trim();
    }

    final List<Map> requestedOrder =
        input.containsKey("order") ? input["order"] : null;
    if (requestedOrder != null && requestedOrder.isNotEmpty) {
      query += " ORDER BY ";
      int i = 0;
      for (Map obj in requestedOrder) {
        final String columnName = obj["name"];
        if (!columnMap.keys.contains(columnName))
          throw "Derartige Sortierung ist nicht erlaubt.";

        String order = obj.containsKey("order") ? obj["order"] : null;
        if (order.isEmpty || order == "ASC")
          order = "ASC";
        else
          order = "DESC";

        if (i > 0) query += ", ";
        query += columnName + " " + order;
        i++;
      }
    }

    // Beispieldaten raussuchen, die im "list"-Parameter angefragt wurden
    columnMap.forEach((columnName, _) {
      columnMap[columnName] = prepareSQLListRenamed(
          "SELECT $columnName, count(*) FROM $viewName $listQueryWhere GROUP BY $columnName",
          "result",
          ["name", "count"]);
    });

    if (requestedValuesWanted != null) {
      for (String columnName in requestedValuesWanted) {
        if (!columnMap.containsKey(columnName))
          throw "Keine Spalte $columnName.";

        final List<Map> possibleValues =
            (await columnMap[columnName]({}, db))["result"];

        valuesWanted[columnName] = possibleValues;
      }
      data["list"] = valuesWanted;
    }

    final int offset = data.containsKey("offset") ? data["offset"] : 0;
    query += " LIMIT 20 OFFSET $offset";

    final int rowCount = (await prepareSQLDetail(countQuery)({}, db))["count"];

    final List<Map> result = (await prepareSQLList(query)({}, db))["result"];

    data["count"] = rowCount;
    data["result"] = result;

    return data;
  };
}
