#SingleInstance, force

Menu, MyMenu, Add, Invoices Update - Warehouse PRO, INVwarehousepro
Menu, MyMenu, Add, Location Update - Stocktake PRO, Stocktakeloccount
Menu, MyMenu, Add, Reload, Reloading

MButton::
Menu, MyMenu, Show
return

Reloading:
Reload
return

INVwarehousepro:
    ExportAndUpload("/04E-INVOICE-SCAN-APP", "04E-INVOICE-SCAN-APP Data.csv")
return

Stocktakeloccount:
    ExportAndUpload("/02-KAINE-LOCATION KIA IUA BYD", "02-KAINE-LOCATION KIA IUA BYD Data.csv")
return

;====================================================================================

ExportAndUpload(eraQuery, csvName) {
    global hCtl
    url := "https://csv-server-production-efc6.up.railway.app/upload"
    csvFile := "C:\Users\" . A_UserName . "\OneDrive - Hopper Motor Group\Documents\PSdata\" . csvName

    preTime := FileExist(csvFile) ? FileGetTimeMod(csvFile) : ""

    if !WinExist("ERA Port")
        return Fail("ERA Port window not found. Is ERA open?")
    ERA_Activate()
    ERA_HomePage()
    if !hCtl
        return Fail("ERA control handle not found after HomePage.")

    SendText(hCtl, "6913`r")
    SendText(hCtl, eraQuery . "`r")
    SendText(hCtl, "o")
    SendText(hCtl, "4")
    SendText(hCtl, "`r")
    SendText(hCtl, "`r")
    SendText(hCtl, "`r")

    if !WaitAndSend("PC destination format", "ListBox1", "{Enter}", 3)
        return
    if !WaitAndSend("Select the destination file for the ERA data", "Button2", "{Enter}", 3)
        return
    if !WaitAndSend("Confirm Save As", "Button1", "{Left}{Enter}", 3)
        return

    ; --- Non-fatal monitor wait (may flash too fast to catch) ---
    WinWaitActive, File Import Monitor,, 10
    if !ErrorLevel
        WinWaitNotActive, File Import Monitor,, 60

    ; --- Confirm export by polling for a fresh CSV (source of truth) ---
    fresh := false
    Loop, 60 {
        if FileExist(csvFile) {
            if (preTime == "" || FileGetTimeMod(csvFile) != preTime) {
                fresh := true
                break
            }
        }
        Sleep, 1000
    }
    if !fresh
        return Fail("CSV not updated within 60s (export may have failed):`n" . csvFile)
    Sleep, 500  ; let file finish flushing

    if !UploadFile(csvFile, url, 3)
        return

    MsgBox, 64, Done!, Uploaded successfully!`n%csvName%
    WinActivate, ERA
    Sleep, 200
    Send,{F1}
    return true
}

WaitAndSend(winTitle, control, keys, timeout) {
    WinWait, %winTitle%,, %timeout%
    if ErrorLevel
        return Fail("Window not found within " . timeout . "s:`n" . winTitle)
    Sleep, 500
    ControlSend, %control%, %keys%, %winTitle%
    if ErrorLevel
        return Fail("ControlSend failed on '" . control . "' in:`n" . winTitle)
    return true
}

UploadFile(file, url, maxTries) {
    resultFile := A_Temp . "\csv_upload_result.txt"
    Loop, %maxTries% {
        cmd := "curl -s --max-time 60 -F ""file=@" . file . """ " . url
        RunWait, %ComSpec% /c %cmd% > "%resultFile%" 2>&1,, Hide
        result := ""
        FileRead, result, %resultFile%
        if InStr(result, "Uploaded successfully")
            return true
        if (A_Index < maxTries)
            Sleep, 2000
    }
    return Fail("Upload failed after " . maxTries . " attempts:`n" . file . "`n`n" . result)
}

FileGetTimeMod(path) {
    FileGetTime, t, %path%, M
    return t
}

Fail(msg) {
    MsgBox, 48, Error, %msg%
    return false
}

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

