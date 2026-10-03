"""Write one constrained admin command to an already identified Windows console."""
import ctypes
import re
import sys

client_fixture = sys.argv[1] == "--module-client"
args = sys.argv[2:] if client_fixture else sys.argv[1:]
pid, command = int(args[0]), args[1]
if client_fixture:
    if command not in ("connect 127.0.0.1:27016", "disconnect", "quit"):
        raise ValueError("Only fixed loopback connect/disconnect/quit is accepted")
elif not re.fullmatch(r"set paris_mod_[a-z_]+ [01]", command):
    raise ValueError("Only a module switch is accepted")
k = ctypes.WinDLL("kernel32", use_last_error=True)
k.FreeConsole()
if not k.AttachConsole(pid):
    raise OSError(ctypes.get_last_error(), "AttachConsole")
k.CreateFileW.restype = ctypes.c_void_p
k.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p]
k.CloseHandle.argtypes = [ctypes.c_void_p]
handle = k.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)
if handle == ctypes.c_void_p(-1).value:
    k.FreeConsole()
    raise OSError(ctypes.get_last_error(), "CONIN$")

class Key(ctypes.Structure):
    _fields_ = [("down", ctypes.c_int), ("repeat", ctypes.c_ushort), ("vk", ctypes.c_ushort), ("scan", ctypes.c_ushort), ("ch", ctypes.c_wchar), ("control", ctypes.c_uint)]

class Event(ctypes.Union):
    _fields_ = [("key", Key), ("pad", ctypes.c_byte * 16)]

class Record(ctypes.Structure):
    _fields_ = [("type", ctypes.c_ushort), ("event", Event)]

records = []
for char in command + "\r":
    record = Record()
    record.type = 1
    record.event.key = Key(1, 1, 13 if char == "\r" else 0, 0, char, 0)
    records.append(record)
array = (Record * len(records))(*records)
written = ctypes.c_uint()
k.WriteConsoleInputW.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p]
try:
    if not k.WriteConsoleInputW(handle, array, len(array), ctypes.byref(written)) or written.value != len(array):
        raise OSError(ctypes.get_last_error(), "WriteConsoleInput")
finally:
    k.CloseHandle(handle)
    k.FreeConsole()
