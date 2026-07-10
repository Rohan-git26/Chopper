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
import logging
import os

from google.adk.agents import Agent

from .prompts import AGENT_INSTRUCTION

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
    instruction = AGENT_INSTRUCTION + memory_content
    return Agent(
        name="chopper_agent",
        model="gemini-3.1-flash-live-preview",
        description="A helpful AI assistant.",
        instruction=instruction,
        tools=[
            make_capture_image_tool(control_queue),
            make_stay_silent_tool(session_context),
            make_update_memory_tool(user_id, memories_dir),
        ],
    )