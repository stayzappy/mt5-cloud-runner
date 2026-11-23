#!/usr/bin/env python3
"""
Modal Dialog Suppressor Daemon (Native libX11 ctypes)
Continuously monitors X11 display (default :100) and automatically closes any
modal dialogs ('Login', 'Open an Account', wine warnings) that lock MT5 IPC.
Zero external CLI dependencies (uses native libX11.so.6).
"""
import ctypes
import time
import os
import sys

def is_target_modal(val: str) -> bool:
    v = val.strip()
    if not v:
        return False
    vl = v.lower()
    # Explicitly protect the main terminal window and standard desktop components
    if any(sig in vl for sig in ["hedge", "exness", "aiwacapital", "toolbox", "default ime", "wine desktop"]):
        return False
    # If title starts with digits (e.g. account login "161806031 - ...", "476871582 - ..."), it is the main MT5 terminal
    first_token = vl.split()[0] if vl.split() else ""
    if first_token.isdigit():
        return False
    # Target dialog titles to dismiss:
    if vl in ["login", "authorization", "authorisation", "open an account", "accounts", "network", "warning", "error"]:
        return True
    if vl.startswith("login") or vl.startswith("open an account") or vl.startswith("wine"):
        return True
    if "open an account" in vl:
        return True
    return False

def dismiss_dialogs(disp, x11, wm_delete, wm_protocols):
    try:
        root = x11.XDefaultRootWindow(disp)
        r = ctypes.c_ulong()
        p = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        n = ctypes.c_uint()
        if not x11.XQueryTree(disp, root, ctypes.byref(r), ctypes.byref(p), ctypes.byref(children), ctypes.byref(n)):
            return

        class XTextProperty(ctypes.Structure):
            _fields_ = [
                ('value', ctypes.c_char_p),
                ('encoding', ctypes.c_ulong),
                ('format', ctypes.c_int),
                ('nitems', ctypes.c_ulong)
            ]

        class XClientMessageEvent(ctypes.Structure):
            _fields_ = [
                ('type', ctypes.c_int),
                ('serial', ctypes.c_ulong),
                ('send_event', ctypes.c_int),
                ('display', ctypes.c_void_p),
                ('window', ctypes.c_ulong),
                ('message_type', ctypes.c_ulong),
                ('format', ctypes.c_int),
                ('data_l', ctypes.c_long * 5)
            ]

        class XEvent(ctypes.Union):
            _fields_ = [
                ('type', ctypes.c_int),
                ('xclient', XClientMessageEvent),
                ('pad', ctypes.c_long * 24)
            ]

        for i in range(n.value):
            wid = children[i]
            prop = XTextProperty()
            if x11.XGetWMName(disp, wid, ctypes.byref(prop)):
                val = prop.value.decode('utf-8', errors='replace') if prop.value else ''
                if is_target_modal(val):
                    print(f"[modal_suppressor] Dismissing modal dialog window {wid}: '{val}'", flush=True)
                    ev = XEvent()
                    ev.type = 33 # ClientMessage
                    ev.xclient.type = 33
                    ev.xclient.serial = 0
                    ev.xclient.send_event = True
                    ev.xclient.display = disp
                    ev.xclient.window = wid
                    ev.xclient.message_type = wm_protocols
                    ev.xclient.format = 32
                    ev.xclient.data_l[0] = wm_delete
                    x11.XSendEvent(disp, wid, False, 0, ctypes.byref(ev))
                    x11.XFlush(disp)
    except Exception:
        pass

def main():
    display_name = os.getenv("DISPLAY", ":100").encode('utf-8')
    try:
        x11 = ctypes.cdll.LoadLibrary("/usr/lib/x86_64-linux-gnu/libX11.so.6")
    except Exception:
        try:
            x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
        except Exception:
            sys.exit(0)

    disp = None
    for _ in range(30):
        disp = x11.XOpenDisplay(display_name)
        if disp:
            break
        time.sleep(1)

    if not disp:
        sys.exit(0)

    wm_delete = x11.XInternAtom(disp, b"WM_DELETE_WINDOW", False)
    wm_protocols = x11.XInternAtom(disp, b"WM_PROTOCOLS", False)

    while True:
        dismiss_dialogs(disp, x11, wm_delete, wm_protocols)
        time.sleep(1.5)

if __name__ == "__main__":
    main()
