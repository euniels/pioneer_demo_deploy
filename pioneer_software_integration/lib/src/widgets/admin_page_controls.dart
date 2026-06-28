import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AdminSearchField extends StatelessWidget {
  const AdminSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: AppTheme.settingsBodyStyle(context),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: AppTheme.settingsSubtitleStyle(context, fontSize: 14),
        prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textSecondary(context)),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: onClear,
                icon: Icon(Icons.close_rounded, color: AppTheme.textSecondary(context)),
              ),
        filled: true,
        fillColor: AppTheme.surfaceInput(context),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppTheme.borderDefault(context)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppTheme.borderDefault(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.infoBlue, width: 1.3),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        isDense: true,
      ),
    );
  }
}

class AdminViewToggle extends StatelessWidget {
  const AdminViewToggle({
    super.key,
    required this.gridActive,
    required this.onGrid,
    required this.onList,
    this.height = 50,
    this.buttonSize = 42,
  });

  final bool gridActive;
  final VoidCallback onGrid;
  final VoidCallback onList;
  final double height;
  final double buttonSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceInput(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderDefault(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AdminViewToggleButton(
            icon: Icons.grid_view_rounded,
            active: gridActive,
            tooltip: 'Grid view',
            onTap: onGrid,
            size: buttonSize,
          ),
          _AdminViewToggleButton(
            icon: Icons.view_list_rounded,
            active: !gridActive,
            tooltip: 'List view',
            onTap: onList,
            size: buttonSize,
          ),
        ],
      ),
    );
  }
}

class _AdminViewToggleButton extends StatelessWidget {
  const _AdminViewToggleButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
    required this.size,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? AppTheme.successGreen.withValues(alpha: 0.22)
                : AppTheme.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            icon,
            color: active ? AppTheme.successGreen : AppTheme.textSecondary(context),
            size: 20,
          ),
        ),
      ),
    );
  }
}

class AdminResultCount extends StatelessWidget {
  const AdminResultCount({
    super.key,
    required this.count,
    required this.label,
  });

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.infoBlue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.infoBlue.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$count $label shown',
        style: const TextStyle(
          color: AppTheme.infoBlue,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class AdminFilterChip extends StatelessWidget {
  const AdminFilterChip({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
    required this.onClear,
    this.activeWhen = 'All',
    this.displayValue,
    this.optionLabels,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;
  final String activeWhen;
  final String? displayValue;
  final Map<String, String>? optionLabels;

  @override
  Widget build(BuildContext context) {
    final active = value != activeWhen;
    final shownValue = displayValue ?? value;
    return PopupMenuButton<String>(
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem(
            value: option,
            child: Text(optionLabels?[option] ?? option),
          ),
      ],
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.successGreen.withValues(alpha: 0.13)
              : AppTheme.surfaceInput(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? AppTheme.successGreen.withValues(alpha: 0.34)
                : AppTheme.borderDefault(context),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              active ? '$label: $shownValue' : shownValue,
              style: TextStyle(
                color: active ? AppTheme.successGreen : AppTheme.textPrimary(context),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: active ? AppTheme.successGreen : AppTheme.textSecondary(context),
            ),
            if (active) ...[
              const SizedBox(width: 4),
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(999),
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: AppTheme.textSecondary(context),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AdminSummaryCard extends StatelessWidget {
  const AdminSummaryCard({
    super.key,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.10),
            blurRadius: 22,
            spreadRadius: -14,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.settingsLabelStyle(context, fontSize: 13),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textPrimary(context),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.settingsSubtitleStyle(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
