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

/// A WebSocketHandler can be hooked to an [EventRouter]. The router will then
/// call the defined methods for each [WebSocketConnection].
abstract class WebSocketHandler {
  /// Called when new client connects
  Future onConnect(WebSocketConnection conn);

  /// Called after a client disconnects
  Future onDisconnect(WebSocketConnection conn);

  /// Called when the client sends a json message [request]. null should be returned
  /// if this handler does not want to deal with the request ("type" attribute should
  /// be checked). Otherwise, the returned data is encoded as json and sent
  /// to the client.
  Future<Map<String, dynamic>> onMessage(WebSocketConnection conn, Map request);
}

/// Provides queries identified by an action (simple string, should be camel cased).
/// The results are merged. On failure, an exception is thrown.
typedef Map<String, List<QueryHandler>> QueryProvider();

/// Provides events identified by an action (simple string, should be camel cased).
/// On failure, an exception is thrown.
typedef Map<String, List<EventHandler>> EventProvider();

/// Merges multiple [EventProvider]s
Map<String, List<EventHandler>> combineEventProviders(
    List<EventProvider> providers) {
  final Map<String, List<EventHandler>> combined = {};

  for (EventProvider p in providers) {
    combined.addAll(p());
  }

  return combined;
}

/// Combines multiple [QueryProvider]s
Map<String, List<QueryHandler>> combineQueryProviders(
    List<QueryProvider> providers) {
  final Map<String, List<QueryHandler>> combined = {};

  for (QueryProvider p in providers) {
    combined.addAll(p());
  }

  return combined;
}

/// EventHandler that returns the empty map in the next eventqueue cycle
Future<Map> emptyHandler(Map e, Transaction trans) => new Future.value({});

/// EventHandler that throws a "deprecated" exception
/// **Note**: Handlers for events that were already executed should never be removed
/// since they have to be rerun on every start.
Future<Map> deprecatedHandler(Map e, Transaction trans) async =>
    throw "Deprecated: Event is no longer supported.";
