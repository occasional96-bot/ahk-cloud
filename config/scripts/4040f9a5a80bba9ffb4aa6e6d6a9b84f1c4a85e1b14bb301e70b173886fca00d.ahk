#NoEnv
#SingleInstance Force
#Persistent
SetBatchLines, -1
SetTitleMatchMode, 2
DetectHiddenWindows, Off        ; visible windows only

; ---------- CONFIG ----------
WinTitleMatch := "Pentana Solutions XT Client"
IntervalSec   := 30
JigglePx      := 15
; ----------------------------

;Menu, Tray, Icon, %A_WinDir%\System32\imageres.dll, 102
Menu, Tray, NoStandard
Menu, Tray, Add, Ping Now, PingNow
Menu, Tray, Add, Identify Target, Identify
Menu, Tray, Add, Exit, QuitScript
Menu, Tray, Tip, XT KeepAlive (%IntervalSec%s)

PingCount := 0
SetTimer, PingNow, % IntervalSec * 1000
return

Identify:
    hWin := FindXT()
    if (!hWin) {
        MsgBox, No visible Chrome/Edge window matched "%WinTitleMatch%"
        return
    }
    WinGetTitle, t, ahk_id %hWin%
    WinGetClass, c, ahk_id %hWin%
    WinGet, mm, MinMax, ahk_id %hWin%
    WinGetPos, x, y, w, h, ahk_id %hWin%
    MsgBox, 0, Target, Title: %t%`nClass: %c%`nMinMax: %mm% (1=max 0=normal -1=min)`nPos: %x%,%y%  Size: %w%x%h%`n`nWindow will flash now.
    Loop, 3 {
        WinMove, ahk_id %hWin%,,,, % w-40, % h
        Sleep, 250
        WinMove, ahk_id %hWin%,,,, % w, % h
        Sleep, 250
    }
return

PingNow:
    hWin := FindXT()
    if (!hWin) {
        TrayTip, XT KeepAlive, WINDOW NOT FOUND, 3, 2
        return
    }
    WinGet, mm, MinMax, ahk_id %hWin%

    wasMin := (mm = -1)
    if (wasMin) {
        DllCall("ShowWindow", "Ptr", hWin, "Int", 4)   ; SW_SHOWNOACTIVATE - restore without focus
        Sleep, 500                                      ; let renderer wake
        WinGet, mm, MinMax, ahk_id %hWin%
    }

    if (mm = 1) {
        hRender := GetRenderHwnd(hWin)
        if (hRender) {
            WinGetPos,,, rw, rh, ahk_id %hRender%
            DllCall("MoveWindow", "Ptr", hRender, "Int", 0, "Int", 0, "Int", rw, "Int", rh - JigglePx, "Int", 1)
            Sleep, 300
            DllCall("MoveWindow", "Ptr", hRender, "Int", 0, "Int", 0, "Int", rw, "Int", rh, "Int", 1)
        }
    } else {
        WinGetPos, x, y, w, h, ahk_id %hWin%
        WinMove, ahk_id %hWin%,,,, % w+JigglePx, % h
        Sleep, 300
        WinMove, ahk_id %hWin%,,,, % w, % h
    }

    if (wasMin)
        DllCall("ShowWindow", "Ptr", hWin, "Int", 7)   ; SW_SHOWMINNOACTIVE - re-minimize without focus

    PingCount++
    FormatTime, ts,, HH:mm:ss
    Menu, Tray, Tip, % "XT KeepAlive - #" PingCount " @ " ts
return

FindXT() {
    global WinTitleMatch
    ; Chrome + Edge top-level windows both use class Chrome_WidgetWin_1
    WinGet, list, List, %WinTitleMatch% ahk_class Chrome_WidgetWin_1
    Loop, %list%
    {
        h := list%A_Index%
        WinGetPos,,, w, h2, ahk_id %h%
        if (w > 200 && h2 > 200)      ; real window, not a stub
            return h
    }
    return 0
}

GetRenderHwnd(hWin) {
    WinGet, ctrls, ControlListHwnd, ahk_id %hWin%
    Loop, Parse, ctrls, `n
    {
        WinGetClass, cls, ahk_id %A_LoopField%
        if (cls = "Chrome_RenderWidgetHostHWND")
            return A_LoopField
    }
    return 0
}

QuitScript:
    ExitApp
return