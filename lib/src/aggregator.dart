part of eventsourcing;

QueryHandler aggregate(String arrayName, String primaryKey,
    String subArrayPrefix, QueryHandler query) {
  return (Map data, QueriableConnection db) async {
    final Map originalData = await query(data, db);
    final List<Map> originalItems = originalData[arrayName];
    final Map<int, Map> itemsInt = {};

    for (Map originalItem in originalItems) {
      final int key = originalItem[primaryKey];
      final Map item =
          itemsInt.containsKey(key) ? itemsInt[key] : {subArrayPrefix: []};
      final List<Map> subItems = item[subArrayPrefix];
      final Map newSubItem = {};

      for (String key in originalItem.keys) {
        if (!key.startsWith(subArrayPrefix) && key != primaryKey) {
          // Direkt reinmachen
          item[key] = originalItem[key];
        } else if (key != primaryKey) {
          // In Unterliste hinzufügen
          newSubItem[key.substring(subArrayPrefix.length)] = originalItem[key];
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
