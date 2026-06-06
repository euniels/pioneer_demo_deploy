import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/fleet_data_coordinator.dart';

void main() {
  test('FleetDataCoordinator coalesces simultaneous requests by key', () async {
    var calls = 0;
    final completer = Completer<String>();

    Future<String> loader() {
      calls += 1;
      return completer.future;
    }

    final first = FleetDataCoordinator.coalesce('same-endpoint', loader);
    final second = FleetDataCoordinator.coalesce('same-endpoint', loader);

    expect(calls, 1);

    completer.complete('shared-result');

    expect(await first, 'shared-result');
    expect(await second, 'shared-result');
  });

  test('FleetDataCoordinator coalescing releases completed keys', () async {
    var calls = 0;

    final first = await FleetDataCoordinator.coalesce('repeat-endpoint', () {
      calls += 1;
      return Future.value('first');
    });
    final second = await FleetDataCoordinator.coalesce('repeat-endpoint', () {
      calls += 1;
      return Future.value('second');
    });

    expect(first, 'first');
    expect(second, 'second');
    expect(calls, 2);
  });
}
