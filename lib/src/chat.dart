part of eventsourcing;

const CHAT_MESSAGES_PER_CONVERSATION = 30;

class ChatUserInformation {
  final int id;
  final String name;

  ChatUserInformation(this.id, this.name);

  Map toJson() {
    return {"id": id, "name": name};
  }
}

enum ChatMessageType { TEXT, IMAGE }

class ChatMessage {
  final int timestamp;
  final ChatMessageType type;
  final String message;
  final ChatUserInformation user;

  ChatMessage(this.timestamp, this.type, this.message, this.user);

  Map toJson() {
    return {
      "timestamp": timestamp,
      "typ": type == ChatMessageType.TEXT ? "text" : "image",
      "message": message,
      "user": user
    };
  }
}

class ChatSession {
  String name;
  final String id = new Uuid().v4();
  final Map<int, String> participants;
  final List<ChatMessage> messages = []; // LIFO
  final EventRouter router;

  Map toJson() {
    final Map<String, String> participantsString = {};
    participants.forEach((k, v) => participantsString[k.toString()] = v);

    return {
      "messages": messages,
      "name": name,
      "participants": participantsString,
      "conversation": id
    };
  }

  ChatSession(this.name, this.participants, this.router) {
    if (name == null) name = "Konversation";

    updateAll();
  }

  void addMessage(
      WebSocketConnection origin, String text, ChatMessageType typ) {
    final ChatMessage msg = new ChatMessage(
        new DateTime.now().millisecondsSinceEpoch,
        typ,
        text,
        new ChatUserInformation(origin.user, origin.username));

    if (messages.length > CHAT_MESSAGES_PER_CONVERSATION) messages.removeAt(0);
    messages.add(msg);

    final Map<String, dynamic> notification = {
      "type": "chat",
      "action": "newMessage",
      "conversation": id,
      "message": msg
    };
    final String notificationJSON = JSON.encode(notification);

    router.connections
        .where((c) => participants.containsKey(c.user))
        .forEach((c) => c.ws.add(notificationJSON));
  }

  void updateAll() {
    final Map notification = toJson();
    notification["type"] = "chat";
    notification["action"] = "conversationUpdate";
    final String notificationJSON = JSON.encode(notification);

    router.connections
        .where((c) => participants.containsKey(c.user))
        .forEach((c) => c.ws.add(notificationJSON));
  }
}

class ChatProvider implements Provider<WebSocketConnection> {
  final Map<String, ChatSession> conversations = {};
  final EventRouter router;

  ChatProvider(this.router);

  void updateOnline() {
    final List<Map> activeUsers = router.connections
        .map((c) =>
            {"id": c.user, "background": c.state == WebSocketState.BACKGROUND})
        .toList();

    final Map sessionInfo = {
      "type": "chat",
      "users": activeUsers,
      "action": "userUpdate"
    };
    final String sessionInfoJSON = JSON.encode(sessionInfo);

    router.connections.forEach((c) => c.ws.add(sessionInfoJSON));
  }

  void updateSession(WebSocketConnection conn) {
    final Map<String, Map> conversationJsons = {};

    conversations.values
        .where((c) => c.participants.containsKey(conn.user))
        .forEach((c) {
      conversationJsons[c.id] = c.toJson();
    });

    final Map response = {
      "type": "chat",
      "action": "conversationsUpdate",
      "conversations": conversationJsons
    };
    conn.ws.add(JSON.encode(response));
  }

  Future onDisconnect(WebSocketConnection conn) async {
    updateOnline();
  }

  Future onConnect(WebSocketConnection conn) async {
    updateSession(conn);
    updateOnline();
  }

  Future<Map<String, dynamic>> onMessage(
      WebSocketConnection conn, Map request) async {
    if (request.containsKey("type") && request["type"] == "chat") {
      final int trackId = request.containsKey("track") ? request["track"] : -1;

      final Map<String, dynamic> response = {
        "type": "chat",
        "status": "ok",
        "track": trackId
      };

      switch (request["action"]) {
        case "backgroundActivate":
          if (conn.state == WebSocketState.OK)
            conn.state = WebSocketState.BACKGROUND;
          updateOnline();
          break;
        case "backgroundDeactivate":
          if (conn.state == WebSocketState.BACKGROUND)
            conn.state = WebSocketState.OK;
          updateOnline();
          break;
        case "newMessage":
          conversations[request["conversation"]].addMessage(
              conn,
              request["message"],
              request["typ"] == "image"
                  ? ChatMessageType.IMAGE
                  : ChatMessageType.TEXT);
          break;
        case "nameConversation":
          final ChatSession c = conversations[request["conversation"]];
          final String oldName = c.name;
          c.name = request["name"];
          c.addMessage(conn, "Titel von ${oldName} zu ${c.name} geändert!",
              ChatMessageType.TEXT);
          c.updateAll();
          break;
        case "newConversation":
          // Nutzer und Nutzernamen werden vom Client geschickt (Altes Protokoll)
          final String name = request["name"];
          final Map<int, String> participants = {};
          request["participants"].forEach((Map p) {
            participants[p["id"]] = p["name"];
          });
          participants[conn.user] = conn.username;

          final ChatSession c = new ChatSession(name, participants, router);
          conversations[c.id] = c;
          response["action"] = "newConversationResponse";
          response["conversation"] = c.id;

          c.addMessage(
              conn,
              request["message"],
              request["typ"] == "text"
                  ? ChatMessageType.TEXT
                  : ChatMessageType.IMAGE);

          if (request.containsKey("message2"))
            c.addMessage(
                conn,
                request["message2"],
                request["typ2"] == "text"
                    ? ChatMessageType.TEXT
                    : ChatMessageType.IMAGE);

          break;
        case "leaveConversation":
          final ChatSession c = conversations[request["conversation"]];

          if (c.participants.containsKey(conn.user)) {
            c.participants.remove(conn.user);
            response["action"] = "leaveConversationResponse";
            response["conversation"] = c.id;
            if (c.participants.isEmpty)
              conversations.remove(c.id);
            else
              c.updateAll();
          }
          break;
        default:
          throw "Unknown chat action";
      }

      return response;
    } else {
      return null;
    }
  }
}
