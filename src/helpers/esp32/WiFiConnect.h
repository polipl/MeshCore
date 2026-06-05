#pragma once

#ifdef ESP_PLATFORM

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiMulti.h>

#define WIFI_CONNECT_TIMEOUT_MS  15000
#define WIFI_MAX_NETWORKS        5

class WiFiConnect {
  WiFiMulti _multi;
  bool _started = false;
  bool _connected = false;

public:
  // Add a network credential. Call before begin().
  void addNetwork(const char* ssid, const char* password) {
    _multi.addAP(ssid, password);
  }

  // Connect to the best available network. Returns true on success.
  bool begin(uint32_t timeout_ms = WIFI_CONNECT_TIMEOUT_MS) {
    if (_started) return _connected;

    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    _started = true;

    uint32_t deadline = millis() + timeout_ms;
    while (millis() < deadline) {
      if (_multi.run() == WL_CONNECTED) {
        _connected = true;
        return true;
      }
      delay(500);
    }
    _connected = false;
    return false;
  }

  // Re-check connection state (call in loop if you need reconnect).
  bool isConnected() {
    _connected = (WiFi.status() == WL_CONNECTED);
    return _connected;
  }

  // Disconnect and release resources.
  void disconnect() {
    WiFi.disconnect(true);
    _started = false;
    _connected = false;
  }

  IPAddress localIP() { return WiFi.localIP(); }
  String    ssid()    { return WiFi.SSID(); }
  int8_t    rssi()    { return WiFi.RSSI(); }
};

#endif // ESP_PLATFORM
