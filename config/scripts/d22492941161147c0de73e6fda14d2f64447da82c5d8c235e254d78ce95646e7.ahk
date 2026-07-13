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
        btn := FindReset(root)
        if btn
            resetRect := btn.CurrentBoundingRectangle
    }
return

; ---------- element lookups: VISIBLE element first ----------
; ExtJS keeps old tabs' buttons hidden in the DOM; AutomationIds are per-tab.
; Name + IsOffscreen=0 always hits the button on the current screen.
FindReset(root) {
    btn := ""
    try btn := root.FindFirstBy("ControlType=Button AND Name=Reset AND IsOffscreen=0")
    if !btn
        try btn := root.FindFirstBy("ControlType=Button AND Name=Reset")
    return btn
}

FindQuery(root) {
    btn := ""
    try btn := root.FindFirstBy("ControlType=Button AND Name=Query AND IsOffscreen=0")
    if !btn
        try btn := root.FindFirstBy("ControlType=Button AND Name=Query")
    return btn
}

FindField(root) {
    fld := ""
    try fld := root.FindFirstBy("ControlType=Edit AND Name=Material code AND IsOffscreen=0", 0x4, 2)
    if !fld
        try fld := root.FindFirstBy("ControlType=Edit AND Name=Material code", 0x4, 2)
    return fld
}

GetFieldValue(root) {
    fld := FindField(root)
    if !fld
        return "<NOFIELD>"
    try return fld.CurrentValue
    return "<ERR>"
}

; ---------- border overlay ----------
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

; ---------- main flow ----------
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

    ShowBorder(root, "FFD400")   ; yellow = working

    needReset := true
    if (fast && GetFieldValue(root) = "")
        needReset := false

    if needReset {
        if (clickReset) {
            btn := FindReset(root)
            if btn
                ClickBtn(btn)
        }
        Sleep, 500   ; absorb ExtJS delayed reset wipe
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
        ; guard: field must stay empty; if the late wipe lands, wait it out
        Loop, 3 {
            Sleep, 100
            if (GetFieldValue(root) != "") {
                Loop, 20 {
                    Sleep, 100
                    if (GetFieldValue(root) = "")
                        break
                }
            }
        }
    }

    if !SetFieldValue(root, part) {
        ShowBorder(root, "FF3030")
        SetTimer, HideBorderTimer, -1500
        busy := false
        return
    }

    Sleep, 200
    FireQuery(root)

    ShowBorder(root, "22CC44")   ; green = success
    SetTimer, HideBorderTimer, -1200
    busy := false
}

; Hybrid set: SetValue head + type last char (fires ExtJS input event),
; full-typing fallback
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

; Mouse-free Query: Enter in the visible field, then focused-button Enter,
; then Invoke; physical click only as absolute last resort
FireQuery(root) {
    fld := FindField(root)
    if fld {
        try {
            fld.SetFocus()
            Sleep, 80
            SendInput, {Enter}
            return 1
        }
    }
    qbtn := FindQuery(root)
    if qbtn {
        try {
            qbtn.SetFocus()
            Sleep, 80
            SendInput, {Enter}
            return 1
        }
        try {
            qbtn.GetCurrentPatternAs("Invoke").Invoke()
            return 1
        }
        try {
            r := qbtn.CurrentBoundingRectangle
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
    }
    return 0
}

; ---------- watcher: manual typing + context-menu paste ----------
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

    ; paste into EMPTY box ("" -> clipboard value): instant Query
    if (lastVal = "" && val != "" && val = clip && validClip) {
        lastVal := val
        Sleep, 100
        try {
            root := UIA.ElementFromHandle(WinExist("DMS - Google Chrome"))
            FireQuery(root)
            ShowBorder(root, "22CC44")
            SetTimer, HideBorderTimer, -1200
        }
        return
    }

    ; paste ONTO old value (mixed text containing clipboard part):
    ; full reset + clean paste + query
    if (val != lastVal && lastVal != "<init>" && lastVal != "" && val != ""
        && val != clip && InStr(val, clip) && validClip) {
        lastVal := val
        DoResetPasteQuery(true, false)
        return
    }

    lastVal := val
return

; Background click: Invoke first, physical click fallback
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

; ============================================================
; UIA library below - paste your UIA_Interface_ChromeMin.ahk
; contents here, or replace this line with:
; #Include UIA_Interface.ahk
; ============================================================
