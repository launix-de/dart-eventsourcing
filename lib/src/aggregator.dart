part of eventsourcing;

/**
 * Returns a QueryHandler that aggregates data returned by
 * [query] in the list with the key [arrayName].
 * This can be used to restructure data retrieved from the database.
 * If the database contains a relation "Machine" with keys "ID", "MachineName",
 * "MachineLocation", this function can be used to get a json map that contains the
 * machine ids as keys and machine properties (name, location) as values. In this case,
 * [primaryKey] would be "ID", [subArrayPrefix] "Machine" (every field starting
 * with "Machine" is stripped of "Machine" in the name and the value is copied to
 * the object with the "ID" key).
 */
QueryHandler aggregate(String arrayName, String primaryKey,
    String subArrayPrefix, QueryHandler query) {
  return (Map data, QueriableConnection db) async {
    final Map originalData = await query(data, db);
    final List<Map> originalItems = originalData[arrayName];
    final Map<int, Map> itemsInt = {};

    for (Map originalItem in originalItems) {
      final int key = originalItem[primaryKey];
      final Map item = itemsInt.containsKey(key)
          ? itemsInt[key]
          : {subArrayPrefix: [], primaryKey: key};
      final List<dynamic> subItems = item[subArrayPrefix];
      var newSubItem = {};

      for (String key in originalItem.keys) {
        if (!key.startsWith(subArrayPrefix) && key != primaryKey) {
          // Direkt reinmachen
          item[key] = originalItem[key];
        } else if (key != primaryKey) {
          // In Unterliste hinzufügen
          final String subKey = key.substring(subArrayPrefix.length);

          if (subKey.isNotEmpty)
            newSubItem[subKey] = originalItem[key];
          else
            newSubItem = originalItem[key];
        }
      }

      subItems.add(newSubItem);
      item[subArrayPrefix] = subItems;
      itemsInt[key] = item;
    }

    final Map<String, Map> items = {};
    itemsInt.forEach((k, v) => items[k.toString()] = v);

    return {arrayName: items};
  };
}
