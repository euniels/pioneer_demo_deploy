self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = { title: 'PioneerPath', body: event.data ? event.data.text() : '' };
  }

  const title = payload.title || 'PioneerPath';
  const options = {
    body: payload.body || payload.message || 'New fleet notification',
    icon: payload.icon || 'icons/Icon-192.png',
    badge: 'icons/Icon-192.png',
    tag: payload.tag || (payload.data && payload.data.notificationId) || 'pioneerpath',
    data: {
      ...(payload.data || {}),
      url: payload.url || (payload.data && payload.data.url) || '/',
    },
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = event.notification.data && event.notification.data.url
    ? event.notification.data.url
    : '/';
  event.waitUntil(clients.openWindow(targetUrl));
});
