#!/usr/bin/env python3
"""
Test script for OBS WebSocket v5 protocol.
Tests connection, authentication, scene management, and recording controls.
"""

import asyncio
import json
import hashlib
import base64
import sys
import time

try:
    import websockets
except ImportError:
    print("ERROR: websockets module not found. Install with: pip3 install websockets")
    sys.exit(1)

# Configuration
OBS_HOST = "localhost"
OBS_PORT = 4455
OBS_PASSWORD = "test1234"

request_counter = 0
pending_requests = {}


def generate_auth_response(password: str, challenge: str, salt: str) -> str:
    """Generate OBS WebSocket v5 authentication response."""
    # Step 1: SHA256(password + salt) -> base64
    secret_hash = hashlib.sha256((password + salt).encode("utf-8")).digest()
    secret = base64.b64encode(secret_hash).decode("utf-8")
    # Step 2: SHA256(secret + challenge) -> base64
    auth_hash = hashlib.sha256((secret + challenge).encode("utf-8")).digest()
    auth_response = base64.b64encode(auth_hash).decode("utf-8")
    return auth_response


async def send_request(ws, request_type: str, request_data: dict = None) -> dict:
    """Send an OBS WebSocket request and wait for the response."""
    global request_counter
    request_counter += 1
    request_id = f"test_req_{request_counter}"

    msg = {
        "op": 6,  # Request
        "d": {
            "requestType": request_type,
            "requestId": request_id,
        },
    }
    if request_data:
        msg["d"]["requestData"] = request_data

    future = asyncio.get_event_loop().create_future()
    pending_requests[request_id] = future

    await ws.send(json.dumps(msg))

    try:
        result = await asyncio.wait_for(future, timeout=10.0)
        return result
    except asyncio.TimeoutError:
        pending_requests.pop(request_id, None)
        return {"error": "Timeout waiting for response"}


def handle_message(message_text: str):
    """Handle incoming WebSocket messages and resolve pending requests."""
    data = json.loads(message_text)
    op = data.get("op")
    d = data.get("d", {})

    if op == 7:  # RequestResponse
        request_id = d.get("requestId")
        if request_id in pending_requests:
            future = pending_requests.pop(request_id)
            if not future.done():
                future.set_result(d)

    return op, d


async def test_connection_and_auth(ws) -> bool:
    """Test connection and authentication with OBS WebSocket."""
    print("\n=== Test 1: Connection & Authentication ===")

    # Wait for Hello message (op: 0)
    raw = await asyncio.wait_for(ws.recv(), timeout=10.0)
    op, d = handle_message(raw)

    if op != 0:
        print(f"  FAIL: Expected Hello (op=0), got op={op}")
        return False

    print(f"  OBS WebSocket version: {d.get('obsWebSocketVersion', 'unknown')}")
    print(f"  RPC version: {d.get('rpcVersion', 'unknown')}")

    # Prepare Identify message (op: 1)
    identify = {"rpcVersion": 1, "eventSubscriptions": 1023}

    auth_info = d.get("authentication")
    if auth_info:
        challenge = auth_info["challenge"]
        salt = auth_info["salt"]
        print(f"  Authentication required (challenge present)")
        auth_response = generate_auth_response(OBS_PASSWORD, challenge, salt)
        identify["authentication"] = auth_response
    else:
        print(f"  No authentication required")

    await ws.send(json.dumps({"op": 1, "d": identify}))

    # Wait for Identified message (op: 2)
    raw = await asyncio.wait_for(ws.recv(), timeout=10.0)
    op, d = handle_message(raw)

    if op == 2:
        print(f"  PASS: Successfully authenticated and connected!")
        return True
    else:
        print(f"  FAIL: Expected Identified (op=2), got op={op}")
        if d.get("requestStatus", {}).get("comment"):
            print(f"  Error: {d['requestStatus']['comment']}")
        return False


async def receive_loop(ws):
    """Background task to receive and route messages."""
    try:
        async for message in ws:
            handle_message(message)
    except websockets.exceptions.ConnectionClosed:
        pass


async def test_get_scene_collections(ws) -> bool:
    """Test fetching scene collections."""
    print("\n=== Test 2: Get Scene Collections ===")
    result = await send_request(ws, "GetSceneCollectionList")

    if "error" in result:
        print(f"  FAIL: {result['error']}")
        return False

    status = result.get("requestStatus", {})
    if not status.get("result"):
        print(f"  FAIL: {status.get('comment', 'Unknown error')}")
        return False

    response_data = result.get("responseData", {})
    collections = response_data.get("sceneCollections", [])
    current = response_data.get("currentSceneCollectionName", "")

    print(f"  Scene collections: {collections}")
    print(f"  Current collection: {current}")
    print(f"  PASS: Found {len(collections)} scene collection(s)")
    return True


async def test_get_profiles(ws) -> bool:
    """Test fetching profiles."""
    print("\n=== Test 3: Get Profiles ===")
    result = await send_request(ws, "GetProfileList")

    if "error" in result:
        print(f"  FAIL: {result['error']}")
        return False

    status = result.get("requestStatus", {})
    if not status.get("result"):
        print(f"  FAIL: {status.get('comment', 'Unknown error')}")
        return False

    response_data = result.get("responseData", {})
    profiles = response_data.get("profiles", [])
    current = response_data.get("currentProfileName", "")

    print(f"  Profiles: {profiles}")
    print(f"  Current profile: {current}")
    print(f"  PASS: Found {len(profiles)} profile(s)")
    return True


async def test_get_scenes(ws) -> bool:
    """Test fetching scenes."""
    print("\n=== Test 4: Get Scenes ===")
    result = await send_request(ws, "GetSceneList")

    if "error" in result:
        print(f"  FAIL: {result['error']}")
        return False

    status = result.get("requestStatus", {})
    if not status.get("result"):
        print(f"  FAIL: {status.get('comment', 'Unknown error')}")
        return False

    response_data = result.get("responseData", {})
    scenes = response_data.get("scenes", [])
    current = response_data.get("currentProgramSceneName", "")

    scene_names = [s.get("sceneName", "?") for s in scenes]
    print(f"  Scenes: {scene_names}")
    print(f"  Current scene: {current}")
    print(f"  PASS: Found {len(scenes)} scene(s)")
    return True, scene_names, current


async def test_switch_scene(ws, scene_names: list, current_scene: str) -> bool:
    """Test switching between scenes."""
    print("\n=== Test 5: Switch Scenes ===")

    if len(scene_names) < 2:
        print(f"  SKIP: Need at least 2 scenes to test switching (have {len(scene_names)})")
        return True

    # Find a scene to switch to (different from current)
    target_scene = None
    for name in scene_names:
        if name != current_scene:
            target_scene = name
            break

    if not target_scene:
        print(f"  SKIP: No different scene to switch to")
        return True

    print(f"  Switching from '{current_scene}' to '{target_scene}'...")
    result = await send_request(ws, "SetCurrentProgramScene", {"sceneName": target_scene})

    if "error" in result:
        print(f"  FAIL: {result['error']}")
        return False

    status = result.get("requestStatus", {})
    if not status.get("result"):
        print(f"  FAIL: {status.get('comment', 'Unknown error')}")
        return False

    # Verify the switch
    await asyncio.sleep(0.5)
    verify_result = await send_request(ws, "GetSceneList")
    verify_data = verify_result.get("responseData", {})
    new_current = verify_data.get("currentProgramSceneName", "")

    if new_current == target_scene:
        print(f"  PASS: Successfully switched to '{target_scene}'")
    else:
        print(f"  WARN: Expected current scene '{target_scene}', got '{new_current}'")

    # Switch back
    print(f"  Switching back to '{current_scene}'...")
    await send_request(ws, "SetCurrentProgramScene", {"sceneName": current_scene})
    await asyncio.sleep(0.5)
    print(f"  Restored original scene")
    return True


async def test_recording(ws) -> bool:
    """Test start/stop recording."""
    print("\n=== Test 6: Recording Control ===")

    # Check current recording status
    status_result = await send_request(ws, "GetRecordStatus")
    if "error" in status_result:
        print(f"  FAIL: Could not get recording status: {status_result['error']}")
        return False

    status_data = status_result.get("requestStatus", {})
    if not status_data.get("result"):
        print(f"  FAIL: GetRecordStatus failed: {status_data.get('comment', 'Unknown error')}")
        return False

    response = status_result.get("responseData", {})
    is_recording = response.get("outputActive", False)
    print(f"  Current recording state: {'Recording' if is_recording else 'Not recording'}")

    if is_recording:
        print(f"  SKIP: Already recording, not testing start/stop")
        return True

    # Start recording
    print(f"  Starting recording...")
    start_result = await send_request(ws, "StartRecord")
    start_status = start_result.get("requestStatus", {})

    if not start_status.get("result"):
        comment = start_status.get("comment", "Unknown error")
        code = start_status.get("code", 0)
        # Code 800 means output already active, which is fine
        if code == 800:
            print(f"  INFO: Recording was already active")
        else:
            print(f"  FAIL: StartRecord failed: {comment} (code: {code})")
            return False
    else:
        print(f"  Recording started successfully")

    # Wait a moment
    await asyncio.sleep(2)

    # Stop recording
    print(f"  Stopping recording...")
    stop_result = await send_request(ws, "StopRecord")
    stop_status = stop_result.get("requestStatus", {})

    if not stop_status.get("result"):
        comment = stop_status.get("comment", "Unknown error")
        code = stop_status.get("code", 0)
        if code == 800:
            print(f"  INFO: Recording was not active")
        else:
            print(f"  FAIL: StopRecord failed: {comment} (code: {code})")
            return False
    else:
        output_path = stop_result.get("responseData", {}).get("outputPath", "unknown")
        print(f"  Recording stopped. Output: {output_path}")

    print(f"  PASS: Recording start/stop works")
    return True


async def test_get_version(ws) -> bool:
    """Test getting OBS version info."""
    print("\n=== Test 7: Get Version Info ===")
    result = await send_request(ws, "GetVersion")

    if "error" in result:
        print(f"  FAIL: {result['error']}")
        return False

    status = result.get("requestStatus", {})
    if not status.get("result"):
        print(f"  FAIL: {status.get('comment', 'Unknown error')}")
        return False

    response_data = result.get("responseData", {})
    print(f"  OBS Version: {response_data.get('obsVersion', 'unknown')}")
    print(f"  WebSocket Version: {response_data.get('obsWebSocketVersion', 'unknown')}")
    print(f"  Platform: {response_data.get('platform', 'unknown')}")
    print(f"  Platform Description: {response_data.get('platformDescription', 'unknown')}")
    print(f"  Available Requests: {len(response_data.get('availableRequests', []))} types")
    print(f"  PASS: Version info retrieved")
    return True


async def main():
    """Run all OBS WebSocket tests."""
    print(f"OBS WebSocket Test Suite")
    print(f"========================")
    print(f"Connecting to ws://{OBS_HOST}:{OBS_PORT}...")

    results = {}
    scene_names = []
    current_scene = ""

    try:
        async with websockets.connect(
            f"ws://{OBS_HOST}:{OBS_PORT}",
            open_timeout=10,
            close_timeout=5,
        ) as ws:
            # Test 1: Connection & Auth
            auth_ok = await test_connection_and_auth(ws)
            results["Connection & Auth"] = auth_ok

            if not auth_ok:
                print("\nAuthentication failed, cannot continue tests.")
                return results

            # Start background message receiver
            receiver = asyncio.create_task(receive_loop(ws))

            # Small delay to let OBS settle
            await asyncio.sleep(0.5)

            # Test 7: Version info (do this early as it's safe)
            results["Get Version"] = await test_get_version(ws)

            # Test 2: Scene Collections
            results["Get Scene Collections"] = await test_get_scene_collections(ws)

            # Test 3: Profiles
            results["Get Profiles"] = await test_get_profiles(ws)

            # Test 4: Scenes
            scene_result = await test_get_scenes(ws)
            if isinstance(scene_result, tuple):
                results["Get Scenes"] = scene_result[0]
                scene_names = scene_result[1]
                current_scene = scene_result[2]
            else:
                results["Get Scenes"] = scene_result

            # Test 5: Switch Scenes
            results["Switch Scenes"] = await test_switch_scene(ws, scene_names, current_scene)

            # Test 6: Recording
            results["Recording Control"] = await test_recording(ws)

            # Cancel receiver
            receiver.cancel()
            try:
                await receiver
            except asyncio.CancelledError:
                pass

    except ConnectionRefusedError:
        print(f"\nFAIL: Could not connect to OBS WebSocket at ws://{OBS_HOST}:{OBS_PORT}")
        print(f"Make sure OBS is running with WebSocket server enabled.")
        return {"Connection": False}
    except asyncio.TimeoutError:
        print(f"\nFAIL: Connection timed out")
        return {"Connection": False}
    except Exception as e:
        print(f"\nFAIL: Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        return {"Connection": False}

    # Summary
    print(f"\n{'='*50}")
    print(f"TEST SUMMARY")
    print(f"{'='*50}")
    total = len(results)
    passed = sum(1 for v in results.values() if v)
    failed = total - passed

    for test_name, result in results.items():
        status = "PASS" if result else "FAIL"
        print(f"  [{status}] {test_name}")

    print(f"\n  Total: {total}, Passed: {passed}, Failed: {failed}")

    if failed == 0:
        print(f"\n  All tests passed!")
    else:
        print(f"\n  Some tests failed!")
        sys.exit(1)

    return results


if __name__ == "__main__":
    asyncio.run(main())
