"""Fire-and-continue execution for slow tools (web search, Hermes, ...).

The live model (`gemini-3.1-flash-live-preview`) does **not** support async /
non-blocking function calling (that is a Gemini 2.5-only feature), so we cannot
return a deferred `FunctionResponse` with `scheduling=WHEN_IDLE/SILENT`. Function
calls are synchronous: the model blocks until the tool returns.

To avoid dead air on a 2-3s lookup we therefore:
  1. Make the tool return **instantly** with a "working" ack (no slow work in the
     tool body) so the model keeps talking ("ek second, dekhta hoon...").
  2. Run the real work in a background job via `ResultDispatcher`.
  3. Inject the result back as a fresh `send_content` turn when the model is idle
     (a manual WHEN_IDLE — `main.py` flushes on `turn_complete`).
  4. Honor the engagement window at delivery: speak if engaged (or within a grace
     window of an engaged dispatch), otherwise file it SILENTLY by setting
     `session_context.suppress_current_turn` so context updates but nothing is
     voiced (a manual SILENT).

If the project later moves to a model that supports non-blocking tools, only
`ResultDispatcher._deliver` needs to change to emit a native scheduled
`FunctionResponse`; the tools and call sites stay the same.
"""

import asyncio
import logging
import os
import time
from typing import Awaitable, Callable

from google import genai
from google.genai import types as gtypes
from google.genai.types import Content, Part

logger = logging.getLogger(__name__)

# How long a background tool may run before we give up and report an error.
TOOL_TIMEOUT_S = float(os.getenv("ASYNC_TOOL_TIMEOUT_S", "12"))
# If a result becomes ready within this many seconds of a dispatch that happened
# while engaged, speak it even if the session has since disengaged. Beyond this
# (or if the user explicitly closed the conversation) it is filed silently.
GRACE_WINDOW_S = float(os.getenv("ASYNC_RESULT_GRACE_S", "20"))
# Separate (non-live) model used for the background web-search grounding call.
SEARCH_MODEL = os.getenv("SEARCH_MODEL", "gemini-2.5-flash")

_genai_client = None


def _client() -> "genai.Client":
    global _genai_client
    if _genai_client is None:
        _genai_client = genai.Client(api_key=os.getenv("GOOGLE_API_KEY"))
    return _genai_client


# -----------------------------------------------------------------------------
# Background work implementations
# -----------------------------------------------------------------------------
async def _run_web_search(query: str) -> str:
    """Grounded web search via a separate Gemini call with the Google Search tool."""
    resp = await _client().aio.models.generate_content(
        model=SEARCH_MODEL,
        contents=query,
        config=gtypes.GenerateContentConfig(
            tools=[gtypes.Tool(google_search=gtypes.GoogleSearch())],
            system_instruction=(
                "You are a research helper for a voice assistant. Answer the query "
                "using web search, in 1-3 short sentences, plainly, suitable to be "
                "read aloud. No markdown, no citations, no lists."
            ),
        ),
    )
    return (resp.text or "").strip() or "No results found."


async def _run_ask_hermes(query: str) -> str:
    """MOCK Hermes-agent call. Replace with the real transport (in-process ADK
    sub-agent, HTTP, or A2A) later — the dispatcher is transport-agnostic."""
    await asyncio.sleep(2)
    return f"(mock Hermes answer for: {query})"


# -----------------------------------------------------------------------------
# Dispatcher
# -----------------------------------------------------------------------------
class ResultDispatcher:
    """Owns background jobs for one live session and delivers their results back
    into the session, gated by idle-ness and the engagement window."""

    def __init__(self, session_context):
        self.session_context = session_context
        # Captured on the event loop (constructed from an async context in
        # main.py) so we can schedule work even if ADK runs a sync tool body in a
        # worker thread.
        self.loop = asyncio.get_running_loop()
        self.live_request_queue = None  # set by main.py once the queue exists
        self.idle = True                # True when the model is not generating
        self._ready: asyncio.Queue = asyncio.Queue()
        self._futures: set = set()

    # -- dispatch ---------------------------------------------------------------
    def dispatch(
        self,
        coro_factory: Callable[[], Awaitable[str]],
        *,
        label: str,
        query: str,
    ) -> None:
        """Fire a background job. Safe whether the tool body runs on the event
        loop or in a worker thread (ADK may do either)."""
        dispatched_at = time.monotonic()
        engaged_at_dispatch = bool(self.session_context.engaged)
        fut = asyncio.run_coroutine_threadsafe(
            self._run(coro_factory, label, query, dispatched_at, engaged_at_dispatch),
            self.loop,
        )
        self._futures.add(fut)
        fut.add_done_callback(self._futures.discard)

    async def _run(self, coro_factory, label, query, dispatched_at, engaged_at_dispatch):
        try:
            result = await asyncio.wait_for(coro_factory(), timeout=TOOL_TIMEOUT_S)
            payload = {"result": result, "error": None}
        except asyncio.CancelledError:
            raise
        except asyncio.TimeoutError:
            payload = {"result": None, "error": "timed out"}
            logger.warning("%s timed out for query=%r", label, query)
        except Exception as e:  # noqa: BLE001
            payload = {"result": None, "error": str(e)}
            logger.error("%s failed for query=%r: %s", label, query, e)
        await self._ready.put((label, query, payload, dispatched_at, engaged_at_dispatch))
        # Deliver immediately if the model is already idle (emulated WHEN_IDLE);
        # otherwise main.py flushes on the next turn_complete.
        if self.idle:
            await self.flush_ready()

    # -- delivery ---------------------------------------------------------------
    async def flush_ready(self) -> None:
        """Deliver all ready results. Called by main.py when the model goes idle."""
        while not self._ready.empty():
            label, query, payload, dispatched_at, engaged_at_dispatch = self._ready.get_nowait()
            self._deliver(label, query, payload, dispatched_at, engaged_at_dispatch)

    def _should_speak(self, dispatched_at, engaged_at_dispatch) -> bool:
        if self.session_context.engaged:
            return True
        if engaged_at_dispatch and (time.monotonic() - dispatched_at) < GRACE_WINDOW_S:
            return True
        return False

    def _deliver(self, label, query, payload, dispatched_at, engaged_at_dispatch):
        if self.live_request_queue is None:
            return
        speak = self._should_speak(dispatched_at, engaged_at_dispatch)
        if payload["error"]:
            body = f'{label} for "{query}" failed: {payload["error"]}.'
        else:
            body = f'{label} result for "{query}": {payload["result"]}'

        if speak:
            text = (
                f"[system: a background {body} "
                "Answer the user now, briefly and naturally, re-anchoring to their "
                "original question.]"
            )
        else:
            # Manual SILENT: keep the info in context but do not voice it.
            self.session_context.suppress_current_turn = True
            text = (
                f"[system: a background {body} "
                "The user is no longer engaged — do NOT speak this. Absorb it "
                "silently and call stay_silent. You will have it if they ask later.]"
            )
        content = Content(role="user", parts=[Part.from_text(text=text)])
        self.live_request_queue.send_content(content=content)
        logger.info("Delivered %s result (speak=%s) for query=%r", label, speak, query)

    def cancel_all(self) -> None:
        for fut in list(self._futures):
            fut.cancel()


# -----------------------------------------------------------------------------
# Tool factories (registered in agent.py)
# -----------------------------------------------------------------------------
def make_web_search_tool(dispatcher: ResultDispatcher):
    def web_search(query: str) -> dict:
        """
        Search the web for current, real-world information you do not already know
        (news, facts, prices, weather, sports, people, live events).

        This returns IMMEDIATELY — the search runs in the background and the answer
        is delivered to you shortly after. When you call this, tell the user you're
        checking (e.g. "ek second, dekhta hoon") and keep the conversation going.
        Do NOT call this tool again for the same query while a result is pending.

        Args:
            query: A natural-language search query.
        """
        logger.info("web_search dispatched: %r", query)
        dispatcher.dispatch(lambda: _run_web_search(query), label="web search", query=query)
        return {
            "status": "working",
            "message": (
                f"Searching the web for '{query}'. Tell the user you're checking; "
                "the answer will arrive shortly."
            ),
        }

    return web_search


def make_ask_hermes_tool(dispatcher: ResultDispatcher):
    def ask_hermes(query: str) -> dict:
        """
        Delegate a complex request to the Hermes agent (MOCK for now).

        Returns IMMEDIATELY — Hermes runs in the background and the answer is
        delivered shortly after. Tell the user you're on it and keep talking. Do
        NOT re-call for the same query while a result is pending.

        Args:
            query: What to ask Hermes.
        """
        logger.info("ask_hermes dispatched: %r", query)
        dispatcher.dispatch(lambda: _run_ask_hermes(query), label="Hermes", query=query)
        return {
            "status": "working",
            "message": (
                f"Asking Hermes about '{query}'. Tell the user you're on it; "
                "the answer will arrive shortly."
            ),
        }

    return ask_hermes
