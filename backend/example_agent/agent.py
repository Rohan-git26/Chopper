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

from google.adk.agents import Agent
from google.adk.tools import ToolContext

from .prompts import AGENT_INSTRUCTION

print(f"AGENT_INSTRUCTION: {AGENT_INSTRUCTION}")

def make_capture_image_tool(control_queue: asyncio.Queue):
    print("make_capture_image_tool called")
    def capture_image() -> dict:
        """
        Requests the connected wearable device (chopper glasses) to take a photo.

        Use this tool whenever the user asks you to look at something, see
        what they see, or take a picture.
        """
        print("capture_image called")
        control_queue.put_nowait({"type": "capture_image"})
        return {
            "status": "success",
            "message": "Requesting a photo from the connected device.",
        }
    return capture_image


# root_agent = Agent(
#     name="example_agent",
#     # model="gemini-live-2.5-flash-native-audio",
#     # model="gemini-2.5-flash-native-audio-preview-12-2025",
#     model="gemini-3.1-flash-live-preview",
#     description="A helpful AI assistant.",
#     instruction=AGENT_INSTRUCTION,
#     tools=[get_order_status, capture_image]
# )

def build_agent(control_queue: asyncio.Queue) -> Agent:
    return Agent(
        name="example_agent",
        model="gemini-3.1-flash-live-preview",
        description="A helpful AI assistant.",
        instruction=AGENT_INSTRUCTION,
        tools=[make_capture_image_tool(control_queue)],
    )