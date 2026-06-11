// DanDanPlay API credentials for the client signature flow.
// Release/PR CI injects them via --dart-define=DANDANAPI_APPID / DANDANAPI_KEY.
const Map<String, String> dandanCredentials = {
  'id': String.fromEnvironment('DANDANAPI_APPID', defaultValue: 'kvpx7qkqjh'),
  'value': String.fromEnvironment(
    'DANDANAPI_KEY',
    defaultValue: 'rABUaBLqdz7aCSi3fe88ZDj2gwga9Vax',
  ),
};
