import 'package:flutter/material.dart';

class AppTheme {
  static const String fontFamily = 'PioneerSans';
  static const List<String> fontFamilyFallback = [
    'Noto Sans',
    'Noto Sans Symbols',
    'Noto Sans Symbols 2',
    'Arial',
    'Roboto',
    'sans-serif',
  ];

  // Pioneer brand foundation
  static const Color pioneerDeepBlue = Color(0xFF1A3A6B);
  static const Color pioneerRed = Color(0xFFC0392B);
  static const Color pioneerBlack = Color(0xFF1A1A1A);

  // Light mode colors
  static const Color lightBg = Color(0xFFF5F6FA);
  static const Color lightCardBg = Color(0xFFFFFFFF);
  static const Color lightSidebar = Color(0xFFFFFFFF);
  static const Color lightPanel = Color(0xFFF8FAFC);
  static const Color lightBorder = Color(0xFFE8EAF0);
  static const Color lightInputBorder = Color(0xFFDCE4F2);
  static const Color lightText = Color(0xFF1F2937);
  static const Color lightSubtleText = Color(0xFF5A6070);
  static const Color lightMutedText = Color(0xFFB0B7C3);

  // Dark mode colors
  static const Color darkBg = Color(0xFF0A0E1A);
  static const Color darkCardBg = Color(0xFF151E2E);
  static const Color darkSidebar = Color(0xFF0F1419);
  static const Color darkPanel = Color(0xFF101827);
  static const Color darkPanelAlt = Color(0xFF1A2538);
  static const Color darkBorder = Color(0xFF2A3F5F);
  static const Color darkInputBorder = Color(0xFF263142);
  static const Color darkText = Color(0xFFFFFFFF);
  static const Color darkSubtleText = Color(0xFFAEB8C8);
  static const Color darkMutedText = Color(0xFF8A94A8);
  static const Color goldAccent = Color(0xFFD9B56D);
  static const Color slateAccent = Color(0xFF7C8AA5);

  // Primary colors
  static const Color primaryBlue = pioneerDeepBlue;
  static const Color accentCyan = Color(0xFF00A6D6);
  static const Color successGreen = Color(0xFF10B981);
  static const Color warningOrange = Color(0xFFFF9F43);
  static const Color errorRed = pioneerRed;
  static const Color colorFF7F1D1D = Color(0xFF7F1D1D);
  static const Color purpleAccent = Color(0xFF8B5CF6);
  static const Color tealAccent = Color(0xFF14B8A6);
  static const Color infoBlue = Color(0xFF0EA5E9);
  static const Color neutralGray = Color(0xFF64748B);
  static const Color markerOfflineGray = Color(0xFF4B5563);
  static const Color disabledGray = Color(0xFF94A3B8);
  // Gap 3 legacy color bridge. Keep raw color literals centralized here.
  static const Color colorFF00A8E8 = Color(0xFF00A8E8);
  static const Color colorFF00C2A8 = Color(0xFF00C2A8);
  static const Color colorFF00D4FF = Color(0xFF00D4FF);
  static const Color colorFF08101D = Color(0xFF08101D);
  static const Color colorFF0A0E1A = Color(0xFF0A0E1A);
  static const Color colorFF0A1220 = Color(0xFF0A1220);
  static const Color colorFF0B1220 = Color(0xFF0B1220);
  static const Color colorFF0B7A3B = Color(0xFF0B7A3B);
  static const Color colorFF0C1220 = Color(0xFF0C1220);
  static const Color colorFF0E1420 = Color(0xFF0E1420);
  static const Color colorFF0E7A43 = Color(0xFF0E7A43);
  static const Color colorFF0EA5E9 = Color(0xFF0EA5E9);
  static const Color colorFF0F1117 = Color(0xFF0F1117);
  static const Color colorFF0F141D = Color(0xFF0F141D);
  static const Color colorFF0F1520 = Color(0xFF0F1520);
  static const Color colorFF0F1A28 = Color(0xFF0F1A28);
  static const Color colorFF0F1A2A = Color(0xFF0F1A2A);
  static const Color colorFF0F1A30 = Color(0xFF0F1A30);
  static const Color colorFF10141D = Color(0xFF10141D);
  static const Color colorFF101826 = Color(0xFF101826);
  static const Color colorFF101827 = Color(0xFF101827);
  static const Color colorFF102036 = Color(0xFF102036);
  static const Color colorFF10B981 = Color(0xFF10B981);
  static const Color colorFF11161F = Color(0xFF11161F);
  static const Color colorFF111722 = Color(0xFF111722);
  static const Color colorFF111723 = Color(0xFF111723);
  static const Color colorFF111827 = Color(0xFF111827);
  static const Color colorFF111A28 = Color(0xFF111A28);
  static const Color colorFF121923 = Color(0xFF121923);
  static const Color colorFF122844 = Color(0xFF122844);
  static const Color colorFF13161E = Color(0xFF13161E);
  static const Color colorFF131A24 = Color(0xFF131A24);
  static const Color colorFF141924 = Color(0xFF141924);
  static const Color colorFF142033 = Color(0xFF142033);
  static const Color colorFF14213A = Color(0xFF14213A);
  static const Color colorFF14B8A6 = Color(0xFF14B8A6);
  static const Color colorFF16A085 = Color(0xFF16A085);
  static const Color colorFF16A34A = Color(0xFF16A34A);
  static const Color colorFF171B23 = Color(0xFF171B23);
  static const Color colorFF171C26 = Color(0xFF171C26);
  static const Color colorFF171F2B = Color(0xFF171F2B);
  static const Color colorFF18212F = Color(0xFF18212F);
  static const Color colorFF18263D = Color(0xFF18263D);
  static const Color colorFF1A1D23 = Color(0xFF1A1D23);
  static const Color colorFF1A202C = Color(0xFF1A202C);
  static const Color colorFF1A2E4A = Color(0xFF1A2E4A);
  static const Color colorFF1A3A6B = Color(0xFF1A3A6B);
  static const Color colorFF1A8A4A = Color(0xFF1A8A4A);
  static const Color colorFF1B2A4A = Color(0xFF1B2A4A);
  static const Color colorFF1E293B = Color(0xFF1E293B);
  static const Color colorFF1E40AF = Color(0xFF1E40AF);
  static const Color colorFF1F2937 = Color(0xFF1F2937);
  static const Color colorFF1F3A5F = Color(0xFF1F3A5F);
  static const Color colorFF203A55 = Color(0xFF203A55);
  static const Color colorFF233244 = Color(0xFF233244);
  static const Color colorFF243447 = Color(0xFF243447);
  static const Color colorFF252930 = Color(0xFF252930);
  static const Color colorFF2563EB = Color(0xFF2563EB);
  static const Color colorFF27AE60 = Color(0xFF27AE60);
  static const Color colorFF2A3F5F = Color(0xFF2A3F5F);
  static const Color colorFF2C3E50 = Color(0xFF2C3E50);
  static const Color colorFF2D3748 = Color(0xFF2D3748);
  static const Color colorFF2ECC71 = Color(0xFF2ECC71);
  static const Color colorFF334155 = Color(0xFF334155);
  static const Color colorFF3498DB = Color(0xFF3498DB);
  static const Color colorFF374151 = Color(0xFF374151);
  static const Color colorFF3A66D4 = Color(0xFF3A66D4);
  static const Color colorFF425466 = Color(0xFF425466);
  static const Color colorFF475569 = Color(0xFF475569);
  static const Color colorFF4B5563 = Color(0xFF4B5563);
  static const Color colorFF4B7BE5 = Color(0xFF4B7BE5);
  static const Color colorFF4CAF50 = Color(0xFF4CAF50);
  static const Color colorFF5A6070 = Color(0xFF5A6070);
  static const Color colorFF64748B = Color(0xFF64748B);
  static const Color colorFF6B7280 = Color(0xFF6B7280);
  static const Color colorFF6C9FFF = Color(0xFF6C9FFF);
  static const Color colorFF7A1FC7 = Color(0xFF7A1FC7);
  static const Color colorFF7A4B00 = Color(0xFF7A4B00);
  static const Color colorFF7C3AED = Color(0xFF7C3AED);
  static const Color colorFF8B5CF6 = Color(0xFF8B5CF6);
  static const Color colorFF8E2DE2 = Color(0xFF8E2DE2);
  static const Color colorFF8E44AD = Color(0xFF8E44AD);
  static const Color colorFF94A3B8 = Color(0xFF94A3B8);
  static const Color colorFF95A5A6 = Color(0xFF95A5A6);
  static const Color colorFF9A5B00 = Color(0xFF9A5B00);
  static const Color colorFF9B59B6 = Color(0xFF9B59B6);
  static const Color colorFF9CA3AF = Color(0xFF9CA3AF);
  static const Color colorFF9E9E9E = Color(0xFF9E9E9E);
  static const Color colorFFA78BFA = Color(0xFFA78BFA);
  static const Color colorFFAEB8C8 = Color(0xFFAEB8C8);
  static const Color colorFFB0B7C3 = Color(0xFFB0B7C3);
  static const Color colorFFB3E5CE = Color(0xFFB3E5CE);
  static const Color colorFFB3E5FC = Color(0xFFB3E5FC);
  static const Color colorFFB42318 = Color(0xFFB42318);
  static const Color colorFFC0392B = Color(0xFFC0392B);
  static const Color colorFFC0C0C0 = Color(0xFFC0C0C0);
  static const Color colorFFC5CEE0 = Color(0xFFC5CEE0);
  static const Color colorFFCD7F32 = Color(0xFFCD7F32);
  static const Color colorFFD4AF37 = Color(0xFFD4AF37);
  static const Color colorFFD9B56D = Color(0xFFD9B56D);
  static const Color colorFFE08A00 = Color(0xFFE08A00);
  static const Color colorFFE3F2FD = Color(0xFFE3F2FD);
  static const Color colorFFE5E7EB = Color(0xFFE5E7EB);
  static const Color colorFFE67E22 = Color(0xFFE67E22);
  static const Color colorFFE74C3C = Color(0xFFE74C3C);
  static const Color colorFFE7ECFF = Color(0xFFE7ECFF);
  static const Color colorFFE8FFF2 = Color(0xFFE8FFF2);
  static const Color colorFFEAF1FF = Color(0xFFEAF1FF);
  static const Color colorFFEAF2FF = Color(0xFFEAF2FF);
  static const Color colorFFEBF5FB = Color(0xFFEBF5FB);
  static const Color colorFFEF4444 = Color(0xFFEF4444);
  static const Color colorFFEFF4FB = Color(0xFFEFF4FB);
  static const Color colorFFEFF5FC = Color(0xFFEFF5FC);
  static const Color colorFFF0F6FF = Color(0xFFF0F6FF);
  static const Color colorFFF0F8FF = Color(0xFFF0F8FF);
  static const Color colorFFF39C12 = Color(0xFFF39C12);
  static const Color colorFFF3F4F6 = Color(0xFFF3F4F6);
  static const Color colorFFF3F6FF = Color(0xFFF3F6FF);
  static const Color colorFFF3F7FF = Color(0xFFF3F7FF);
  static const Color colorFFF4F6F8 = Color(0xFFF4F6F8);
  static const Color colorFFF4F7FB = Color(0xFFF4F7FB);
  static const Color colorFFF4F8FF = Color(0xFFF4F8FF);
  static const Color colorFFF59E0B = Color(0xFFF59E0B);
  static const Color colorFFF5F6F8 = Color(0xFFF5F6F8);
  static const Color colorFFF5F7FA = Color(0xFFF5F7FA);
  static const Color colorFFF5F8FF = Color(0xFFF5F8FF);
  static const Color colorFFF5F9FF = Color(0xFFF5F9FF);
  static const Color colorFFF7F8FB = Color(0xFFF7F8FB);
  static const Color colorFFF7F9FC = Color(0xFFF7F9FC);
  static const Color colorFFF7FAFF = Color(0xFFF7FAFF);
  static const Color colorFFF8F9FA = Color(0xFFF8F9FA);
  static const Color colorFFF8FAFB = Color(0xFFF8FAFB);
  static const Color colorFFF8FAFC = Color(0xFFF8FAFC);
  static const Color colorFFF8FAFD = Color(0xFFF8FAFD);
  static const Color colorFFF8FBFF = Color(0xFFF8FBFF);
  static const Color colorFFF9FAFB = Color(0xFFF9FAFB);
  static const Color colorFFFFA500 = Color(0xFFFFA500);
  static const Color colorFFFFB020 = Color(0xFFFFB020);
  static const Color colorFFFFB84D = Color(0xFFFFB84D);
  static const Color colorFFFFD166 = Color(0xFFFFD166);
  static const Color colorFFFFD700 = Color(0xFFFFD700);
  static const Color colorFFFFEAEA = Color(0xFFFFEAEA);
  static const Color colorFFFFF6E6 = Color(0xFFFFF6E6);
  static const Color colorFFFFFFFF = Color(0xFFFFFFFF);

  // Material color aliases used by legacy screens after token migration.
  static const Color transparent = Color(0x00000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color white70 = Color(0xB3FFFFFF);
  static const Color white60 = Color(0x99FFFFFF);
  static const Color white54 = Color(0x8AFFFFFF);
  static const Color white38 = Color(0x62FFFFFF);
  static const Color white24 = Color(0x3DFFFFFF);
  static const Color white12 = Color(0x1FFFFFFF);
  static const Color white10 = Color(0x1AFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color black87 = Color(0xDD000000);
  static const Color black54 = Color(0x8A000000);
  static const Color black45 = Color(0x73000000);
  static const Color black38 = Color(0x61000000);
  static const Color black26 = Color(0x42000000);
  static const Color black12 = Color(0x1F000000);
  static const Color materialGrey = Color(0xFF9E9E9E);
  static const Color gray200 = Color(0xFFEEEEEE);
  static const Color gray300 = Color(0xFFE0E0E0);
  static const Color gray400 = Color(0xFFBDBDBD);
  static const Color gray500 = Color(0xFF9E9E9E);
  static const Color gray600 = Color(0xFF757575);
  static const Color gray700 = Color(0xFF616161);
  static const Color gray800 = Color(0xFF424242);
  static const Color materialAmber = Color(0xFFFFC107);
  static const Color greenAccent = Color(0xFF69F0AE);
  static const Color orangeAccent = Color(0xFFFFAB40);

  static const String css18212F = '#18212F';
  static const String css1A3A6B = '#1A3A6B';
  static const String css64748B = '#64748B';
  static const String cssD8E1F0 = '#D8E1F0';
  static const String cssF0F6FF = '#F0F6FF';

  // Spacing tokens
  static const double space2 = 2;
  static const double space4 = 4;
  static const double space6 = 6;
  static const double space8 = 8;
  static const double space10 = 10;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;

  // Executive dashboard scale
  static const double dashboardPageTitleSize = 28;
  static const double dashboardSectionHeaderSize = 20;
  static const double dashboardKpiValueSize = 36;
  static const double dashboardKpiLabelSize = 13;
  static const double dashboardBodySize = 14;
  static const double dashboardSecondarySize = 12;
  static const double dashboardKpiIconSize = 32;
  static const double dashboardSectionSpacing = space24;
  static const double dashboardKpiPadding = space20;

  // Shape and elevation tokens
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 20;
  static const double radiusPanel = 24;
  static const double elevationCard = 1;
  static const double elevationModal = 8;

  // Primary gradient
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryBlue, accentCyan],
  );

  // Success gradient
  static const LinearGradient successGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [successGreen, tealAccent],
  );

  // Warning gradient
  static const LinearGradient warningGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [warningOrange, Color(0xFFFFB366)],
  );

  // Error gradient
  static const LinearGradient errorGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [errorRed, Color(0xFFFF9B9B)],
  );

  // Purple gradient
  static const LinearGradient purpleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [purpleAccent, Color(0xFFD946EF)],
  );

  // Accent gradient
  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFC0392B), Color(0xFFD35400)],
  );

  // Card shadows (for backward compatibility)
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x1A000000), blurRadius: 20, offset: Offset(0, 8)),
  ];

  // Card shadows
  static List<BoxShadow> getCardShadow(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return [
      BoxShadow(
        color: isDark ? const Color(0x1A000000) : const Color(0x0F000000),
        blurRadius: isDark ? 24 : 8,
        offset: const Offset(0, 2),
        spreadRadius: 0,
      ),
      BoxShadow(
        color: isDark ? const Color(0x08000000) : const Color(0x05000000),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ];
  }

  static List<BoxShadow> getElevatedShadow(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return [
      BoxShadow(
        color: isDark ? const Color(0x33000000) : const Color(0x1A000000),
        blurRadius: 32,
        offset: const Offset(0, 12),
      ),
    ];
  }

  static List<BoxShadow> getGlassShadow(BuildContext context) {
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: ((255 ~/ 10) / 255)),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ];
  }

  static Color getCardBg(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkCardBg : lightCardBg;
  }

  static Color getBackgroundColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkBg : lightBg;
  }

  static Color getSidebarColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkSidebar : lightSidebar;
  }

  static Color getBorderColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkBorder : lightBorder;
  }

  static Color getSecondaryBg(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkSidebar : lightPanel;
  }

  static Color getTextColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkText : lightText;
  }

  static Color getSubtleTextColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkMutedText : lightSubtleText;
  }

  static Color getMutedTextColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? neutralGray : lightMutedText;
  }

  static Color getAnalyticsTextColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? gray300 : lightText;
  }

  static Color getAnalyticsSecondaryTextColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkSubtleText : lightSubtleText;
  }

  static Color getAnalyticsMutedTextColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkSubtleText : lightMutedText;
  }

  static Color getAnalyticsAccentTextColor(BuildContext context, Color accent) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark && accent == primaryBlue) {
      return infoBlue;
    }
    return accent;
  }

  static TextStyle getAnalyticsHeadingStyle(
    BuildContext context, {
    double fontSize = 20,
  }) {
    return _systemTextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      color: getAnalyticsTextColor(context),
      letterSpacing: 0,
    );
  }

  static TextStyle getAnalyticsBodyStyle(
    BuildContext context, {
    double fontSize = 14,
  }) {
    return _systemTextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      color: getAnalyticsTextColor(context),
    );
  }

  static TextStyle getAnalyticsSecondaryStyle(BuildContext context) {
    return _systemTextStyle(
      fontSize: dashboardSecondarySize,
      fontWeight: FontWeight.w500,
      color: getAnalyticsSecondaryTextColor(context),
    );
  }

  static TextStyle getAnalyticsCaptionStyle(BuildContext context) {
    return _systemTextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: getAnalyticsMutedTextColor(context),
      letterSpacing: 0,
    );
  }

  static TextStyle getTitleStyle(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _systemTextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w800,
      color: isDark ? white : lightText,
      letterSpacing: 0,
    );
  }

  static TextStyle getSubtitleStyle(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _systemTextStyle(
      color: isDark ? darkSubtleText : colorFF6B7280,
      fontSize: 14,
      fontWeight: FontWeight.w500,
    );
  }

  static TextStyle getHeadingStyle(
    BuildContext context, {
    double fontSize = 20,
  }) {
    return _systemTextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      color: getTextColor(context),
      letterSpacing: 0,
    );
  }

  static TextStyle getBodyStyle(BuildContext context, {double fontSize = 14}) {
    return _systemTextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      color: getTextColor(context),
    );
  }

  static TextStyle getCaptionStyle(BuildContext context) {
    return _systemTextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: getMutedTextColor(context),
      letterSpacing: 0,
    );
  }

  static TextStyle getDashboardPageTitleStyle(BuildContext context) {
    return getHeadingStyle(
      context,
      fontSize: dashboardPageTitleSize,
    ).copyWith(fontWeight: FontWeight.w800);
  }

  static TextStyle getDashboardSectionHeaderStyle(BuildContext context) {
    return getHeadingStyle(
      context,
      fontSize: dashboardSectionHeaderSize,
    ).copyWith(fontWeight: FontWeight.w600);
  }

  static TextStyle getDashboardKpiValueStyle(BuildContext context) {
    return _systemTextStyle(
      fontSize: dashboardKpiValueSize,
      fontWeight: FontWeight.w800,
      color: getTextColor(context),
    );
  }

  static TextStyle getDashboardKpiLabelStyle(BuildContext context) {
    return _systemTextStyle(
      fontSize: dashboardKpiLabelSize,
      fontWeight: FontWeight.w500,
      color: getSubtleTextColor(context),
    );
  }

  static TextStyle getDashboardBodyStyle(BuildContext context) {
    return _systemTextStyle(
      fontSize: dashboardBodySize,
      fontWeight: FontWeight.w500,
      color: getTextColor(context),
    );
  }

  static TextStyle getDashboardSecondaryStyle(BuildContext context) {
    return _systemTextStyle(
      fontSize: dashboardSecondarySize,
      fontWeight: FontWeight.w500,
      color: getSubtleTextColor(context),
    );
  }

  static BorderRadius getCardRadius() {
    return BorderRadius.circular(radiusLg);
  }

  static BorderRadius getButtonRadius() {
    return BorderRadius.circular(radiusMd);
  }

  static BorderRadius getPanelRadius() {
    return BorderRadius.circular(radiusPanel);
  }

  static EdgeInsets getPagePadding(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return EdgeInsets.all(width < 600 ? space16 : space20);
  }

  static Color statusColor(String rawStatus) {
    final status = rawStatus.toLowerCase().trim();
    if (status.contains('complete') || status.contains('synced')) {
      return successGreen;
    }
    if (status.contains('late') ||
        status.contains('error') ||
        status.contains('fail') ||
        status.contains('overdue')) {
      return errorRed;
    }
    if (status.contains('idle') ||
        status.contains('pending') ||
        status.contains('warning') ||
        status.contains('due')) {
      return warningOrange;
    }
    if (status.contains('moving') ||
        status.contains('transit') ||
        status.contains('active')) {
      return primaryBlue;
    }
    return neutralGray;
  }

  static TextStyle _systemTextStyle({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  static TextTheme _buildSystemTextTheme({
    required Color text,
    required Color subtle,
    required Color muted,
  }) {
    return TextTheme(
      displayLarge: _systemTextStyle(
        fontSize: 56,
        fontWeight: FontWeight.w800,
        color: text,
        letterSpacing: 0,
        height: 1.08,
      ),
      displayMedium: _systemTextStyle(
        fontSize: 44,
        fontWeight: FontWeight.w800,
        color: text,
        letterSpacing: 0,
        height: 1.1,
      ),
      displaySmall: _systemTextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w800,
        color: text,
        letterSpacing: 0,
        height: 1.12,
      ),
      headlineLarge: _systemTextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: text,
        letterSpacing: 0,
        height: 1.15,
      ),
      headlineMedium: _systemTextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        color: text,
        letterSpacing: 0,
        height: 1.18,
      ),
      headlineSmall: _systemTextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: text,
        letterSpacing: 0,
        height: 1.2,
      ),
      titleLarge: _systemTextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: text,
        letterSpacing: 0,
        height: 1.2,
      ),
      titleMedium: _systemTextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: text,
        letterSpacing: 0,
        height: 1.25,
      ),
      titleSmall: _systemTextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: text,
        letterSpacing: 0,
        height: 1.25,
      ),
      bodyLarge: _systemTextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: text,
        letterSpacing: 0,
        height: 1.45,
      ),
      bodyMedium: _systemTextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: text,
        letterSpacing: 0,
        height: 1.4,
      ),
      bodySmall: _systemTextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: subtle,
        letterSpacing: 0,
        height: 1.35,
      ),
      labelLarge: _systemTextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: text,
        letterSpacing: 0,
        height: 1.25,
      ),
      labelMedium: _systemTextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: subtle,
        letterSpacing: 0,
        height: 1.25,
      ),
      labelSmall: _systemTextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: muted,
        letterSpacing: 0,
        height: 1.2,
      ),
    );
  }

  static InputDecorationTheme _inputTheme({
    required Color fill,
    required Color text,
    required Color label,
    required Color hint,
    required Color border,
    required Color focused,
  }) {
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      labelStyle: _systemTextStyle(
        color: label,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      floatingLabelStyle: _systemTextStyle(
        color: focused,
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
      hintStyle: _systemTextStyle(
        color: hint,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      helperStyle: _systemTextStyle(
        color: hint,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      errorStyle: _systemTextStyle(
        color: errorRed,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      prefixIconColor: label,
      suffixIconColor: label,
      border: OutlineInputBorder(
        borderRadius: getButtonRadius(),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: getButtonRadius(),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: getButtonRadius(),
        borderSide: BorderSide(color: focused, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: getButtonRadius(),
        borderSide: const BorderSide(color: errorRed),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: getButtonRadius(),
        borderSide: const BorderSide(color: errorRed, width: 1.4),
      ),
    );
  }

  static TextButtonThemeData _textButtonTheme(Color color) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: color,
        textStyle: _systemTextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }

  static ElevatedButtonThemeData _elevatedButtonTheme(Color background) {
    return ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: background,
        foregroundColor: white,
        disabledForegroundColor: white60,
        textStyle: _systemTextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        shape: RoundedRectangleBorder(borderRadius: getButtonRadius()),
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(Color color) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.55)),
        textStyle: _systemTextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        shape: RoundedRectangleBorder(borderRadius: getButtonRadius()),
      ),
    );
  }

  static ThemeData buildLightTheme() {
    final textTheme = _buildSystemTextTheme(
      text: lightText,
      subtle: lightSubtleText,
      muted: lightMutedText,
    );
    final base = ThemeData(
      brightness: Brightness.light,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: lightBg,
      colorScheme: const ColorScheme.light(
        primary: primaryBlue,
        secondary: goldAccent,
        surface: lightCardBg,
      ),
      cardColor: lightCardBg,
      dividerColor: const Color(0xFFE8EAF0),
      useMaterial3: true,
    );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: lightCardBg,
        foregroundColor: lightText,
        titleTextStyle: textTheme.titleLarge,
        toolbarTextStyle: textTheme.bodyMedium,
      ),
      cardTheme: CardThemeData(
        color: lightCardBg,
        elevation: 1,
        shadowColor: const Color(0x0F000000),
        shape: RoundedRectangleBorder(borderRadius: getCardRadius()),
      ),
      inputDecorationTheme: _inputTheme(
        fill: white,
        text: lightText,
        label: lightSubtleText,
        hint: lightMutedText,
        border: lightInputBorder,
        focused: primaryBlue,
      ),
      textButtonTheme: _textButtonTheme(primaryBlue),
      elevatedButtonTheme: _elevatedButtonTheme(primaryBlue),
      outlinedButtonTheme: _outlinedButtonTheme(primaryBlue),
      listTileTheme: ListTileThemeData(
        textColor: lightText,
        iconColor: lightSubtleText,
        titleTextStyle: textTheme.titleSmall,
        subtitleTextStyle: textTheme.bodySmall,
      ),
    );
  }

  static ThemeData buildDarkTheme() {
    final textTheme = _buildSystemTextTheme(
      text: darkText,
      subtle: darkSubtleText,
      muted: darkMutedText,
    );
    final base = ThemeData(
      brightness: Brightness.dark,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: darkBg,
      colorScheme: const ColorScheme.dark(
        primary: accentCyan,
        secondary: goldAccent,
        surface: darkCardBg,
      ),
      cardColor: darkCardBg,
      dividerColor: const Color(0xFF273245),
      useMaterial3: true,
    );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: darkCardBg,
        foregroundColor: darkText,
        titleTextStyle: textTheme.titleLarge,
        toolbarTextStyle: textTheme.bodyMedium,
      ),
      cardTheme: CardThemeData(
        color: darkCardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: getCardRadius()),
      ),
      inputDecorationTheme: _inputTheme(
        fill: darkPanel,
        text: darkText,
        label: darkSubtleText,
        hint: darkMutedText,
        border: darkInputBorder,
        focused: accentCyan,
      ),
      textButtonTheme: _textButtonTheme(accentCyan),
      elevatedButtonTheme: _elevatedButtonTheme(primaryBlue),
      outlinedButtonTheme: _outlinedButtonTheme(accentCyan),
      listTileTheme: ListTileThemeData(
        textColor: darkText,
        iconColor: darkSubtleText,
        titleTextStyle: textTheme.titleSmall,
        subtitleTextStyle: textTheme.bodySmall,
      ),
    );
  }
}
