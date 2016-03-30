/**
 * This library implements a framework for use in realtime rich internet applications,
 * using [Dart](https://dartlang.org), MySQL, WebSockets and [Eventsourcing](https://de.wikipedia.org/wiki/Event_Sourcing).
 * It provides an application template that contains a HTTP1.1-server which hosts
 * a WebSocket-Service (see [WebSocketConnection] for protocol definition). Clients can
 * send json-encoded queries and events that are logged in a file-based event queue.
 */

library eventsourcing;

import "dart:async";
import "dart:typed_data";
import "dart:convert";
import "dart:io";
import "package:sqljocky/sqljocky.dart";
import 'package:http_server/http_server.dart';
import 'package:path/path.dart' as Path;
import 'package:crc32/crc32.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';

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
part 'src/subscription.dart';
part 'src/upload.dart';
part 'src/chat.dart';
