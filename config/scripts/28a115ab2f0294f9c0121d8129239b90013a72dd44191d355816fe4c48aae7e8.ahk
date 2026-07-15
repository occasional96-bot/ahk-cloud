#SingleInstance Force
#Persistent
SetTitleMatchMode, 2

SetTimer, Ping, 3000
return

Ping:
    if (A_TimeIdlePhysical < 5000)   ; user active in last 5s - skip, try next timer tick
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
    DllCall("SetFocus", "Ptr", hRender, "Ptr")

    ;~ PostMessage, 0x100, 0x76, 0x00410001,, ahk_id %hRender%   ; F7 down
    ;~ PostMessage, 0x101, 0x76, 0xC0410001,, ahk_id %hRender%   ; F7 up
    Sleep, 1000
	;~ PostMessage, 0x100, 0x76, 0x00410001,, ahk_id %hRender%   ; F7 down
    ;~ PostMessage, 0x101, 0x76, 0xC0410001,, ahk_id %hRender%   ; F7 up


    DllCall("AttachThreadInput", "UInt", myThread, "UInt", fgThread, "Int", 1)
    DllCall("SetFocus", "Ptr", fgWin, "Ptr")
    DllCall("AttachThreadInput", "UInt", myThread, "UInt", fgThread, "Int", 0)
    DllCall("AttachThreadInput", "UInt", myThread, "UInt", targetThread, "Int", 0)
return