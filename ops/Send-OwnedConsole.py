"""Send one console line after the caller has validated its owned process tuple."""
import argparse
import ctypes
from ctypes import wintypes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pid', type=int)
    parser.add_argument('command')
    args = parser.parse_args()
    if args.pid <= 0 or not args.command or len(args.command) > 512 or any(ord(c) < 32 or ord(c) > 126 for c in args.command):
        parser.error('Positive PID and one bounded printable ASCII command required')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.AttachConsole.argtypes = [wintypes.DWORD]
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.FreeConsole()
    if not kernel.AttachConsole(args.pid):
        raise ctypes.WinError(ctypes.get_last_error())
    handle = None
    try:
        handle = kernel.CreateFileW('CONIN$', 0xC0000000, 3, None, 3, 0, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        class Key(ctypes.Structure):
            _fields_ = [('down', wintypes.BOOL), ('repeat', wintypes.WORD), ('vk', wintypes.WORD),
                        ('scan', wintypes.WORD), ('char', wintypes.WCHAR), ('control', wintypes.DWORD)]
        class Event(ctypes.Union):
            _fields_ = [('key', Key), ('padding', ctypes.c_byte * 16)]
        class Record(ctypes.Structure):
            _fields_ = [('type', wintypes.WORD), ('event', Event)]
        records = (Record * (len(args.command) + 1))()
        for row, char in zip(records, args.command + '\r'):
            row.type = 1
            row.event.key = Key(True, 1, 13 if char == '\r' else 0, 0, char, 0)
        written = wintypes.DWORD()
        kernel.WriteConsoleInputW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Record), wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
        if not kernel.WriteConsoleInputW(handle, records, len(records), ctypes.byref(written)) or written.value != len(records):
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        if handle is not None and handle != ctypes.c_void_p(-1).value:
            kernel.CloseHandle(handle)
        kernel.FreeConsole()


if __name__ == '__main__':
    main()
