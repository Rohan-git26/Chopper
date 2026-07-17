# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Chopper is a wearable AI assistant system consisting of smart glasses (ESP32-S3), a Python backend using Google's ADK / Gemini Live API, a Next.js web client, and a Flutter mobile app. The backend receives real-time text, audio, and image data from clients, bridges it to Google's ADK bidi-streaming API, and streams back audio/text responses. The agent ("Chopper") is address-gated (responds only when spoken to by name), has long-term memory, and can act on the user's Google Calendar / Tasks.

## Architecture

```
┌─────────────┐     BLE (OMI protocol)     ┌──────────────┐
│  Firmware   │◄──────────────────────────►│  Flutter App   │
│  (ESP32-S3) │   + WiFi/HTTP (photo,      │   (Mobile)     │
│             │      MJPEG live video)     │                │
└─────────────┘                            └───────┬────────┘
                                                   │
                                            WebSocket
                                                   │
┌──────────────┐     WebSocket (ADK)       ┌──────▼──────┐
│ Next.js      │◄──────────────────────────►│   Backend   │
│ (Web)        │                            │  (FastAPI)  │
└──────────────┘                            └──────┬──────┘
                                                    │
                                     Google ADK / Gemini Live API
                                     + Google Calendar / Tasks APIs
```

## Sub-projects

### `firmware/` — ESP32-S3 Wearable Device

The firmware runs on a **Seeed XIAO ESP32S3 Sense** board with an OV2640 camera, PDM microphone, and BLE radio. It implements the OMI BLE protocol (custom service UUID `19B10000-E8F2-537E-4F6C-D104768A1214`). Advertised BLE name is `"Tony Tony Chopper"`; firmware version string is in `config.h` (`FIRMWARE_VERSION_STRING`, currently `2.3.2`).

- **Boot**: `main.cpp` (or `firmware.ino`) → `src/app.h` → `src/app.cpp` (`setup_app()` / `loop_app()`).
- **Key modules**:
  - `app.cpp` — main loop: BLE server, camera, photo capture + BLE chunked upload, audio pipeline, power management.
  - `mic.h/cpp` — I2S PDM mic capture (16 kHz).
  - `opus_encoder.cpp` — Opus encode for BLE audio streaming.
  - `ota.cpp` — OTA updates (also does WiFi-over-BLE credential handoff, the pattern the photo path reuses).
  - `wifi_photo.h/cpp` — **WiFi photo transport** + **MJPEG live-video stream** (see below).
  - `wifi_net.h` — shared `wifiRadioBegin()` / `wifiRadioOff()` used by both `ota.cpp` and `wifi_photo.cpp`.
  - `wifi_creds.h` — shared `parseWifiCreds()` (parses `[len,ssid,len,pass]` frames) used by OTA + WiFi photo.
  - `camera_index.h`, `camera_pins.h`, `mulaw.h` — camera web UI, pin map, µ-law helper.
- **Config**: All device constants in `src/config.h` — camera resolution/quality, BLE parameters + MTU/chunk sizes, Opus settings, power management, OTA UUIDs, and WiFi/stream ports & timeouts.

**BLE Service UUID**: `19B10000-E8F2-537E-4F6C-D104768A1214`
- Audio: `19B10001-...` (notifications, Opus frames with 3-byte header `[idx_lo, idx_hi, 0]`)
- Codec: `19B10002-...` (read, value = 21 for Opus)
- Photo data: `19B10005-...` (notifications; JPEG reassembly **and** multiplexed WiFi status frames)
- Photo control: `19B10006-...` (write; single-byte = legacy capture, multi-byte = WiFi commands)
- Battery service: standard `0x180F` / `0x2A19`

**Photo capture (BLE path)**: `handlePhotoControl()` — single-byte write `0xFF`/`-1` = single shot, `0x00` = stop, `5..300` = interval capture. `take_photo()` → `capture_fresh_frame()` grabs a frame; the upload loop in `loop_app()` sends it over the photo-data characteristic in chunks framed as: first chunk `[0,0, orientation, data...]` (3-byte header), continuations `[idx_lo, idx_hi, data...]` (2-byte header), end marker `[0xFF, 0xFF]`. Chunk size is clamped to the negotiated ATT MTU (`g_negotiated_mtu`, set in `onMtuChanged`) so notifications are never truncated on a low-MTU stack.

**Camera capture robustness (`capture_fresh_frame()`)**: uses `fb_count=2` + `CAMERA_GRAB_LATEST` and a discard-grab (`get→return→get`) to avoid returning a stale (previous) frame. Because `fb_count=2` can hand back a buffer whose `fb->len` overshoots the real image (trailing stale bytes → a valid JPEG followed by garbage, ~2× size, two `FFD9` markers — rejected by Gemini as `1007 invalid argument`), it also: (1) discards + re-grabs **once** if a frame has no EOI (the ~5% truncated-frame glitch, espressif/esp32-camera#162), and (2) **trims `fb->len` to the true EOI** (`jpeg_eoi_len()` finds the first `FFD9` after `FFD8`). Shared by the BLE upload path and the WiFi `/photo` handler.

**WiFi photo transport + live video (`wifi_photo.cpp`)**: an in-app toggle switches photo transfer from BLE to WiFi/HTTP (BLE stays the default). The app sends WiFi credentials as a **multi-byte** write to the photo-control characteristic:
- `0x10` + `[ssidLen, ssid, passLen, pass]` → connect (`WIFI_PHOTO_CMD_SET_WIFI`)
- `0x11` + padding → disconnect (`WIFI_PHOTO_CMD_DISCONNECT`; must be ≥2 bytes so it isn't routed to the legacy single-byte capture handler)

Status is pushed back over the photo-data characteristic, framed `[0xF1, 0xF1, status, <ascii ip>]` (two-byte magic `WIFI_PHOTO_STATUS_MARKER` so it can't alias a photo chunk index). Statuses: `0x00` disconnected, `0x01` connecting, `0x02` connected (+IP), `0x03` failed. Once connected the device serves:
- `GET /photo` on port 80 (Arduino `WebServer`) — captures a fresh JPEG on request.
- `GET /stream` on port 81 (`esp_http_server`, own FreeRTOS task) — MJPEG `multipart/x-mixed-replace` live video.

While `/stream` has a client, the stream is the **sole camera consumer** (`wifiPhoto_isStreaming()` gates BLE interval capture and makes `/photo` return 503); the app snapshots the live frame instead. Streaming drops to `STREAM_FRAME_SIZE` (CIF) for a smoother frame rate and restores `CAMERA_FRAME_SIZE` (VGA) on stop. All WiFi API calls happen in `wifiPhoto_loop()` (main task); the BLE callback only sets pending flags. A link monitor tears down after `WIFI_LINK_LOST_DEBOUNCE_MS` of sustained loss. WiFi activity suppresses light-sleep/CPU-throttle (`wifiPhoto_isActive()`). **Constraint: phone and glasses must be on the same WiFi network.**

### `backend/` — FastAPI + Google ADK WebSocket Server

The backend is a **FastAPI** application that bridges WebSocket clients to Google's ADK (Agent Development Kit) with the Gemini Live API in bidi streaming mode. Uses **uv** for dependency management (non-packaged project — no build-system).

- **`main.py`**: FastAPI app, WebSocket endpoint at `/ws/{user_id}`. Runs two loops per connection — agent→client and client→agent. Receives binary frames (raw 16 kHz PCM audio) and JSON text frames. Holds a per-connection `SessionContext` and an `asyncio.Queue` control channel (agent tool calls like `capture_image` push here; `control_queue_to_client` forwards them to the client). Saves received images (see below). Output suppression is driven by `session_context.suppress_current_turn` (set by the `stay_silent` tool, cleared at turn boundaries).
- **`auth.py`**: Firebase Admin SDK auth. Expects `Authorization: Bearer <token>` on the WebSocket. Set `AUTH_BYPASS=true` in dev.
- **`chopper_agent/agent.py`**: Agent definition (`google.adk.agents.Agent`, model `gemini-3.1-flash-live-preview`). `build_agent(control_queue, session_context, user_id, memories_dir)` wires the tools and injects long-term memory + current IST time into the instruction. Defines `SessionContext` (`engaged`, `suppress_current_turn`, `google_access_token`) and the tool factories:
  - `capture_image` — requests a photo from the glasses (pushes to `control_queue`).
  - `stay_silent(reason)` — sets `suppress_current_turn` so the model's output for this turn is dropped (the "not addressed / merely mentioned" action). Ungated.
  - `start_engagement` / `stop_engagement` — toggle `session_context.engaged` (conversation engagement so follow-ups don't need the wake word). Ungated (they *define* `engaged`).
  - `update_memory(information)` — appends a fact to `memories/{user_id}_memory.md`. Ungated.
  - Google action tools (from `google_tools.py`) — all wrapped with `require_engaged(...)` as a server-side backstop so they can't run unless the session is engaged.
- **`chopper_agent/google_tools.py`**: Google Calendar + Tasks tools built from the user's OAuth access token (`session_context.google_access_token`): add/list/delete calendar events, add/list/complete/delete tasks, get agenda. Times handled in IST.
- **`chopper_agent/prompts.py`**: The system prompt — defines Chopper's persona and the **address-gating** behavior (respond only when addressed by name; call `stay_silent` otherwise; manage engagement/follow-ups; Hinglish-friendly).

**Addressing model (important):** Chopper *hears* all audio but only *responds* when addressed by name ("Chopper" / "chopper bhai", name anywhere in the utterance) or while already engaged. Every turn the model either speaks or calls `stay_silent` — turning "silence" into an explicit action that both suppresses output and keeps conversation history honest. Engagement (`start_engagement`/`stop_engagement`) lets follow-up turns skip the wake word until a closer ("thanks", "bas", "bye").

**Image saving:** received JPEGs are written to `IMAGE_SAVE_DIR` (default `received_images/`) unless `SAVE_IMAGES=false`. Writes are offloaded to a thread; the directory is capped at `MAX_SAVED_IMAGES` (default 500, oldest evicted). Filenames are `YYYYMMDD_HHMMSS_micros.jpg`. **Diagnostic** (verify a captured JPEG isn't corrupt): count `\xff\xd8` (SOI, should be 1) and `\xff\xd9` (EOI, should be 1) in the file — >1 EOI means trailing garbage (see firmware `capture_fresh_frame`).

**WebSocket Protocol (client ↔ backend):**
- **Inbound binary**: raw 16 kHz PCM16 audio (WebSocket binary frame).
- **Inbound JSON**: `{"mime_type": "text/plain", "data": "..."}`, `{"mime_type": "audio/pcm", "data": "<base64>"}`, `{"mime_type": "image/jpeg", "data": "<base64>"}`, or `{"mime_type": "application/x-google-auth", "data": "<oauth access token>"}` (stored on the session for Google tools).
- **Outbound JSON**: `{"author":"agent", "turn_complete":bool, "interrupted":bool, "parts":[{"type":"audio/pcm","data":"<base64>"}], "input_transcription":{"text":"...","is_final":bool}, "output_transcription":{"text":"...","is_final":bool}}`. Control messages (e.g. capture-image requests) are also forwarded over this socket.

### `client/` — Next.js 15 Web Client

A Next.js **React 19 / TypeScript** app that connects to the backend WebSocket.

- **`src/app/page.tsx`**: Main UI with video feed, transcript panel, and controls. Uses `useLiveConnection`.
- **`src/hooks/useLiveConnection.ts`**: WebSocket logic + AudioWorklet management. `AudioContext` at 16 kHz (record) and 24 kHz (playback). Captures video frames (camera or screen share) every 250 ms as base64 JPEG.
- **`src/components/SidePanel.tsx`**: Event log / transcript.
- **`public/audio-recorder-worklet.js`** / **`public/audio-player-worklet.js`**: mic capture (16 kHz PCM16 out) and speaker playback (24 kHz PCM16 in).

### `app/` — Flutter Mobile App

A **Flutter** app that connects to the glasses via BLE (+ optional WiFi) and to the backend via WebSocket.

- **`main.dart`**: Entry point. Initializes Opus decoder (`opus_dart` / `opus_flutter`), Firebase, foreground task service.
- **`config.dart`**: Reads `ADK_WS_URL` from `.env` asset (default `ws://10.0.2.2:8000/ws/chopper-user`); supports a persisted `customWsUrl` override.
- **Pages** (`pages/`): `home_page.dart` (main/minimal), `device_page.dart` (scan/connect, WiFi transport toggle + SSID/password + status/IP, Live Video button), `video_page.dart` (MJPEG viewer + Start/Stop), `log_page.dart` (in-app log), `auth_page.dart`, `chat_page.dart`.
- **Services** (`services/`):
  - `adk_agent_service.dart` — WebSocket client wrapping the ADK protocol; sends binary audio, parses events into typed `AdkEvent` subclasses; `sendBlob()` for images.
  - `omi_device_service.dart` — BLE client (`OmiDeviceService`): scan/connect, MTU 517, subscribe to audio/photo/battery notifications, JPEG reassembly, Opus frames, WiFi commands (`connectWifi`/`disconnectWifi`/`capturePhotoOverWifi`), 0xF1F1 status parsing, and app-level auto-reconnect.
  - `mjpeg_stream.dart` — custom MJPEG client (scans `FFD8`/`FFD9`, per-frame callback).
  - `http_util.dart` — shared `httpGetOk()` (photo fetch + MJPEG).
  - `audio_io.dart` — `AudioIo` wrapping `record` (16 kHz mic) + `flutter_pcm_sound` (24 kHz out, jitter buffer).
  - `opus_audio_decoder.dart`, `app_log.dart`, `auth_service.dart`, `foreground_task_handler.dart`.
- **`providers/chat_provider.dart`**: Central `ChangeNotifier` orchestrating the chat lifecycle — drives `AdkAgentService`, `AudioIo`, `OmiDeviceService`; owns the `MjpegStream`; `PhotoTransport` enum (ble/wifi) + `enableWifi`/`disableWifi`/`setPhotoTransport`; persists settings via `shared_preferences`; folds ADK events into UI messages.
- **`providers/auth_provider.dart`** + **Auth**: Firebase Auth with `google_sign_in`.

## Common Commands

### Backend
```bash
cd backend

# Run the server (requires GOOGLE_API_KEY in .env)
uv run uvicorn main:app --host 0.0.0.0 --port 8000 --reload

# Install dependencies
uv sync

# Run the ADK agent directly
uv run python -m chopper_agent.agent

# Lint / format
uv run ruff check .
uv run ruff format .

# Tests
uv run pytest
```

### Client
```bash
cd client
npm run dev      # dev server (Turbopack)
npm run build    # production build
npm run lint
```

### App (Flutter)
```bash
cd app
flutter run
flutter test
flutter analyze
flutter format lib/
```

### Firmware
```bash
cd firmware

# Build and upload via PlatformIO
pio run -e seeed_xiao_esp32s3 --target upload

# Monitor serial
pio device monitor --baud 115200

# Build UF2 (for drag-and-drop flashing)
./scripts/build_uf2.sh
./scripts/build_uf2.sh -e uf2_release   # release UF2

# Clean build
pio run --target clean

# Arduino-CLI alternative
arduino-cli compile --build-path build --output-dir dist -u -p COM5 -b esp32:esp32:XIAO_ESP32S3
```

> Note: firmware builds may trip endpoint-security policies on some corporate machines; build/flash in a sanctioned environment. Do not run `pio` builds from an agent without confirmation.

## Environment Setup

All secrets are gitignored. Copy the `.env.example` files in each sub-project and fill in real values:

- **`backend/.env`**: `GOOGLE_API_KEY`, `APP_NAME`, `AGENT_VOICE`, `FIREBASE_CREDENTIALS_PATH`, optional `AUTH_BYPASS`. Optional: `IMAGE_SAVE_DIR`, `SAVE_IMAGES`, `MAX_SAVED_IMAGES`, `MEMORIES_DIR`.
- **`app/.env`**: `ADK_WS_URL` (WebSocket endpoint the mobile app connects to).
- **Runtime dirs** (backend): `received_images/` (saved captures) and `memories/` (`{user_id}_memory.md` long-term memory) are created on startup.

## Key Conventions

- **Audio**: Client sends raw 16 kHz PCM16 as WebSocket binary frames. Server returns 24 kHz PCM16 base64 inside JSON `parts`. Firmware captures PDM mic at 16 kHz and encodes to Opus (codec=21) for BLE; the app decodes Opus back to PCM.
- **Images**: Firmware captures VGA JPEG (quality 25). Default transport is **BLE** (chunked notifications, reassembled by the app); an optional **WiFi/HTTP** transport (`GET /photo`) is faster when the link stays warm. The web client captures `<video>` frames every 250 ms as base64 JPEG. Always validate captured JPEGs (SOI/EOI) — the ESP32 camera can emit trailing/truncated frames (handled in `capture_fresh_frame`).
- **Live video**: WiFi-only, MJPEG `GET /stream` on port 81; the app renders it and can snapshot the current frame for the agent while streaming.
- **Addressing / engagement**: the agent responds only when addressed by name or while engaged; it calls `stay_silent` otherwise. Action tools (Google Calendar/Tasks, capture) are gated on `engaged` both in the prompt and server-side (`require_engaged`).
- **Memory**: durable user facts live in `memories/{user_id}_memory.md`, written by the `update_memory` tool and injected into the agent instruction at connect time.
- **Google integration**: the app passes a Google OAuth access token to the backend (`application/x-google-auth`); the agent's Calendar/Tasks tools use it per-session.
- **Auth**: web client passes a Firebase ID token as a `Bearer` token in the WebSocket headers; `AUTH_BYPASS=true` for local dev. The Flutter app also uses Firebase Auth.
- **Power Management**: firmware is aggressively power-optimized for 6–8 h battery life (CPU throttling, camera power-cycling, light sleep). WiFi/streaming activity temporarily suspends these. All configurable in `firmware/src/config.h`.
