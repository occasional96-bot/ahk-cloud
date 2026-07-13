#NoEnv
#SingleInstance Force
SetBatchLines, -1

global UIA := UIA_Interface()
global lastVal := ""
global wasFocused := false
global busy := false
global resetRect := ""

SetTimer, WatchField, 150
SetTimer, CacheResetRect, 1000
return

#IfWinActive DMS - Google Chrome
$^v::
    DoResetPasteQuery(true)
return
#IfWinActive

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
        btn := root.FindFirstBy("AutomationId=button-1107")
        if btn
            resetRect := btn.CurrentBoundingRectangle
    }
return

FindField(root) {
    try return root.FindFirstBy("ControlType=Edit AND Name=Material code", 0x4, 2)
    return ""
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
        return
    busy := true

    part := Trim(Clipboard)
    if (part = "") {
        busy := false
        return
    }

    root := UIA.ElementFromHandle(WinExist("DMS - Google Chrome"))
    if !root {
        busy := false
        return
    }

    if (clickReset) {
        try {
            btn := root.FindFirstBy("AutomationId=button-1107")
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
        return
    }

    ; SetValue first; typing only as fallback if it doesn't stick
    ok := false
    Loop, 3 {
        fld := FindField(root)
        if !fld {
            Sleep, 200
            continue
        }
        try {
            fld.SetFocus()
            fld.GetCurrentPatternAs("Value").SetValue(part)
        }
        Loop, 6 {
            Sleep, 100
            if (GetFieldValue(root) = part) {
                ok := true
                break
            }
        }
        if ok
            break
        ; fallback: real keystrokes
        try fld.SetFocus()
        Sleep, 100
        SendInput, ^a
        Sleep, 50
        SendInput, {Raw}%part%
        Loop, 6 {
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
        return
    }

    Sleep, 200
    try {
        qbtn := root.FindFirstBy("AutomationId=button-1106")
        if qbtn
            ClickBtn(qbtn)
    }
    busy := false
}

WatchField:
    if (busy || !WinActive("DMS - Google Chrome"))
        return
    try focused := UIA.GetFocusedElement()
    catch
        return
    if (!focused || focused.CurrentControlType != 50004 || !InStr(focused.CurrentName, "Material code")) {
        lastVal := ""
        wasFocused := false
        return
    }
    try val := focused.CurrentValue
    catch
        return
    ; Just gained focus (e.g. double-click on existing text): baseline the
    ; current value WITHOUT firing - only changes made while focused count
    if !wasFocused {
        wasFocused := true
        lastVal := val
        return
    }
    if (val != lastVal && val != "") {
        clip := Trim(Clipboard)
        if (val = clip && RegExMatch(val, "^\d{8}-\d{2}$")) {
            Sleep, 100
            try {
                root := UIA.ElementFromHandle(WinExist("A"))
                btn := root.FindFirstBy("AutomationId=button-1106")
                if btn
                    ClickBtn(btn)
            }
        }
    }
    lastVal := val
return

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