import 'package:test/test.dart';

import 'package:dangi_doctor/crawler/vm_locator.dart';

void main() {
  group('isDartVmVersionResponse', () {
    test('accepts a real getVersion JSON-RPC response', () {
      const body =
          '{"jsonrpc":"2.0","result":{"type":"Version","major":4,"minor":16},"id":"1"}';
      expect(isDartVmVersionResponse(body), isTrue);
    });

    test('rejects an HTML page served on the same port', () {
      const body = '<!DOCTYPE html><html><head><title>Dev server</title>'
          '</head><body>It works!</body></html>';
      expect(isDartVmVersionResponse(body), isFalse);
    });

    test('rejects JSON that is not a Version result', () {
      expect(
          isDartVmVersionResponse(
              '{"jsonrpc":"2.0","result":{"type":"Error"},"id":"1"}'),
          isFalse);
      expect(isDartVmVersionResponse('{"status":"ok"}'), isFalse);
      expect(isDartVmVersionResponse('[1,2,3]'), isFalse);
    });

    test('rejects empty and non-JSON bodies', () {
      expect(isDartVmVersionResponse(''), isFalse);
      expect(isDartVmVersionResponse('not json at all'), isFalse);
    });
  });
}
