# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Chopper is a wearable AI assistant system consisting of smart glasses (ESP32-S3), a Python backend using Google's ADK/Gemini Live API, a Next.js web client, and a Flutter mobile app. The backend receives real-timeRunning text, audio, and image data from clients, bridges it to Google's ADK bidi-streaming API, and sends back audio/text responses.

## Architecture

```
┌─────────────┐     BLE (OMI protocol)     ┌──────────────┐
│  Firmware   │◄──────────────────────────►│  Flutter App   │
│  (ESP32-S3) │                            │   (Mobile)     │
└─────────────┘                            └───────┬────────┘
                                                   │
                                            WebSocket
                                                   │
┌──────────────┐     WebSocket (ADK)       ┌──────▼──────┐
│ Next.js      │◄──────────────────────────►│   Backend   │
│ (Web)        │                            │  (FastAPI)  │
└──────────────┘                            └──────┬──────┘
                                                    │
                                            Google ADK/Gemini Live API
```

## Sub-projects

### `firmware/` — ESP32-S3 Wearable Device

The firmware runs on a **Seeed XIAO ESP32S3 Sense** board with an OV2640 camera, PDM microphone, and BLE radio. It implements the OMI BLE protocol (custom UUID `19B10000-E8F2-537E-4F6C-D104768A1214`).

- **Boot**: `firmware.ino` → includes `src/app.h` → `src/app.cpp`
- **Key modules**: `mic.h/cpp` (I2S PDM mic capture), `opus_encoder.cpp` (Opus encode for BLE streaming), `ota.cpp` (OTA updates), `camera_index.h` (camera web UI)
- **Config**: All device constants in `src/config.h` — camera resolution, BLE parameters, Opus settings, power management, OTA UUIDs
- **BLE Service UUID**: `19B10000-E8F2-537E-4F6C-D104768A1214`
  - Audio characteristic: `19B10001-E8F2-537E-4F6C-D104768A1214` (notifications, Opus frames with 3-byte header)
  - Codec characteristic: `19B10002-E8F2-537E-4F6C-D104768A1214` (read, value = 21 for Opus)
  - Photo data: `19B10005-E8F2-537E-4F6C-D104768A1214` (notifications, JPEG reassembly)
  - Photo control: `19B10006-E8F2-537E-4F6C-D104768A1214` (write, trigger capture)
  - Battery service: standard `0x180F` / `0x2A19`

### `backend/` — FastAPI + Google ADK WebSocket Server

The backend is a **FastAPI** application that bridges WebSocket clients to Google's ADK (Agent Development Kit) with the Gemini Live API in bidi streaming mode.

- **`main.py`**: FastAPI app, WebSocket endpoint at `/ws/{user_id}`, agents-to-client and client-to-agent messaging loops. Receives binary frames (raw PCM audio) and JSON text frames (text, images). Returns JSON with `parts` (audio PCM base64), `input_transcription`, `output_transcription`, `turn_complete`, and `interrupted`.
- **`auth.py`**: Firebase Admin SDK auth. Expects an `Authorization: Bearer <token>` header on WebSocket connections. Set `AUTH_BYPASS=true` in dev.
- **`example_agent/agent.py`**: Agent definition using `google.adk.agents.Agent` with the `gemini-3.1-flash-live-preview` model. Builds an agent with a tool for `capture_image` (pushes to the control queue, which `main.py` forwards to clients).
- **`example_agent/prompts.py`**: Agent system prompt.

**WebSocket Protocol (client ↔ backend):**
- **Inbound binary**: raw 16kHz PCM16 audio (sent as WebSocket binary frame)
- **Inbound JSON**: `{"mime_type": "text/plain", "data": "..."}` or `{"mime_type": "image/jpeg", "data": "<base64>"}`
- **Outbound JSON**: `{"author":"agent", "turn_complete":bool, "interrupted":bool, "parts":[{"type":"audio/pcm","data":"<base64>"}], "input_transcription":{"text":"...","is_final":bool}, "output_transcription":{"text":"...","is_final":bool}}`

### `client/` — Next.js 15 Web Client

A Next.js **React 19 / TypeScript** app that connects to the backend WebSocket.

- **`src/app/page.tsx`**: Main UI with video feed, transcript panel, and controls. Uses `useLiveConnection` hook.
- **`src/hooks/useLiveConnection.ts`**: Core WebSocket logic and AudioWorklet management. Sets up `AudioContext` at 16kHz for recording and 24kHz for playback. Captures video frames (camera or screen share) at 250ms intervals and base64-encodes them as JPEG.
- **`src/components/SidePanel.tsx`**: Renders the event log / transcript.
- **`public/audio-recorder-worklet.js`** and **`public/audio-player-worklet.js`**: AudioWorklet processors for mic capture (output 16kHz PCM16) and speaker playback (input 24kHz PCM16).

### `app/` — Flutter Mobile App

A **Flutter** app that connects to the chopper glasses via BLE and to the backend via WebSocket.

- **`main.dart`**: Entry point. Initializes Opus decoder (via `opus_dart`/`opus_flutter`), Firebase, foreground task service.
- **`config.dart`**: Reads `ADK_WS_URL` from `.env` asset. Default: `ws://10.0.2.2:8000/ws/chopper-user` (Android emulator localhost).
- **`services/adk_agent_service.dart`**: WebSocket client wrapping ADK protocol (`AdkAgentService`). Manages connection, sends binary audio chunks, parses incoming events into typed `AdkEvent` subclasses.
- **`services/omi_device_service.dart`**: BLE client (`OmiDeviceService`) for the chopper glasses. Scans, connects, discovers services, subscribes to audio/photo/battery notifications. Reassembles JPEG photos from chunked BLE notifications. Decodes Opus audio frames.
- **`services/audio_io.dart`**: `AudioIo` class wrapping `record` (mic) and `flutter_pcm_sound` (speaker). 16kHz mic capture, 24kHz PCM16 output with a jitter buffer + feed callback.
- **`providers/chat_provider.dart`**: Central `ChangeNotifier` that orchestrates the chat lifecycle: drives `AdkAgentService`, `AudioIo`, and `OmiDeviceService`, folding streamed ADK events into UI messages.
- **Auth**: Firebase Auth with `google_sign_in`. `AuthProvider` / `AuthPage` handle sign-in flow.

## Common Commands

### Backend
```bash
cd backend

# Run the server (requires GOOGLE_API_KEY in .env)
uv run uvicorn main:app --host 0.0.0.0 --port 8000 --reload

# Install dependencies
uv sync

# Run the ADK agent directly
uv run python -m example_agent.agent

# Lint
uv run ruff check .
uv run ruff format .

# Tests (pytest configured in pyproject.toml dev deps)
uv run pytest
```

### Client
```bash
cd client

# Dev server (Turbopack)
npm run dev

# Production build
npm run build

# Lint
npm run lint
```

### App (Flutter)
```bash
cd app

# Run on connected device
flutter run

# Run tests
flutter test

# Analyze
flutter analyze

# Format
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

# Or build release UF2
./scripts/build_uf2.sh -e uf2_release

# Clean build
pio run --target clean

# Arduino-CLI alternative
arduino-cli compile --build-path build --output-dir dist -u -p COM5 -b esp32:esp32:XIAO_ESP32S3
```

## Environment Setup

All secrets are gitignored. Copy the `.env.example` files in each sub-project and fill in real values:

- **`backend/.env`**: `GOOGLE_API_KEY`, `APP_NAME`, `AGENT_VOICE`, `FIREBASE_CREDENTIALS_PATH`, optional `AUTH_BYPASS`
- **`app/.env`**: `ADK_WS_URL` (WebSocket endpoint the mobile app connects to)

## Key Conventions

- **Audio**: Client sends raw 16kHz PCM16 as WebSocket binary frames. Server sends back 24kHz PCM16 base64 inside JSON `parts`. The firmware captures PDM mic at 16kHz and encodes to Opus (code=21) for BLE streaming; the app decodes Opus back to PCM.
- **Images**: The firmware takes photos and streams JPEG chunks over BLE. The web client captures frames from `<video>` every 250ms and sends base64 JPEG via JSON WebSocket text frames.
- **Auth**: The web client passes a Firebase ID token as a `Bearer` token in the WebSocket headers. Set `AUTH_BYPASS=true` for local dev. The mobile app (Flutter) also uses Firebase Auth.
- **Power Management**: The firmware is aggressively power-optimized for 6-8 hour battery life. CPU frequency is throttled, camera power-cycles, and light sleep is used. All configurable in `firmware/src/config.h`.
