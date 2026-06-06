#!/usr/bin/env bash
set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
    git clone https://github.com/flutter/flutter.git --branch stable --depth 1 /tmp/flutter
    export PATH="/tmp/flutter/bin:${PATH}"
fi

flutter config --enable-web
flutter pub get

RESOLVED_API_BASE_URL="${API_BASE_URL:-${PIONEER_API_BASE_URL:-}}"

if [[ -z "${RESOLVED_API_BASE_URL}" ]]; then
    echo "API_BASE_URL is required. Set it to your Render backend URL, for example https://your-backend.onrender.com."
    exit 1
fi

flutter build web \
    --release \
    --dart-define=API_BASE_URL="${RESOLVED_API_BASE_URL}" \
    --dart-define=PIONEER_SHOW_MOCK_DATA="${PIONEER_SHOW_MOCK_DATA:-true}"
