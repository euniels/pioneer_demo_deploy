import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/src/pages/dispatch_queue_page.dart',
  ).readAsStringSync();

  test('dispatch renders GeoTab route plans above the tabs', () {
    final panelIndex = source.indexOf(
      '_buildGeotabRoutesPanel(isDark, isMobile)',
    );
    final tabBarIndex = source.indexOf('child: TabBar(');

    expect(panelIndex, greaterThan(-1));
    expect(tabBarIndex, greaterThan(panelIndex));
  });

  test('dispatch route plan fetch is independent from page cache loader', () {
    final initStateStart = source.indexOf('void initState()');
    final onDataChangedStart = source.indexOf('void _onDataChanged()');
    final initState = source.substring(initStateStart, onDataChangedStart);

    final loaderStart = source.indexOf('loader: () async {');
    final loaderEnd = source.indexOf(').catchError', loaderStart);
    final loaderBody = source.substring(loaderStart, loaderEnd);

    expect(initState, contains('_loadGeotabRoutes();'));
    expect(loaderBody, isNot(contains('_loadGeotabRoutes')));
  });

  test('pending empty state points users to available route plans', () {
    expect(source, contains('GeoTab route plans are available above'));
    expect(
      source,
      contains('pending route trips after the fleet snapshot refreshes'),
    );
  });
}
