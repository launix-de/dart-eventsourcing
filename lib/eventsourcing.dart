/**
 * Diese Bibliothek implementiert ein Framework für Echtzeit-RIAs unter Verwendung
 * von MySQL, WebSockets und [Eventsourcing](https://de.wikipedia.org/wiki/Event_Sourcing).
 * Enthalten ist ein HTTP 1.1-Server, der einen WS-Service bereitstellt.
 * Clients können über diesen JSON-kodierte Abfragen stellen und Kommandos senden,
 * die in einer Datei gesichert werden.
 */

library eventsourcing;

import "package:sqljocky/sqljocky.dart";
import "dart:async";
import "dart:typed_data";
import "dart:convert";
import "dart:io";
import 'package:http_server/http_server.dart';
import 'package:path/path.dart' as Path;
import "package:collection/collection.dart";

part 'src/aggregator.dart';
part 'src/eventrouter.dart';
part 'src/eventfile.dart';
part 'src/util/db.dart';
part 'src/event.dart';
part 'src/validator.dart';
part 'src/sql.dart';
part 'src/sqlfilter.dart';
part 'src/ws.dart';
part 'src/authenticate.dart';
