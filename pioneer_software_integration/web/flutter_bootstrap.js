{{flutter_js}}
{{flutter_build_config}}

const serviceWorkerVersion = {{flutter_service_worker_version}};

const flutterLoaderOptions = {
  config: {
    fontFallbackBaseUrl: 'assets/font-fallback/',
  },
};

if (serviceWorkerVersion != null) {
  flutterLoaderOptions.serviceWorkerSettings = {
    serviceWorkerVersion: serviceWorkerVersion,
  };
}

_flutter.loader.load(flutterLoaderOptions);
