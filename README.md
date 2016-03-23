# eventsourcing

This library implements a framework for use in the backend of realtime rich internet applications
that demand reliable execution and fast response times. It uses [Dart](https://dartlang.org),
MySQL, WebSockets and [Eventsourcing](https://de.wikipedia.org/wiki/Event_Sourcing).
It provides an application template that contains a HTTP1.1-server which hosts
a WebSocket-Service (see [WebSocketConnection] for protocol definition). Clients can
send json-encoded queries and events that are logged in a file-based event queue.

**NOTE**: This framework was originally written to comply with an existing
client software and therefore contains legacy code and compromises in design.
Future versions will feature more abstractions and better documentation. Documentation
is in german atm (TODO).

TODO: Framework overview.

## [API documentation](http://launix-de.github.io/dart-eventsourcing/doc/api/eventsourcing/eventsourcing-library.html)
