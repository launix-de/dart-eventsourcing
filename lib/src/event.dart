part of eventsourcing;

typedef Future<dynamic> BaseHandler(Map data, QueriableConnection conn);

typedef Future EventHandler(Map event, Transaction trans);
typedef Future<Map> QueryHandler(Map query, ConnectionPool pool);
typedef Future<Map> ResultHandler(Results results);

typedef Future HttpHandler(EventRouter router, HttpRequest request);

typedef Map<String, List<HttpHandler>> HttpHandlerProvider();

abstract class Provider<T> {
  Future onConnect(T conn);
  Future onDisconnect(T conn);
  Future<Map<String, dynamic>> onMessage(T conn, Map request);
}

/// Stellt benannte Queries zur Verfügung
typedef Map<String, List<QueryHandler>> QueryProvider();

/// Stellt benannte Events zur Verfügung
typedef Map<String, List<EventHandler>> EventProvider();

/// Kombiniert die Events aus mehreren [EventProvider]n in einer Map
Map<String, List<EventHandler>> combineEventProviders(
    List<EventProvider> providers) {
  final Map<String, List<EventHandler>> combined = {};

  for (EventProvider p in providers) {
    combined.addAll(p());
  }

  return combined;
}

/// Kombiniert die Events aus mehreren [QueryProvider]n in einer Map
Map<String, List<QueryHandler>> combineQueryProviders(
    List<QueryProvider> providers) {
  final Map<String, List<QueryHandler>> combined = {};

  for (QueryProvider p in providers) {
    combined.addAll(p());
  }

  return combined;
}

/// EventHandler, der nichts tut
Future<Map> emptyHandler(Map e, Transaction trans) => new Future.value({});

/// EventHandler, der einen "Deprecated"-Fehler wirft. **Achtung**: Einmal verwendete
/// Events dürfen nie entfernt werden, da sie ja bei jedem Start neu eingelesen werden.
Future<Map> deprecatedHandler(Map e, Transaction trans) async =>
    throw "Deprecated: Ereignis ist veraltet und wird nicht mehr unterstützt.";
