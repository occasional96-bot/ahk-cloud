#MaxHotkeysPerInterval
#SingleInstance Force
SetTitleMatchMode, 2
SendMode Input
SetControlDelay, -1
SetBatchLines, -1
SetKeyDelay, -1
SetNumLockState, AlwaysOn

; --- Tray icon + menu ---------------------------------------------
;Menu, Tray, Icon, D:\Windows System\Work\8a16bd60-f9c6-49ed-aa0c-2f38d75403fe.jpg
Menu, Tray, Tip, NetumScanner
Menu, Tray, NoStandard
Menu, Tray, Add, Edit Substitutions, ShowSubsGui
Menu, Tray, Add
Menu, Tray, Add, Reload Script, ReloadScript
Menu, Tray, Add, Exit, ExitScript
Menu, Tray, Default, Edit Substitutions
; ------------------------------------------------------------------

; --- Substitutions storage ----------------------------------------
global SubsFile := A_ScriptDir . "\subs.csv"
global SubsMap := {}
global SelectedRow := 0

; ONE-TIME RESEED: delete old subs.csv on first run after this update
global SeedFlag := A_ScriptDir . "\.subs_seeded_v2"
if (!FileExist(SeedFlag)) {
    FileDelete, %SubsFile%
    FileAppend, , %SeedFlag%
}

LoadSubs()
; ------------------------------------------------------------------

global scannedValue := ""
global lastKeyTime := 0
global waiting := false

#InputLevel 1
$a::HandleKey("a"), return
$b::HandleKey("b"), return
$c::HandleKey("c"), return
$d::HandleKey("d"), return
$e::HandleKey("e"), return
$f::HandleKey("f"), return
$g::HandleKey("g"), return
$h::HandleKey("h"), return
$i::HandleKey("i"), return
$j::HandleKey("j"), return
$k::HandleKey("k"), return
$l::HandleKey("l"), return
$m::HandleKey("m"), return
$n::HandleKey("n"), return
$o::HandleKey("o"), return
$p::HandleKey("p"), return
$q::HandleKey("q"), return
$r::HandleKey("r"), return
$s::HandleKey("s"), return
$t::HandleKey("t"), return
$u::HandleKey("u"), return
$v::HandleKey("v"), return
$w::HandleKey("w"), return
$x::HandleKey("x"), return
$y::HandleKey("y"), return
$z::HandleKey("z"), return
$+a::HandleKey("A"), return
$+b::HandleKey("B"), return
$+c::HandleKey("C"), return
$+d::HandleKey("D"), return
$+e::HandleKey("E"), return
$+f::HandleKey("F"), return
$+g::HandleKey("G"), return
$+h::HandleKey("H"), return
$+i::HandleKey("I"), return
$+j::HandleKey("J"), return
$+k::HandleKey("K"), return
$+l::HandleKey("L"), return
$+m::HandleKey("M"), return
$+n::HandleKey("N"), return
$+o::HandleKey("O"), return
$+p::HandleKey("P"), return
$+q::HandleKey("Q"), return
$+r::HandleKey("R"), return
$+s::HandleKey("S"), return
$+t::HandleKey("T"), return
$+u::HandleKey("U"), return
$+v::HandleKey("V"), return
$+w::HandleKey("W"), return
$+x::HandleKey("X"), return
$+y::HandleKey("Y"), return
$+z::HandleKey("Z"), return
$0::HandleKey("0"), return
$1::HandleKey("1"), return
$2::HandleKey("2"), return
$3::HandleKey("3"), return
$4::HandleKey("4"), return
$5::HandleKey("5"), return
$6::HandleKey("6"), return
$7::HandleKey("7"), return
$8::HandleKey("8"), return
$9::HandleKey("9"), return
$-::HandleKey("-"), return
$/::HandleKey("/"), return
$.::HandleKey("."), return
$,::HandleKey(","), return
$+1::HandleKey("!"), return
$+2::HandleKey("@"), return
$+3::HandleKey("#"), return
$+4::HandleKey("$"), return
$+5::HandleKey("%"), return
$+6::HandleKey("^"), return
$+7::HandleKey("&"), return
$+8::HandleKey("*"), return
$+9::HandleKey("("), return
$+0::HandleKey(")"), return
$+`;::HandleKey(":"), return
$Space::HandleKey(" "), return

; -- QR code detector ----------------------------------------------
IsQRCode(val) {
    if (InStr(val, "http") || InStr(val, "://") || InStr(val, "\"))
        return true
    if (SubStr(val, 1, 1) = "&")
        return true
    if (StrLen(val) > 30)
        return true
    return false
}
; ------------------------------------------------------------------

; -- Part number substitutions (driven by subs.csv) ----------------
SubPart(val) {
    global SubsMap
    if (SubsMap.HasKey(val))
        return SubsMap[val]
    return val
}
; ------------------------------------------------------------------

; -- CSV load/save -------------------------------------------------
LoadSubs() {
    global SubsFile, SubsMap
    SubsMap := {}
    if (!FileExist(SubsFile)) {
        FileAppend, 766041657725`,6577WOR`r`n, %SubsFile%
        FileAppend, 766041657527`,KE75N1C8`r`n, %SubsFile%
        FileAppend, http://fqrct.com/t/6f748ff`,KIASANITISER`r`n, %SubsFile%
    }
    Loop, Read, %SubsFile%
    {
        line := A_LoopReadLine
        if (line = "")
            continue
        StringSplit, parts, line, `,
        if (parts0 >= 2) {
            key := Trim(parts1)
            val := Trim(parts2)
            if (key != "")
                SubsMap[key] := val
        }
    }
}

SaveSubs(rows) {
    global SubsFile
    FileDelete, %SubsFile%
    for index, row in rows {
        bc := Trim(row.barcode)
        pn := Trim(row.part)
        if (bc = "" && pn = "")
            continue
        FileAppend, %bc%`,%pn%`r`n, %SubsFile%
    }
    LoadSubs()
}
; ------------------------------------------------------------------

$Enter::
    now := A_TickCount
    timeSinceLast := now - lastKeyTime
    SetTimer, FlushBuffer, Off

    captured := SubPart(scannedValue)
    scannedValue := ""
    lastKeyTime := 0
    waiting := false

    if (captured != "" && timeSinceLast < 200) {
        if (IsQRCode(captured)) {
            return
        }
        if (SubStr(captured, 1, 2) = "RO") {
            ERA_HomePage()
            SendText(hCtl, "2525`r`r")
            SendText(hCtl, "KI`r")
            Sleep, 50
            SendInput, %captured%
            Sleep, 200
            SendText(hCtl, "`rKT`r")
            if (Clipboard = "RO") {
                SendText(hCtl, "DO`r`r")
            } else {
                SendText(hCtl, "`r`r")
            }
            Clipboard := SaveClipBorad
        } else {

            IfWinNotActive, ERA Port
            {
                WinActivate, ERA Port
                WinWaitActive, ERA Port
                Array := StrSplit(captured , " ")
                ERA_HomePage()
                SendText(hCtl, "2102`r")
                SendText(hCtl, "NG`r")
                Sleep, 100
                SendInput, % Array[1]
                Sleep, 100
                SendText(hCtl, "`r")
                return
            }
            SendInput, %captured%
            sleep, 125
            SendInput, {Enter}
        }
    } else if (captured != "") {
        MsgBox, Typed input (too slow for scanner):`n`n%captured%
    } else {
        SendInput {Enter}
    }
return

$Esc::
    SetTimer, FlushBuffer, Off
    if (scannedValue != "") {
        SendInput % scannedValue
        scannedValue := ""
    }
    waiting := false
    SendInput {Escape}
return

HandleKey(k) {
    global scannedValue, lastKeyTime, waiting
    now := A_TickCount
    timeSinceLast := now - lastKeyTime
    scannedValue .= k
    lastKeyTime := now
    if (!waiting) {
        waiting := true
        SetTimer, FlushBuffer, -30
    } else {
        SetTimer, FlushBuffer, -30
    }
}

FlushBuffer:
    global scannedValue, lastKeyTime, waiting
    now := A_TickCount
    timeSinceLast := now - lastKeyTime
    if (timeSinceLast >= 28 && scannedValue != "") {
        if (IsQRCode(scannedValue)) {
            scannedValue := ""
            lastKeyTime := 0
            waiting := false
            return
        }
        SendInput % scannedValue
        scannedValue := ""
        lastKeyTime := 0
        waiting := false
    }
return

;====================================================================================
; --- Substitutions GUI (native, single window, inline edit) -------
ShowSubsGui:
    Gui, Subs:Destroy
    SelectedRow := 0
    Gui, Subs:Margin, 10, 10
    Gui, Subs:Font, s9, Segoe UI

    Gui, Subs:Add, Text, x10 y8 w400, Part substitutions  (click row to edit below)

    Gui, Subs:Add, ListView, x10 y26 w420 h150 vSubsLV gSubsLV_Event AltSubmit -Multi, Barcode|Part Number
    LV_ModifyCol(1, 240)
    LV_ModifyCol(2, 170)

    for key, val in SubsMap {
        LV_Add("", key, val)
    }

    Gui, Subs:Add, Text, x10 y184 w70, Barcode:
    Gui, Subs:Add, Edit, x80 y181 w350 vEditBarcode,
    Gui, Subs:Add, Text, x10 y210 w70, Part #:
    Gui, Subs:Add, Edit, x80 y207 w350 vEditPart,

    Gui, Subs:Add, Button, x10  y238 w70 h26 gSubsApply,     Add / Update
    Gui, Subs:Add, Button, x84  y238 w70 h26 gSubsDeleteRow, Delete
    Gui, Subs:Add, Button, x158 y238 w50 h26 gSubsClear,     Clear
    Gui, Subs:Add, Button, x278 y238 w70 h26 gSubsCancel,    Cancel
    Gui, Subs:Add, Button, x352 y238 w78 h26 gSubsSave Default, Save

    Gui, Subs:Show, w440 h274, NetumScanner - Substitutions
return

SubsLV_Event:
    if (A_GuiEvent = "I") {
        row := LV_GetNext(0, "F")
        if (!row)
            return
        SelectedRow := row
        LV_GetText(bc, row, 1)
        LV_GetText(pn, row, 2)
        GuiControl, Subs:, EditBarcode, %bc%
        GuiControl, Subs:, EditPart, %pn%
    }
return

SubsApply:
    Gui, Subs:Submit, NoHide
    bc := Trim(EditBarcode)
    pn := Trim(EditPart)
    if (bc = "" || pn = "") {
        MsgBox, 48, Missing data, Both fields required.
        return
    }
    ; if barcode already exists in list, update that row; else add new
    found := 0
    Loop % LV_GetCount() {
        LV_GetText(existing, A_Index, 1)
        if (existing = bc) {
            LV_Modify(A_Index, "", bc, pn)
            found := 1
            break
        }
    }
    if (!found)
        LV_Add("", bc, pn)
    GuiControl, Subs:, EditBarcode,
    GuiControl, Subs:, EditPart,
    SelectedRow := 0
return

SubsDeleteRow:
    row := LV_GetNext(0, "F")
    if (!row) {
        MsgBox, 48, No selection, Select a row first.
        return
    }
    LV_Delete(row)
    GuiControl, Subs:, EditBarcode,
    GuiControl, Subs:, EditPart,
    SelectedRow := 0
return

SubsClear:
    GuiControl, Subs:, EditBarcode,
    GuiControl, Subs:, EditPart,
    SelectedRow := 0
return

SubsCancel:
SubsGuiClose:
SubsGuiEscape:
    Gui, Subs:Destroy
return

SubsSave:
    rows := []
    Loop % LV_GetCount() {
        LV_GetText(bc, A_Index, 1)
        LV_GetText(pn, A_Index, 2)
        rows.Push({barcode: bc, part: pn})
    }
    SaveSubs(rows)
    Gui, Subs:Destroy
    Reload
return

ReloadScript:
    Reload
return

ExitScript:
    ExitApp
return
;====================================================================================

ERA_Activate() {
WinActivate, ERA Port
WinWaitActive, ERA Port

global hWnd
global hCtl

hWnd := WinExist("ERA Port")
Sleep, 100

ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%
if (!hCtl) {
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
}

    text := "C:\Program Files (x86)\PowerLink\image\i_pageb.bmp"
    ControlClick , Button18, ahk_id %hWnd%, %text%, Left, 1, NA
}

ERA_HomePage(){
WinActivate, ERA Port
WinWaitActive, ERA Port

global hWnd
global hCtl

hWnd := WinExist("ERA Port")
Sleep, 100

ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%
if (!hCtl) {
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
}

text := "C:\Program Files (x86)\PowerLink\image\i_pageb.bmp"
ControlClick , Button18, ahk_id %hWnd%, %text%, Left, 1, NA

Loop 13
    SendKey(hCtl, 0x08)

Loop, 1
    SendKey(hCtl, 0x71)

Loop, 2
    SendKey(hCtl, 0x70)

Loop, 3
    SendText(hCtl, "END`r")

Sleep, 250
WinGet, hwnd, ID,, No previous menu
PostMessage, 0x10,, , , ahk_id %hwnd%
}

SendText_Variable(hwnd, text) {
    Loop, Parse, text
    {
        SendCharToControl(hwnd, A_LoopField)
    }
    Sleep, 100
}

SendKey(hwnd, vk) {
    WM_KEYDOWN := 0x100
    WM_KEYUP := 0x101
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_KEYDOWN, "Ptr", vk, "Ptr", 0)
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_KEYUP, "Ptr", vk, "Ptr", 0)
}

SendText(hwnd, text) {
    Loop, Parse, text
    {
        SendCharToControl(hwnd, A_LoopField)
    }
    Sleep, 150
}

SendCharToControl(hwnd, char) {
    WM_CHAR := 0x102
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_CHAR, "Ptr", Asc(char), "Ptr", 0)
}

SendCtrlKey_DLL(key) {
    DllCall("keybd_event", "UChar", 0x11, "UChar", 0x1D, "UInt", 0, "Ptr", 0)
    SendKey_DLL(key)
    DllCall("keybd_event", "UChar", 0x11, "UChar", 0x1D, "UInt", 2, "Ptr", 0)
}

SendAltKey_DLL(key) {
    DllCall("keybd_event", "UChar", 0x12, "UChar", 0x38, "UInt", 0, "Ptr", 0)
    SendKey_DLL(key)
    DllCall("keybd_event", "UChar", 0x12, "UChar", 0x38, "UInt", 2, "Ptr", 0)
}

SendKey_DLL(key) {
    vk := GetKeyVK(key)
    sc := GetKeySC(key)
    DllCall("keybd_event", "UChar", vk, "UChar", sc, "UInt", 0, "Ptr", 0)
    DllCall("keybd_event", "UChar", vk, "UChar", sc, "UInt", 2, "Ptr", 0)
}
