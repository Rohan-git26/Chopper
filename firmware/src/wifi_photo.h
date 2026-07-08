#ifndef WIFI_PHOTO_H
#define WIFI_PHOTO_H

#include <Arduino.h>

// -----------------------------------------------------------------------------
// WiFi photo transport
//
// Hybrid photo transfer: BLE still carries the lightweight capture *trigger*,
// but when the app enables WiFi mode the JPEG itself is fetched over HTTP
// (GET /photo) instead of being reassembled from BLE notification chunks.
//
// The app talks to this module through *multi-byte* writes on the existing
// photo-control characteristic (single-byte writes remain the legacy BLE
// capture path — see PhotoControlCallback in app.cpp). Status (including the
// device's IP once connected) is reported back over the photo-data
// characteristic, framed with WIFI_PHOTO_STATUS_MARKER so the app can tell it
// apart from ordinary photo chunks.
// -----------------------------------------------------------------------------

// Commands (first byte of a multi-byte photo-control write).
#define WIFI_PHOTO_CMD_SET_WIFI   0x10 // [0x10, ssidLen, ssid..., passLen, pass...] -> connect
#define WIFI_PHOTO_CMD_DISCONNECT 0x11 // [0x11] -> stop server + WiFi off

// Status frames sent over the photo-data characteristic:
//   [WIFI_PHOTO_STATUS_MARKER, status, <ascii ip if connected>]
#define WIFI_PHOTO_STATUS_MARKER   0xF1
#define WIFI_PHOTO_ST_DISCONNECTED 0x00
#define WIFI_PHOTO_ST_CONNECTING   0x01
#define WIFI_PHOTO_ST_CONNECTED    0x02 // followed by ASCII IP address
#define WIFI_PHOTO_ST_FAILED       0x03

// Call once from setup_app().
void wifiPhoto_setup();

// Call every iteration of loop_app(). Drives the (non-blocking) connect state
// machine and services HTTP requests while WiFi is up.
void wifiPhoto_loop();

// Handle a multi-byte photo-control write (WiFi commands). Runs in the BLE
// callback task; only sets flags — all WiFi work happens in wifiPhoto_loop().
void wifiPhoto_handleCommand(const uint8_t *data, size_t len);

// True while WiFi is connecting or connected. Used to suppress light sleep /
// CPU throttling that would otherwise tear down the WiFi link.
bool wifiPhoto_isActive();

#endif // WIFI_PHOTO_H
