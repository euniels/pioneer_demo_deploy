<?php

test('maps config reports disabled when no google maps browser key is configured', function () {
    config(['services.google_maps.browser_key' => '']);

    $this->getJson('/api/fleet/maps/config')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.configured', false)
        ->assertJsonPath('data.browserKey', '')
        ->assertJsonPath('data.provider', 'google_maps')
        ->assertJsonPath('data.enabledApis.0', 'maps_javascript_sdk');
});

test('maps config returns configured browser key from services config', function () {
    config(['services.google_maps.browser_key' => 'browser-test-key']);

    $this->getJson('/api/fleet/maps/config')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.configured', true)
        ->assertJsonPath('data.browserKey', 'browser-test-key')
        ->assertJsonPath('data.provider', 'google_maps');
});
