part of eventsourcing;

/// Limit of chat messages per conversation. This amount of messages is kept
/// in memory, older messages are freed.
const CHAT_MESSAGES_PER_CONVERSATION = 30;

/// Stores information about a user participating in a conversation
class ChatUserInformation {
  /// The user's id
  final int id;

  /// The user's name
  final String name;

  ChatUserInformation(this.id, this.name);

  /// Returns the json representation of this user
  Map toJson() {
    return {"id": id, "name": name};
  }
}

/// At the moment, chat messages can only be standard text messages (UTF8 strings),
/// or they contain a single base64 encoded image
enum ChatMessageType { TEXT, IMAGE }

/// Represents a chat message sent to a chat conversation by a participan
/// of the conversation
class ChatMessage {
  /// Time the message was sent by the client
  final int timestamp;

  /// Type of the message (Image / text)
  final ChatMessageType type;

  /// Message content (either raw text or base64 encoded image data)
  final String message;

  /// User who sent this message
  final ChatUserInformation user;

  /// Initializes a new ChatMessage
  ChatMessage(this.timestamp, this.type, this.message, this.user);

  /// JSON representation of a chat message
  Map toJson() {
    return {
      "timestamp": timestamp,
      "typ": type == ChatMessageType.TEXT ? "text" : "image",
      "message": message,
      "user": user
    };
  }
}

/// A chat session is an open chat conversation, kept in memory. It is freed
/// as soon as every participant has left. Participants who are offline
/// can request all messages as soon as they go online.
class ChatSession {
  /// Name of this conversation, can be set by every participant
  String name;

  /// Unique id identifying this conversation
  final String id = new Uuid().v4();

  /// Users currently participating in the conversation. User id is stored as key,
  /// user name stored as value.
  final Map<int, String> participants;

  /// Backlog of the messages sent to this conversation
  final List<ChatMessage> messages = []; // LIFO

  /// Router on whose connections this conversatoin has been created
  final EventRouter router;

  /// JSON representation of a conversation
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

  /// Creates a new chat conversation. Notifies all participants.
  ChatSession(this.name, this.participants, this.router) {
    if (name == null) name = "Konversation";

    updateAll();
  }

  /// Retrieves a new message, sent via [origin]. The message is relayed
  /// to all online participants.
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

  /// Notifies all participants that they are still part of this conversation
  /// and sends them the message backlog stored in [messages], as well as a
  /// list of all [participants].
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

/// ChatProvider implements a ws protocol addon to be added
/// to a router. Chat messages are identified by type "chat".
/// The ChatProvider also keeps track of the online status of users;
/// A user can be online (connected via WebSocket), in background mode
/// (activated via action "backgroundActivate"), or offline.
class ChatProvider implements WebSocketHandler {
  /// Conversations currently active
  final Map<String, ChatSession> conversations = {};

  /// Router this provider is tied to
  final EventRouter router;

  /// Creates a new ChatProvider tied to the given EventRouter
  ChatProvider(this.router);

  /// Sends a list of known users and their online status to all online clients
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

  /// Sends a list with all conversations the specified user is participating in, including
  /// the backlog and participants of every conversation.
  void updateClient(WebSocketConnection conn) {
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

  /// Called when a WS client disconnects. Sends a list with the currently
  /// online users to all clients.
  Future onDisconnect(WebSocketConnection conn) async {
    updateOnline();
  }

  /// Called when a WS client connects. Sends a list with the currently
  /// online users to all clients, and sends all conversation information
  /// to the new client.
  Future onConnect(WebSocketConnection conn) async {
    updateClient(conn);
    updateOnline();
  }

  /// Called when a WS client sends a ws message with typ "chat" (new chat
  /// message or status update).
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
