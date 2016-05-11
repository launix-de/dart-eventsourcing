part of eventsourcing;

class LatexPrinter {
  // TODO Configurable
  static final latexTemplatePath = "latex";

  final Map request;
  final EventRouter router;

  LatexPrinter(this.request, this.router);

  String get filename {
    const defaultFilename = "dokument.pdf";

    if (request.containsKey("filename")) {
      try {
        return request["filename"];
      } catch (e) {
        return defaultFilename;
      }
    } else {
      return defaultFilename;
    }
  }

  Future writeTo(HttpResponse resp) async {
    final Directory latexTempDir =
        await Directory.systemTemp.createTemp("waechtler_latex_");

    String combinedErrorOutput;
    String templateName;

    try {
      final File latexFile = new File(Path.join(latexTempDir.path, "x.tex"));
      final File logoFile = new File(Path.join(latexTemplatePath, "logo.png"));
      final File logoTargetFile =
          new File(Path.join(latexTempDir.path, "logo.png"));

      await logoFile.copy(logoTargetFile.path);
      templateName = request["template"];

      final ProcessResult templateResult = await Process.run(
          "nodejs", ["${templateName}.js", JSON.encode(request)],
          stderrEncoding: UTF8,
          stdoutEncoding: UTF8,
          workingDirectory: latexTemplatePath);

      if (templateResult.exitCode != 0) {
        throw templateResult.stderr;
      }

      await latexFile.writeAsString(templateResult.stdout);

      ProcessResult pdflatexResult = await Process.run("pdflatex",
          ["-interaction", "nonstopmode", "-file-line-error", "x.tex"],
          stderrEncoding: UTF8,
          stdoutEncoding: UTF8,
          workingDirectory: latexTempDir.path);

      // pdflatex gibt nur 0 zurueck, wenn keine Warnungen aufgetreten sind...
      // Warum auch immer

      final File latexPdfFile = new File(Path.join(latexTempDir.path, "x.pdf"));
      try {
        final FileStat stat = await latexPdfFile.stat();
        combinedErrorOutput = pdflatexResult.stderr +
            "\r\n------------\r\n" +
            pdflatexResult.stdout;

        if (pdflatexResult.exitCode != 0 && stat.size == 0) {
          throw combinedErrorOutput;
        }
      } catch (e) {
        throw combinedErrorOutput;
      }

      resp
        ..statusCode = HttpStatus.OK
        ..headers.contentType = ContentType.parse("application/pdf")
        ..headers.set("Content-Disposition",
            "attachment; filename=${Uri.encodeComponent(filename)}");

      await latexPdfFile.openRead().pipe(resp);

      await router.logAction(
          user: 0,
          timestamp: new DateTime.now().millisecondsSinceEpoch,
          success: true,
          parameters: JSON.encode(request),
          type: "latex",
          action: templateName,
          source: "latex",
          result: "PDF successfully generated!\r\n\r\n" + combinedErrorOutput);
    } catch (e) {
      resp
        ..statusCode = HttpStatus.INTERNAL_SERVER_ERROR
        ..headers.contentType = ContentType.TEXT
        ..write(e)
        ..close();

      await router.logAction(
          user: 0,
          timestamp: new DateTime.now().millisecondsSinceEpoch,
          success: false,
          source: "latex",
          parameters: JSON.encode(request),
          type: "latex",
          action: templateName,
          result: combinedErrorOutput);
    } finally {
      await latexTempDir.delete(recursive: true);
    }
  }
}

enum LatexHttpMethod { POST, GET }

HttpHandler latexHandler(LatexHttpMethod method) {
  return (EventRouter router, HttpRequest req) async {
    Map request;

    if (method == LatexHttpMethod.POST) {
      final String buffer = await req.transform(UTF8.decoder).join();
      final List<String> fields = buffer.split("&");

      for (String field in fields) {
        final List<String> pair = field.split("=");
        final String key = pair[0];
        final String value = pair[1];

        if (key == "data") {
          request = JSON.decode(Uri.decodeQueryComponent(value));
        }
      }
    } else {
      request = JSON.decode(req.uri.queryParameters['data']);
    }

    if (request == null) throw "No data record given";

    final LatexPrinter latexPrinter = new LatexPrinter(request, router);

    latexPrinter.writeTo(req.response);
  };
}
