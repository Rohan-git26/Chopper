#ifndef WIFI_CREDS_H
#define WIFI_CREDS_H

#include <Arduino.h>
#include <string.h>

// Parse the length-prefixed WiFi credential frame that the app sends over BLE:
//
//   [ ...prefix..., ssidLen, ssid[ssidLen], passLen, pass[passLen] ]
//
// `off` is the index of the ssidLen byte (both callers prefix a 1-byte command,
// so off == 1). On success, the NUL-terminated SSID and password are copied into
// the caller's buffers and true is returned. Any bounds violation returns false
// and leaves the buffers untouched.
//
// Shared by ota.cpp (OTA_CMD_SET_WIFI) and wifi_photo.cpp (WIFI_PHOTO_CMD_SET_WIFI)
// so the wire format and bounds checks live in exactly one place.
static inline bool parseWifiCreds(const uint8_t *data, size_t len, size_t off,
                                  char *ssidOut, size_t ssidCap,
                                  char *passOut, size_t passCap)
{
    if (data == nullptr || len < off + 1) {
        return false;
    }
    uint8_t ssidLen = data[off];
    if ((size_t) ssidLen >= ssidCap || len < off + 1 + (size_t) ssidLen + 1) {
        return false;
    }
    uint8_t passLen = data[off + 1 + ssidLen];
    if ((size_t) passLen >= passCap || len < off + 2 + (size_t) ssidLen + (size_t) passLen) {
        return false;
    }
    memcpy(ssidOut, &data[off + 1], ssidLen);
    ssidOut[ssidLen] = '\0';
    memcpy(passOut, &data[off + 2 + ssidLen], passLen);
    passOut[passLen] = '\0';
    return true;
}

#endif // WIFI_CREDS_H
