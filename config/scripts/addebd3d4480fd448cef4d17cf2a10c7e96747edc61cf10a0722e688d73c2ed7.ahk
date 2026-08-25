#NoEnv
#SingleInstance, Force
#InstallMouseHook
SetBatchLines, -1
SetTitleMatchMode, 2


; ==================================================================================================
; MIDDLE MOUSE BUTTON MENU
; ==================================================================================================

Menu, MyMenu, Add
Menu, MyMenu, Add, Quote List Export - Shaun, QuoteListExport
Menu, MyMenu, Add, Trade Customers Export - Shaun, TradeCustomersExport
Menu, MyMenu, Add, RoadWorthy Vehicle - Shaun, RoadWorthyVehicleExport
Menu, MyMenu, Add
Menu, MyMenu, Add, Invoices Update - Warehouse PRO, INVwarehousepro
Menu, MyMenu, Add, Location Update - Stocktake PRO, Stocktakeloccount

return


; ==================================================================================================
; MIDDLE MOUSE BUTTON
; ==================================================================================================

$MButton::
    Menu, MyMenu, Show
return


; ==================================================================================================
; SHAUN EXPORTS
; ==================================================================================================

QuoteListExport:
    ExportOnly("/KAINET-QUOTE-LIST", "KAINET-QUOTE-LIST Data.csv")
return


TradeCustomersExport:
    ExportOnly("/05A-PARTS-TRADE-CUSTOMERS", "05A-PARTS-TRADE-CUSTOMERS Data.csv")
return


RoadWorthyVehicleExport:
    ExportOnly("/04R-ROADWORTHY-VEHICLE-UPLOAD", "04R-ROADWORTHY-VEHICLE-UPLOAD Data.csv")
return


; ==================================================================================================
; WAREHOUSE PRO / STOCKTAKE PRO
; ==================================================================================================

INVwarehousepro:
    ExportAndUpload("/04E-INVOICE-SCAN-APP", "04E-INVOICE-SCAN-APP Data.csv")
return


Stocktakeloccount:
    ExportAndUpload("/02-KAINE-LOCATION KIA IUA BYD", "02-KAINE-LOCATION KIA IUA BYD Data.csv")
return


; ==================================================================================================
; EXPORT ONLY
; ==================================================================================================

ExportOnly(eraQuery, csvName)
{
    global hCtl

    ; ----------------------------------------------------------------------------------------------
    ; Possible locations where ERA may save the CSV.
    ; Whichever location receives a fresh file first will be used.
    ; ----------------------------------------------------------------------------------------------

    paths := []

    paths.Push("C:\Users\" . A_UserName . "\OneDrive - Hopper Motor Group\Documents\PSdata\" . csvName)
    paths.Push("C:\Users\" . A_UserName . "\Documents\PSdata\" . csvName)
    paths.Push("C:\Users\runsheet\Documents\PSdata\" . csvName)


    ; ----------------------------------------------------------------------------------------------
    ; Record modification times BEFORE export.
    ; This lets us confirm ERA actually produced a new file.
    ; ----------------------------------------------------------------------------------------------

    preTimes := []

    for i, p in paths
    {
        if FileExist(p)
            preTimes[i] := FileGetTimeMod(p)
        else
            preTimes[i] := ""
    }


    ; ----------------------------------------------------------------------------------------------
    ; Check ERA
    ; ----------------------------------------------------------------------------------------------

    if !WinExist("ERA Port")
        return Fail("ERA Port window not found.`n`nMake sure ERA is open.")


    ; ----------------------------------------------------------------------------------------------
    ; Return ERA to home page
    ; ----------------------------------------------------------------------------------------------

    ERA_Activate()
    ERA_HomePage()


    if !hCtl
        return Fail("ERA control handle could not be found.")


    ; ----------------------------------------------------------------------------------------------
    ; Open report writer
    ; ----------------------------------------------------------------------------------------------

    SendText(hCtl, "6913`r")

    Sleep, 200


    ; ----------------------------------------------------------------------------------------------
    ; Enter report name
    ; ----------------------------------------------------------------------------------------------

    SendText(hCtl, eraQuery . "`r")

    Sleep, 200


    ; ----------------------------------------------------------------------------------------------
    ; Output report
    ; ----------------------------------------------------------------------------------------------

    SendText(hCtl, "o")

    Sleep, 150

    SendText(hCtl, "4")

    Sleep, 150

    SendText(hCtl, "`r")
    SendText(hCtl, "`r")
    SendText(hCtl, "`r")


    ; ----------------------------------------------------------------------------------------------
    ; PC destination format
    ; ----------------------------------------------------------------------------------------------

    if !WaitAndSend("PC destination format", "ListBox1", "{Enter}", 6)
        return


    ; ----------------------------------------------------------------------------------------------
    ; Destination file
    ; ----------------------------------------------------------------------------------------------

    if !WaitAndSend("Select the destination file for the ERA data", "Button2", "{Enter}", 6)
        return


    ; ----------------------------------------------------------------------------------------------
    ; Confirm overwrite/save
    ; ----------------------------------------------------------------------------------------------

    if !WaitAndSend("Confirm Save As", "Button1", "{Left}{Enter}", 6)
        return


    ; ----------------------------------------------------------------------------------------------
    ; ERA may display File Import Monitor.
    ; Do not fail if it disappears too quickly.
    ; ----------------------------------------------------------------------------------------------

    WinWait, File Import Monitor,, 10

    if !ErrorLevel
    {
        WinWaitClose, File Import Monitor,, 120
    }


    ; ----------------------------------------------------------------------------------------------
    ; Wait for fresh CSV
    ; ----------------------------------------------------------------------------------------------

    csvFile := ""

    Loop, 60
    {
        for i, p in paths
        {
            if FileExist(p)
            {
                currentTime := FileGetTimeMod(p)

                if (preTimes[i] = "" || currentTime != preTimes[i])
                {
                    csvFile := p
                    break
                }
            }
        }

        if (csvFile != "")
            break

        Sleep, 1000
    }


    ; ----------------------------------------------------------------------------------------------
    ; No new CSV found
    ; ----------------------------------------------------------------------------------------------

    if (csvFile = "")
    {
        pathList := ""

        for i, p in paths
        {
            pathList .= p . "`n"
        }

        return Fail(
            "CSV was not updated within 60 seconds.`n`n"
            . "ERA may not have completed the export.`n`n"
            . "Checked:`n"
            . pathList
        )
    }


    ; Let Windows finish writing the file
    Sleep, 500


    ; ----------------------------------------------------------------------------------------------
    ; Complete
    ; ----------------------------------------------------------------------------------------------

    MsgBox, 64, Export Complete, Export complete!`n`n%csvName%`n`n%csvFile%


    ; ----------------------------------------------------------------------------------------------
    ; Return to ERA
    ; ----------------------------------------------------------------------------------------------

    WinActivate, ERA Port
    Sleep, 200

    SendKey(hCtl, 0x70)

    return true
}



; ==================================================================================================
; EXPORT AND UPLOAD
; ==================================================================================================

ExportAndUpload(eraQuery, csvName)
{
    global hCtl

    url := "https://csv-server-production-efc6.up.railway.app/upload"


    ; ----------------------------------------------------------------------------------------------
    ; Possible CSV locations
    ; ----------------------------------------------------------------------------------------------

    paths := []

    paths.Push("C:\Users\" . A_UserName . "\OneDrive - Hopper Motor Group\Documents\PSdata\" . csvName)
    paths.Push("C:\Users\" . A_UserName . "\Documents\PSdata\" . csvName)
    paths.Push("C:\Users\runsheet\Documents\PSdata\" . csvName)


    ; ----------------------------------------------------------------------------------------------
    ; Record modification times before export
    ; ----------------------------------------------------------------------------------------------

    preTimes := []

    for i, p in paths
    {
        if FileExist(p)
            preTimes[i] := FileGetTimeMod(p)
        else
            preTimes[i] := ""
    }


    ; ----------------------------------------------------------------------------------------------
    ; Check ERA
    ; ----------------------------------------------------------------------------------------------

    if !WinExist("ERA Port")
        return Fail("ERA Port window not found.`n`nMake sure ERA is open.")


    ; ----------------------------------------------------------------------------------------------
    ; Return ERA to home
    ; ----------------------------------------------------------------------------------------------

    ERA_Activate()
    ERA_HomePage()


    if !hCtl
        return Fail("ERA control handle could not be found.")


    ; ----------------------------------------------------------------------------------------------
    ; Report writer
    ; ----------------------------------------------------------------------------------------------

    SendText(hCtl, "6913`r")

    Sleep, 200


    ; ----------------------------------------------------------------------------------------------
    ; Report name
    ; ----------------------------------------------------------------------------------------------

    SendText(hCtl, eraQuery . "`r")

    Sleep, 200


    ; ----------------------------------------------------------------------------------------------
    ; Output
    ; ----------------------------------------------------------------------------------------------

    SendText(hCtl, "o")

    Sleep, 150

    SendText(hCtl, "4")

    Sleep, 150

    SendText(hCtl, "`r")
    SendText(hCtl, "`r")
    SendText(hCtl, "`r")


    ; ----------------------------------------------------------------------------------------------
    ; PC destination
    ; ----------------------------------------------------------------------------------------------

    if !WaitAndSend("PC destination format", "ListBox1", "{Enter}", 6)
        return


    ; ----------------------------------------------------------------------------------------------
    ; Select destination file
    ; ----------------------------------------------------------------------------------------------

    if !WaitAndSend("Select the destination file for the ERA data", "Button2", "{Enter}", 6)
        return


    ; ----------------------------------------------------------------------------------------------
    ; Confirm Save As
    ; ----------------------------------------------------------------------------------------------

    if !WaitAndSend("Confirm Save As", "Button1", "{Left}{Enter}", 6)
        return


    ; ----------------------------------------------------------------------------------------------
    ; File Import Monitor
    ; ----------------------------------------------------------------------------------------------

    WinWait, File Import Monitor,, 10

    if !ErrorLevel
    {
        WinWaitClose, File Import Monitor,, 80
    }


    ; ----------------------------------------------------------------------------------------------
    ; Wait for the new CSV
    ; ----------------------------------------------------------------------------------------------

    csvFile := ""

    Loop, 60
    {
        for i, p in paths
        {
            if FileExist(p)
            {
                currentTime := FileGetTimeMod(p)

                if (preTimes[i] = "" || currentTime != preTimes[i])
                {
                    csvFile := p
                    break
                }
            }
        }

        if (csvFile != "")
            break

        Sleep, 1000
    }


    ; ----------------------------------------------------------------------------------------------
    ; CSV not found
    ; ----------------------------------------------------------------------------------------------

    if (csvFile = "")
    {
        pathList := ""

        for i, p in paths
        {
            pathList .= p . "`n"
        }

        return Fail(
            "CSV was not updated within 60 seconds.`n`n"
            . "ERA may not have completed the export.`n`n"
            . "Checked:`n"
            . pathList
        )
    }


    ; Give Windows time to finish writing it
    Sleep, 500


    ; ----------------------------------------------------------------------------------------------
    ; Upload
    ; ----------------------------------------------------------------------------------------------

    if !UploadFile(csvFile, url, 3)
        return


    ; ----------------------------------------------------------------------------------------------
    ; Complete
    ; ----------------------------------------------------------------------------------------------

    MsgBox, 64, Upload Complete, Uploaded successfully!`n`n%csvName%`n`n%csvFile%


    ; ----------------------------------------------------------------------------------------------
    ; Return to ERA
    ; ----------------------------------------------------------------------------------------------

    WinActivate, ERA Port
    Sleep, 200

    SendKey(hCtl, 0x70)

    return true
}



; ==================================================================================================
; WAIT FOR ERA WINDOWS AND SEND KEYS
; ==================================================================================================

WaitAndSend(winTitle, control, keys, timeout)
{
    WinWait, %winTitle%,, %timeout%

    if ErrorLevel
    {
        return Fail(
            "Window not found within "
            . timeout
            . " seconds:`n`n"
            . winTitle
        )
    }


    Sleep, 400


    ControlSend, %control%, %keys%, %winTitle%


    if ErrorLevel
    {
        return Fail(
            "ControlSend failed on control:`n"
            . control
            . "`n`nWindow:`n"
            . winTitle
        )
    }


    return true
}



; ==================================================================================================
; UPLOAD CSV TO RAILWAY
; ==================================================================================================

UploadFile(file, url, maxTries)
{
    resultFile := A_Temp . "\csv_upload_result.txt"

    result := ""


    Loop, %maxTries%
    {
        FileDelete, %resultFile%


        cmd := "curl -s --max-time 60 -F ""file=@" . file . """ """ . url . """"


        RunWait, %ComSpec% /c %cmd% > "%resultFile%" 2>&1,, Hide


        result := ""

        FileRead, result, %resultFile%


        if InStr(result, "Uploaded successfully")
        {
            return true
        }


        if (A_Index < maxTries)
        {
            Sleep, 2000
        }
    }


    return Fail(
        "Upload failed after "
        . maxTries
        . " attempts.`n`n"
        . file
        . "`n`nServer response:`n"
        . result
    )
}



; ==================================================================================================
; GET FILE MODIFIED TIME
; ==================================================================================================

FileGetTimeMod(path)
{
    FileGetTime, t, %path%, M

    return t
}



; ==================================================================================================
; ERROR MESSAGE
; ==================================================================================================

Fail(msg)
{
    MsgBox, 48, Error, %msg%

    return false
}



; ==================================================================================================
; ACTIVATE ERA
; ==================================================================================================

ERA_Activate()
{
    global hWnd
    global hCtl


    WinActivate, ERA Port
    WinWaitActive, ERA Port,, 5


    if ErrorLevel
    {
        hWnd := 0
        hCtl := 0
        return false
    }


    hWnd := WinExist("ERA Port")


    Sleep, 100


    ; First known ERA terminal control
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%


    ; Alternate ERA terminal control
    if (!hCtl)
    {
        ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
    }


    ; Home/Page button
    if (hWnd)
    {
        ControlClick, Button18, ahk_id %hWnd%,, Left, 1, NA
    }


    return hCtl ? true : false
}



; ==================================================================================================
; RETURN ERA TO HOME PAGE
; ==================================================================================================

ERA_HomePage()
{
    global hWnd
    global hCtl


    WinActivate, ERA Port
    WinWaitActive, ERA Port,, 5


    if ErrorLevel
        return false


    hWnd := WinExist("ERA Port")


    Sleep, 100


    ; Main ERA control
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%


    ; Alternate ERA control
    if (!hCtl)
    {
        ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
    }


    if (!hCtl)
        return false


    ; Click ERA page/home control
    ControlClick, Button18, ahk_id %hWnd%,, Left, 1, NA


    Sleep, 100


    ; Backspace x13
    Loop, 13
    {
        SendKey(hCtl, 0x08)
        Sleep, 20
    }


    ; F2 x1
    Loop, 1
    {
        SendKey(hCtl, 0x71)
        Sleep, 30
    }


    ; F1 x2
    Loop, 2
    {
        SendKey(hCtl, 0x70)
        Sleep, 30
    }


    ; END x3
    Loop, 3
    {
        SendText(hCtl, "END`r")
        Sleep, 50
    }


    Sleep, 250


    ; Close "No previous menu" popup if present
    WinGet, previousMenuHwnd, ID,, No previous menu


    if (previousMenuHwnd)
    {
        PostMessage, 0x10,,,, ahk_id %previousMenuHwnd%
    }


    return true
}



; ==================================================================================================
; SEND A VIRTUAL KEY DIRECTLY TO ERA
; ==================================================================================================

SendKey(hwnd, vk)
{
    WM_KEYDOWN := 0x100
    WM_KEYUP   := 0x101


    DllCall(
        "PostMessage"
        , "Ptr", hwnd
        , "UInt", WM_KEYDOWN
        , "Ptr", vk
        , "Ptr", 0
    )


    DllCall(
        "PostMessage"
        , "Ptr", hwnd
        , "UInt", WM_KEYUP
        , "Ptr", vk
        , "Ptr", 0
    )
}



; ==================================================================================================
; SEND TEXT DIRECTLY TO ERA
; ==================================================================================================

SendText(hwnd, text)
{
    Loop, Parse, text
    {
        SendCharToControl(hwnd, A_LoopField)
    }


    Sleep, 150
}



; ==================================================================================================
; SEND CHARACTER DIRECTLY TO ERA
; ==================================================================================================

SendCharToControl(hwnd, char)
{
    WM_CHAR := 0x102


    DllCall(
        "PostMessage"
        , "Ptr", hwnd
        , "UInt", WM_CHAR
        , "Ptr", Asc(char)
        , "Ptr", 0
    )
}