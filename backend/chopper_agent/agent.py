# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import asyncio
import functools
import logging
import os

from google.adk.agents import Agent

from .prompts import AGENT_INSTRUCTION
from .google_tools import (
    make_google_calendar_tool,
    make_google_tasks_tool,
    make_delete_calendar_event_tool,
    make_list_calendar_events_tool,
    make_list_google_tasks_tool,
    make_delete_google_task_tool,
    make_get_agenda_tool,
    make_complete_google_task_tool,
)

logger = logging.getLogger(__name__)

logger.debug("AGENT_INSTRUCTION loaded (length: %d)", len(AGENT_INSTRUCTION))

def make_capture_image_tool(control_queue: asyncio.Queue):
    logger.debug("make_capture_image_tool called")
    def capture_image() -> dict:
        """
        Requests the connected wearable device (chopper glasses) to take a photo.

        Use this tool whenever the user asks you to look at something, see
        what they see, or take a picture.
        """
        logger.info("capture_image tool called")
        control_queue.put_nowait({"type": "capture_image"})
        return {
            "status": "success",
            "message": "Requesting a photo from the connected device.",
        }
    return capture_image


class SessionContext:
    def __init__(self):
        self.suppress_current_turn = False
        self.google_access_token = None
        # The single source of truth for "is Chopper currently engaged in a
        # conversation with the user". This is ONLY ever mutated by the
        # model itself, via the start_engagement / stop_engagement tools
        # below (see prompts.py for when it's told to call them).
        #
        # main.py used to ALSO force this to True via a server-side
        # wake-word keyword match on every transcript, and separately
        # tracked a "was_engaged_at_turn_start" snapshot to gate audio
        # output. That was a second, competing source of truth: the
        # keyword match couldn't distinguish being *addressed* from being
        # merely *mentioned*, and the snapshot raced against
        # stop_engagement() firing mid-turn (a Live API function-call round
        # trip can emit its own turn_complete before the model's spoken
        # reply streams in), which is what was swallowing the closing
        # acknowledgment. Both have been removed from main.py — engagement
        # and output suppression are now driven purely by these tool calls.
        self.engaged = False


def require_engaged(session_context: "SessionContext", tool_name: str):
    """
    Decorator factory used to gate action tools so they refuse to actually
    execute unless the session is currently engaged.

    This is a server-side backstop, independent of the model's judgment.
    The system prompt already instructs the model to only call action tools
    while addressed/engaged, but a single inference mistake shouldn't be
    able to create a calendar event or delete a task in the background.

    `stay_silent` and `update_memory` are intentionally never wrapped with
    this — they're the two tools that are allowed to run regardless of
    engagement. `start_engagement` / `stop_engagement` also aren't wrapped,
    since they're what define `engaged` in the first place.
    """
    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            if not session_context.engaged:
                logger.warning(
                    "Blocked '%s' call: session is not engaged (not addressed).",
                    tool_name,
                )
                return {
                    "status": "error",
                    "message": "Not addressed/engaged — action not performed.",
                }
            return fn(*args, **kwargs)
        return wrapper
    return decorator


def make_stay_silent_tool(session_context: SessionContext):
    def stay_silent(reason: str = None) -> dict:
        """
        Call this tool when you are NOT addressed and NOT already engaged, or when you are merely mentioned, to stay silent and not respond.

        Args:
            reason: The reason for staying silent (e.g., "Not addressed", "Third person mention").
        """
        logger.info("stay_silent called. Reason: %s", reason)
        session_context.suppress_current_turn = True
        return {
            "status": "success",
            "message": "Staying silent.",
        }
    return stay_silent


def make_start_engagement_tool(session_context: SessionContext):
    def start_engagement() -> dict:
        """
        Starts the active conversation engagement.
        Call this tool immediately when the user addresses you by name ("Chopper") to start a conversation.
        """
        logger.info("start_engagement tool called: Engaging session.")
        session_context.engaged = True
        return {
            "status": "success",
            "message": "Engagement started. Subsequent follow-up turns do not require the wake word.",
        }
    return start_engagement


def make_stop_engagement_tool(session_context: SessionContext):
    def stop_engagement() -> dict:
        """
        Ends the current active conversation engagement.
        Call this tool immediately when the user speaks a closing phrase (e.g., "thanks", "bye", "bas").
        """
        logger.info("stop_engagement tool called: Disengaging session.")
        session_context.engaged = False
        return {
            "status": "success",
            "message": "Engagement stopped. Wake word required for next command.",
        }
    return stop_engagement


def make_update_memory_tool(user_id: str, memories_dir: str):
    def update_memory(information: str) -> dict:
        """
        Save important facts, preferences, or context about the user or conversation
        to long-term memory. Use this when the user tells you something important
        that should be remembered across sessions.

        Args:
            information: The specific facts or preferences to remember (e.g., "User's name is Rohan", "User is allergic to peanuts").
        """
        memory_path = os.path.join(memories_dir, f"{user_id}_memory.md")
        try:
            with open(memory_path, "a", encoding="utf-8") as f:
                f.write(f"- {information}\n")
            logger.info("Memory updated for %s: %s", user_id, information)
            return {
                "status": "success",
                "message": f"Successfully saved to long-term memory: '{information}'",
            }
        except Exception as e:
            return {
                "status": "error",
                "message": f"Failed to save memory: {e}",
            }
    return update_memory



def load_memory(user_id: str, memories_dir: str) -> str:
    memory_path = os.path.join(memories_dir, f"{user_id}_memory.md")
    if os.path.exists(memory_path):
        try:
            with open(memory_path, "r", encoding="utf-8") as f:
                content = f.read().strip()
                if content:
                    return f"\n\n<long_term_memory>\n{content}\n</long_term_memory>"
        except Exception as e:
            logger.error("Error reading memory file %s: %s", memory_path, e)
    return ""


# root_agent = Agent(
#     name="chopper_agent",
#     # model="gemini-live-2.5-flash-native-audio",
#     # model="gemini-2.5-flash-native-audio-preview-12-2025",
#     model="gemini-3.1-flash-live-preview",
#     description="A helpful AI assistant.",
#     instruction=AGENT_INSTRUCTION,
#     tools=[get_order_status, capture_image]
# )

def build_agent(
    control_queue: asyncio.Queue,
    session_context: SessionContext,
    user_id: str,
    memories_dir: str = "memories",
) -> Agent:
    memory_content = load_memory(user_id, memories_dir)

    # Calculate current IST local time to inject into prompt context
    from datetime import datetime, timezone, timedelta
    ist = timezone(timedelta(hours=5, minutes=30), name="IST")
    now_str = datetime.now(ist).strftime("%Y-%m-%d %H:%M:%S")
    time_context = f"\n\n<current_time_context>\n- Today's date and time in IST: {now_str}\n</current_time_context>\n"

    instruction = AGENT_INSTRUCTION + memory_content + time_context

    def gated(tool_name, fn):
        return require_engaged(session_context, tool_name)(fn)

    # Action tools: gated so they can't actually run unless engaged, on top
    # of the prompt instruction telling the model the same thing. Wrapping
    # the returned callables here (rather than editing each factory in
    # google_tools.py) keeps the gating in one place.
    action_tools = [
        gated("capture_image", make_capture_image_tool(control_queue)),
        gated("add_calendar_event", make_google_calendar_tool(session_context)),
        gated("add_google_task", make_google_tasks_tool(session_context)),
        gated("delete_calendar_event", make_delete_calendar_event_tool(session_context)),
        gated("list_calendar_events", make_list_calendar_events_tool(session_context)),
        gated("list_google_tasks", make_list_google_tasks_tool(session_context)),
        gated("delete_google_task", make_delete_google_task_tool(session_context)),
        gated("get_agenda", make_get_agenda_tool(session_context)),
        gated("complete_google_task", make_complete_google_task_tool(session_context)),
    ]

    return Agent(
        name="chopper_agent",
        model="gemini-3.1-flash-live-preview",
        description="A helpful AI assistant.",
        instruction=instruction,
        tools=[
            *action_tools,
            # Ungated: this IS the "not addressed" tool.
            make_stay_silent_tool(session_context),
            # Ungated: allowed to run any time, even when not addressed.
            make_update_memory_tool(user_id, memories_dir),
            # Ungated: these two tools are what define `engaged` in the
            # first place, so gating them on `engaged` would be circular.
            make_start_engagement_tool(session_context),
            make_stop_engagement_tool(session_context),
        ],
    )