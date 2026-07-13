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
    DoResetPasteQuery(true, true)
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
        DoResetPasteQuery(false, false)
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
    th := 3
    Loop, 4 {
        Gui, Border%A_Index%: Destroy
        Gui, Border%A_Index%: +AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound
        Gui, Border%A_Index%: Color, %color%
    }
    Gui, Border1: Show, % "x" x " y" y " w" w " h" th " NA"
    Gui, Border2: Show, % "x" x " y" (y+h-th) " w" w " h" th " NA"
    Gui, Border3: Show, % "x" x " y" y " w" th " h" h " NA"
    Gui, Border4: Show, % "x" (x+w-th) " y" y " w" th " h" h " NA"
}

HideBorder() {
    Loop, 4
        Gui, Border%A_Index%: Destroy
}

HideBorderTimer:
    HideBorder()
return

DoResetPasteQuery(clickReset, fast) {
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

    ShowBorder(root, "FFD400")

    needReset := true
    if (fast && GetFieldValue(root) = "")
        needReset := false

    if needReset {
        if (clickReset) {
            try {
                btn := root.FindFirstBy("AutomationId=button-1107")
                if btn
                    ClickBtn(btn)
            }
        }
        Sleep, 500
        cleared := false
        Loop, 30 {
            if (GetFieldValue(root) = "") {
                cleared := true
                break
            }
            Sleep, 100
        }
        if !cleared {
            ShowBorder(root, "FF3030")
            SetTimer, HideBorderTimer, -1500
            busy := false
            return
        }
    }

    ok := SetFieldValue(root, part)
    if !ok {
        ShowBorder(root, "FF3030")
        SetTimer, HideBorderTimer, -1500
        busy := false
        return
    }

    Sleep, 200
    FireQuery(root)

    ShowBorder(root, "22CC44")
    SetTimer, HideBorderTimer, -1200
    busy := false
}

; Hybrid set: SetValue head + type last char, with full-typing fallback
SetFieldValue(root, part) {
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
            if (GetFieldValue(root) = part)
                return 1
        }
        try fld.SetFocus()
        Sleep, 100
        SendInput, ^a
        Sleep, 50
        SendInput, {Raw}%part%
        Loop, 6 {
            Sleep, 100
            if (GetFieldValue(root) = part)
                return 1
        }
    }
    return 0
}

FireQuery(root) {
    try {
        qbtn := root.FindFirstBy("AutomationId=button-1106")
        if qbtn {
            ClickBtn(qbtn)
            return 1
        }
    }
    return 0
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
    clip := Trim(Clipboard)
    validClip := RegExMatch(clip, "^\d{8}-\d{2}$")

    ; Context paste into EMPTY box: value goes "" -> clipboard -> just Query
    if (lastVal = "" && val != "" && val = clip && validClip) {
        lastVal := val
        Sleep, 100
        try {
            root := UIA.ElementFromHandle(WinExist("A"))
            FireQuery(root)
            ShowBorder(root, "22CC44")
            SetTimer, HideBorderTimer, -1200
        }
        return
    }

    ; Context paste ONTO an old value: value changed, now contains clipboard
    ; mixed with old text -> run full reset+paste+query flow
    if (val != lastVal && lastVal != "<init>" && lastVal != "" && val != ""
        && val != clip && InStr(val, clip) && validClip) {
        lastVal := val
        DoResetPasteQuery(true, false)
        return
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