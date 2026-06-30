import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;

import '../theme/app_theme.dart';

enum PioneerMapMarkerStyle { moving, idle, offline, stale }

class PioneerGoogleMapMarkerFactory {
  static final Map<String, gmaps.BitmapDescriptor> _cache = {};

  static Future<gmaps.BitmapDescriptor> marker(
    PioneerMapMarkerStyle style, {
    bool selected = false,
    bool compact = false,
    double zoomScale = 1.0,
  }) async {
    final key =
        "${style.name}:${selected ? 'selected' : 'base'}:${compact ? 'compact' : 'full'}:${zoomScale.toStringAsFixed(2)}";
    final cached = _cache[key];
    if (cached != null) {
      return cached;
    }

    final bytes = await _drawMarker(
      style,
      selected: selected,
      compact: compact,
    );
    final logicalSize = markerLogicalSize(
      style,
      selected: selected,
      compact: compact,
      zoomScale: zoomScale,
    );
    final descriptor = gmaps.BitmapDescriptor.bytes(
      bytes,
      width: logicalSize,
      height: logicalSize,
    );
    _cache[key] = descriptor;
    return descriptor;
  }

  static double markerLogicalSize(
    PioneerMapMarkerStyle style, {
    bool selected = false,
    bool compact = false,
    double zoomScale = 1.0,
  }) {
    double base;
    if (compact) {
      switch (style) {
        case PioneerMapMarkerStyle.moving:
          base = 38.0;
          break;
        case PioneerMapMarkerStyle.idle:
          base = 34.0;
          break;
        case PioneerMapMarkerStyle.offline:
          base = 29.0;
          break;
        case PioneerMapMarkerStyle.stale:
          base = 31.0;
          break;
      }
      return (selected ? base + 7.0 : base) * zoomScale;
    }
    switch (style) {
      case PioneerMapMarkerStyle.moving:
        base = 86.0;
        break;
      case PioneerMapMarkerStyle.idle:
        base = 72.0;
        break;
      case PioneerMapMarkerStyle.offline:
        base = 58.0;
        break;
      case PioneerMapMarkerStyle.stale:
        base = 62.0;
        break;
    }
    return (selected ? base + 16.0 : base) * zoomScale;
  }

  static Color markerFillColor(PioneerMapMarkerStyle style) {
    switch (style) {
      case PioneerMapMarkerStyle.moving:
        return AppTheme.primaryBlue;
      case PioneerMapMarkerStyle.idle:
        return AppTheme.warningOrange;
      case PioneerMapMarkerStyle.offline:
        return AppTheme.markerOfflineGray;
      case PioneerMapMarkerStyle.stale:
        return AppTheme.markerOfflineGray.withValues(alpha: 0.58);
    }
  }

  static Future<Uint8List> _drawMarker(
    PioneerMapMarkerStyle style, {
    required bool selected,
    required bool compact,
  }) async {
    const size = 128.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);

    if (compact) {
      _drawCompactMarker(canvas, center, style, selected: selected);
    } else {
      if (selected) {
        _drawSelectionHalo(canvas, center, style);
      }
      switch (style) {
        case PioneerMapMarkerStyle.moving:
          _drawMovingFleetMarker(canvas, center);
          break;
        case PioneerMapMarkerStyle.idle:
          _drawDirectionalMarker(
            canvas,
            center,
            fillColor: markerFillColor(style),
            strokeColor: AppTheme.white,
            accentColor: AppTheme.warningOrange,
            scale: 0.84,
            idleRing: true,
            badgeIcon: Icons.pause_rounded,
          );
          break;
        case PioneerMapMarkerStyle.offline:
          _drawDirectionalMarker(
            canvas,
            center,
            fillColor: markerFillColor(style),
            strokeColor: AppTheme.white.withAlpha(230),
            accentColor: AppTheme.disabledGray,
            scale: 0.72,
            badgeIcon: Icons.power_settings_new_rounded,
          );
          break;
        case PioneerMapMarkerStyle.stale:
          _drawDirectionalMarker(
            canvas,
            center,
            fillColor: markerFillColor(style),
            strokeColor: AppTheme.white.withAlpha(210),
            accentColor: AppTheme.warningOrange,
            scale: 0.74,
            dashedStroke: true,
            badgeIcon: Icons.schedule_rounded,
          );
          break;
      }
    }

    final image = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  static void _drawCompactMarker(
    Canvas canvas,
    Offset center,
    PioneerMapMarkerStyle style, {
    required bool selected,
  }) {
    final fillColor = markerFillColor(style);
    final radius = selected ? 33.0 : 28.0;
    final glow = Paint()
      ..color = fillColor.withAlpha(selected ? 100 : 72)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(center, radius + 8, glow);
    if (selected) {
      canvas.drawCircle(
        center,
        radius + 8,
        Paint()
          ..color = fillColor.withAlpha(210)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = AppTheme.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    if (style == PioneerMapMarkerStyle.stale) {
      _drawIconGlyph(
        canvas,
        center,
        Icons.schedule_rounded,
        size: 29,
        color: AppTheme.white,
      );
      return;
    }
    canvas.drawCircle(
      center,
      selected ? 9 : 8,
      Paint()
        ..color = AppTheme.white
        ..style = PaintingStyle.fill,
    );
  }

  static void _drawMovingFleetMarker(Canvas canvas, Offset center) {
    _drawDirectionalMarker(
      canvas,
      center,
      fillColor: AppTheme.primaryBlue,
      strokeColor: AppTheme.white,
      accentColor: AppTheme.accentCyan,
      scale: 1,
    );
  }

  static void _drawSelectionHalo(
    Canvas canvas,
    Offset center,
    PioneerMapMarkerStyle style,
  ) {
    final Color haloColor;
    switch (style) {
      case PioneerMapMarkerStyle.moving:
        haloColor = AppTheme.primaryBlue;
        break;
      case PioneerMapMarkerStyle.idle:
        haloColor = AppTheme.warningOrange;
        break;
      case PioneerMapMarkerStyle.offline:
        haloColor = AppTheme.neutralGray;
        break;
      case PioneerMapMarkerStyle.stale:
        haloColor = AppTheme.warningOrange;
        break;
    }
    final fill = Paint()
      ..color = haloColor.withAlpha(46)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = haloColor.withAlpha(199)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6;
    canvas.drawCircle(center, 61, fill);
    canvas.drawCircle(center, 61, stroke);
  }

  static void _drawDirectionalMarker(
    Canvas canvas,
    Offset center, {
    required Color fillColor,
    required Color strokeColor,
    required Color accentColor,
    required double scale,
    bool idleRing = false,
    bool dashedStroke = false,
    IconData? badgeIcon,
  }) {
    final haloRadius = 50.0 * scale;
    final shadow = Paint()
      ..color = AppTheme.black.withAlpha(132)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
    final fill = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final accentStroke = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final outerStroke = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9 * scale
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    if (idleRing) {
      canvas.drawCircle(
        center,
        haloRadius + 7,
        Paint()
          ..color = accentColor.withAlpha(72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8,
      );
      canvas.drawCircle(
        center,
        haloRadius + 18,
        Paint()
          ..color = accentColor.withAlpha(42)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    final halo = Paint()
      ..color = accentColor.withAlpha(dashedStroke ? 55 : 105)
      ..style = PaintingStyle.fill;
    halo.maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);

    final bodyRect = Rect.fromCenter(
      center: center,
      width: 78 * scale,
      height: 74 * scale,
    );
    final bodyPath = Path()
      ..addRRect(
        RRect.fromRectAndRadius(bodyRect, Radius.circular(24 * scale)),
      );
    final directionNotch = Path()
      ..moveTo(center.dx, center.dy - 57 * scale)
      ..lineTo(center.dx + 13 * scale, center.dy - 36 * scale)
      ..lineTo(center.dx - 13 * scale, center.dy - 36 * scale)
      ..close();
    final lowerPin = Path()
      ..moveTo(center.dx - 10 * scale, center.dy + 35 * scale)
      ..quadraticBezierTo(
        center.dx,
        center.dy + 54 * scale,
        center.dx + 10 * scale,
        center.dy + 35 * scale,
      )
      ..close();
    final path = Path.combine(
      ui.PathOperation.union,
      Path.combine(ui.PathOperation.union, bodyPath, directionNotch),
      lowerPin,
    );

    canvas.drawCircle(center, haloRadius, halo);
    canvas.drawPath(path.shift(Offset(0, 5 * scale)), shadow);
    if (dashedStroke) {
      _drawDashedPath(canvas, path, outerStroke);
    } else {
      canvas.drawPath(path, outerStroke);
    }
    canvas.drawPath(path, fill);
    canvas.drawPath(path, accentStroke);

    _drawIconGlyph(
      canvas,
      center.translate(0, 2 * scale),
      Icons.local_shipping_rounded,
      size: 36 * scale,
      color: AppTheme.white.withAlpha(dashedStroke ? 178 : 238),
    );

    if (badgeIcon != null) {
      final badgeCenter = Offset(
        center.dx + 34 * scale,
        center.dy - 32 * scale,
      );
      canvas.drawCircle(
        badgeCenter,
        18 * scale,
        Paint()
          ..color = accentColor
          ..style = PaintingStyle.fill,
      );
      _drawIconGlyph(
        canvas,
        badgeCenter,
        badgeIcon,
        size: 22 * scale,
        color: AppTheme.white,
      );
    }
  }

  static void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 10.0;
      const gap = 7.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  static void _drawIconGlyph(
    Canvas canvas,
    Offset center,
    IconData icon, {
    required double size,
    required Color color,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          color: color,
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }
}
