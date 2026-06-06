(function () {
  const defaultApiBase = 'http://127.0.0.1:8000/api';
  const apiBase = window.PIONEER_API_BASE || defaultApiBase;

  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const rawData = window.atob(base64);
    const outputArray = new Uint8Array(rawData.length);
    for (let i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
  }

  async function registerPush() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
      return;
    }

    const storedPermission = window.localStorage.getItem('pioneerpath.push.permission');
    if (storedPermission === 'denied') {
      return;
    }

    const registration = await navigator.serviceWorker.register('pioneer_push_sw.js');
    if (!('Notification' in window)) {
      return;
    }

    const permission = Notification.permission === 'default' && storedPermission !== 'granted'
      ? await Notification.requestPermission()
      : Notification.permission;
    window.localStorage.setItem('pioneerpath.push.permission', permission);
    if (permission !== 'granted') {
      return;
    }

    const configResponse = await fetch(`${apiBase}/fleet/push/config`, {
      headers: { Accept: 'application/json' },
    });
    const configPayload = await configResponse.json();
    const vapidKey = configPayload && configPayload.data
      ? configPayload.data.publicKey
      : '';
    if (!vapidKey) {
      return;
    }

    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(vapidKey),
    });

    await fetch(`${apiBase}/fleet/push/subscriptions`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        platform: 'web',
        endpoint: subscription.endpoint,
        contentEncoding: PushManager.supportedContentEncodings &&
          PushManager.supportedContentEncodings.includes('aes128gcm')
          ? 'aes128gcm'
          : 'aesgcm',
        keys: subscription.toJSON().keys || {},
        meta: { userAgent: navigator.userAgent },
      }),
    });
  }

  window.PioneerPathPush = {
    register: () => registerPush().catch((error) => {
      console.debug('[PioneerPath push] registration skipped', error);
    }),
  };
})();
