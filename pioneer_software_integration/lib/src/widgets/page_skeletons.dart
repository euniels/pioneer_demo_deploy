import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'dashboard_layout.dart';
import 'shimmer_loading.dart';

class DeferredRouteSkeleton extends StatelessWidget {
  const DeferredRouteSkeleton({required this.routeName, super.key});

  final String routeName;

  @override
  Widget build(BuildContext context) {
    final config = _SkeletonConfig.forRoute(routeName);
    return DashboardLayout(
      currentRoute: routeName,
      title: config.title,
      subtitle: config.subtitle,
      child: PioneerPageSkeleton(config: config),
    );
  }
}

class PioneerRouteSkeletonBody extends StatelessWidget {
  const PioneerRouteSkeletonBody({required this.routeName, super.key});

  final String routeName;

  @override
  Widget build(BuildContext context) {
    return PioneerPageSkeleton(config: _SkeletonConfig.forRoute(routeName));
  }
}

class PioneerPageSkeleton extends StatelessWidget {
  const PioneerPageSkeleton({required this.config, super.key});

  final _SkeletonConfig config;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 720;

    return SingleChildScrollView(
      padding: AppTheme.getPagePadding(context),
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (config.showKpis)
            _SkeletonGrid(
              columns: isMobile ? 1 : config.kpiColumns,
              children: List.generate(
                config.kpiCount,
                (_) => const _SkeletonKpiCard(),
              ),
            ),
          if (config.showKpis) const SizedBox(height: AppTheme.space16),
          for (var index = 0; index < config.sections.length; index++) ...[
            _SkeletonSection(section: config.sections[index]),
            if (index != config.sections.length - 1)
              const SizedBox(height: AppTheme.space16),
          ],
        ],
      ),
    );
  }
}

class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = columns == 1 ? AppTheme.space12 : AppTheme.space16;
        final itemWidth =
            (constraints.maxWidth - (gap * (columns - 1))) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}

class _SkeletonKpiCard extends StatelessWidget {
  const _SkeletonKpiCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 88,
      padding: const EdgeInsets.all(AppTheme.space16),
      decoration: _skeletonDecoration(context),
      child: const Row(
        children: [
          ShimmerLoading(width: 46, height: 46),
          SizedBox(width: AppTheme.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ShimmerLoading(width: 86, height: 14),
                SizedBox(height: 10),
                ShimmerLoading(width: 132, height: 22),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonSection extends StatelessWidget {
  const _SkeletonSection({required this.section});

  final _SkeletonSectionConfig section;

  @override
  Widget build(BuildContext context) {
    if (section.kind == _SkeletonSectionKind.map) {
      return const _SkeletonMapSection();
    }
    if (section.kind == _SkeletonSectionKind.table) {
      return _SkeletonTableSection(rows: section.rows);
    }

    return _SkeletonGrid(
      columns: section.columns,
      children: List.generate(
        section.items,
        (_) =>
            ShimmerCard(height: section.height, showFooter: section.showFooter),
      ),
    );
  }
}

class _SkeletonMapSection extends StatelessWidget {
  const _SkeletonMapSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 430,
      padding: const EdgeInsets.all(AppTheme.space16),
      decoration: _skeletonDecoration(context),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShimmerLoading(width: 180, height: 22),
              Spacer(),
              ShimmerLoading(width: 96, height: 34),
            ],
          ),
          SizedBox(height: AppTheme.space12),
          Expanded(child: ShimmerLoading(height: double.infinity)),
        ],
      ),
    );
  }
}

class _SkeletonTableSection extends StatelessWidget {
  const _SkeletonTableSection({required this.rows});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.space16),
      decoration: _skeletonDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ShimmerLoading(width: 190, height: 22),
          const SizedBox(height: AppTheme.space16),
          for (var row = 0; row < rows; row++) ...[
            const Row(
              children: [
                Expanded(flex: 3, child: ShimmerLoading(height: 18)),
                SizedBox(width: AppTheme.space12),
                Expanded(flex: 2, child: ShimmerLoading(height: 18)),
                SizedBox(width: AppTheme.space12),
                Expanded(child: ShimmerLoading(height: 18)),
              ],
            ),
            if (row != rows - 1) const SizedBox(height: AppTheme.space12),
          ],
        ],
      ),
    );
  }
}

BoxDecoration _skeletonDecoration(BuildContext context) {
  return BoxDecoration(
    color: AppTheme.surfaceCard(context),
    borderRadius: AppTheme.getButtonRadius(),
    border: Border.all(color: AppTheme.borderDefault(context)),
  );
}

class _SkeletonConfig {
  const _SkeletonConfig({
    required this.title,
    required this.subtitle,
    required this.sections,
    this.showKpis = true,
    this.kpiCount = 4,
    this.kpiColumns = 4,
  });

  final String title;
  final String subtitle;
  final List<_SkeletonSectionConfig> sections;
  final bool showKpis;
  final int kpiCount;
  final int kpiColumns;

  static _SkeletonConfig forRoute(String route) {
    switch (route) {
      case '/dashboard':
        return const _SkeletonConfig(
          title: 'Dashboard',
          subtitle: 'Fleet overview and live operating status',
          showKpis: true,
          kpiCount: 4,
          sections: [
            _SkeletonSectionConfig.cards(items: 2, columns: 2, height: 240),
            _SkeletonSectionConfig.table(rows: 5),
          ],
        );
      case '/live-tracking':
        return const _SkeletonConfig(
          title: 'Live Tracking',
          subtitle: 'Fleet map, route orders, and active status',
          kpiCount: 3,
          kpiColumns: 3,
          sections: [
            _SkeletonSectionConfig.map(),
            _SkeletonSectionConfig.cards(
              items: 3,
              columns: 3,
              height: 120,
              showFooter: false,
            ),
          ],
        );
      case '/client-tracking':
        return const _SkeletonConfig(
          title: 'Client Tracking',
          subtitle: 'Order map and delivery visibility',
          kpiCount: 2,
          kpiColumns: 2,
          sections: [
            _SkeletonSectionConfig.map(),
            _SkeletonSectionConfig.cards(items: 2, columns: 2, height: 140),
          ],
        );
      case '/dispatch-queue':
        return const _SkeletonConfig(
          title: 'Dispatch Queue',
          subtitle: 'Assignments, route plans, and active dispatches',
          kpiCount: 4,
          sections: [
            _SkeletonSectionConfig.cards(items: 3, columns: 3, height: 150),
            _SkeletonSectionConfig.table(rows: 4),
          ],
        );
      case '/trips':
        return const _SkeletonConfig(
          title: 'Trips',
          subtitle: 'Route orders and delivery workflow',
          kpiCount: 4,
          sections: [
            _SkeletonSectionConfig.table(rows: 5),
            _SkeletonSectionConfig.cards(items: 2, columns: 2, height: 150),
          ],
        );
      case '/routes':
        return const _SkeletonConfig(
          title: 'Routes',
          subtitle: 'Route templates, ordered stops, and GeoTab sync',
          kpiCount: 3,
          kpiColumns: 3,
          sections: [
            _SkeletonSectionConfig.cards(items: 3, columns: 3, height: 120),
            _SkeletonSectionConfig.table(rows: 5),
            _SkeletonSectionConfig.map(),
          ],
        );
      case '/analytics':
        return const _SkeletonConfig(
          title: 'Operational Analytics',
          subtitle: 'Fleet utilization and operating insight',
          kpiCount: 4,
          sections: [
            _SkeletonSectionConfig.cards(items: 2, columns: 2, height: 230),
            _SkeletonSectionConfig.table(rows: 5),
          ],
        );
      case '/delivery-confirm':
        return const _SkeletonConfig(
          title: 'Fuel & Energy',
          subtitle: 'Spend, consumption, and refuel visibility',
          kpiCount: 4,
          sections: [
            _SkeletonSectionConfig.cards(items: 2, columns: 2, height: 210),
            _SkeletonSectionConfig.table(rows: 5),
          ],
        );
      case '/clients':
        return const _SkeletonConfig(
          title: 'Clients',
          subtitle: 'Client master records and account history',
          kpiCount: 3,
          kpiColumns: 3,
          sections: [_SkeletonSectionConfig.table(rows: 6)],
        );
      case '/billing':
      case '/statements-of-accounts':
        return const _SkeletonConfig(
          title: 'Billing',
          subtitle: 'Invoice and account readiness',
          kpiCount: 3,
          kpiColumns: 3,
          sections: [_SkeletonSectionConfig.table(rows: 6)],
        );
      case '/vehicles':
      case '/drivers':
      case '/maintenance':
      case '/notifications':
      case '/settings':
      default:
        return _SkeletonConfig(
          title: _titleForRoute(route),
          subtitle: 'Loading the latest PioneerPath workspace',
          kpiCount: 3,
          kpiColumns: 3,
          sections: const [
            _SkeletonSectionConfig.cards(items: 3, columns: 3, height: 150),
            _SkeletonSectionConfig.table(rows: 4),
          ],
        );
    }
  }

  static String _titleForRoute(String route) {
    return switch (route) {
      '/vehicles' => 'Vehicles',
      '/routes' => 'Routes',
      '/clients' => 'Clients',
      '/drivers' => 'Drivers',
      '/maintenance' => 'Maintenance',
      '/notifications' => 'Notifications',
      '/settings' => 'Settings',
      _ => 'PioneerPath',
    };
  }
}

class _SkeletonSectionConfig {
  const _SkeletonSectionConfig.cards({
    required this.items,
    required this.columns,
    required this.height,
    this.showFooter = true,
  }) : kind = _SkeletonSectionKind.cards,
       rows = 0;

  const _SkeletonSectionConfig.table({required this.rows})
    : kind = _SkeletonSectionKind.table,
      items = 0,
      columns = 1,
      height = 0,
      showFooter = false;

  const _SkeletonSectionConfig.map()
    : kind = _SkeletonSectionKind.map,
      items = 0,
      columns = 1,
      rows = 0,
      height = 0,
      showFooter = false;

  final _SkeletonSectionKind kind;
  final int items;
  final int columns;
  final int rows;
  final double height;
  final bool showFooter;
}

enum _SkeletonSectionKind { cards, table, map }
