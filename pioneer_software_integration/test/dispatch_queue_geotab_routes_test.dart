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

  test('dispatch queue keeps real-data navigation light', () {
    expect(source, contains('_dataRebuildDebounce'));
    expect(source, contains('Timer(const Duration(milliseconds: 120)'));
    expect(source, contains('_initialWorkflowVisibleLimit = 8'));
    expect(source, contains('_workflowVisibleLimits'));
    expect(source, contains('_availableVehiclesVisibleLimit = 24'));
    expect(source, contains('_activeDispatchVisibleLimit = 40'));
    expect(source, contains('_dispatchChromeAnimationDuration'));
    expect(source, contains('Builder('));
    expect(source, isNot(contains('.animate()')));
  });
}
