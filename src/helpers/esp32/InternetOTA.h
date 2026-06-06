#pragma once

#ifdef ESP_PLATFORM

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <HTTPUpdate.h>
#include "WiFiConnect.h"

// Base URL for firmware manifests: <OTA_BASE_URL>/<board_id>/manifest.json
// Server uses HTTPS — certificate validation is skipped (embedded device, known server).
#ifndef OTA_BASE_URL
  #define OTA_BASE_URL "https://meshcore.epila.pl/firmware"
#endif

// Board ID must be defined per variant (e.g. "heltec_v4", "heltec_v3", "xiao_s3_wio")
#ifndef BOARD_ID
  #define BOARD_ID "unknown"
#endif

// OTA download token — must match the token configured in nginx.conf on the server.
// Set via -D OTA_TOKEN='"token"' in platformio.local.ini (gitignored, never committed).
// If empty, requests are sent without a token (server will reject with 401).
#ifndef OTA_TOKEN
  #define OTA_TOKEN ""
#endif

struct OTAManifest {
  char version[32];   // e.g. "v1.15.1"
  char url[256];      // full URL to .bin
};

// Compare semantic versions: "vMAJOR.MINOR.PATCH" or "vMAJOR.MINOR.PATCH.BUILD".
// The optional BUILD field (4th part) lets PoLi builds (e.g. v1.15.0.3) compare
// correctly against upstream 3-part versions (v1.15.0 treated as v1.15.0.0).
// Returns: <0 if a < b, 0 if equal, >0 if a > b
static int ota_semver_cmp(const char* a, const char* b) {
  if (*a == 'v' || *a == 'V') a++;
  if (*b == 'v' || *b == 'V') b++;

  int maj_a = 0, min_a = 0, pat_a = 0, bld_a = 0;
  int maj_b = 0, min_b = 0, pat_b = 0, bld_b = 0;
  sscanf(a, "%d.%d.%d.%d", &maj_a, &min_a, &pat_a, &bld_a);
  sscanf(b, "%d.%d.%d.%d", &maj_b, &min_b, &pat_b, &bld_b);

  if (maj_a != maj_b) return maj_a - maj_b;
  if (min_a != min_b) return min_a - min_b;
  if (pat_a != pat_b) return pat_a - pat_b;
  return bld_a - bld_b;
}

class InternetOTA {
  WiFiConnect* _wifi;

  // Minimal JSON field extractor — avoids pulling in ArduinoJson.
  // Finds the value of the first occurrence of `"key":"value"` or `"key": "value"`.
  bool extractJsonString(const char* json, const char* key, char* out, size_t out_len) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char* p = strstr(json, needle);
    if (!p) return false;
    p += strlen(needle);
    while (*p == ' ' || *p == ':' || *p == '\t') p++;
    if (*p != '"') return false;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i < out_len - 1) {
      out[i++] = *p++;
    }
    out[i] = '\0';
    return i > 0;
  }

public:
  explicit InternetOTA(WiFiConnect& wifi) : _wifi(&wifi) {}

  // Fetch manifest from server and fill `manifest`. Returns true on success.
  bool fetchManifest(OTAManifest& manifest, char reply[], size_t reply_len) {
    if (!_wifi->isConnected()) {
      snprintf(reply, reply_len, "ERR: WiFi not connected");
      return false;
    }

    char url[320];
    if (strlen(OTA_TOKEN) > 0) {
      snprintf(url, sizeof(url), "%s/%s/manifest.json?token=%s", OTA_BASE_URL, BOARD_ID, OTA_TOKEN);
    } else {
      snprintf(url, sizeof(url), "%s/%s/manifest.json", OTA_BASE_URL, BOARD_ID);
    }

    WiFiClientSecure tls;
    tls.setInsecure();  // skip cert validation — known server, firmware hash verified by ESP-IDF

    HTTPClient http;
    http.begin(tls, url);
    http.setTimeout(10000);
    int code = http.GET();

    if (code != 200) {
      snprintf(reply, reply_len, "ERR: HTTP %d from %s", code, url);
      http.end();
      return false;
    }

    String body = http.getString();
    http.end();

    bool ok = extractJsonString(body.c_str(), "version", manifest.version, sizeof(manifest.version))
           && extractJsonString(body.c_str(), "url",     manifest.url,     sizeof(manifest.url));

    if (!ok) {
      snprintf(reply, reply_len, "ERR: invalid manifest JSON");
      return false;
    }
    return true;
  }

  // Check if server has a newer version than `current_version`.
  // Fills `reply` with a status message. Returns true if update is available.
  bool checkForUpdate(const char* current_version, OTAManifest& manifest, char reply[], size_t reply_len) {
    if (!fetchManifest(manifest, reply, reply_len)) return false;

    if (ota_semver_cmp(manifest.version, current_version) > 0) {
      snprintf(reply, reply_len, "Update available: %s -> %s", current_version, manifest.version);
      return true;
    }

    snprintf(reply, reply_len, "Up to date: %s (server: %s)", current_version, manifest.version);
    return false;
  }

  // Download and flash firmware from `url`. Calls `on_progress` (if non-null)
  // periodically with bytes written and total. Returns true on success.
  bool applyUpdate(const OTAManifest& manifest, char reply[], size_t reply_len,
                   void (*on_progress)(int, int) = nullptr) {
    if (!_wifi->isConnected()) {
      snprintf(reply, reply_len, "ERR: WiFi not connected");
      return false;
    }

    WiFiClientSecure tls;
    tls.setInsecure();  // skip cert validation — firmware hash verified by ESP-IDF partition check

    if (on_progress) {
      httpUpdate.onProgress(on_progress);
    }

    httpUpdate.rebootOnUpdate(false);  // we reboot ourselves after logging

    char fw_url[320];
    if (strlen(OTA_TOKEN) > 0) {
      snprintf(fw_url, sizeof(fw_url), "%s?token=%s", manifest.url, OTA_TOKEN);
    } else {
      strncpy(fw_url, manifest.url, sizeof(fw_url) - 1);
      fw_url[sizeof(fw_url) - 1] = '\0';
    }

    t_httpUpdate_return ret = httpUpdate.update(tls, fw_url);

    switch (ret) {
      case HTTP_UPDATE_FAILED:
        snprintf(reply, reply_len, "ERR: update failed (%d) %s",
                 httpUpdate.getLastError(),
                 httpUpdate.getLastErrorString().c_str());
        return false;

      case HTTP_UPDATE_NO_UPDATES:
        snprintf(reply, reply_len, "Server: no update needed");
        return false;

      case HTTP_UPDATE_OK:
        snprintf(reply, reply_len, "OK: flashed %s — rebooting", manifest.version);
        return true;

      default:
        snprintf(reply, reply_len, "ERR: unknown update result");
        return false;
    }
  }

  // Convenience: check + apply in one call. Returns true if reboot is needed.
  bool checkAndUpdate(const char* current_version, char reply[], size_t reply_len,
                      void (*on_progress)(int, int) = nullptr) {
    OTAManifest manifest;
    if (!checkForUpdate(current_version, manifest, reply, reply_len)) {
      return false;  // either up-to-date or error (reply already set)
    }
    return applyUpdate(manifest, reply, reply_len, on_progress);
  }
};

#endif // ESP_PLATFORM
