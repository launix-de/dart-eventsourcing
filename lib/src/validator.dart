part of eventsourcing;

/**
 *  Ein Validator ist eine Funktion, die bei Ausführung die Daten in [data] überprüft
 *  (mittels SQL-Verbindung in [conn]) und einen Future zurückgibt.
 *  Tritt ein Validierungsfehler auf, sollte der Future mit einem Fehler beendet werden.
 *  Wenn alle Prüfungen erfolgreich vollzogen wurden, sollte der zurückgegebene Future
 *  regulär beendet werden. */
typedef Future Validator(Map data, QueriableConnection conn);

Validator combineValidatorsOr(List<Validator> validators, String errorMessage) {
  return (Map data, QueriableConnection conn) async {
    bool oneSuccess = false;

    // TODO: Validatoren parallel ausführen; Warum geht der Code unten nicht?
    for (Validator v in validators) {
      try {
        await v(new Map.from(data), conn);
        oneSuccess = true;
      } catch (e) {
        // Egal
      }
    }

    /* await Future.wait(validators.map((Validator v) {
      return () async {
        try {
          await v(data, conn);
          oneSuccess = true;
        } catch (e) {
          // Egal
        }
      }();
    })); */

    if (!oneSuccess) throw errorMessage;
  };
}
