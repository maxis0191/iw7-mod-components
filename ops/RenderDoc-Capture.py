"""Run via qrenderdoc --python after the fixture helper has verified protection."""
import json
from pathlib import Path
import sys
import time
import traceback

import renderdoc as rd

runtime = Path.cwd() / "runtime"
control = None
try:
    fixture = json.loads((runtime / "rhino-agent-client.json").read_text(encoding="utf-8-sig"))
    control = rd.CreateTargetControl("localhost", fixture["RenderDocIdent"], "Rhino frame diagnosis", False)
    if control is None or not control.Connected() or control.GetPID() != fixture["PID"]:
        raise RuntimeError("RenderDoc target differs from the protected fixture")
    control.TriggerCapture(1)
    deadline = time.monotonic() + 45
    result = None
    while time.monotonic() < deadline and control.Connected():
        message = control.ReceiveMessage(None)
        if message.type == rd.TargetControlMessageType.NewCapture:
            result = {"Success": True, "PID": fixture["PID"], "Capture": message.newCapture.path,
                      "Frame": message.newCapture.frameNumber, "Bytes": message.newCapture.byteSize}
            break
    if result is None:
        raise RuntimeError("No completed RenderDoc capture before deadline")
except Exception:
    result = {"Success": False, "Error": traceback.format_exc()}
finally:
    if control is not None:
        control.Shutdown()
    (runtime / "renderdoc-capture-result.json").write_text(json.dumps(result), encoding="utf-8")
    sys.exit(0)
