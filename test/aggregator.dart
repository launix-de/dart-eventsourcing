import "package:eventsourcing/eventsourcing.dart";
import "package:test/test.dart";

void main() {
  test('Aggregator', () async {
    Map r = await aggregate(
        "list",
        "ID",
        "Mitarbeiter",
        (data, db) async => {
              "list": [
                {
                  "ID": 1,
                  "Bezeichnung": "Maschine A",
                  "MitarbeiterName": "Name1",
                  "MitarbeiterVorname": "Vorname1"
                },
                {
                  "ID": 1,
                  "Bezeichnung": "Maschine A",
                  "MitarbeiterName": "Name2",
                  "MitarbeiterVorname": "Vorname2"
                },
                {
                  "ID": 2,
                  "Bezeichnung": "Maschine B",
                  "MitarbeiterName": "Name3",
                  "MitarbeiterVorname": "Vorname3"
                }
              ]
            })({}, null);
    expect(r, {
      "list": {
        "1": {
          "Mitarbeiter": [
            {"Name": "Name1", "Vorname": "Vorname1"},
            {"Name": "Name2", "Vorname": "Vorname2"}
          ],
          "Bezeichnung": "Maschine A"
        },
        "2": {
          "Mitarbeiter": [
            {"Name": "Name3", "Vorname": "Vorname3"}
          ],
          "Bezeichnung": "Maschine B"
        }
      }
    });
  });
}
