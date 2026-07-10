import 'dart:io';

/// Open an HTTP GET on [client] for [url], returning the response or throwing on
/// a non-200 status. The caller owns [client] (and must close it) so both a
/// one-shot fetch and a long-lived stream can share the same request/validate
/// logic. Shared by the WiFi photo fetch and the MJPEG live stream.
Future<HttpClientResponse> httpGetOk(
  HttpClient client,
  String url, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  client.connectionTimeout = timeout;
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  if (response.statusCode != 200) {
    throw StateError('HTTP ${response.statusCode}');
  }
  return response;
}
