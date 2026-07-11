import logging
from datetime import datetime, timezone, timedelta
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

logger = logging.getLogger(__name__)

# Indian Standard Time (IST) configuration
ist = timezone(timedelta(hours=5, minutes=30), name="IST")

def convert_to_ist(iso_str: str) -> str:
    if not iso_str:
        return ""
    try:
        if iso_str.endswith('Z'):
            iso_str = iso_str[:-1] + '+00:00'
        dt = datetime.fromisoformat(iso_str)
        if dt.tzinfo is not None:
            return dt.astimezone(ist).isoformat()
        else:
            return dt.replace(tzinfo=timezone.utc).astimezone(ist).isoformat()
    except Exception as e:
        logger.error("Failed to convert ISO string %s to IST: %s", iso_str, e)
        return iso_str


def make_google_calendar_tool(session_context):
    def add_calendar_event(summary: str, start_time: str, end_time: str, description: str = None) -> dict:
        """
        Creates an event in the user's Google Calendar.

        Args:
            summary: Title of the event (e.g. "Dentist appointment").
            start_time: ISO-8601 formatted start time string in UTC or local offset (e.g. "2026-07-12T15:00:00Z").
            end_time: ISO-8601 formatted end time string in UTC or local offset (e.g. "2026-07-12T16:00:00Z").
            description: Optional details about the event.
        """
        logger.info("Google Calendar: Adding event '%s' from %s to %s", summary, start_time, end_time)
        token = session_context.google_access_token
        if not token:
            logger.warning("Google Calendar tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        try:
            creds = Credentials(token=token)
            service = build("calendar", "v3", credentials=creds)
            
            event = {
                'summary': summary,
                'description': description,
                'start': {'dateTime': start_time},
                'end': {'dateTime': end_time},
            }
            
            created_event = service.events().insert(calendarId='primary', body=event).execute()
            logger.info("Google Calendar event created successfully: %s", created_event.get("id"))
            return {
                "status": "success",
                "event_id": created_event.get("id"),
                "link": created_event.get("htmlLink"),
            }
        except Exception as e:
            logger.error("Failed to create Google Calendar event: %s", e)
            return {"status": "error", "message": str(e)}

    return add_calendar_event


def make_delete_calendar_event_tool(session_context):
    def delete_calendar_event(event_id: str) -> dict:
        """
        Deletes a specific event in the user's Google Calendar by its ID.

        Args:
            event_id: The unique ID of the event to delete.
        """
        logger.info("Google Calendar: Deleting event ID '%s'", event_id)
        token = session_context.google_access_token
        if not token:
            logger.warning("Delete Calendar Event tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        try:
            creds = Credentials(token=token)
            service = build("calendar", "v3", credentials=creds)
            
            service.events().delete(calendarId='primary', eventId=event_id).execute()
            logger.info("Google Calendar event deleted successfully: %s", event_id)
            return {
                "status": "success",
                "message": f"Successfully deleted calendar event '{event_id}'",
            }
        except Exception as e:
            logger.error("Failed to delete Google Calendar event: %s", e)
            return {"status": "error", "message": str(e)}

    return delete_calendar_event


def make_list_calendar_events_tool(session_context):
    def list_calendar_events(date: str = None, max_results: int = 10) -> dict:
        """
        Fetches upcoming events in the user's Google Calendar.

        Args:
            date: Optional date string in YYYY-MM-DD format (e.g. "2026-07-12") to filter events for a specific day. If omitted, lists upcoming events from the start of today onwards.
            max_results: Maximum number of events to return. Defaults to 10.
        """
        logger.info("Google Calendar: Listing events (date=%s, max=%d)", date, max_results)
        token = session_context.google_access_token
        if not token:
            logger.warning("List Calendar Events tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        try:
            creds = Credentials(token=token)
            service = build("calendar", "v3", credentials=creds)
            
            list_params = {
                'calendarId': 'primary',
                'maxResults': max_results,
                'singleEvents': True,
                'orderBy': 'startTime'
            }

            if date:
                # Filter strictly within the target date
                list_params['timeMin'] = f"{date}T00:00:00+05:30"
                list_params['timeMax'] = f"{date}T23:59:59+05:30"
            else:
                # Start of today (midnight IST) onwards
                now_dt = datetime.now(ist)
                list_params['timeMin'] = datetime(now_dt.year, now_dt.month, now_dt.day, tzinfo=ist).isoformat()

            events_result = service.events().list(**list_params).execute()
            
            events = events_result.get('items', [])
            logger.info("Fetched %d Google Calendar events", len(events))
            
            simplified_events = []
            for item in events:
                start_dt = item.get("start", {}).get("dateTime")
                end_dt = item.get("end", {}).get("dateTime")
                
                # Convert dateTimes to IST; leave date strings (all-day events) as is
                start_str = convert_to_ist(start_dt) if start_dt else item.get("start", {}).get("date")
                end_str = convert_to_ist(end_dt) if end_dt else item.get("end", {}).get("date")

                simplified_events.append({
                    "id": item.get("id"),
                    "summary": item.get("summary"),
                    "start": start_str,
                    "end": end_str,
                    "description": item.get("description"),
                })
            
            return {
                "status": "success",
                "events": simplified_events,
            }
        except Exception as e:
            logger.error("Failed to list Google Calendar events: %s", e)
            return {"status": "error", "message": str(e)}

    return list_calendar_events


def make_google_tasks_tool(session_context):
    def add_google_task(title: str, notes: str = None, due: str = None, status: str = "needsAction") -> dict:
        """
        Creates a new task in the user's Google Tasks default list.

        Args:
            title: The title/name of the task (e.g. "Buy milk").
            notes: Optional description/notes for the task.
            due: Optional RFC 3339 formatted due date-time string (e.g. "2026-07-12T18:00:00Z").
            status: Optional status string: either "needsAction" (pending) or "completed". Defaults to "needsAction".
        """
        logger.info("Google Tasks: Adding task '%s' (due=%s, status=%s)", title, due, status)
        token = session_context.google_access_token
        if not token:
            logger.warning("Google Tasks tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        try:
            creds = Credentials(token=token)
            service = build("tasks", "v1", credentials=creds)
            
            task = {
                'title': title,
                'notes': notes,
                'due': due,
                'status': status
            }
            
            created_task = service.tasks().insert(tasklist='@default', body=task).execute()
            logger.info("Google Task created successfully: %s", created_task.get("id"))
            return {"status": "success", "task_id": created_task.get("id")}
        except Exception as e:
            logger.error("Failed to create Google Task: %s", e)
            return {"status": "error", "message": str(e)}

    return add_google_task


def make_list_google_tasks_tool(session_context):
    def list_google_tasks(date: str = None, max_results: int = 20) -> dict:
        """
        Fetches tasks in the user's default Google Tasks list.

        Args:
            date: Optional date string in YYYY-MM-DD format (e.g. "2026-07-12") to filter tasks due on that specific day.
            max_results: Maximum number of tasks to return. Defaults to 20.
        """
        logger.info("Google Tasks: Listing tasks (date=%s, max=%d)", date, max_results)
        token = session_context.google_access_token
        if not token:
            logger.warning("List Google Tasks tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        try:
            creds = Credentials(token=token)
            service = build("tasks", "v1", credentials=creds)
            
            tasks_result = service.tasks().list(
                tasklist='@default',
                maxResults=max_results,
                showCompleted=False
            ).execute()
            
            tasks = tasks_result.get('items', [])
            logger.info("Fetched %d Google Tasks", len(tasks))
            
            simplified_tasks = []
            for item in tasks:
                due_val = item.get("due")
                ist_due = convert_to_ist(due_val) if due_val else None
                # If date is specified, filter tasks due on that exact day
                if date and ist_due and ist_due[:10] != date:
                    continue
                simplified_tasks.append({
                    "id": item.get("id"),
                    "title": item.get("title"),
                    "notes": item.get("notes"),
                    "due": ist_due,
                    "status": item.get("status"),
                })
            
            return {
                "status": "success",
                "tasks": simplified_tasks,
            }
        except Exception as e:
            logger.error("Failed to list Google Tasks: %s", e)
            return {"status": "error", "message": str(e)}

    return list_google_tasks


def make_delete_google_task_tool(session_context):
    def delete_google_task(task_id: str) -> dict:
        """
        Deletes a specific task in the user's default Google Tasks list by its ID.

        Args:
            task_id: The unique ID of the task to delete.
        """
        logger.info("Google Tasks: Deleting task ID '%s'", task_id)
        token = session_context.google_access_token
        if not token:
            logger.warning("Delete Google Task tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        try:
            creds = Credentials(token=token)
            service = build("tasks", "v1", credentials=creds)
            
            service.tasks().delete(tasklist='@default', task=task_id).execute()
            logger.info("Google Task deleted successfully: %s", task_id)
            return {
                "status": "success",
                "message": f"Successfully deleted task '{task_id}'",
            }
        except Exception as e:
            logger.error("Failed to delete Google Task: %s", e)
            return {"status": "error", "message": str(e)}

    return delete_google_task


def make_get_agenda_tool(session_context):
    def get_agenda(date: str = None, max_events: int = 10, max_tasks: int = 20) -> dict:
        """
        Fetches both upcoming calendar events and tasks in one go to present a unified agenda.

        Args:
            date: Optional date string in YYYY-MM-DD format (e.g. "2026-07-12") to view agenda for a specific day. If omitted, defaults to today.
            max_events: Maximum calendar events to return. Defaults to 10.
            max_tasks: Maximum tasks to return. Defaults to 20.
        """
        logger.info("Google: Fetching unified agenda (date=%s, max_events=%d, max_tasks=%d)", date, max_events, max_tasks)
        token = session_context.google_access_token
        if not token:
            logger.warning("Get Agenda tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        # Resolve target date (default to today IST)
        if not date:
            now_dt = datetime.now(ist)
            date = now_dt.strftime("%Y-%m-%d")

        start_time = f"{date}T00:00:00+05:30"
        end_time = f"{date}T23:59:59+05:30"

        agenda = {"events": [], "tasks": []}
        try:
            creds = Credentials(token=token)
            
            # Fetch Calendar Events
            try:
                cal_service = build("calendar", "v3", credentials=creds)
                events_result = cal_service.events().list(
                    calendarId='primary',
                    maxResults=max_events,
                    singleEvents=True,
                    orderBy='startTime',
                    timeMin=start_time,
                    timeMax=end_time
                ).execute()
                for item in events_result.get('items', []):
                    start_dt = item.get("start", {}).get("dateTime")
                    end_dt = item.get("end", {}).get("dateTime")
                    
                    # Convert to IST; leave date strings (all-day events) as is
                    start_str = convert_to_ist(start_dt) if start_dt else item.get("start", {}).get("date")
                    end_str = convert_to_ist(end_dt) if end_dt else item.get("end", {}).get("date")

                    agenda["events"].append({
                        "id": item.get("id"),
                        "summary": item.get("summary"),
                        "start": start_str,
                        "end": end_str,
                        "description": item.get("description"),
                    })
            except Exception as cal_err:
                logger.error("Failed to list Calendar events for agenda: %s", cal_err)
                agenda["events_error"] = str(cal_err)

            # Fetch Tasks
            try:
                tasks_service = build("tasks", "v1", credentials=creds)
                tasks_result = tasks_service.tasks().list(
                    tasklist='@default',
                    maxResults=max_tasks,
                    showCompleted=False
                ).execute()
                for item in tasks_result.get('items', []):
                    due_val = item.get("due")
                    ist_due = convert_to_ist(due_val) if due_val else None
                    # Only return tasks due on this specific date
                    if ist_due and ist_due[:10] != date:
                        continue
                    agenda["tasks"].append({
                        "id": item.get("id"),
                        "title": item.get("title"),
                        "notes": item.get("notes"),
                        "due": ist_due,
                        "status": item.get("status"),
                    })
            except Exception as task_err:
                logger.error("Failed to list Tasks for agenda: %s", task_err)
                agenda["tasks_error"] = str(task_err)

            return {
                "status": "success",
                "agenda": agenda
            }
        except Exception as e:
            return {"status": "error", "message": str(e)}

    return get_agenda


def make_complete_google_task_tool(session_context):
    def complete_google_task(task_id: str) -> dict:
        """
        Marks a specific task in the user's default Google Tasks list as completed.

        Args:
            task_id: The unique ID of the task to mark as completed.
        """
        logger.info("Google Tasks: Completing task ID '%s'", task_id)
        token = session_context.google_access_token
        if not token:
            logger.warning("Complete Google Task tool called but no access token is set.")
            return {
                "status": "error",
                "message": "User is not authenticated with Google or access token is missing.",
            }

        try:
            creds = Credentials(token=token)
            service = build("tasks", "v1", credentials=creds)
            
            # Fetch the task first to ensure it exists and get its metadata
            task = service.tasks().get(tasklist='@default', task=task_id).execute()
            
            # Update status to completed
            task['status'] = 'completed'
            
            updated_task = service.tasks().update(
                tasklist='@default',
                task=task_id,
                body=task
            ).execute()
            
            logger.info("Google Task marked completed successfully: %s", task_id)
            return {
                "status": "success",
                "message": f"Successfully completed task '{task_id}'",
                "task_id": updated_task.get("id"),
            }
        except Exception as e:
            logger.error("Failed to complete Google Task: %s", e)
            return {"status": "error", "message": str(e)}

    return complete_google_task
