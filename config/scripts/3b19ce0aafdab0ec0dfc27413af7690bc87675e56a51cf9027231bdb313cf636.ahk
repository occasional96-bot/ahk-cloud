#NoEnv
#SingleInstance Force
SetBatchLines, -1

global UIA := UIA_Interface()
global lastVal := "<init>"
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

; ---------- Border overlay (4 thin always-on-top strips) ----------
ShowBorder(root, color) {
    global
    local fld, r, x, y, w, h, th
    fld := FindField(root)
    if !fld
        return
    try r := fld.CurrentBoundingRectangle
    catch
        return
    x := r.l - 3, y := r.t - 3
    w := (r.r - r.l) + 6, h := (r.b - r.t) + 6
    th := 3   ; thickness
    Loop, 4 {
        Gui, Border%A_Index%: Destroy
        Gui, Border%A_Index%: +AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound
        Gui, Border%A_Index%: Color, %color%
    }
    Gui, Border1: Show, % "x" x " y" y " w" w " h" th " NA"                 ; top
    Gui, Border2: Show, % "x" x " y" (y+h-th) " w" w " h" th " NA"          ; bottom
    Gui, Border3: Show, % "x" x " y" y " w" th " h" h " NA"                 ; left
    Gui, Border4: Show, % "x" (x+w-th) " y" y " w" th " h" h " NA"          ; right
}

HideBorder() {
    Loop, 4
        Gui, Border%A_Index%: Destroy
}

HideBorderTimer:
    HideBorder()
return
; -------------------------------------------------------------------

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

    ; YELLOW = working
    ShowBorder(root, "FFD400")

    if (clickReset) {
        try {
            btn := root.FindFirstBy("AutomationId=button-1107")
            if btn
                ClickBtn(btn)
        }
    }

    Sleep, 1300

    cleared := false
    Loop, 30 {
        if (GetFieldValue(root) = "") {
            cleared := true
            break
        }
        Sleep, 100
    }
    if !cleared {
        ShowBorder(root, "FF3030")   ; red = failed
        SetTimer, HideBorderTimer, -1500
        busy := false
        return
    }

    ; hybrid set: SetValue head + type last char
    ok := false
    head := SubStr(part, 1, StrLen(part)-1)
    tail := SubStr(part, 0)
    Loop, 3 {
        fld := FindField(root)
        if !fld {
            Sleep, 200
            continue
        }
        try {
            fld.SetFocus()
            Sleep, 100
            fld.GetCurrentPatternAs("Value").SetValue(head)
            Sleep, 100
            SendInput, {End}
            SendInput, {Raw}%tail%
        }
        Loop, 8 {
            Sleep, 100
            if (GetFieldValue(root) = part) {
                ok := true
                break
            }
        }
        if ok
            break
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
        ShowBorder(root, "FF3030")   ; red = failed
        SetTimer, HideBorderTimer, -1500
        busy := false
        return
    }

    Sleep, 200
    try {
        qbtn := root.FindFirstBy("AutomationId=button-1106")
        if qbtn
            ClickBtn(qbtn)
    }

    ; GREEN = success, auto-hide after 1.2s
    ShowBorder(root, "22CC44")
    SetTimer, HideBorderTimer, -1000
    busy := false
}

WatchField:
    if (busy || !WinActive("DMS - Google Chrome"))
        return
    try focused := UIA.GetFocusedElement()
    catch
        return
    if (!focused || focused.CurrentControlType != 50004 || !InStr(focused.CurrentName, "Material code")) {
        lastVal := "<init>"
        return
    }
    try val := focused.CurrentValue
    catch
        return
    if (lastVal = "" && val != "") {
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