#include "wifi_photo.h"

#include "config.h"
#include "esp_camera.h"
#include "esp_http_server.h"
#include "wifi_creds.h"
#include "wifi_net.h"

#include <BLECharacteristic.h>
#include <WebServer.h>
#include <WiFi.h>

// Provided by app.cpp — reused so WiFi status can be pushed to the app over the
// existing photo-data notify channel, and the shared fresh-frame grabber.
extern BLECharacteristic *photoDataCharacteristic;
extern bool connected;
extern camera_fb_t *capture_fresh_frame();
extern void camera_lock();
extern void camera_unlock();

// Still-capture server (GET /photo on port 80), serviced from loop() via
// handleClient(). Kept on the Arduino WebServer since it already works.
static WebServer server(WIFI_PHOTO_HTTP_PORT);
static bool serverStarted = false;

// True while a client is connected to /stream. Written by the stream task, read
// by the loop task — so the camera is only ever accessed by one consumer.
static volatile bool s_streamClient = false;
// Set by the loop task to ask the stream handler to exit its send loop, so
// stopStreamServer()'s httpd_stop() doesn't block on an in-flight handler.
static volatile bool s_streamStop = false;

// MJPEG live-video server (GET /stream on :81). Runs in its OWN FreeRTOS task
// (esp_http_server), so the endless stream loop never blocks loop_app().
static httpd_handle_t stream_httpd = nullptr;

#define STREAM_PART_BOUNDARY "chopperframe"
static const char *STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=" STREAM_PART_BOUNDARY;
static const char *STREAM_BOUNDARY = "\r\n--" STREAM_PART_BOUNDARY "\r\n";
static const char *STREAM_PART_HEADER = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

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
    // Framing: [0xF1, 0xF1, status, <ascii ip...>]. A TWO-byte magic is used so
    // the frame cannot be mistaken for a photo chunk: a photo continuation frame
    // starts with its 16-bit index, and index 0xF1F1 (~61937) would require a
    // >30 MB image — impossible. (A single 0xF1 collided with chunk #241.)
    uint8_t buf[3 + 16]; // 2-byte magic + status + up to 15 chars of IPv4
    buf[0] = WIFI_PHOTO_STATUS_MARKER;
    buf[1] = WIFI_PHOTO_STATUS_MARKER;
    buf[2] = status;
    size_t n = 3;
    if (ip != nullptr) {
        size_t l = strlen(ip);
        if (l > 15) {
            l = 15;
        }
        memcpy(buf + 3, ip, l);
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
    // The stream owns the camera while a client is connected — refuse stills so
    // the sensor is never grabbed from two tasks at once. The app snapshots the
    // live stream frame in this case instead of calling /photo.
    if (s_streamClient) {
        server.send(503, "text/plain", "camera busy (streaming)");
        return;
    }
    camera_fb_t *f = capture_fresh_frame();
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
// MJPEG stream handler (GET /stream) — runs in the esp_http_server task.
// Streams JPEG frames as multipart/x-mixed-replace until the client
// disconnects (which is how the app's Start/Stop works).
// -----------------------------------------------------------------------------
static esp_err_t stream_handler(httpd_req_t *req)
{
    esp_err_t res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
    if (res != ESP_OK) {
        return res;
    }
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Connection", "close");

    Serial.println("WiFiPhoto: stream client connected");
    s_streamStop = false;
    s_streamClient = true; // camera now owned by the stream — /photo & BLE capture refused

    // Switch to the lower streaming resolution for a smoother frame rate; the
    // full still-photo resolution is restored when the stream ends.
    sensor_t *sensor = esp_camera_sensor_get();
    if (sensor != nullptr) {
        sensor->set_framesize(sensor, (framesize_t) STREAM_FRAME_SIZE);
    }

    char part_header[64];

    while (true) {
        // Allow the loop task to stop us (WiFi teardown) without httpd_stop
        // having to interrupt an in-flight send.
        if (s_streamStop) {
            break;
        }

        // Serialize camera access with the loop-task capture path.
        camera_lock();
        camera_fb_t *fb = esp_camera_fb_get();
        camera_unlock();
        if (!fb) {
            res = ESP_FAIL;
            break;
        }

        // Boundary, then per-part header, then the JPEG bytes.
        if (res == ESP_OK) {
            res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
        }
        if (res == ESP_OK) {
            size_t hlen = snprintf(part_header, sizeof(part_header), STREAM_PART_HEADER, (unsigned) fb->len);
            res = httpd_resp_send_chunk(req, part_header, hlen);
        }
        if (res == ESP_OK) {
            res = httpd_resp_send_chunk(req, (const char *) fb->buf, fb->len);
        }

        camera_lock();
        esp_camera_fb_return(fb);
        camera_unlock();

        if (res != ESP_OK) {
            // Client closed the connection (Stop) — end the stream.
            break;
        }
    }

    // Restore full still-photo resolution for subsequent /photo captures.
    if (sensor != nullptr) {
        sensor->set_framesize(sensor, (framesize_t) CAMERA_FRAME_SIZE);
    }

    s_streamClient = false; // camera released — still captures allowed again
    Serial.println("WiFiPhoto: stream client disconnected");
    return res;
}

static void startStreamServer()
{
    if (stream_httpd != nullptr) {
        return;
    }
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = WIFI_STREAM_HTTP_PORT;
    config.ctrl_port = 32769; // distinct from any other httpd instance
    config.lru_purge_enable = true;

    httpd_uri_t stream_uri = {
        .uri = "/stream",
        .method = HTTP_GET,
        .handler = stream_handler,
        .user_ctx = nullptr,
    };

    if (httpd_start(&stream_httpd, &config) == ESP_OK) {
        httpd_register_uri_handler(stream_httpd, &stream_uri);
        Serial.println("WiFiPhoto: MJPEG stream server started on :81/stream");
    } else {
        Serial.println("WiFiPhoto: failed to start stream server");
        stream_httpd = nullptr;
    }
}

static void stopStreamServer()
{
    if (stream_httpd == nullptr) {
        return;
    }
    // Ask an in-flight stream handler to exit its send loop first, then wait
    // briefly, so httpd_stop() doesn't block on a handler stuck streaming.
    s_streamStop = true;
    unsigned long t = millis();
    while (s_streamClient && millis() - t < 1000) {
        delay(10);
    }
    httpd_stop(stream_httpd);
    stream_httpd = nullptr;
    s_streamClient = false; // ensure cleared even if the handler didn't run its own exit
    s_streamStop = false;
    // Guarantee the sensor is back at still-photo resolution even if the stream
    // handler was torn down before its own restore ran — otherwise stills stay CIF.
    sensor_t *sensor = esp_camera_sensor_get();
    if (sensor != nullptr) {
        sensor->set_framesize(sensor, (framesize_t) CAMERA_FRAME_SIZE);
    }
    Serial.println("WiFiPhoto: stream server stopped");
}

// Full WiFi teardown: stop both servers, drop the link, report `status` to the
// app. Shared by the disconnect command, connect timeout, and lost-link paths.
static void teardownWifi(uint8_t status)
{
    stopStreamServer();
    if (serverStarted) {
        server.stop();
        serverStarted = false;
    }
    wifiRadioOff();
    wifiUp = false;
    connecting = false;
    notifyStatus(status);
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
        if (!parseWifiCreds(data, len, 1, s_ssid, sizeof(s_ssid), s_pass, sizeof(s_pass))) {
            Serial.println("WiFiPhoto: invalid credentials frame");
            return;
        }
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
        teardownWifi(WIFI_PHOTO_ST_DISCONNECTED);
        Serial.println("WiFiPhoto: WiFi off.");
        return;
    }

    // Kick off a requested connection (all WiFi calls happen in this task).
    if (pendingConnect) {
        pendingConnect = false;
        connecting = true;
        connectStart = millis();
        wifiRadioBegin(s_ssid, s_pass);
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
            startStreamServer();
            String ip = WiFi.localIP().toString();
            notifyStatus(WIFI_PHOTO_ST_CONNECTED, ip.c_str());
            Serial.printf("WiFiPhoto: connected, IP=%s\n", ip.c_str());
        } else if (millis() - connectStart > WIFI_CONNECT_TIMEOUT_MS) {
            teardownWifi(WIFI_PHOTO_ST_FAILED);
            Serial.println("WiFiPhoto: connect timeout.");
        }
    }

    // Monitor the established link. Without this, a dropped AP after a
    // successful connect would leave wifiUp=true forever — permanently
    // suppressing light sleep/CPU throttle and leaving the app hitting a dead
    // IP. Require a sustained (>3s) loss to avoid tripping on brief glitches.
    if (wifiUp) {
        static unsigned long linkLostSince = 0;
        if (WiFi.status() != WL_CONNECTED) {
            if (linkLostSince == 0) {
                linkLostSince = millis();
            } else if (millis() - linkLostSince > WIFI_LINK_LOST_DEBOUNCE_MS) {
                linkLostSince = 0;
                teardownWifi(WIFI_PHOTO_ST_FAILED);
                Serial.println("WiFiPhoto: link lost.");
                return;
            }
        } else {
            linkLostSince = 0;
            server.handleClient();
        }
    }
}

bool wifiPhoto_isActive()
{
    return wifiUp || connecting;
}

bool wifiPhoto_isStreaming()
{
    return s_streamClient;
}
