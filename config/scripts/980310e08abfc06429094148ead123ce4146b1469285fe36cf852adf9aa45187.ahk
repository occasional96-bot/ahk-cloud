#SingleInstance, Force
DetectHiddenWindows, On
DetectHiddenText, On
SetTitleMatchMode, 2
SetNumLockState, AlwaysOn

NumLock::
ToolTip, Numlock
ERA_HomePage()
SendText(hCtl, "2525`r")
SendText(hCtl, "`rKI`rRO")
Sleep, 200
ToolTip
return

#IfWinActive ERA
; Parts Master 2102
^Numpad2::
ERA_HomePage()
SendText(hCtl, "2102`rKI`r")
return
#IfWinActive


#IfWinActive ERA
:://::
send,/KG{Enter}
return
#IfWinActive



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

;WinMove, ahk_id %hWnd%,,,, 820, 502

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

