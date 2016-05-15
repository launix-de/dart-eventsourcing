part of eventsourcing;

const int MAX_UPLOAD_FILE_SIZE = 1000 * 1000 * 50; // 50 MB

EventHandler uploadRemovalHandler(String uploadPath) {
  return (Map event, Transaction tx) async {
    final int fileId = event["file"];
    final File file = new File(Path.join(uploadPath, "${fileId}.dat"));

    if (await file.exists()) {
      await file.delete();
    } else {
      throw "File does not exist";
    }
  };
}

HttpHandler uploadHandler() {
  return (EventRouter router, final HttpRequest req) async {
    final String requestedFilename = req.uri.pathSegments[1];

    if (requestedFilename == "upload") {
      // Datei herunterladen
      final String boundary = req.headers.contentType.parameters['boundary'];
      final Stream<HttpMultipartFormData> formDataStream = req
          .transform(new MimeMultipartTransformer(boundary))
          .map(HttpMultipartFormData.parse);

      String username = "";
      String password = "";
      String filename = "";
      ContentType contentType;
      Map uploadEvent = {};
      final Directory tmpDir =
          (await Directory.systemTemp.createTemp("eventsourcing"));
      final File tmpFile = new File(Path.join(tmpDir.path, 'upload.dat'));

      try {
        await for (var formData in formDataStream) {
          final Map<String, String> parameters =
              formData.contentDisposition.parameters;
          final String name = parameters['name'];

          switch (name) {
            case "username":
              username = await formData.join();
              break;
            case "password":
              password = await formData.join();
              break;
            case "event":
              uploadEvent = JSON.decode(await formData.join());
              break;
            case "file":
              filename = parameters['filename'];
              contentType = formData.contentType;

              if (contentType == null) throw "Missing content type information";

              int size = 0;
              final IOSink sink = tmpFile.openWrite();

              await for (var chunk in formData) {
                size += chunk.length;
                if (size >= MAX_UPLOAD_FILE_SIZE)
                  throw "Exceeded maximum upload file size";
                sink.add(chunk);
              }

              await sink.flush();
              await sink.close();

              break;
            default:
              throw "Unexpected multipart chunk";
          }
        }

        final int userId = await router.authenticator(username, password,
            req.connectionInfo.remoteAddress.address, router.db);

        final int fileId = router.getNewEventId();

        uploadEvent["user"] = userId;
        uploadEvent["filename"] = filename;
        uploadEvent["file"] = fileId;

        final Map response =
            await router.submitEvent(uploadEvent, {"httprequest": req}, userId);
        if (response.containsKey("error")) throw response["error"];

        await tmpFile
            .copy(Path.join(router.uploadDirectory.path, "${fileId}.dat"));
        tmpFile.delete();

        req.response
          ..headers.contentType = ContentType.JSON
          ..statusCode = HttpStatus.OK
          ..write(JSON.encode(response));
        await req.response.close();
      } finally {
        // Upload failed; remove temp dir
        if (await tmpDir.exists()) tmpDir.delete(recursive: true);
      }
    } else {
      // TODO: Check auth (not done in weachtler frontend atm)

      final int requestedFileId = int.parse(requestedFilename);
      final String filename = req.uri.queryParameters["filename"];
      final bool inline = req.uri.queryParameters.containsKey("inline");
      final File requestedFile = new File(
          Path.join(router.uploadDirectory.path, "${requestedFileId}.dat"));

      if (!await requestedFile.exists()) {
        req.response.statusCode = HttpStatus.NOT_FOUND;
        await req.response.close();
        return;
      } else {
        req.response.statusCode = HttpStatus.OK;
        req.response.headers.contentType =
            ContentType.parse(lookupMimeType(filename.toLowerCase()));

        req.response.headers.set("Content-Disposition",
            "${inline ? 'inline' : 'attach'}; filename=${Uri.encodeFull(filename)}");

        requestedFile.openRead().pipe(req.response);
      }
    }
  };
}
