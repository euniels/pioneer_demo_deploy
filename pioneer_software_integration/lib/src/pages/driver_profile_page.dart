import 'package:flutter/material.dart';
import '../widgets/dashboard_layout.dart';
import '../services/auth.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

class DriverProfilePage extends StatefulWidget {
  const DriverProfilePage({super.key});
  @override
  State<DriverProfilePage> createState() => _DriverProfilePageState();
}

class _DriverProfilePageState extends State<DriverProfilePage>
    with TickerProviderStateMixin {
  late AnimationController _cardAnimationController;
  late AnimationController _chartAnimationController;

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;
  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;

  @override
  void initState() {
    super.initState();
    _cardAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _chartAnimationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _cardAnimationController.forward();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _chartAnimationController.forward();
    });
  }

  @override
  void dispose() {
    _cardAnimationController.dispose();
    _chartAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/driver-profile',
      title: 'My Profile',
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = _isMobile(context);
    final isTablet = _isTablet(context);
    final user = AuthService.currentUserData!;

    return SingleChildScrollView(
      padding: EdgeInsets.all(
        isMobile
            ? 16
            : isTablet
            ? 24
            : 32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // â”€â”€ Profile hero â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          _buildProfileHero(user, isDark, isMobile)
              .animate()
              .fadeIn(duration: 400.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 400.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          // â”€â”€ Performance stats (same as DashboardPage stat cards) â”€â”€
          _buildPerformanceCards(isDark, isMobile)
              .animate()
              .fadeIn(duration: 500.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 500.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          // â”€â”€ Info + achievements â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          _buildDetailsSection(user, isDark, isMobile)
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 600.ms,
                curve: Curves.easeOut,
              ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  PROFILE HERO â€” green gradient, matches current trip card style
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildProfileHero(dynamic user, bool isDark, bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 20 : 28),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.colorFF27AE60, AppTheme.colorFF1A8A4A],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.colorFF27AE60.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          Container(
            width: isMobile ? 72 : 88,
            height: isMobile ? 72 : 88,
            decoration: BoxDecoration(
              color: AppTheme.white,
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Text(
                user.fullName[0].toUpperCase(),
                style: TextStyle(
                  fontSize: isMobile ? 30 : 36,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.colorFF27AE60,
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.fullName,
                  style: TextStyle(
                    fontSize: isMobile ? 20 : 24,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user.roleName ?? 'Driver',
                  style: TextStyle(
                    fontSize: isMobile ? 13 : 14,
                    color: AppTheme.white.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                // Rating + vehicle row
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            color: AppTheme.materialAmber,
                            size: 16,
                          ),
                          const SizedBox(width: 5),
                          const Text(
                            '4.8',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.white,
                            ),
                          ),
                          Text(
                            ' rating',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.white.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (user.assignedVehicle != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.local_shipping_rounded,
                              color: AppTheme.white,
                              size: 14,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              user.assignedVehicle,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  PERFORMANCE CARDS â€” exact DashboardPage _buildTopStatCard style
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildPerformanceCards(bool isDark, bool isMobile) {
    final sw = MediaQuery.of(context).size.width;
    final cards = [
      _buildStatCard(
        title: 'TOTAL TRIPS',
        value: '2,847',
        subtitle: 'lifetime trips',
        icon: Icons.route_rounded,
        color: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _buildStatCard(
        title: 'ON-TIME RATE',
        value: '98%',
        subtitle: 'deliveries on time',
        icon: Icons.check_circle_rounded,
        color: AppTheme.colorFF27AE60,
        isDark: isDark,
      ),
      _buildStatCard(
        title: 'SAFETY SCORE',
        value: '95/100',
        subtitle: 'safety rating',
        icon: Icons.security_rounded,
        color: AppTheme.colorFFF39C12,
        isDark: isDark,
      ),
      _buildStatCard(
        title: 'EXPERIENCE',
        value: '12 yrs',
        subtitle: 'driving experience',
        icon: Icons.workspace_premium_rounded,
        color: AppTheme.colorFFE74C3C,
        isDark: isDark,
      ),
    ];

    if (sw >= 1000) {
      return Row(
        children: cards
            .asMap()
            .entries
            .map(
              (e) => Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: e.key < cards.length - 1 ? 20 : 0,
                  ),
                  child: e.value,
                ),
              ),
            )
            .toList(),
      );
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 12),
            Expanded(child: cards[1]),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: cards[2]),
            const SizedBox(width: 12),
            Expanded(child: cards[3]),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    final sw = MediaQuery.of(context).size.width;
    final pad = sw < 360
        ? 12.0
        : sw < 600
        ? 16.0
        : 20.0;
    final br = sw < 360
        ? 10.0
        : sw < 600
        ? 12.0
        : 16.0;
    final titleSz = sw < 360
        ? 9.0
        : sw < 600
        ? 10.0
        : 11.0;
    final valueSz = sw < 360
        ? 20.0
        : sw < 600
        ? 24.0
        : 32.0;
    final subSz = sw < 360
        ? 9.0
        : sw < 600
        ? 10.0
        : 11.0;
    final iconSz = sw < 360
        ? 16.0
        : sw < 600
        ? 18.0
        : 20.0;
    final spSm = sw < 360
        ? 4.0
        : sw < 600
        ? 6.0
        : 8.0;
    final spMd = sw < 360
        ? 6.0
        : sw < 600
        ? 8.0
        : 12.0;

    return Container(
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                colors: [
                  color.withValues(alpha: 0.3),
                  color.withValues(alpha: 0.1),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isDark ? null : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(br),
        border: Border.all(
          color: isDark
              ? color.withValues(alpha: 0.3)
              : color.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: titleSz,
                    fontWeight: FontWeight.w600,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: spSm),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: iconSz),
              ),
            ],
          ),
          SizedBox(height: spMd),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: valueSz,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.white : color,
              ),
            ),
          ),
          SizedBox(height: spSm),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: subSz,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  DETAILS SECTION â€” personal info + achievements
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildDetailsSection(dynamic user, bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 900) {
      return Column(
        children: [
          _buildPersonalInfo(user, isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildAchievements(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: _buildPersonalInfo(user, isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 5, child: _buildAchievements(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildPersonalInfo(dynamic user, bool isDark, bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Personal Information',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your account details',
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 20),
          _infoRow(
            Icons.badge_rounded,
            'Driver ID',
            user.id,
            AppTheme.colorFF4B7BE5,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.email_rounded,
            'Email',
            user.email,
            AppTheme.colorFF27AE60,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.phone_rounded,
            'Phone',
            user.phone ?? 'Not provided',
            AppTheme.colorFFF39C12,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.local_shipping_rounded,
            'Assigned Vehicle',
            user.assignedVehicle ?? 'Not assigned',
            AppTheme.colorFF4B7BE5,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.calendar_today_rounded,
            'Join Date',
            user.joinDate != null
                ? '${user.joinDate!.day}/${user.joinDate!.month}/${user.joinDate!.year}'
                : 'N/A',
            AppTheme.colorFFE74C3C,
            isDark,
            isMobile,
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _infoRow(
    IconData icon,
    String label,
    String value,
    Color color,
    bool isDark,
    bool isMobile, {
    bool isLast = false,
  }) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: color, size: isMobile ? 17 : 19),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: isMobile ? 11 : 12,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: isMobile ? 13 : 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!isLast)
          Divider(
            height: 1,
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.06)
                : AppTheme.black.withValues(alpha: 0.05),
          ),
      ],
    );
  }

  Widget _buildAchievements(bool isDark, bool isMobile) {
    final achievements = [
      {
        'title': 'Perfect Week',
        'desc': '7 days on-time delivery',
        'icon': Icons.emoji_events_rounded,
        'color': AppTheme.colorFFF39C12,
      },
      {
        'title': 'Speed Star',
        'desc': 'Fastest delivery of the month',
        'icon': Icons.bolt_rounded,
        'color': AppTheme.colorFF4B7BE5,
      },
      {
        'title': 'Top Earner',
        'desc': 'Highest earnings this quarter',
        'icon': Icons.payments_rounded,
        'color': AppTheme.colorFF27AE60,
      },
      {
        'title': 'Safety Pro',
        'desc': '100 trips without incidents',
        'icon': Icons.security_rounded,
        'color': AppTheme.colorFFE74C3C,
      },
    ];

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Achievements',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Badges earned on the road',
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 20),
          ...achievements.map((a) {
            final color = a['color'] as Color;
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: isDark
                    ? LinearGradient(
                        colors: [
                          color.withValues(alpha: 0.2),
                          color.withValues(alpha: 0.05),
                        ],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      )
                    : null,
                color: isDark ? null : color.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? color.withValues(alpha: 0.25)
                      : color.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(a['icon'] as IconData, color: color, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a['title'] as String,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          a['desc'] as String,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check_rounded, color: color, size: 14),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  BoxDecoration _card(bool isDark) => BoxDecoration(
    color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
    borderRadius: BorderRadius.circular(20),
    border: Border.all(
      color: isDark
          ? AppTheme.white.withValues(alpha: 0.08)
          : AppTheme.black.withValues(alpha: 0.05),
    ),
    boxShadow: [
      BoxShadow(
        color: AppTheme.black.withValues(alpha: isDark ? 0.2 : 0.02),
        blurRadius: 10,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
