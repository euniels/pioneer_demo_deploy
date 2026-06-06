import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/optimistic_mutation_service.dart';
import 'package:pioneerpath/src/services/page_cache_service.dart';
import 'package:pioneerpath/src/widgets/page_skeletons.dart';

void main() {
  test(
    'PageCacheService returns stale data immediately and refreshes later',
    () async {
      const key = 'group1-stale-page';
      PageCacheService.invalidate(key);
      PageCacheService.store<String>(key, 'old');

      final result = await PageCacheService.getOrLoad<String>(
        key: key,
        ttl: const Duration(microseconds: -1),
        loader: () async => 'new',
      );

      expect(result, 'old');

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(PageCacheService.anyData<String>(key), 'new');
    },
  );

  testWidgets('OptimisticMutationService restores snapshots on failure', (
    tester,
  ) async {
    final notifier = ValueNotifier<List<Map<String, dynamic>>>([
      {'id': 'driver-1', 'status': 'available'},
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  OptimisticMutationService.run<void>(
                    context: context,
                    snapshots: [OptimisticSnapshot.mapList(notifier)],
                    apply: () {
                      notifier.value = [
                        {'id': 'driver-1', 'status': 'inactive'},
                      ];
                    },
                    commit: () async {
                      throw Exception('backend failed');
                    },
                  );
                },
                child: const Text('deactivate'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('deactivate'));
    await tester.pump();
    await tester.pump();

    expect(notifier.value.single['status'], 'available');
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('DeferredRouteSkeleton renders a dashboard-shaped skeleton', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: DeferredRouteSkeleton(routeName: '/dashboard')),
    );

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.byType(PioneerPageSkeleton), findsOneWidget);
  });
}
