import 'package:flutter/material.dart';

class GlobalMarginWrapper extends StatelessWidget {
  final Widget child;
  final double topMargin;
  final double leftMargin;
  final double rightMargin;
  final double bottomMargin;
  const GlobalMarginWrapper({
    super.key,
    required this.child,
    this.topMargin = 0,
    this.leftMargin = 0,
    this.rightMargin = 0,
    this.bottomMargin = 0,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: topMargin,
        left: leftMargin,
        right: rightMargin,
        bottom: bottomMargin,
      ),
      child: child,
    );
  }
}

class SafeAreaWithMargin extends StatelessWidget {
  final Widget child;
  final double additionalTopMargin;
  const SafeAreaWithMargin({
    super.key,
    required this.child,
    this.additionalTopMargin = 0,
  });
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(top: additionalTopMargin),
        child: child,
      ),
    );
  }
}

/// Example DashboardLayout with Global Margin Applied class DashboardLayoutWithMargin extends StatelessWidget {   final String currentRoute;   final String title;   final String? subtitle;   final Widget child;    static const double globalTopMargin = 23.0;    const DashboardLayoutWithMargin({     super.key,     required this.currentRoute,     required this.title,     this.subtitle,     required this.child,   });    @override   Widget build(BuildContext context) {     final isDark = Theme.of(context).brightness == Brightness.dark;      return Scaffold(       backgroundColor: isDark           ? AppTheme.colorFF0A0E1A // Dark background from sidebar           : AppTheme.colorFFF5F6F8, // Light background from sidebar       body: Row(         children: [           // Sidebar placeholder           Container(             width: 240,             color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,             child: const Center(               child: Text(                 'Sidebar',                 style: TextStyle(                   color: AppTheme.colorFFE74C3C,                   fontWeight: FontWeight.w600,                 ),               ),             ),           ),            // Main content with global top margin           Expanded(             child: GlobalMarginWrapper(               topMargin: globalTopMargin,               child: Column(                 children: [                   // Header with sidebar colors                   Container(                     padding: const EdgeInsets.all(24),                     decoration: BoxDecoration(                       color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,                       border: Border(                         bottom: BorderSide(                           color: isDark                               ? AppTheme.white.withValues(alpha: 0.08)                               : AppTheme.black.withValues(alpha: 0.08),                         ),                       ),                     ),                     child: Row(                       children: [                         Column(                           crossAxisAlignment: CrossAxisAlignment.start,                           children: [                             Text(                               title,                               style: TextStyle(                                 fontSize: 24,                                 fontWeight: FontWeight.w700,                                 color: isDark                                     ? AppTheme.white                                     : AppTheme.colorFF2C3E50,                               ),                             ),                             if (subtitle != null) ...[                               const SizedBox(height: 4),                               Text(                                 subtitle!,                                 style: TextStyle(                                   fontSize: 14,                                   color: isDark                                       ? AppTheme.gray400                                       : AppTheme.gray600,                                 ),                               ),                             ],                           ],                         ),                       ],                     ),                   ),                    // Page content                   Expanded(child: child),                 ],               ),             ),           ),         ],       ),     );   } }  class MainAppWithGlobalMargin extends StatelessWidget {   const MainAppWithGlobalMargin({super.key});    @override   Widget build(BuildContext context) {     return GlobalMarginWrapper(       topMargin: 20,       child: MaterialApp(         title: 'Fleet Management',         theme: ThemeData.light(),         darkTheme: ThemeData.dark(),         home: const Scaffold(           body: Center(             child: Text(               'Your App Content',               style: TextStyle(                 color: AppTheme.colorFFE74C3C,                 fontWeight: FontWeight.w600,               ),             ),           ),         ),       ),     );   } }  class ResponsiveGlobalMargin extends StatelessWidget {   final Widget child;    const ResponsiveGlobalMargin({super.key, required this.child});    double _getTopMargin(BuildContext context) {     final screenWidth = MediaQuery.of(context).size.width;      if (screenWidth < 600) {       return 12;     } else if (screenWidth < 1024) {       return 18;     } else {       return 23;     }   }    @override   Widget build(BuildContext context) {     final isDark = Theme.of(context).brightness == Brightness.dark;      return Padding(       padding: EdgeInsets.only(top: _getTopMargin(context)),       child: Container(         decoration: BoxDecoration(           color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,           borderRadius: BorderRadius.circular(8),           boxShadow: [             BoxShadow(               color: AppTheme.black.withValues(alpha: isDark ? 0.3 : 0.05),               blurRadius: 10,               offset: const Offset(2, 0),             ),           ],         ),         child: child,       ),     );   } }
