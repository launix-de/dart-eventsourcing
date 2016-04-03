part of eventsourcing;

QueryHandler csvExtractor(
    QueryHandler sub, String array, String field, List<String> columns) {
  final String columnSeperator = "|";
  final String rowSeperator = "\$";

  return (Map<String, dynamic> data, QueriableConnection db) async {
    final Map result = await sub(new Map.from(data), db);

    final List arr = result[array];
    for (Map o in arr) {
      if (o.containsKey(field) && o[field] != null) {
        final String x = o[field];
        final List<String> rows = x.split(rowSeperator);
        final List newField = [];

        for (int j = 0; j < rows.length; j++) {
          final Map newRow = {};
          final List<String> y = rows[j].split(columnSeperator);
          for (int k = 0; k < columns.length; k++) newRow[columns[k]] = y[k];
          newField.add(newRow);
        }
        o[field] = newField;
      }
    }

    return result;
  };
}
