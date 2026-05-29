// Public DanDanPlay API credentials used by the client signature flow.
// CI replaces these values for release builds.
const Map<String, String> dandanCredentials = {
  'id': String.fromEnvironment('DANDANAPI_APPID', defaultValue: 'kvpx7qkqjh'),
  'value': String.fromEnvironment(
    'DANDANAPI_KEY',
    defaultValue: 'rABUaBLqdz7aCSi3fe88ZDj2gwga9Vax',
  ),
};
