; ============================================================
;  Pentana XT Keep-Alive  v2.0  (AHK v1)
;  Eclipse RAP/RWT session ping via render-widget resize jiggle.
;  No focus steal, no window activation, no keystrokes.
;  Session dies in ~60s -> ping every 25s.
; ============================================================
#SingleInstance Force
#Persistent
#NoEnv
SetBatchLines, -1
SetTitleMatchMode, 2
SetWinDelay, -1

global TITLE     := "Pentana Solutions XT Client"
global PING_MS   := 25000
global LOGFILE   := A_ScriptDir "\Pentana_KeepAlive.log"
global g_RW      := 0
global g_Fails   := 0
global g_Cb      := RegisterCallback("EnumRW", "Fast", 2)

Menu, Tray, NoStandard
Menu, Tray, Tip, Pentana Keep-Alive (25s)
Menu, Tray, Add, Ping now, TrayPing
Menu, Tray, Add, Open log, TrayLog
Menu, Tray, Add
Menu, Tray, Add, Exit, TrayExit
Menu, Tray, Default, Ping now

Log("=== started, interval " PING_MS "ms ===")
SetTimer, Ping, %PING_MS%
GoSub, Ping
return

; ---------------- main ----------------
Ping:
    Jiggle()
return

Jiggle() {
    global TITLE, g_Fails
    DetectHiddenWindows, Off
    WinGet, list, List, %TITLE%
    if (!list) {
        Log("no window matching title")
        return
    }
    Loop, %list%
    {
        hWin := list%A_Index%
        WinGet, mmx, MinMax, ahk_id %hWin%
        hRW := FindRenderWidget(hWin)
        if (!hRW) {
            g_Fails++
            Log("no render widget for " hWin " (bg tab? not Chrome/Edge?) fails=" g_Fails)
            continue
        }
        if (JiggleChild(hRW)) {
            g_Fails := 0
            Log("ok  win=" hWin " rw=" hRW " minmax=" mmx)
        } else {
            g_Fails++
            Log("FAIL win=" hWin " rw=" hRW " minmax=" mmx " fails=" g_Fails)
        }
    }
    if (g_Fails >= 3) {
        Log("3 consecutive fails -> fallback activate")
        FallbackActivate()
        g_Fails := 0
    }
}

; 1px height shrink + restore on the Chrome render widget.
; Fires WM_SIZE -> renderer resize -> RWT posts client-area to server.
JiggleChild(hRW) {
    VarSetCapacity(rc, 16, 0)
    if (!DllCall("GetWindowRect", "Ptr", hRW, "Ptr", &rc))
        return 0
    sx := NumGet(rc, 0, "Int"), sy := NumGet(rc, 4, "Int")
    w  := NumGet(rc, 8, "Int") - sx
    h  := NumGet(rc, 12, "Int") - sy
    if (w < 20 || h < 20)
        return 0

    hParent := DllCall("GetParent", "Ptr", hRW, "Ptr")
    VarSetCapacity(pt, 8, 0)
    NumPut(sx, pt, 0, "Int"), NumPut(sy, pt, 4, "Int")
    if (hParent)
        DllCall("ScreenToClient", "Ptr", hParent, "Ptr", &pt)
    cx := NumGet(pt, 0, "Int"), cy := NumGet(pt, 4, "Int")

    DllCall("MoveWindow", "Ptr", hRW, "Int", cx, "Int", cy, "Int", w, "Int", h - 1, "Int", 1)
    Sleep, 150
    DllCall("MoveWindow", "Ptr", hRW, "Int", cx, "Int", cy, "Int", w, "Int", h, "Int", 1)
    return 1
}

; ---------------- render widget lookup ----------------
FindRenderWidget(hWin) {
    global g_RW, g_Cb
    g_RW := 0
    DllCall("EnumChildWindows", "Ptr", hWin, "Ptr", g_Cb, "Ptr", 0)
    return g_RW
}

EnumRW(hChild, lParam) {
    global g_RW
    VarSetCapacity(cls, 256 * 2, 0)
    DllCall("GetClassNameW", "Ptr", hChild, "Str", cls, "Int", 256)
    if (cls != "Chrome_RenderWidgetHostHWND")
        return 1
    if (!DllCall("IsWindowVisible", "Ptr", hChild))
        return 1
    VarSetCapacity(rc, 16, 0)
    DllCall("GetWindowRect", "Ptr", hChild, "Ptr", &rc)
    w := NumGet(rc, 8, "Int") - NumGet(rc, 0, "Int")
    h := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    if (w > 100 && h > 100) {
        g_RW := hChild
        return 0            ; stop enumeration
    }
    return 1
}

; ---------------- last-resort fallback ----------------
FallbackActivate() {
    global TITLE
    WinGet, hWin, ID, %TITLE%
    if (!hWin)
        return
    fg := DllCall("GetForegroundWindow", "Ptr")
    if (fg = hWin)
        return
    WinSet, Transparent, 0, ahk_id %hWin%
    WinActivate, ahk_id %hWin%
    Sleep, 400
    WinSet, Bottom,, ahk_id %hWin%
    WinSet, Transparent, Off, ahk_id %hWin%
    if (fg)
        WinActivate, ahk_id %fg%
}

; ---------------- logging ----------------
Log(msg) {
    global LOGFILE
    FormatTime, ts,, yyyy-MM-dd HH:mm:ss
    FileGetSize, sz, %LOGFILE%
    if (sz > 500000)
        FileDelete, %LOGFILE%
    FileAppend, % ts "  " msg "`n", %LOGFILE%
}

; ---------------- tray ----------------
TrayPing:
    GoSub, Ping
return
TrayLog:
    Run, notepad.exe "%LOGFILE%",, UseErrorLevel
return
TrayExit:
    ExitApp
return
