import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ModernSearchBar extends StatefulWidget {
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSearch;
  final TextEditingController? controller;
  final bool showFilter;
  final VoidCallback? onFilterTap;

  const ModernSearchBar({
    this.hintText = 'Search...',
    this.onChanged,
    this.onSearch,
    this.controller,
    this.showFilter = true,
    this.onFilterTap,
    super.key,
  });

  @override
  State<ModernSearchBar> createState() => _ModernSearchBarState();
}

class _ModernSearchBarState extends State<ModernSearchBar> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      setState(() => _isFocused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppTheme.getCardBg(context),
        border: Border.all(
          color: _isFocused
              ? AppTheme.primaryBlue.withValues(alpha: ((200) / 255))
              : AppTheme.getBorderColor(context),
          width: _isFocused ? 2 : 1,
        ),
        boxShadow: _isFocused
            ? [
                BoxShadow(
                  color: AppTheme.primaryBlue.withValues(alpha: ((30) / 255)),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(
            Icons.search_rounded,
            color: AppTheme.getMutedTextColor(context),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: widget.onChanged,
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(
                  color: AppTheme.getMutedTextColor(context),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              style: TextStyle(
                color: AppTheme.getTextColor(context),
                fontSize: 14,
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                setState(() => _controller.clear());
                widget.onChanged?.call('');
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  Icons.close_rounded,
                  color: AppTheme.getMutedTextColor(context),
                  size: 18,
                ),
              ),
            ),
          if (widget.showFilter) ...[
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 1,
              height: 24,
              color: AppTheme.getBorderColor(context),
            ),
            GestureDetector(
              onTap: widget.onFilterTap,
              child: Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppTheme.primaryBlue.withValues(alpha: ((20) / 255)),
                ),
                child: Icon(
                  Icons.tune_rounded,
                  color: AppTheme.primaryBlue,
                  size: 18,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
