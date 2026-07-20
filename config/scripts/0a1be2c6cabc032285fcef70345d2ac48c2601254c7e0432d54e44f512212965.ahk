#SingleInstance Force
#Persistent
SetTitleMatchMode, 2

IdleThreshold := 15000

SetTimer, Ping, 10000
return

Ping:
    if (A_TimeIdlePhysical < IdleThreshold)
        return

    WinGet, hWin, ID, Pentana Solutions XT Client
    if (!hWin)
        return

    fgWin := DllCall("GetForegroundWindow", "Ptr")   ; remember user's window

    WinSet, Transparent, 0, ahk_id %hWin%            ; invisible
    WinActivate, ahk_id %hWin%                       ; focus so F7 registers
    ;ControlSend,, {F7}, ahk_id %hWin%
    Sleep, 1000

    WinSet, Bottom,, ahk_id %hWin%                   ; send to back
    WinSet, Transparent, Off, ahk_id %hWin%          ; visible again

    if (fgWin)
        WinActivate, ahk_id %fgWin%                  ; restore user's window
return

^Esc::
    Reload
return