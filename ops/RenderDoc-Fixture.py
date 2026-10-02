"""Run through qrenderdoc --python; launch only the bounded private Rhino fixture."""
import json
from pathlib import Path
import sys
import traceback

import renderdoc as rd

runtime = Path.cwd() / "runtime"  # qrenderdoc's embedded interpreter does not define __file__.
result_path = runtime / "renderdoc-fixture-result.json"
control = None
try:
    request = json.loads((runtime / "renderdoc-fixture-request.json").read_text(encoding="utf-8-sig"))
    exe = Path(request["Executable"])
    if exe.name != "iw7-paris-voice.exe" or not exe.is_file():
        raise ValueError("Unexpected fixture executable")
    arguments = "-noupdate -nosteam -cpMode -stdout -paris-asset-test -paris-voice-local-test -paris-rhino-client-probe +loadzone paris_rhino +exec paris-rhino-agent-test.cfg"
    options = rd.CaptureOptions()
    options.captureAllCmdLists = True
    launched = rd.ExecuteAndInject(str(exe), str(exe.parent), arguments, [], request["CaptureTemplate"], options, False)
    if launched.result != rd.ResultCode.Succeeded:
        raise RuntimeError(str(launched.result))
    control = rd.CreateTargetControl("localhost", launched.ident, "Rhino fixture launch", False)
    if control is None or not control.Connected():
        raise RuntimeError("No RenderDoc target control connection")
    result = {"Nonce": request["Nonce"], "PID": control.GetPID(), "Ident": launched.ident, "Success": True}
except Exception:
    result = {"Success": False, "Error": traceback.format_exc()}
finally:
    if control is not None:
        control.Shutdown()
    result_path.write_text(json.dumps(result), encoding="utf-8")
    sys.exit(0)
