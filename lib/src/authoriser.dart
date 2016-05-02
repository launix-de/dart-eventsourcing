part of eventsourcing;

/**
 * Checks whether a user is allowed to send queries / events. On success,
 * the future completes with the user's ID.
 */
typedef Future<int> Authoriser(
    String username, String password, String remote, QueriableConnection db);
