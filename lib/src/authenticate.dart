part of eventsourcing;

typedef Future<int> Authenticator(
    String username, String password, String remote, QueriableConnection db);
