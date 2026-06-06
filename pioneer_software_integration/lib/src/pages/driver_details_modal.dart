import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../services/api.dart';
import '../widgets/enhanced_button.dart';
import '../widgets/geotab_sync_status_badge.dart';
// progress_ring not used here

class DriverDetailsModal extends StatefulWidget {
  final String driverName;

  const DriverDetailsModal({required this.driverName, super.key});

  @override
  State<DriverDetailsModal> createState() => _DriverDetailsModalState();
}

class _DriverDetailsModalState extends State<DriverDetailsModal> {
  late Future<Map<String, dynamic>> driverDataFuture;

  @override
  void initState() {
    super.initState();
    driverDataFuture = Api.getDriverDetails(widget.driverName);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: driverDataFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppTheme.primaryBlue),
          );
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('Driver not found'));
        }

        final driver = snapshot.data!;
        final ratingColor = driver['rating'] >= 4.5
            ? AppTheme.successGreen
            : AppTheme.primaryBlue;

        return Container(
          decoration: BoxDecoration(
            color: AppTheme.getCardBg(context),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with gradient
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [ratingColor, ratingColor.withValues(alpha: 0.7)],
                  ),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: AppTheme.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: Text(
                          (driver['name'] ?? 'D').substring(0, 1).toUpperCase(),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.colorFF4B7BE5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            driver['name'] ?? 'Unknown',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              driver['status'] ?? 'Unknown',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.white,
                              ),
                            ),
                          ),
                          if (driver.containsKey('syncStatus')) ...[
                            const SizedBox(height: 8),
                            GeoTabSyncStatusBadge.fromEntity(
                              driver,
                              compact: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppTheme.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.close,
                          color: AppTheme.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    // Performance Metrics Row
                    Row(
                      children: [
                        Expanded(
                          child: _buildMetricCard(
                            'Safety Score',
                            '${driver['safetyScore']}%',
                            AppTheme.successGreen,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildMetricCard(
                            'Rating',
                            '${driver['rating']}/5',
                            ratingColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildMetricCard(
                            'On-Time',
                            '${driver['onTimePercentage']}%',
                            AppTheme.primaryBlue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildSection('Contact Information', [
                      _buildInfoRow('License', driver['license'] ?? 'N/A'),
                      _buildInfoRow('Phone', driver['phone'] ?? 'N/A'),
                      _buildInfoRow('Email', driver['email'] ?? 'N/A'),
                    ]),
                    const SizedBox(height: 24),
                    _buildSection('Experience & Statistics', [
                      _buildInfoRow(
                        'Experience',
                        driver['experience'] ?? 'N/A',
                      ),
                      _buildInfoRow(
                        'Total Trips',
                        driver['totalTrips']?.toString() ?? 'N/A',
                      ),
                      _buildInfoRow(
                        'Total Distance',
                        driver['totalDistance'] ?? 'N/A',
                      ),
                      _buildInfoRow(
                        'Violations',
                        '${driver['violations'] ?? 0}',
                      ),
                    ]),
                    const SizedBox(height: 24),
                    _buildSection('License & Assignment', [
                      _buildInfoRow(
                        'Current Vehicle',
                        driver['currentVehicle'] ?? 'N/A',
                      ),
                      _buildInfoRow(
                        'License Expires',
                        driver['licenseExpiry'] ?? 'N/A',
                      ),
                      _buildInfoRow('Join Date', driver['joinDate'] ?? 'N/A'),
                    ]),
                    const SizedBox(height: 30),
                    Row(
                      children: [
                        Expanded(
                          child: EnhancedButton(
                            label: 'View Trips',
                            style: EnhancedButtonStyle.primary,
                            onPressed: () {
                              // View trips functionality
                            },
                          ).animate().fadeIn(duration: 300.ms),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: EnhancedButton(
                            label: 'Contact',
                            style: EnhancedButtonStyle.secondary,
                            onPressed: () {
                              // Contact functionality
                            },
                          ).animate().fadeIn(duration: 300.ms),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMetricCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.getSubtleTextColor(context),
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTheme.getHeadingStyle(
            context,
            fontSize: 14,
          ).copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.5),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.getSecondaryBg(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.getBorderColor(context)),
          ),
          child: Column(
            children: List.generate(children.length, (index) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: children[index],
                  ),
                  if (index < children.length - 1)
                    Divider(height: 1, color: AppTheme.getBorderColor(context)),
                ],
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: AppTheme.getSubtleTextColor(context),
          ),
        ),
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.getTextColor(context),
            ),
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
