#NoEnv
#SingleInstance Force
SetBatchLines, -1

global UIA := UIA_Interface()
global lastVal := ""
global busy := false
global resetRect := ""

SetTimer, WatchField, 150
SetTimer, CacheResetRect, 1000
return

#IfWinActive DMS - Google Chrome
$^v::
    if !DoResetPasteQuery(true)
        SendInput, ^v   ; never swallow the paste - fall back to a normal Ctrl+V
return
#IfWinActive

; Global hook - works even when the click is what activates Chrome
~LButton::
    if busy
        return
    if !IsObject(resetRect)
        return
    CoordMode, Mouse, Screen
    MouseGetPos, mx, my, winUnderMouse
    WinGetTitle, t, ahk_id %winUnderMouse%
    if !InStr(t, "DMS - Google Chrome")
        return
    if (mx >= resetRect.l && mx <= resetRect.r && my >= resetRect.t && my <= resetRect.b) {
        WinActivate, ahk_id %winUnderMouse%
        Sleep, 100
        DoResetPasteQuery(false)
    }
return

CacheResetRect:
    if busy
        return
    if !WinExist("DMS - Google Chrome")
        return
    try {
        root := UIA.ElementFromHandle(WinExist("DMS - Google Chrome"))
        btn := FindBtn(root, "Reset", "button-1107")
        if btn
            resetRect := btn.CurrentBoundingRectangle
    }
return

FindField(root) {
    try return root.FindFirstBy("ControlType=Edit AND Name=Material code", 0x4, 2)
    return ""
}

; Name first (stable across sessions), ExtJS auto-id only as fallback -
; ids like button-1106 are regenerated per session and cannot be relied on
FindBtn(root, name, autoId) {
    btn := ""
    try btn := root.FindFirstBy("ControlType=Button AND Name=" name)
    if !btn
        try btn := root.FindFirstBy("AutomationId=" autoId)
    return btn
}

GetFieldValue(root) {
    fld := FindField(root)
    if !fld
        return "<NOFIELD>"
    try return fld.CurrentValue
    return "<ERR>"
}

DoResetPasteQuery(clickReset) {
    global UIA, busy
    if busy
        return 0
    busy := true

    part := Trim(Clipboard)
    if (part = "") {
        busy := false
        return 0
    }

    root := UIA.ElementFromHandle(WinExist("DMS - Google Chrome"))
    if !root {
        busy := false
        return 0
    }

    if (clickReset) {
        try {
            btn := FindBtn(root, "Reset", "button-1107")
            if btn
                ClickBtn(btn)
        }
    }

    Sleep, 1300   ; absorb ExtJS delayed reset wipe

    cleared := false
    Loop, 30 {
        if (GetFieldValue(root) = "") {
            cleared := true
            break
        }
        Sleep, 100
    }
    if !cleared {
        busy := false
        return 0
    }

    ; type as real keystrokes (no mouse) - ExtJS model needs key events
    ok := false
    Loop, 3 {
        fld := FindField(root)
        if !fld {
            Sleep, 200
            continue
        }
        try fld.SetFocus()
        Sleep, 150
        SendInput, ^a
        Sleep, 50
        SendInput, {Raw}%part%
        Loop, 8 {
            Sleep, 100
            if (GetFieldValue(root) = part) {
                ok := true
                break
            }
        }
        if ok
            break
    }
    if !ok {
        busy := false
        return 0
    }

    Sleep, 200
    try {
        qbtn := FindBtn(root, "Query", "button-1106")
        if qbtn
            ClickBtn(qbtn)
    }
    busy := false
    return 1
}

WatchField:
    if (busy || !WinActive("DMS - Google Chrome"))
        return
    try focused := UIA.GetFocusedElement()
    catch
        return
    if (!focused || focused.CurrentControlType != 50004 || !InStr(focused.CurrentName, "Material code")) {
        lastVal := ""
        return
    }
    try val := focused.CurrentValue
    catch
        return
    if (val != lastVal && val != "") {
        clip := Trim(Clipboard)
        if (val = clip && RegExMatch(val, "^\d{8}-\d{2}$")) {
            Sleep, 100
            try {
                root := UIA.ElementFromHandle(WinExist("A"))
                btn := FindBtn(root, "Query", "button-1106")
                if btn
                    ClickBtn(btn)
            }
        }
    }
    lastVal := val
return

; Invoke pattern (background, no mouse) with physical-click fallback
ClickBtn(el) {
    try {
        if el.GetCurrentPropertyValue(30031) {
            el.GetCurrentPatternAs("Invoke").Invoke()
            return 1
        }
    }
    try {
        r := el.CurrentBoundingRectangle
        if (r.r > r.l && r.b > r.t) {
            x := (r.l + r.r) // 2
            y := (r.t + r.b) // 2
            CoordMode, Mouse, Screen
            MouseGetPos, ox, oy
            Click, %x% %y%
            MouseMove, %ox%, %oy%, 0
            return 1
        }
    }
    return 0
}