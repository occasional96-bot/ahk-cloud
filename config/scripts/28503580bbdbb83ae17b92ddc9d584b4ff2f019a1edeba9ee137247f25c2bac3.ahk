F9::
global hWnd
global hCtl

ERA_HomePage()
Sleep, 150
SendText(hCtl, "2119`r")
Sleep, 150
SendText(hCtl, "NG`r")
Sleep, 100
MsgBox,4,, Continue?
IfMsgBox, Yes
    Goto, Post_Transaction
IfMsgBox, No
    Return

; =============================
; RAW DATA (CSV STYLE)
; =============================
Post_Transaction:
rawData := Clipboard

if (rawData = "") {
    MsgBox, 48, No Data, Clipboard is empty! Please copy CSV data first.
    Return
}

; =============================
; GUI
; =============================
Gui, Font, s10, Segoe UI
Gui, Add, ListView, x10 y10 w560 h260 Grid AltSubmit vLV
    , Make|Part Number|Sys Qty|Old Bin|New Bin
Gui, Add, Button, x10  y280 w140 h30 gSendAll vSendAllBtn, Send All to ERA
Gui, Add, Button, x160 y280 w140 h30 gSendSelected, Send Selected
Gui, Add, Button, x310 y280 w140 h30 gCopySelected, Copy Row
Gui, Add, Button, x460 y280 w110 h30 gGuiCloseBIN, Exit
Gui, Add, Text, x10 y320 w660 h20 vStatusText, Ready

; =============================
; PARSE DATA
; =============================
Loop, Parse, rawData, `n, `r
{
    if (A_Index = 1 || A_LoopField = "")
        continue

    fields := CSV_ParseLine2(A_LoopField)

    make    := Trim(fields[1])
    partNum := Trim(fields[2])
    sysQty  := Trim(fields[3])
    oldBin  := Trim(fields[4])
    newBin  := Trim(fields[5])

    LV_Add("", make, partNum, sysQty, oldBin, newBin)
}

LV_ModifyCol()
LV_ModifyCol(1, 50)   ; Make
LV_ModifyCol(2, 130)  ; Part
LV_ModifyCol(3, 80)   ; Qty
LV_ModifyCol(4, 80)   ; Old Bin
LV_ModifyCol(5, 80)   ; New Bin

Gui, Show, x291 y124 w580, ERA Bin Update Sender
GuiControl, Focus, SendAllBtn

Sleep, 200
WinWaitActive, ERA Bin Update Sender
Send, {Right}{Left}
Return

; =============================
; SEND ALL ROWS
; =============================
SendAll:
totalRows := LV_GetCount()
processed := 0

Loop, %totalRows%
{
    row := A_Index

    LV_GetText(make,    row, 1)
    LV_GetText(partNum, row, 2)
    LV_GetText(newBin,  row, 5)

    GuiControl,, StatusText
        , Processing %row%/%totalRows% ? %make% %partNum% ? %newBin%

    SendToERA2(make, partNum, newBin)
    processed++
    Sleep, 500
}

GuiControl,, StatusText, Complete! Processed: %processed%
MsgBox, 64, Complete, Finished processing!`nProcessed: %processed%
Return

; =============================
; SEND SELECTED ROW
; =============================
SendSelected:
row := LV_GetNext()
if (!row) {
    MsgBox, 48, No Selection, Please select a row first.
    Return
}

LV_GetText(make,    row, 1)
LV_GetText(partNum, row, 2)
LV_GetText(newBin,  row, 5)

GuiControl,, StatusText, Sending ? %make% %partNum%
SendToERA2(make, partNum, newBin)
GuiControl,, StatusText, Sent ? %make% %partNum%
Return

; =============================
; COPY ROW
; =============================
CopySelected:
row := LV_GetNext()
if (!row)
    Return

LV_GetText(make,    row, 1)
LV_GetText(partNum, row, 2)
LV_GetText(sysQty,  row, 3)
LV_GetText(oldBin,  row, 4)
LV_GetText(newBin,  row, 5)

Clipboard := make "," partNum "," sysQty "," oldBin "," newBin
GuiControl,, StatusText, Copied: %make% %partNum%
Return

; =============================
; CORE ERA SEND LOGIC
; =============================
SendToERA2(make, partNum, newBin)
{
    global hCtl
    ERA_Activate()

    make    := Trim(make)
    partNum := Trim(partNum)
    newBin  := Trim(newBin)

    ; --- SEND MAKE ---
    SendText(hCtl, "=" make)
    Sleep, 50
    SendText(hCtl, "`r")
    Sleep, 100

    ; --- SEND PART NUMBER ---
    SendText(hCtl, "." partNum)
    Sleep, 50
    SendText(hCtl, "`r")
    Sleep, 100

    ; --- SEND NEW BIN ---
    SendText(hCtl, newBin)
    Sleep, 50
    SendText(hCtl, "`r`r")
    Sleep, 100
}


; =============================
; CSV PARSER (HANDLES QUOTES)
; =============================
CSV_ParseLine2(line)
{
    arr := []
    field := ""
    inQuotes := false
    Loop, Parse, line
    {
        char := A_LoopField
        if (char = """")
        {
            inQuotes := !inQuotes
            continue
        }
        if (char = "," && !inQuotes)
        {
            arr.Push(field)
            field := ""
        }
        else
            field .= char
    }
    arr.Push(field)
    return arr
}
return

GuiCloseBIN:
WinClose, ERA Bin Update Sender
return


F10::
global hWnd
global hCtl

ERA_HomePage()
Sleep, 150
SendText(hCtl, "2010`r`r")
Sleep, 150
SendText(hCtl, "NG")
SendText(hCtl, "`r`rKT`r`r`r")
SendText(hCtl, "STK ADJ`r")
Sleep, 100
MsgBox,4,, Continue?
ifMsgBox, Yes
Goto, Post_Transaction1

ifMsgBox, No
	return
; =============================
; RAW DATA (CSV STYLE)
; =============================
Post_Transaction1:
rawData := Clipboard

; Check if clipboard has data
if (rawData = "") {
    MsgBox, 48, No Data, Clipboard is empty! Please copy CSV data first.
    ExitApp
}

; =============================
; GUI
; =============================
Gui, Font, s10, Segoe UI
Gui, Add, ListView, x10 y10 w560 h260 Grid AltSubmit vLV, Bin|Type|Make|Part Number|Description|Difference
Gui, Add, Button, x10 y280 w140 h30 gSendAll2 vSendAllBtn, Send All to ERA
Gui, Add, Button, x160 y280 w140 h30 gSendSelected2, Send Selected
Gui, Add, Button, x310 y280 w140 h30 gCopySelected2, Copy Row
Gui, Add, Button, x740 y280 w150 h30 gGuiClose, Exit
Gui, Add, Text, x10 y320 w880 h20 vStatusText, Ready

; =============================
; PARSE DATA
; =============================
Loop, Parse, rawData, `n, `r
{
    if (A_Index = 1 || A_LoopField = "")
        continue
    fields := CSV_ParseLine(A_LoopField)
    bin         := fields[1]
    type        := fields[2]
    make        := fields[3]
    part        := fields[4]
    desc        := fields[5]
    diff        := fields[8]
    LV_Add("", bin, type, make, part, desc, diff)
}
LV_ModifyCol()
LV_ModifyCol(1, 65)
LV_ModifyCol(2, 60)
LV_ModifyCol(3, 50)
LV_ModifyCol(4, 110)
LV_ModifyCol(5, 200)  ; Description column
LV_ModifyCol(6, 75)  ; Description column
Gui, Show,x291 y124 w580, ERA Stock Adjustment Sender

; Set focus to Send All button
GuiControl, Focus, SendAllBtn
Sleep, 200
WinWaitActive, ERA Stock Adjustment Sender
Send, {Right}{Left}
Return

; =============================
; SEND ALL ROWS
; =============================
SendAll2:
totalRows := LV_GetCount()
processed := 0
skipped := 0

Loop, %totalRows%
{
    currentRow := A_Index

    ; Get row data
    LV_GetText(bin, currentRow, 1)
    LV_GetText(make, currentRow, 3)
    LV_GetText(part, currentRow, 4)
    LV_GetText(diff, currentRow, 6)

    ; Update status
    GuiControl,, StatusText, Processing %currentRow% of %totalRows%: %bin% - %part%

    ; Skip if difference is 0
    if (diff = "0") {
        skipped++
        continue
    }

    ; Send to ERA
    SendToERA(make, part, diff)
    processed++

    ; Delay between entries
    Sleep, 500
}

GuiControl,, StatusText, Complete! Processed: %processed% | Skipped: %skipped%
MsgBox, 64, Complete, Finished processing!`n`nProcessed: %processed%`nSkipped: %skipped%
Return

; =============================
; SEND SELECTED ROW
; =============================
SendSelected2:
Row := LV_GetNext()
if (!Row) {
    MsgBox, 48, No Selection, Please select a row first.
    Return
}
LV_GetText(make, Row, 3)
LV_GetText(part, Row, 4)
LV_GetText(diff, Row, 6)

if (diff = "0") {
    MsgBox, 48, No Adjustment Needed, This item has no difference (0).
    Return
}

GuiControl,, StatusText, Sending: %part%
SendToERA(make, part, diff)
GuiControl,, StatusText, Sent: %part%
Return

; =============================
; COPY ROW
; =============================
CopySelected2:
Row := LV_GetNext()
if (!Row)
    Return
LV_GetText(bin, Row, 1)
LV_GetText(type, Row, 2)
LV_GetText(make, Row, 3)
LV_GetText(part, Row, 4)
LV_GetText(desc, Row, 5)
LV_GetText(diff, Row, 6)
Clipboard := bin "," type "," make "," part "," desc "," diff
GuiControl,, StatusText, Copied: %part%
Return

; =============================
; CORE ERA SEND LOGIC
; =============================
SendToERA(make, part, diff)
{
    ERA_Activate()

    ; --- SEND MAKE CODE ---
    SendText(hCtl, "=" . make)
    Sleep, 50
    SendText(hCtl, "`r")
    Sleep, 50

    ; --- PART NUMBER ---
    SendText(hCtl, "." . part)
    Sleep, 50
    SendText(hCtl, "`r")
    Sleep, 50

    ; --- DIFFERENCE ---
    if InStr(diff, "-")
    {
        Min := StrSplit(diff, "-")
        SendText(hCtl, Min[2])
        Sleep, 50
        SendText(hCtl, "`r")
        Sleep, 50
        SendText(hCtl, "SM")
        Sleep, 50
        SendText(hCtl, "`r")
        Sleep, 50
    }
    else if InStr(diff, "+")
    {
        plus := StrSplit(diff, "+")
        SendText(hCtl, plus[2])
        Sleep, 50
        SendText(hCtl, "`r")
        Sleep, 50
        SendText(hCtl, "SA")
        Sleep, 50
        SendText(hCtl, "`r")
        Sleep, 50
    }
}


; =============================
; CSV PARSER (HANDLES QUOTES)
; =============================
CSV_ParseLine(line)
{
    arr := []
    field := ""
    inQuotes := false
    Loop, Parse, line
    {
        char := A_LoopField
        if (char = """")
        {
            inQuotes := !inQuotes
            continue
        }
        if (char = "," && !inQuotes)
        {
            arr.Push(field)
            field := ""
        }
        else
            field .= char
    }
    arr.Push(field)
    return arr
}
return
GuiClose:
WinClose, ERA Stock Adjustment Sender
return

ERA_Activate() {
WinActivate, ERA Port
WinWaitActive, ERA Port

global hWnd
global hCtl

hWnd := WinExist("ERA Port")
Sleep, 100

; Try the first control
ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%

; If not found, try the second control
if (!hCtl) {
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
}


	WinMove, ahk_id %hWnd%,,,, 820, 502
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

; Try the first control
ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%

; If not found, try the second control
if (!hCtl) {
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
}

;MsgBox, % "Final hCtl = " hCtl

text := "C:\Program Files (x86)\PowerLink\image\i_pageb.bmp"
ControlClick , Button18, ahk_id %hWnd%, %text%, Left, 1, NA

WinMove, ahk_id %hWnd%,,,, 820, 502

Loop 13
	SendKey(hCtl, 0x08) ; Backspace = 0x08

Loop, 1
	SendKey(hCtl, 0x71) ; F2 = 0x71

Loop, 2
    SendKey(hCtl, 0x70) ; F1 = 0x70

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

SendKey(hwnd, vk) { ; Send a virtual key (like F11)
    WM_KEYDOWN := 0x100
    WM_KEYUP := 0x101

    ; Key Down
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_KEYDOWN, "Ptr", vk, "Ptr", 0)
    ; Key Up
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_KEYUP, "Ptr", vk, "Ptr", 0)
}

/* Function Key Virtual-Key (VK) Codes
Key	VK Code (Hex)
F1	0x70	112
F2	0x71	113
F3	0x72	114
F4	0x73	115
F5	0x74	116
F6	0x75	117
F7	0x76	118
F8	0x77	119
F9	0x78	120
F10	0x79	121
F11	0x7A	122
F12	0x7B	123
F13	0x7C	124
F14	0x7D	125
F15	0x7E	126
F16	0x7F	127
F17	0x80	128
F18	0x81	129
F19	0x82	130
F20	0x83	131
F21	0x84	132
F22	0x85	133
F23	0x86	134
F24	0x87	135
*/

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
    ; Press CTRL
    DllCall("keybd_event", "UChar", 0x11, "UChar", 0x1D, "UInt", 0, "Ptr", 0)

    ; Press the key
    SendKey_DLL(key)

    ; Release CTRL
    DllCall("keybd_event", "UChar", 0x11, "UChar", 0x1D, "UInt", 2, "Ptr", 0)
}



SendAltKey_DLL(key) {
    ; Press ALT
    DllCall("keybd_event", "UChar", 0x12, "UChar", 0x38, "UInt", 0, "Ptr", 0)

    ; Press key
    SendKey_DLL(key)

    ; Release ALT
    DllCall("keybd_event", "UChar", 0x12, "UChar", 0x38, "UInt", 2, "Ptr", 0)
}

SendKey_DLL(key) {
    vk := GetKeyVK(key)
    sc := GetKeySC(key)
    DllCall("keybd_event", "UChar", vk, "UChar", sc, "UInt", 0, "Ptr", 0)
    DllCall("keybd_event", "UChar", vk, "UChar", sc, "UInt", 2, "Ptr", 0)
}


F12::
Reload
return

