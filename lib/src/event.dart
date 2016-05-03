part of eventsourcing;

/// A base handler is a function that deals with an incoming request and which
/// can access the database [conn].
typedef Future<dynamic> BaseHandler(Map data, QueriableConnection conn);

/// An EventHandler is a function that deals with an incoming event. Database access
/// should be limited to operations on [trans].
typedef Future EventHandler(Map event, Transaction trans);

/// A QueryHandler is a function that deals with an incoming query. The returned
/// future completes with the result that should be sent back to the client. The
/// database should only be accessed via [pool].
typedef Future<Map> QueryHandler(Map query, ConnectionPool pool);

/// A ResultHandler is a function that converts a set of sql results to a simple map
typedef Future<Map> ResultHandler(Results results);

/// A HttpHandler is a function that deals with an incoming http [request] to
/// the eventsourcing system defined by [router]. Http handlers can be registered
/// at [router].
typedef Future HttpHandler(EventRouter router, HttpRequest request);

/// A HttpHandlerProvider is a function that returns some [HttpHandler]s identified
/// by the absolute path specified by the map key.
typedef Map<String, List<HttpHandler>> HttpHandlerProvider();

abstract class WebSocketHandler {
  Future onConnect(WebSocketConnection conn);
  Future onDisconnect(WebSocketConnection conn);
  Future<Map<String, dynamic>> onMessage(WebSocketConnection conn, Map request);
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
    throw "Deprecated: Event is no longer supported.";
