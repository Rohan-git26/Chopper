#include "wifi_photo.h"

#include "config.h"
#include "esp_camera.h"

#include <BLECharacteristic.h>
#include <WebServer.h>
#include <WiFi.h>

// Provided by app.cpp — reused so WiFi status can be pushed to the app over the
// existing photo-data notify channel.
extern BLECharacteristic *photoDataCharacteristic;
extern bool connected;

static WebServer server(80);
static bool serverStarted = false;

// Connection lifecycle. handleCommand() (BLE task) only sets the pending flags;
// wifiPhoto_loop() (main task) performs every actual WiFi call so the WiFi API
// is only ever touched from a single task.
static bool pendingConnect = false;
static bool pendingDisconnect = false;
static bool connecting = false;
static bool wifiUp = false;
static unsigned long connectStart = 0;

static char s_ssid[WIFI_MAX_SSID_LEN + 1] = {0};
static char s_pass[WIFI_MAX_PASS_LEN + 1] = {0};

// -----------------------------------------------------------------------------
// Status reporting (over photo-data characteristic)
// -----------------------------------------------------------------------------
static void notifyStatus(uint8_t status, const char *ip = nullptr)
{
    if (photoDataCharacteristic == nullptr || !connected) {
        return;
    }
    uint8_t buf[2 + 46]; // marker + status + up to 45 chars of IP
    buf[0] = WIFI_PHOTO_STATUS_MARKER;
    buf[1] = status;
    size_t n = 2;
    if (ip != nullptr) {
        size_t l = strlen(ip);
        if (l > 45) {
            l = 45;
        }
        memcpy(buf + 2, ip, l);
        n += l;
    }
    photoDataCharacteristic->setValue(buf, n);
    photoDataCharacteristic->notify();
}

// -----------------------------------------------------------------------------
// HTTP handler: GET /photo -> capture a fresh JPEG and stream it back.
// -----------------------------------------------------------------------------
static void handlePhotoRequest()
{
    camera_fb_t *f = esp_camera_fb_get();
    if (!f) {
        server.send(500, "text/plain", "camera capture failed");
        return;
    }
    WiFiClient client = server.client();
    server.setContentLength(f->len);
    server.send(200, "image/jpeg", "");
    client.write(f->buf, f->len);
    size_t len = f->len;
    esp_camera_fb_return(f);
    Serial.printf("WiFiPhoto: served /photo (%u bytes)\n", (unsigned) len);
}

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------
void wifiPhoto_setup()
{
    // Register the route once; the server is only started once WiFi is up.
    server.on("/photo", HTTP_GET, handlePhotoRequest);
}

void wifiPhoto_handleCommand(const uint8_t *data, size_t len)
{
    if (len < 1) {
        return;
    }
    switch (data[0]) {
    case WIFI_PHOTO_CMD_SET_WIFI: {
        // [0x10, ssidLen, ssid..., passLen, pass...]
        if (len < 3) {
            return;
        }
        uint8_t ssidLen = data[1];
        if (ssidLen > WIFI_MAX_SSID_LEN || len < (size_t) (3 + ssidLen)) {
            return;
        }
        memcpy(s_ssid, &data[2], ssidLen);
        s_ssid[ssidLen] = '\0';

        uint8_t passLen = data[2 + ssidLen];
        if (passLen > WIFI_MAX_PASS_LEN || len < (size_t) (3 + ssidLen + passLen)) {
            return;
        }
        memcpy(s_pass, &data[3 + ssidLen], passLen);
        s_pass[passLen] = '\0';

        Serial.printf("WiFiPhoto: credentials set, SSID=%s\n", s_ssid);
        pendingConnect = true; // actioned in loop (main task)
        break;
    }
    case WIFI_PHOTO_CMD_DISCONNECT:
        Serial.println("WiFiPhoto: disconnect requested");
        pendingDisconnect = true;
        break;
    default:
        break;
    }
}

void wifiPhoto_loop()
{
    // Handle a requested teardown.
    if (pendingDisconnect) {
        pendingDisconnect = false;
        pendingConnect = false;
        connecting = false;
        if (serverStarted) {
            server.stop();
            serverStarted = false;
        }
        WiFi.disconnect(true);
        WiFi.mode(WIFI_OFF);
        wifiUp = false;
        notifyStatus(WIFI_PHOTO_ST_DISCONNECTED);
        Serial.println("WiFiPhoto: WiFi off.");
        return;
    }

    // Kick off a requested connection (all WiFi calls happen in this task).
    if (pendingConnect) {
        pendingConnect = false;
        connecting = true;
        connectStart = millis();
        WiFi.mode(WIFI_STA);
        WiFi.begin(s_ssid, s_pass);
        notifyStatus(WIFI_PHOTO_ST_CONNECTING);
        Serial.println("WiFiPhoto: connecting...");
    }

    // Poll the (non-blocking) connection attempt.
    if (connecting) {
        if (WiFi.status() == WL_CONNECTED) {
            connecting = false;
            wifiUp = true;
            if (!serverStarted) {
                server.begin();
                serverStarted = true;
            }
            String ip = WiFi.localIP().toString();
            notifyStatus(WIFI_PHOTO_ST_CONNECTED, ip.c_str());
            Serial.printf("WiFiPhoto: connected, IP=%s\n", ip.c_str());
        } else if (millis() - connectStart > WIFI_CONNECT_TIMEOUT_MS) {
            connecting = false;
            wifiUp = false;
            WiFi.disconnect(true);
            WiFi.mode(WIFI_OFF);
            notifyStatus(WIFI_PHOTO_ST_FAILED);
            Serial.println("WiFiPhoto: connect timeout.");
        }
    }

    // Service HTTP requests while the link is up.
    if (wifiUp) {
        server.handleClient();
    }
}

bool wifiPhoto_isActive()
{
    return wifiUp || connecting;
}
