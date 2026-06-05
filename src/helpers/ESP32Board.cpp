#ifdef ESP_PLATFORM

#include "ESP32Board.h"

#if defined(ADMIN_PASSWORD) && !defined(DISABLE_WIFI_OTA)   // Repeater or Room Server only
#include <WiFi.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <AsyncElegantOTA.h>

#include <SPIFFS.h>

bool ESP32Board::startOTAUpdate(const char* id, char reply[]) {
  inhibit_sleep = true;   // prevent sleep during OTA
  WiFi.softAP("MeshCore-OTA", NULL);

  sprintf(reply, "Started: http://%s/update", WiFi.softAPIP().toString().c_str());
  MESH_DEBUG_PRINTLN("startOTAUpdate: %s", reply);

  static char id_buf[60];
  sprintf(id_buf, "%s (%s)", id, getManufacturerName());
  static char home_buf[90];
  sprintf(home_buf, "<H2>Hi! I am a MeshCore Repeater. ID: %s</H2>", id);

  AsyncWebServer* server = new AsyncWebServer(80);

  server->on("/", HTTP_GET, [](AsyncWebServerRequest *request) {
    request->send(200, "text/html", home_buf);
  });
  server->on("/log", HTTP_GET, [](AsyncWebServerRequest *request) {
    request->send(SPIFFS, "/packet_log", "text/plain");
  });

  AsyncElegantOTA.setID(id_buf);
  AsyncElegantOTA.begin(server);    // Start ElegantOTA
  server->begin();

  return true;
}

#else
bool ESP32Board::startOTAUpdate(const char* id, char reply[]) {
  return false; // not supported
}
#endif

// ---- Internet OTA (WiFi STA + HTTP pull from meshcore.epila.pl) ----
#if defined(WIFI_INTERNET_OTA)

#include <helpers/esp32/WiFiConnect.h>
#include <helpers/esp32/InternetOTA.h>

static WiFiConnect _ota_wifi;
static bool _ota_wifi_configured = false;

static void _ensure_wifi_configured() {
  if (_ota_wifi_configured) return;
  _ota_wifi_configured = true;
  // Configure via WIFI_SSID_1/WIFI_PWD_1 … WIFI_SSID_5/WIFI_PWD_5 in platformio.local.ini
#if defined(WIFI_SSID_1) && defined(WIFI_PWD_1)
  _ota_wifi.addNetwork(WIFI_SSID_1, WIFI_PWD_1);
#endif
#if defined(WIFI_SSID_2) && defined(WIFI_PWD_2)
  _ota_wifi.addNetwork(WIFI_SSID_2, WIFI_PWD_2);
#endif
#if defined(WIFI_SSID_3) && defined(WIFI_PWD_3)
  _ota_wifi.addNetwork(WIFI_SSID_3, WIFI_PWD_3);
#endif
#if defined(WIFI_SSID_4) && defined(WIFI_PWD_4)
  _ota_wifi.addNetwork(WIFI_SSID_4, WIFI_PWD_4);
#endif
#if defined(WIFI_SSID_5) && defined(WIFI_PWD_5)
  _ota_wifi.addNetwork(WIFI_SSID_5, WIFI_PWD_5);
#endif
}

bool ESP32Board::checkInternetOTA(const char* firmware_version, char reply[]) {
  _ensure_wifi_configured();
  inhibit_sleep = true;

  if (!_ota_wifi.begin()) {
    strcpy(reply, "ERR: WiFi connect failed");
    inhibit_sleep = false;
    return false;
  }

  InternetOTA ota(_ota_wifi);
  OTAManifest manifest;
  bool has_update = ota.checkForUpdate(firmware_version, manifest, reply, 160);

  // Keep WiFi up if update available so caller can apply it immediately
  if (!has_update) {
    _ota_wifi.disconnect();
    inhibit_sleep = false;
  }
  return has_update;
}

bool ESP32Board::startInternetOTA(const char* firmware_version, char reply[]) {
  _ensure_wifi_configured();
  inhibit_sleep = true;

  if (!_ota_wifi.isConnected()) {
    if (!_ota_wifi.begin()) {
      strcpy(reply, "ERR: WiFi connect failed");
      inhibit_sleep = false;
      return false;
    }
  }

  InternetOTA ota(_ota_wifi);
  bool ok = ota.checkAndUpdate(firmware_version, reply, 160);

  _ota_wifi.disconnect();
  inhibit_sleep = false;

  if (ok) {
    delay(500);
    esp_restart();
  }
  return ok;
}

#else

bool ESP32Board::checkInternetOTA(const char* firmware_version, char reply[]) {
  strcpy(reply, "ERR: WIFI_INTERNET_OTA not enabled for this build");
  return false;
}

bool ESP32Board::startInternetOTA(const char* firmware_version, char reply[]) {
  strcpy(reply, "ERR: WIFI_INTERNET_OTA not enabled for this build");
  return false;
}

#endif  // WIFI_INTERNET_OTA

#endif  // ESP_PLATFORM
