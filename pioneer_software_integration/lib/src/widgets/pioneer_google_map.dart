import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/google_maps_loader.dart';
import '../theme/app_theme.dart';

class PioneerGoogleMap extends StatefulWidget {
  const PioneerGoogleMap({
    super.key,
    required this.initialCenter,
    this.initialZoom = 13,
    this.markers = const <Marker>{},
    this.polylines = const <Polyline>{},
    this.polygons = const <Polygon>{},
    this.circles = const <Circle>{},
    this.onMapCreated,
    this.onTap,
    this.onCameraMove,
    this.onCameraIdle,
    this.myLocationEnabled = false,
    this.zoomControlsEnabled = true,
    this.mapToolbarEnabled = false,
    this.trafficEnabled = false,
  });

  final LatLng initialCenter;
  final double initialZoom;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final Set<Polygon> polygons;
  final Set<Circle> circles;
  final ValueChanged<GoogleMapController>? onMapCreated;
  final ArgumentCallback<LatLng>? onTap;
  final ArgumentCallback<CameraPosition>? onCameraMove;
  final VoidCallback? onCameraIdle;
  final bool myLocationEnabled;
  final bool zoomControlsEnabled;
  final bool mapToolbarEnabled;
  final bool trafficEnabled;

  @override
  State<PioneerGoogleMap> createState() => _PioneerGoogleMapState();
}

class _PioneerGoogleMapState extends State<PioneerGoogleMap> {
  late Future<bool> _readyFuture;

  @override
  void initState() {
    super.initState();
    _readyFuture = ensureGoogleMapsReady();
  }

  void _retryGoogleMapsLoad() {
    setState(() {
      _readyFuture = ensureGoogleMapsReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _readyFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _GoogleMapOverlay(
            icon: Icons.map_rounded,
            title: 'Loading Google Maps',
            message:
                'Checking the map configuration and preparing the route view.',
            showSpinner: true,
          );
        }

        if (snapshot.data != true) {
          return GoogleMapsNotConfigured(onRetry: _retryGoogleMapsLoad);
        }

        return GoogleMap(
          initialCameraPosition: CameraPosition(
            target: widget.initialCenter,
            zoom: widget.initialZoom,
          ),
          markers: widget.markers,
          polylines: widget.polylines,
          polygons: widget.polygons,
          circles: widget.circles,
          onMapCreated: widget.onMapCreated,
          onTap: widget.onTap,
          onCameraMove: widget.onCameraMove,
          onCameraIdle: widget.onCameraIdle,
          myLocationEnabled: widget.myLocationEnabled,
          zoomControlsEnabled: widget.zoomControlsEnabled,
          mapToolbarEnabled: widget.mapToolbarEnabled,
          trafficEnabled: widget.trafficEnabled,
          rotateGesturesEnabled: false,
          compassEnabled: true,
        );
      },
    );
  }
}

class GoogleMapsNotConfigured extends StatelessWidget {
  const GoogleMapsNotConfigured({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return _GoogleMapOverlay(
      icon: Icons.map_outlined,
      title: 'Google Maps API key required',
      message:
          'Maps stay disabled until Laravel returns a configured browser key or GOOGLE_MAPS_API_KEY is supplied locally.',
      actionLabel: 'Retry map',
      onAction: onRetry,
    );
  }
}

class _GoogleMapOverlay extends StatelessWidget {
  const _GoogleMapOverlay({
    required this.icon,
    required this.title,
    required this.message,
    this.showSpinner = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool showSpinner;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF101826 : AppTheme.colorFFF8FAFC,
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSpinner)
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            else
              Icon(icon, size: 40, color: AppTheme.primaryBlue),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTheme.getHeadingStyle(context, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTheme.getSubtitleStyle(context),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
