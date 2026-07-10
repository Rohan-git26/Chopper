import asyncio
import base64
import json
import logging
import os
import threading
from datetime import datetime

from dotenv import load_dotenv
from chopper_agent.agent import build_agent
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, status
from google.adk.agents import LiveRequestQueue
from google.adk.agents.run_config import RunConfig
from google.adk.runners import InMemoryRunner
from google.genai import types
from google.genai.types import (
    Blob,
    Content,
    Part,
)
from auth import authenticate_websocket, initialize_firebase

load_dotenv()

# Configure logging for the server and agent events
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

initialize_firebase()

# Directory where images received from clients are saved. Override with the
# IMAGE_SAVE_DIR env var; defaults to ./received_images next to this file.
IMAGE_SAVE_DIR = os.getenv("IMAGE_SAVE_DIR", "received_images")

# Map incoming image mime types to file extensions.
_IMAGE_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
}


# Whether to persist received images, and how many to keep (oldest evicted
# beyond this; 0 = unlimited). Overridable via env.
SAVE_IMAGES = os.getenv("SAVE_IMAGES", "true").lower() != "false"
MAX_SAVED_IMAGES = int(os.getenv("MAX_SAVED_IMAGES", "500"))

# Create the directory ONCE at startup rather than on every frame (the web
# client can send ~4 images/sec).
if SAVE_IMAGES:
    try:
        os.makedirs(IMAGE_SAVE_DIR, exist_ok=True)
    except Exception as e:  # noqa: BLE001
        logging.error("Could not create image dir %s: %s", IMAGE_SAVE_DIR, e)
        SAVE_IMAGES = False


# Serializes cap enforcement across to_thread workers and throttles it so the
# O(n) listdir+sort runs periodically rather than on every saved frame.
_save_lock = threading.Lock()
_save_count = 0
_CAP_ENFORCE_EVERY = 50

# Retains references to in-flight save tasks so they aren't garbage-collected
# mid-run (asyncio only holds a weak ref to a bare create_task).
_pending_saves: set[asyncio.Task] = set()


def _enforce_image_cap() -> None:
    """Delete the oldest files beyond MAX_SAVED_IMAGES. Runs in a worker thread."""
    try:
        files = [
            p
            for p in (os.path.join(IMAGE_SAVE_DIR, n) for n in os.listdir(IMAGE_SAVE_DIR))
            if os.path.isfile(p)
        ]
        if len(files) <= MAX_SAVED_IMAGES:
            return
        files.sort(key=os.path.getmtime)
        for old in files[: len(files) - MAX_SAVED_IMAGES]:
            try:
                os.remove(old)
            except OSError:
                pass
    except Exception as e:  # noqa: BLE001
        logging.error("Image cap enforcement failed: %s", e)


def _write_image_sync(data: bytes, mime_type: str) -> None:
    """Blocking image write + rotation. Runs off the event loop via to_thread."""
    try:
        ext = _IMAGE_EXTENSIONS.get(mime_type.lower(), ".bin")
        # e.g. 20260707_181530_123456.jpg
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        path = os.path.join(IMAGE_SAVE_DIR, f"{timestamp}{ext}")
        with open(path, "wb") as f:
            f.write(data)
        if MAX_SAVED_IMAGES > 0:
            # Enforce periodically under a lock: avoids the O(n) listdir+sort on
            # every frame and serializes concurrent workers (no listdir/remove race).
            global _save_count
            with _save_lock:
                _save_count += 1
                if _save_count % _CAP_ENFORCE_EVERY == 0:
                    _enforce_image_cap()
        logging.info("Saved received image (%d bytes) to %s", len(data), path)
    except Exception as e:  # noqa: BLE001
        logging.error("Failed to save received image: %s", e)


async def save_image(data: bytes, mime_type: str) -> None:
    """Persist a received image without blocking the asyncio event loop."""
    if not SAVE_IMAGES:
        return
    await asyncio.to_thread(_write_image_sync, data, mime_type)


async def start_agent_session(user_id: str, control_queue: asyncio.Queue):
    """Starts an agent session"""

    agent = build_agent(control_queue)

    # Create a Runner
    runner = InMemoryRunner(app_name=os.getenv("APP_NAME"), agent=agent)
    logging.info(f"Created InMemoryRunner for app={os.getenv('APP_NAME')} user={user_id}")

    # Create a Session
    session = await runner.session_service.create_session(
        app_name=os.getenv("APP_NAME"),
        user_id=user_id,
    )

    # Create a LiveRequestQueue for this session
    live_request_queue = LiveRequestQueue()
    logging.debug("LiveRequestQueue created")

    # Setup RunConfig
    run_config = RunConfig(
        streaming_mode="bidi",
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                start_of_speech_sensitivity=types.StartSensitivity.START_SENSITIVITY_HIGH,
                end_of_speech_sensitivity=types.EndSensitivity.END_SENSITIVITY_LOW,
                prefix_padding_ms=20,
                silence_duration_ms=300,
            )
        ),
        response_modalities=["AUDIO"],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(
                    voice_name=os.getenv("AGENT_VOICE", "Puck")
                )
            ),
            # language_code=os.getenv("AGENT_LANGUAGE"),
        ),
        output_audio_transcription={},
        input_audio_transcription={},
    )

    # Start agent session
    live_events = runner.run_live(
        session=session,
        live_request_queue=live_request_queue,
        run_config=run_config,
    )
    logging.info("Agent live session started")
    return live_events, live_request_queue


# async def agent_to_client_messaging(websocket: WebSocket, live_events):
#     """Agent to client communication: Sends structured event data."""
#     async for event in live_events:
#         logging.debug(f"Received agent event: {event}")
#         try:
#             message_to_send = {
#                 "author": event.author or "agent",
#                 "is_partial": event.partial or False,
#                 "turn_complete": event.turn_complete or False,
#                 "interrupted": event.interrupted or False,
#                 "parts": [],
#                 "input_transcription": None,
#                 "output_transcription": None,
#             }

#             # if not event.content:
#             #     if (
#             #         message_to_send["turn_complete"]
#             #         or message_to_send["interrupted"]
#             #     ):
#             #         await websocket.send_text(json.dumps(message_to_send))
#             #     continue

#             # logging.debug(
#             #     "Event has content; parts=%s",
#             #     [getattr(p, 'text', None) for p in getattr(event.content, 'parts', [])],
#             # )

#             # Use the dedicated server-side transcription objects instead of
#             # reading part.text directly. The native-audio preview model
#             # bundles a chain-of-thought "intent statement" into the same
#             # text part as the spoken reply, but output_transcription /
#             # input_transcription are clean TTS / STT of the audio and never
#             # contain thoughts.
#             input_tx = getattr(event, "input_transcription", None)
#             if input_tx and getattr(input_tx, "text", None):
#                 message_to_send["input_transcription"] = {
#                     "text": input_tx.text,
#                     "is_final": getattr(input_tx, "finished", False),
#                 }

#             output_tx = getattr(event, "output_transcription", None)
#             if output_tx and getattr(output_tx, "text", None):
#                 message_to_send["output_transcription"] = {
#                     "text": output_tx.text,
#                     "is_final": getattr(output_tx, "finished", False),
#                 }

#             # Only forward audio (and function calls/responses) from
#             # event.content.parts. Text display uses output_transcription
#             # above, so we deliberately do NOT push part.text into parts.
#             if event.content and event.content.parts:
#                 for part in event.content.parts:
#                     if (
#                         part.inline_data
#                         and part.inline_data.mime_type.startswith("audio/pcm")
#                     ):
#                         audio_data = part.inline_data.data
#                         encoded_audio = base64.b64encode(audio_data).decode(
#                             "ascii"
#                         )
#                         message_to_send["parts"].append(
#                             {"type": "audio/pcm", "data": encoded_audio}
#                         )

#                     elif part.function_call:
#                         message_to_send["parts"].append(
#                             {
#                                 "type": "function_call",
#                                 "data": {
#                                     "name": part.function_call.name,
#                                     "args": part.function_call.args or {},
#                                 },
#                             }
#                         )

#                     elif part.function_response:
#                         message_to_send["parts"].append(
#                             {
#                                 "type": "function_response",
#                                 "data": {
#                                     "name": part.function_response.name,
#                                     "response": part.function_response.response
#                                     or {},
#                                 },
#                             }
#                         )

#             if (
#                 message_to_send["parts"]
#                 or message_to_send["turn_complete"]
#                 or message_to_send["interrupted"]
#                 or message_to_send["input_transcription"]
#                 or message_to_send["output_transcription"]
#             ):
#                 payload = json.dumps(message_to_send)
#                 logging.info(f"Sending payload to client: {payload}")
#                 await websocket.send_text(payload)

#         except Exception as e:
#             logging.error(f"Error in agent_to_client_messaging: {e}")


async def agent_to_client_messaging(websocket: WebSocket, live_events):

    async for event in live_events:
        try:
            message = {
                "author": event.author or "agent",
                "is_partial": bool(event.partial),
                "turn_complete": bool(event.turn_complete),
                "interrupted": bool(event.interrupted),
                "parts": [],
                "input_transcription": None,
                "output_transcription": None,
            }

            # 1.Input Transcription (USER STT)
            input_tx = getattr(event, "input_transcription", None)
            if input_tx and getattr(input_tx, "text", None):
                message["input_transcription"] = {
                    "text": input_tx.text,
                    "is_final": getattr(input_tx, "finished", False),
                }
                logging.info("Input transcription: %s", message["input_transcription"])

            # 2.Output Transcription (MODEL TTS)
            output_tx = getattr(event, "output_transcription", None)
            if output_tx and getattr(output_tx, "text", None):
                message["output_transcription"] = {
                    "text": output_tx.text,
                    "is_final": getattr(output_tx, "finished", False),
                }
                logging.info("Output transcription: %s", message["output_transcription"])

            # 3.Content Parts — only forward audio; text display uses output_transcription
            if event.content and event.content.parts:
                for part in event.content.parts:
                    inline_data = getattr(part, "inline_data", None)
                    if inline_data and getattr(inline_data, "mime_type", "").startswith("audio/pcm"):
                        audio_data = getattr(inline_data, "data", None)
                        if audio_data:
                            encoded = base64.b64encode(audio_data).decode("ascii")
                            message["parts"].append({
                                "type": "audio/pcm",
                                "data": encoded,
                            })
                            # logging.info("Receiving audio data:")

                    # function_call = getattr(part, "function_call", None)
                    # if function_call and function_call.name == "capture_image":
                    #     logging.info("Agent requested capture_image; notifying client")
                        # await websocket.send_text(
                        #     json.dumps({"type": "capture_image"})
                        # )

            # Send only if meaningful
            if (
                message["parts"]
                or message["input_transcription"]
                or message["output_transcription"]
                or message["turn_complete"]
                or message["interrupted"]
            ):
                await websocket.send_text(json.dumps(message))

        except Exception as e:
            logging.error("agent_to_client_messaging error: %s", e)

async def client_to_agent_messaging(
    websocket: WebSocket, live_request_queue: LiveRequestQueue
):
    """Client to agent communication — binary frames for audio, text frames for JSON control."""
    while True:
        try:
            raw = await websocket.receive()

            if raw["type"] == "websocket.disconnect":
                logging.info("Client disconnected.")
                break

            # Binary frame → raw PCM audio (no base64 overhead)
            raw_bytes = raw.get("bytes")
            if raw_bytes:
                live_request_queue.send_realtime(
                    Blob(data=raw_bytes, mime_type="audio/pcm;rate=16000")
                )
                # logging.info("Sending audio data to agent")
                continue

            # Text frame → JSON control / text messages
            raw_text = raw.get("text")
            if raw_text:
                message = json.loads(raw_text)

                mime_type = message.get("mime_type", "")

                if mime_type == "text/plain":
                    data = message.get("data")
                    if not data:
                        logging.warning("text/plain message missing data field")
                        continue
                    content = Content(
                        role="user", parts=[Part.from_text(text=data)]
                    )
                    live_request_queue.send_content(content=content)
                    logging.info("Text sent as content turn")

                elif mime_type == "audio/pcm":
                    data = message.get("data")
                    decoded_data = base64.b64decode(data)
                    live_request_queue.send_realtime(
                        Blob(data=decoded_data, mime_type=mime_type)
                    )
                    # logging.info("Sent realtime audio blob to agent queue (audio/pcm)")

                elif mime_type.startswith("image/"):
                    data = message.get("data")
                    if not data:
                        logging.warning("image message missing data field")
                        continue

                    decoded_data = base64.b64decode(data)

                    # Persist the received image for later inspection, off the
                    # hot path (fire-and-forget; never blocks agent bridging).
                    # Retain the task reference so it isn't GC'd mid-run.
                    _save_task = asyncio.create_task(save_image(decoded_data, mime_type))
                    _pending_saves.add(_save_task)
                    _save_task.add_done_callback(_pending_saves.discard)

                    content = Content(
                        role="user",
                        parts=[
                            Part(
                                inline_data=Blob(
                                    data=decoded_data,
                                    mime_type=mime_type,
                                )
                            )
                        ],
                    )

                    live_request_queue.send_content(content=content)

                    logging.info("Image sent as content turn")

                else:
                    logging.warning("Mime type not supported: %s", mime_type)

        except WebSocketDisconnect:
            logging.info("Client disconnected (WebSocketDisconnect).")
            break

        except Exception as e:
            logging.error("client_to_agent_messaging error: %s", e)

async def control_queue_to_client(websocket: WebSocket, control_queue: asyncio.Queue):
    while True:
        msg = await control_queue.get()
        if (msg.get("type") == "capture_image"):
            logging.info("Agent requested capture_image; notifying client; reading from queue")
            await websocket.send_text(json.dumps(msg))

# async def client_to_agent_messaging(
#     websocket: WebSocket, live_request_queue: LiveRequestQueue
# ):
#     """Client to agent communication"""
#     while True:
#         try:
#             message_json = await websocket.receive_text()
#             message = json.loads(message_json)
#             logging.debug(f"Received message from client with mime_type: {message.get('mime_type')}")
#             mime_type = message.get("mime_type")

#             if mime_type == "text/plain":
#                 data = message["data"]
#                 content = Content(
#                     role="user", parts=[Part.from_text(text=data)]
#                 )
#                 live_request_queue.send_content(content=content)
#                 logging.info(f"Sent text content to agent queue: {data}")

#             elif mime_type == "audio/pcm":
#                 data = message["data"]
#                 decoded_data = base64.b64decode(data)
#                 live_request_queue.send_realtime(
#                     Blob(data=decoded_data, mime_type=mime_type)
#                 )
#                 # logging.info("Sent realtime audio blob to agent queue (audio/pcm)")

#             elif mime_type == "image/jpeg":
#                 data = message["data"]
#                 decoded_data = base64.b64decode(data)
#                 live_request_queue.send_realtime(
#                     Blob(data=decoded_data, mime_type=mime_type)
#                 )
#                 # logging.info("Sent realtime image blob to agent queue (image/jpeg)")

#             else:
#                 logging.warning(f"Mime type not supported: {mime_type}")

#         except WebSocketDisconnect:
#             logging.info("Client disconnected (WebSocketDisconnect).")
#             break

#         except Exception as e:
#             logging.error(
#                 f"An error occurred in client_to_agent_messaging: {e}"
#             )

# async def send_greeting(live_request_queue, greeting_text: str):
#     """Inject a greeting as if the agent decided to speak first."""
#     from google.genai import types

#     content = types.Content(
#         role="user",
#         parts=[types.Part(text=greeting_text)]
#     )

#     live_request_queue.send_content(content=content)


app = FastAPI()


@app.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    """Client websocket endpoint"""

    try:
        logging.info("Client connected, authenticating user_id=%s", user_id)
        auth_user_id = authenticate_websocket(headers=dict(websocket.headers))
    except ValueError as exc:
        logging.debug(f"Authentication failed for user_id={user_id}: {exc}")
        await websocket.accept()
        reason = str(exc)[:100]  # WS close reason must be short (spec limit ~123 bytes)
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason=reason)
        return

    await websocket.accept()

    resolved_user_id = auth_user_id
    control_queue: asyncio.Queue = asyncio.Queue()
    live_events, live_request_queue = await start_agent_session(resolved_user_id, control_queue)

    content = Content(role="user", parts=[Part.from_text(text="Start")])
    live_request_queue.send_content(content=content)

    agent_to_client_task = asyncio.create_task(
        agent_to_client_messaging(websocket, live_events)
    )
    client_to_agent_task = asyncio.create_task(
        client_to_agent_messaging(websocket, live_request_queue)
    )
    control_task = asyncio.create_task(
        control_queue_to_client(websocket, control_queue)
    )

    tasks = [agent_to_client_task, client_to_agent_task, control_task]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    live_request_queue.close()
    print(f"Client #{resolved_user_id} disconnected")
