from unittest.mock import patch, MagicMock
from chopper_agent.agent import SessionContext
from chopper_agent.google_tools import (
    make_google_calendar_tool,
    make_google_tasks_tool,
    make_delete_calendar_event_tool,
    make_list_calendar_events_tool,
    make_list_google_tasks_tool,
    make_delete_google_task_tool,
    make_get_agenda_tool,
)

def test_google_tools_no_token():
    context = SessionContext()
    add_event = make_google_calendar_tool(context)
    add_task = make_google_tasks_tool(context)
    delete_event = make_delete_calendar_event_tool(context)
    list_events = make_list_calendar_events_tool(context)
    list_tasks = make_list_google_tasks_tool(context)
    delete_task = make_delete_google_task_tool(context)
    get_agenda = make_get_agenda_tool(context)

    # Missing token -> should return error status
    res_cal = add_event(summary="Dentist", start_time="2026-07-12T15:00:00Z", end_time="2026-07-12T16:00:00Z")
    assert res_cal["status"] == "error"
    assert "access token is missing" in res_cal["message"]

    res_task = add_task(title="Buy milk")
    assert res_task["status"] == "error"
    assert "access token is missing" in res_task["message"]

    res_del = delete_event(event_id="evt123")
    assert res_del["status"] == "error"
    assert "access token is missing" in res_del["message"]

    res_list_evt = list_events()
    assert res_list_evt["status"] == "error"
    assert "access token is missing" in res_list_evt["message"]

    res_list_tsk = list_tasks()
    assert res_list_tsk["status"] == "error"
    assert "access token is missing" in res_list_tsk["message"]

    res_del_tsk = delete_task(task_id="tsk123")
    assert res_del_tsk["status"] == "error"
    assert "access token is missing" in res_del_tsk["message"]

    res_agenda = get_agenda()
    assert res_agenda["status"] == "error"
    assert "access token is missing" in res_agenda["message"]

@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_add_calendar_event_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    mock_events = MagicMock()
    mock_service.events.return_value = mock_events
    mock_insert = MagicMock()
    mock_events.insert.return_value = mock_insert
    mock_insert.execute.return_value = {"id": "event123", "htmlLink": "http://event-link"}

    add_event = make_google_calendar_tool(context)
    res = add_event(summary="Dentist", start_time="2026-07-12T15:00:00Z", end_time="2026-07-12T16:00:00Z", description="Checkup")

    assert res["status"] == "success"
    assert res["event_id"] == "event123"
    assert res["link"] == "http://event-link"
    
    mock_credentials.assert_called_once_with(token="mock-access-token")
    mock_build.assert_called_once_with("calendar", "v3", credentials=mock_credentials.return_value)
    mock_events.insert.assert_called_once()

@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_delete_calendar_event_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    mock_events = MagicMock()
    mock_service.events.return_value = mock_events
    mock_delete = MagicMock()
    mock_events.delete.return_value = mock_delete
    mock_delete.execute.return_value = {}

    delete_event = make_delete_calendar_event_tool(context)
    res = delete_event(event_id="evt123")

    assert res["status"] == "success"
    assert "evt123" in res["message"]
    
    mock_credentials.assert_called_once_with(token="mock-access-token")
    mock_build.assert_called_once_with("calendar", "v3", credentials=mock_credentials.return_value)
    mock_events.delete.assert_called_once_with(calendarId="primary", eventId="evt123")

@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_list_calendar_events_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    mock_events = MagicMock()
    mock_service.events.return_value = mock_events
    mock_list = MagicMock()
    mock_events.list.return_value = mock_list
    mock_list.execute.return_value = {
        "items": [
            {
                "id": "evtA",
                "summary": "Meeting A",
                "start": {"dateTime": "2026-07-12T10:00:00Z"},
                "end": {"dateTime": "2026-07-12T11:00:00Z"},
                "description": "Desc A"
            }
        ]
    }

    list_events = make_list_calendar_events_tool(context)
    res = list_events(max_results=5)

    assert res["status"] == "success"
    assert len(res["events"]) == 1
    assert res["events"][0]["id"] == "evtA"

@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_add_google_task_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    mock_tasks = MagicMock()
    mock_service.tasks.return_value = mock_tasks
    mock_insert = MagicMock()
    mock_tasks.insert.return_value = mock_insert
    mock_insert.execute.return_value = {"id": "task123"}

    add_task = make_google_tasks_tool(context)
    res = add_task(title="Buy milk", notes="Whole milk", due="2026-07-12T18:00:00Z", status="needsAction")

    assert res["status"] == "success"
    assert res["task_id"] == "task123"
    mock_tasks.insert.assert_called_once_with(
        tasklist='@default',
        body={
            'title': 'Buy milk',
            'notes': 'Whole milk',
            'due': '2026-07-12T18:00:00Z',
            'status': 'needsAction'
        }
    )

@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_list_google_tasks_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    mock_tasks = MagicMock()
    mock_service.tasks.return_value = mock_tasks
    mock_list = MagicMock()
    mock_tasks.list.return_value = mock_list
    mock_list.execute.return_value = {
        "items": [
            {
                "id": "tskB",
                "title": "Task B",
                "notes": "Notes B",
                "due": "2026-07-12T18:00:00Z",
                "status": "needsAction"
            }
        ]
    }

    list_tasks = make_list_google_tasks_tool(context)
    res = list_tasks(max_results=10)

    assert res["status"] == "success"
    assert len(res["tasks"]) == 1
    assert res["tasks"][0]["id"] == "tskB"

@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_delete_google_task_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    mock_tasks = MagicMock()
    mock_service.tasks.return_value = mock_tasks
    mock_delete = MagicMock()
    mock_tasks.delete.return_value = mock_delete
    mock_delete.execute.return_value = {}

    delete_task = make_delete_google_task_tool(context)
    res = delete_task(task_id="tsk123")

    assert res["status"] == "success"
    assert "tsk123" in res["message"]
    
    mock_credentials.assert_called_once_with(token="mock-access-token")
    mock_build.assert_called_once_with("tasks", "v1", credentials=mock_credentials.return_value)
    mock_tasks.delete.assert_called_once_with(tasklist="@default", task="tsk123")

@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_get_agenda_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    
    mock_events = MagicMock()
    mock_tasks = MagicMock()
    
    mock_list_events = MagicMock()
    mock_list_tasks = MagicMock()
    
    # Configure build side effects depending on serviceName
    def build_side_effect(serviceName, version, credentials):
        if serviceName == "calendar":
            mock_service.events.return_value = mock_events
            mock_events.list.return_value = mock_list_events
            mock_list_events.execute.return_value = {
                "items": [{"id": "cal1", "summary": "Meeting 1", "start": {"dateTime": "2026-07-12T10:00:00Z"}, "end": {"dateTime": "2026-07-12T11:00:00Z"}}]
            }
            return mock_service
        elif serviceName == "tasks":
            # Return a different service instance or the same mocked one
            mock_tasks_service = MagicMock()
            mock_tasks_service.tasks.return_value = mock_tasks
            mock_tasks.list.return_value = mock_list_tasks
            mock_list_tasks.execute.return_value = {
                "items": [{"id": "task1", "title": "Buy groceries", "notes": "Milk, bread", "due": "2026-07-12T18:00:00Z", "status": "needsAction"}]
            }
            return mock_tasks_service
            
    mock_build.side_effect = build_side_effect

    get_agenda = make_get_agenda_tool(context)
    res = get_agenda(date="2026-07-12", max_events=5, max_tasks=10)

    assert res["status"] == "success"
    assert "agenda" in res
    assert len(res["agenda"]["events"]) == 1
    assert res["agenda"]["events"][0]["summary"] == "Meeting 1"
    assert len(res["agenda"]["tasks"]) == 1
    assert res["agenda"]["tasks"][0]["title"] == "Buy groceries"


@patch("chopper_agent.google_tools.build")
@patch("chopper_agent.google_tools.Credentials")
def test_complete_google_task_success(mock_credentials, mock_build):
    context = SessionContext()
    context.google_access_token = "mock-access-token"
    
    mock_service = MagicMock()
    mock_build.return_value = mock_service
    mock_tasks = MagicMock()
    mock_service.tasks.return_value = mock_tasks
    
    # Mock get() call to return the original task
    mock_get = MagicMock()
    mock_tasks.get.return_value = mock_get
    mock_get.execute.return_value = {
        "id": "tsk123",
        "title": "Buy milk",
        "status": "needsAction"
    }
    
    # Mock update() call to return the updated task
    mock_update = MagicMock()
    mock_tasks.update.return_value = mock_update
    mock_update.execute.return_value = {
        "id": "tsk123",
        "title": "Buy milk",
        "status": "completed"
    }

    from chopper_agent.google_tools import make_complete_google_task_tool
    complete_task = make_complete_google_task_tool(context)
    res = complete_task(task_id="tsk123")

    assert res["status"] == "success"
    assert res["task_id"] == "tsk123"
    
    mock_tasks.get.assert_called_once_with(tasklist="@default", task="tsk123")
    mock_tasks.update.assert_called_once_with(
        tasklist="@default",
        task="tsk123",
        body={
            "id": "tsk123",
            "title": "Buy milk",
            "status": "completed"
        }
    )


def test_engagement_tools_success():
    from chopper_agent.agent import (
        make_start_engagement_tool,
        make_stop_engagement_tool,
    )
    context = SessionContext()
    assert context.engaged is False
    
    start_tool = make_start_engagement_tool(context)
    stop_tool = make_stop_engagement_tool(context)
    
    res_start = start_tool()
    assert res_start["status"] == "success"
    assert context.engaged is True
    
    res_stop = stop_tool()
    assert res_stop["status"] == "success"
    assert context.engaged is False
