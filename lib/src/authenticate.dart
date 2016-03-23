part of eventsourcing;

/**
 * Prüft, ob ein Benutzer Anfragen / Kommandos an den Server stellen darf.
 * Im Erfolgsfall wird die Benutzer-ID zurückgegeben. 
 */
typedef Future<int> Authenticator(
    String username, String password, String remote, QueriableConnection db);
