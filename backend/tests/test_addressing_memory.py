import shutil
import tempfile
from chopper_agent.agent import SessionContext, make_stay_silent_tool, make_update_memory_tool, load_memory

def test_session_context_initialization():
    context = SessionContext()
    assert context.suppress_current_turn is False

def test_stay_silent_tool():
    context = SessionContext()
    stay_silent = make_stay_silent_tool(context)
    
    assert context.suppress_current_turn is False
    response = stay_silent(reason="test mention")
    
    assert context.suppress_current_turn is True
    assert response["status"] == "success"
    assert "Staying silent" in response["message"]

def test_memory_tools_isolated():
    # Use a temporary directory for memories to isolate tests
    temp_dir = tempfile.mkdtemp()
    try:
        user_1 = "user_abc"
        user_2 = "user_xyz"
        
        update_user_1 = make_update_memory_tool(user_1, temp_dir)
        update_user_2 = make_update_memory_tool(user_2, temp_dir)
        
        # Verify initial memory is empty
        assert load_memory(user_1, temp_dir) == ""
        assert load_memory(user_2, temp_dir) == ""
        
        # Update user 1's memory
        res1 = update_user_1("Name is Rohan")
        assert res1["status"] == "success"
        
        # Verify user 1 has memory, user 2 is still empty
        mem1 = load_memory(user_1, temp_dir)
        mem2 = load_memory(user_2, temp_dir)
        
        assert "Name is Rohan" in mem1
        assert "<long_term_memory>" in mem1
        assert mem2 == ""
        
        # Update user 2's memory
        res2 = update_user_2("Allergic to peanuts")
        assert res2["status"] == "success"
        
        # Verify both have their separate memories
        mem1_updated = load_memory(user_1, temp_dir)
        mem2_updated = load_memory(user_2, temp_dir)
        
        assert "Name is Rohan" in mem1_updated
        assert "Allergic to peanuts" not in mem1_updated
        
        assert "Allergic to peanuts" in mem2_updated
        assert "Name is Rohan" not in mem2_updated
        
    finally:
        shutil.rmtree(temp_dir)
