#ifndef WIFI_NET_H
#define WIFI_NET_H

#include <WiFi.h>

// Shared WiFi radio bring-up / teardown so wifi_photo.cpp and ota.cpp use one
// canonical sequence (the connect polling loops differ — blocking OTA task vs
// non-blocking state machine — and stay in their own files).
static inline void wifiRadioBegin(const char *ssid, const char *pass)
{
    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid, pass);
}

static inline void wifiRadioOff()
{
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
}

#endif // WIFI_NET_H
