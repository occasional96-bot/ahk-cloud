#SingleInstance Force
#Persistent
SetTitleMatchMode, 2

IdleThreshold := 5000   ; only ping if idle this long (ms)

SetTimer, Ping, 10000
return

Ping:
    if (A_TimeIdlePhysical < IdleThreshold)   ; user is actively typing/moving - skip
        return

    WinGet, hWin, ID, Pentana Solutions XT Client
    if (!hWin)
        return
    ControlGet, hRender, Hwnd,, Chrome_RenderWidgetHostHWND1, ahk_id %hWin%
    if (!hRender)
        hRender := hWin

    myThread     := DllCall("GetCurrentThreadId")
    targetThread := DllCall("GetWindowThreadProcessId", "Ptr", hRender, "Ptr", 0)

    fgWin    := DllCall("GetForegroundWindow", "Ptr")
    fgThread := DllCall("GetWindowThreadProcessId", "Ptr", fgWin, "Ptr", 0)

    DllCall("AttachThreadInput", "UInt", myThread, "UInt", targetThread, "Int", 1)
    hPrevFocus := DllCall("SetFocus", "Ptr", hRender, "Ptr")

    Sleep, 1000

    if (hPrevFocus)
        DllCall("SetFocus", "Ptr", hPrevFocus, "Ptr")
    DllCall("AttachThreadInput", "UInt", myThread, "UInt", targetThread, "Int", 0)

    ; push Pentana to the bottom of the Z-order (background, no activation)
    ; SetWindowPos HWND_BOTTOM=1, SWP_NOSIZE 0x1 | SWP_NOMOVE 0x2 | SWP_NOACTIVATE 0x10 = 0x13
    DllCall("SetWindowPos", "Ptr", hWin, "Ptr", 1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)

    ; restore user's foreground window
    DllCall("AttachThreadInput", "UInt", myThread, "UInt", fgThread, "Int", 1)
    DllCall("SetFocus", "Ptr", fgWin, "Ptr")
    DllCall("AttachThreadInput", "UInt", myThread, "UInt", fgThread, "Int", 0)
return