#NoEnv
#SingleInstance, Force
SetBatchLines, -1
SetEmbeddedIcon()


; ---------------------------------------------------------------------------
; RegoCheck.ahk - Australian registration lookup with no browser involved.
;
; VicRoads is asked first. If Victoria has no record of the plate, the other
; states that allow a plain HTTP lookup are tried in turn until one answers.
;
; States it can reach:
;   VIC  VicRoads         form page, hidden anti-forgery token, POST
;   SA   EzyReg           JSON endpoint, no token at all
;   ACT  Access Canberra  Wicket wizard, privacy tick then plate, then details
;   WA   DoTDirect        Wicket AJAX, the answer arrives behind a redirect
;   QLD  TMR Check Rego   JSF, accept the terms, then search
;
; States it cannot reach, and why:
;   NSW  the API wants an x-recaptcha-token that only Google's JavaScript can
;        mint, so a real browser is the only way in
;   TAS  the whole transport.tas.gov.au site sits behind a Cloudflare bot
;        challenge and answers 403 to anything that is not a browser
;   NT   nt.gov.au sits behind the same Cloudflare challenge
;
; AutoHotkey and DllCall into winhttp.dll only. No COM, no libraries.
;
; Use it:  run it, type a plate, press Enter
;          Ctrl+Alt+R            brings the window back, plate off the clipboard
;          RegoCheck.ahk ABC123  opens with that plate already searched
;          double-click a row    copies that value
; ---------------------------------------------------------------------------

; The order states are tried in. Victoria first, then quickest to slowest.
; Reorder or trim this line to change which states are asked and when.
global RC_ORDER := ["VIC", "SA", "ACT", "WA", "QLD"]

; Every state and territory, in the order EzyParts is asked which one holds
; a plate. Wider than RC_ORDER - the register behind EzyParts knows cars in
; the three states whose websites this script cannot read.
global RC_PROBE := ["VIC", "NSW", "QLD", "SA", "WA", "TAS", "NT", "ACT"]

; The EzyParts trade login. Burson does not bill rego lookups on this
; account. Plain text by necessity - keep this file to yourself.
global RC_EZY_ACCT := "31147"
global RC_EZY_USER := "kaine"
global RC_EZY_PASS := "Kia2024*"
global RC_EZY_HOST := "ezyparts.burson.com.au"
global RC_EZY_BASE := "/burson/ezyparts/en/AUD"

global RC_UA := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"

global RC_VIC_HOST := "www.vicroads.vic.gov.au"
global RC_VIC_PATH := "/registration/buy-sell-or-transfer-a-vehicle/check-vehicle-registration/vehicle-registration-enquiry"
global RC_SA_HOST  := "account.ezyreg.sa.gov.au"
global RC_ACT_HOST := "rego.act.gov.au"
global RC_WA_HOST  := "online.transport.wa.gov.au"
global RC_QLD_HOST := "www.service.transport.qld.gov.au"

global RC_hSess := 0
global RC_hConn := 0
global RC_hEdit := 0

; EzyParts keeps its own pair of handles, apart from the ones above, so the
; login survives from one search to the next instead of being paid again
; each time. RC_EzyErr says in words why the portal could not be used, for
; the status line - empty means it was fine, or was never needed.
global RC_EzyS   := 0
global RC_EzyC   := 0
global RC_EzyErr := ""

; Every answered search is kept for the rest of the day, so asking the same
; plate twice costs nothing the second time. Keyed by the plate or VIN as
; typed; gone when the script is.
global RC_CACHE   := {}
global RC_LastKey := ""

; The last ten searches that found a car, newest first, for the dropdown
; under the list - and the day book they are quietly written into, one line
; per lookup, next to the script. The list is NOT called RC_RECENT: variable
; names here are case-blind, so that name is the dropdown's own variable,
; and the control would overwrite the list with its own text every time it
; was read - which is exactly what used to empty it.
global RC_LASTTEN := []
global RC_Recent := ""
global RC_LOG    := A_ScriptDir . "\RegoCheck.log"

; The window's own controls. AHK v1 insists a Gui control's variable is global,
; and RC_BuildGui below is a function, so they have to be declared out here.
global RC_Plate    := ""
; How much of the chain a search is allowed to walk. 1 is fast - the register
; and nothing else - 2 is the lot, the fitment shop and the wiper sizes with
; it. The choice is kept in an ini file beside the script, so the window opens
; the way it was last left. RC_STEPS is how many notches the bar has at that
; setting, RC_T0 when the search started.
global RC_SPEED := 1
global RC_STEPS := 3
global RC_LOADING := false
global RC_T0    := 0
global RC_INI   := A_ScriptDir . "\RegoCheck.ini"
global RC_List     := ""
global RC_Toast    := ""
global RC_ToastBar := ""
global RC_ToastVal := ""
global RC_Make     := ""
global RC_MakeX    := ""

; Shown in the title bar. Goes up by one every time the script changes.
global RC_VER := "2.8"

; Handle of the list, and the one row that should be drawn red - the expiry
; when the rego has already run out. Zero means no row is red.
global RC_hLV   := 0
global RC_RedRow := 0

; The window itself, and how much bigger its frame is than the drawing area
; inside it. The list grows and shrinks to the number of rows an answer has,
; and the window follows it, so both sums are done against the client size.
global RC_hGui := 0
global RC_PadW := 0
global RC_PadH := 0

; The wiper table and the picking of a line out of it. The rego services name
; the make and the year but never the model, so every fitment for that make and
; year is a candidate and the dropdown asks which one. RC_WipeRow is where the
; three wiper rows start in the list, RC_ModelPick is the dropdown's answer.
global RC_Model     := ""
global RC_WIPE      := []
global RC_Cands     := []
global RC_ModelPick := 0
global RC_WipeRow   := 0

RC_WipeLoad()
RC_BuildGui()
Menu, Tray, Add, Show Rego check, RC_TrayShow
Menu, Tray, Default, Show Rego check

; Started with a plate on the command line: fill it in and search straight away.
if (A_Args.Length() >= 1) {
    GuiControl, RC:, RC_Plate, % A_Args[1]
    RC_OnSearch()
}
return


; --- the window ------------------------------------------------------------

RC_BuildGui() {
    global RC_hEdit, RC_hGui, RC_PadW, RC_PadH
    ; Named only so RC_FitList can slide them up and down with the list.
    global RC_LblModel, RC_LblRecent, RC_LblSpeed, RC_Sep
    global RC_Fast, RC_Full, RC_Bar, RC_StepTxt, RC_Detail, RC_Result
    Gui, RC:New, -MaximizeBox -Resize +HwndRC_hGui, Rego check
    Gui, RC:Default
    Gui, Margin, 12, 12
    Gui, Font, s10, Segoe UI

    Gui, Add, Text,   x12 y17 w62 h20, Rego/VIN
    ; 17 characters so a whole VIN can be pasted in as well as a plate.
    Gui, Add, Edit,   x78 y12 w172 h27 vRC_Plate HwndRC_hEdit Uppercase Limit17
    Gui, Add, Button, x258 y12 w110 h27 Default gRC_OnSearch, Search

    ; The toast, shrunk to a small green pill - "copied" - with the VIN itself
    ; as plain text beside it. The Progress bar is the pill's colour, the
    ; transparent Text on top of it is the word. All start hidden. The word
    ; sits hard against the left of the pill on purpose: that puts it on the
    ; same line down the window as "Rego/VIN" above and the build below. The
    ; pill is only as wide as it has to be, because the VIN beside it starts
    ; where the box above it starts - the two read as one column.
    Gui, Add, Progress, x12 y46 w62 h22 BackgroundEAF3DE vRC_ToastBar Hidden Disabled
    Gui, Font, s9 c27500A, Segoe UI
    Gui, Add, Text, x12 y49 w62 h16 BackgroundTrans vRC_Toast Hidden, %A_Space%
    Gui, Font, s9 cDefault, Segoe UI
    Gui, Add, Text, x78 y49 w160 h16 vRC_ToastVal Hidden, %A_Space%
    Gui, Font, s10 cDefault, Segoe UI

    ; The make of the car in bold on the right of the toast row. Two lines
    ; deep so a long one - MERCEDES-BENZ - wraps instead of being cut off.
    ; The exact build goes on its own full-width line below, and it wraps
    ; too. The status line lives at the very bottom now.
    Gui, Font, s13 w600, Segoe UI
    Gui, Add, Text, x246 y40 w122 h44 Right vRC_Make, %A_Space%
    Gui, Font, s10 w600, Segoe UI
    Gui, Add, Text, x12 y88 w356 h34 Hidden vRC_MakeX, %A_Space%
    Gui, Font, s10 w400, Segoe UI

    ; Tall enough for the header and every row the tyre shops can fill at
    ; once. If it is any shorter a scrollbar appears, which then eats the
    ; width and brings a second scrollbar along the bottom with it.
    Gui, Add, ListView, x12 y126 w356 h348 vRC_List HwndRC_hLV gRC_OnList -Multi +Grid NoSortHdr, Field|Value

    ; Wide enough for the longest field name - "Tyres (front & rear)" - with
    ; the rest left for the values, which are mostly short.
    LV_ModifyCol(1, 138)
    LV_ModifyCol(2, 210)

    ; Row colouring is not something a ListView does on its own - Windows has to
    ; be asked, row by row, while it paints. RC_OnNotify answers.
    OnMessage(0x004E, "RC_OnNotify")

    ; Which of the make's models this actually is. Nothing the states send says
    ; so, so it has to be asked. Lives down here with Recent - it is really only
    ; ever touched to sort the wipers out.
    Gui, Add, Text, x12 y488 w62 h20 vRC_LblModel, Model
    Gui, Add, DropDownList, x78 y482 w290 vRC_Model gRC_OnModel AltSubmit, Pick a model

    ; The day's earlier lookups, newest at the top. Picking one runs that
    ; search again - answered from the kept copy, so it is instant.
    Gui, Add, Text, x12 y520 w62 h20 vRC_LblRecent, Recent
    Gui, Add, DropDownList, x78 y514 w290 vRC_Recent gRC_OnRecent AltSubmit, Recent lookups

    ; How far down the chain a search goes. Fast is the register on its own;
    ; Full adds the fitment and the wiper sizes. The pick is remembered.
    Gui, Add, Text,  x12 y552 w62 h20 vRC_LblSpeed, Speed
    Gui, Add, Radio, x78 y551 w62 h20 vRC_Fast gRC_OnSpeed Group, Fast
    Gui, Add, Radio, x150 y551 w62 h20 vRC_Full gRC_OnSpeed, Full

    ; The bottom of the window: an etched line, then either the bar walking
    ; through the steps of a search, or the tick or cross it ended on. The two
    ; sit in the same place and take turns.
    Gui, Add, Text, x0 y578 w380 h2 0x10 vRC_Sep
    Gui, Add, Progress, x12 y586 w356 h16 cA0C63C BackgroundF0F0F0 vRC_Bar Hidden Disabled

    ; The step words and the count are deliberately plain - "Step 3/5 ·
    ; fitment" - so a screenshot of the window never says who was asked.
    Gui, Font, s8 w400, Consolas
    Gui, Add, Text, x12 y606 w220 h16 vRC_StepTxt Hidden, %A_Space%
    Gui, Add, Text, x148 y606 w220 h16 Right vRC_Detail Hidden, %A_Space%
    Gui, Font, s10 w600, Segoe UI
    Gui, Add, Text, x12 y584 w220 h20 vRC_Result, %A_Space%
    Gui, Font, s10 w400, Segoe UI

    ; Built at full size but left out of sight, so starting the script does not
    ; interrupt whatever is on screen. Page Down brings it up when it is wanted.
    Gui, Show, Hide w380 h632, Rego check v%RC_VER%

    ; How much the frame - border and title bar - adds to the drawing area.
    ; RC_FitList resizes with WinMove, which counts the frame in, so the two
    ; numbers have to be known before the first answer arrives.
    prev := A_DetectHiddenWindows
    DetectHiddenWindows, On
    WinGetPos, , , ow, oh, ahk_id %RC_hGui%
    DetectHiddenWindows, %prev%
    RC_PadW := ow - 380
    RC_PadH := oh - 632

    RC_SpeedLoad()
    RC_Ready()
}

; The speed the window was last left on, out of the ini beside the script.
; Ticking the radio here must not look like the user ticking it, or the load
; would write straight back over what it just read.
RC_SpeedLoad() {
    global RC_SPEED, RC_STEPS, RC_INI, RC_LOADING
    IniRead, v, %RC_INI%, RegoCheck, Speed, 1
    RC_SPEED := (v = 2) ? 2 : 1
    RC_STEPS := (RC_SPEED = 2) ? 5 : 3
    RC_LOADING := true
    GuiControl, RC:, % (RC_SPEED = 2) ? "RC_Full" : "RC_Fast", 1
    RC_LOADING := false
}

; A radio was clicked. The pick is written straight back out, so the next
; time the script starts it opens the same way.
RC_OnSpeed() {
    global RC_SPEED, RC_STEPS, RC_INI, RC_LOADING
    if (RC_LOADING)
        return
    Gui, RC:Default
    GuiControlGet, full, RC:, RC_Full
    RC_SPEED := full ? 2 : 1
    RC_STEPS := (RC_SPEED = 2) ? 5 : 3
    IniWrite, %RC_SPEED%, %RC_INI%, RegoCheck, Speed
}

; --- the bar along the bottom ----------------------------------------------

; How many pieces a separated list has, or 0 when it is empty.
RC_Count(text, sep) {
    if (Trim(text) = "")
        return 0
    n := 0
    Loop, Parse, text, %sep%
        n += 1
    return n
}

; Waiting for a plate. No bar, no tick, just the invitation.
RC_Ready() {
    Gui, RC:Default
    GuiControl, RC:Hide, RC_Bar
    GuiControl, RC:Hide, RC_StepTxt
    GuiControl, RC:Hide, RC_Detail
    Gui, Font, s9 w400 c808080, Segoe UI
    GuiControl, RC:Font, RC_Result
    GuiControl, RC:, RC_Result, Type a plate or VIN and press Enter.
    GuiControl, RC:Show, RC_Result
    Gui, Font, s10 w400 cDefault, Segoe UI
}

; One notch along. The word says what is being fetched, never who from.
RC_Progress(n, word) {
    global RC_STEPS
    Gui, RC:Default
    if (n > RC_STEPS)
        n := RC_STEPS
    GuiControl, RC:Hide, RC_Result
    GuiControl, RC:Show, RC_Bar
    GuiControl, RC:Show, RC_StepTxt
    GuiControl, RC:Show, RC_Detail
    GuiControl, RC:, RC_Bar, % Round(n * 100 / RC_STEPS)
    GuiControl, RC:, RC_StepTxt, % "Step " . n . "/" . RC_STEPS . "  " . Chr(0xB7) . " " . word
    GuiControl, RC:, RC_Detail, %A_Space%
    Sleep, 10
}

; The end of it: a green tick and the word, or a red cross and the short
; reason. The detail on the right is a count and a time, nothing more.
RC_Done(ok, word, detail := "") {
    global RC_STEPS, RC_T0
    Gui, RC:Default
    GuiControl, RC:, RC_Bar, 100
    GuiControl, RC:Hide, RC_Bar
    GuiControl, RC:Hide, RC_StepTxt
    if (detail = "" && RC_T0)
        detail := RC_STEPS . "/" . RC_STEPS . "  " . Chr(0xB7) . " "
                . Round((A_TickCount - RC_T0) / 1000, 1) . " s"

    ; Segoe UI Symbol has both marks; the ordinary UI font does not always.
    Gui, Font, % "s11 w600 " . (ok ? "c1E7B34" : "cB02020"), Segoe UI Symbol
    GuiControl, RC:Font, RC_Result
    GuiControl, RC:, RC_Result, % (ok ? Chr(0x2713) : Chr(0x2715)) . "  " . word
    GuiControl, RC:Show, RC_Result
    Gui, Font, s8 w400 c808080, Consolas
    GuiControl, RC:Font, RC_Detail
    GuiControl, RC:, RC_Detail, %detail%
    GuiControl, % (detail != "") ? "RC:Show" : "RC:Hide", RC_Detail
    Gui, Font, s10 w400 cDefault, Segoe UI
}

; The list is built at its tallest, then trimmed to whatever the answer
; actually filled - and everything under it, right down to the bottom edge of
; the window, comes up to meet it. A short answer gets a short window; a long
; one grows until the list would be taller than a screenful of rows.
RC_FitList() {
    global RC_hLV, RC_hGui, RC_PadW, RC_PadH
    static LIST_Y := 126, BASE_B := 474, BASE_H := 632
    static BELOW  := [ ["RC_LblModel", 488], ["RC_Model", 482]
                     , ["RC_LblRecent", 520], ["RC_Recent", 514]
                     , ["RC_LblSpeed", 552], ["RC_Fast", 551], ["RC_Full", 551]
                     , ["RC_Sep", 578], ["RC_Bar", 586], ["RC_Result", 584]
                     , ["RC_StepTxt", 606], ["RC_Detail", 606] ]
    Gui, RC:Default
    n := LV_GetCount()

    ; Rows are measured, not guessed - the row height follows the font and the
    ; screen's scaling. The top of the first row is the header's height.
    top := 22
    rowH := 20
    if (n >= 1) {
        VarSetCapacity(rc, 16, 0)
        NumPut(0, rc, 0, "Int")
        SendMessage, 0x100E, 0, &rc, , ahk_id %RC_hLV%     ; LVM_GETITEMRECT
        if (ErrorLevel != "FAIL" && ErrorLevel) {
            t := NumGet(rc, 4, "Int")
            r := NumGet(rc, 12, "Int") - t
            if (t > 0 && t < 60 && r >= 12 && r <= 44) {
                top := t
                rowH := r
            }
        }
    }

    ; Never so short that the window looks broken, never so tall that it runs
    ; off the bottom of the screen.
    if (n < 6)
        n := 6
    if (n > 22)
        n := 22

    h := top + rowH * n + 8
    delta := (LIST_Y + h) - BASE_B
    GuiControl, RC:MoveDraw, RC_List, h%h%
    for i, c in BELOW {
        y := c[2] + delta
        GuiControl, RC:MoveDraw, % c[1], y%y%
    }
    GuiControl, RC:MoveDraw, RC_Sep, w380

    prev := A_DetectHiddenWindows
    DetectHiddenWindows, On
    WinGetPos, wx, wy, , , ahk_id %RC_hGui%
    WinMove, ahk_id %RC_hGui%, , wx, wy, 380 + RC_PadW, BASE_H + delta + RC_PadH
    ; Moved controls leave their old paint behind - the labels ghost on top of
    ; one another - until the whole window is told to draw itself again.
    WinSet, Redraw, , ahk_id %RC_hGui%
    DetectHiddenWindows, %prev%
}

; Whatever the bold line above the list already says does not need saying
; twice - the series, when it is the trim in the badge, goes. The rego, the
; VIN, the expiry, the year and the wiper rows stay whatever happens: they
; are the reason the window is open.
RC_DropDupes() {
    global RC_RedRow, RC_WipeRow
    static KEEP := ",Registration,VIN/Chassis,Expiry,Year,Wiper driver,Wiper passenger,Wiper rear,"
    Gui, RC:Default
    GuiControlGet, mk, RC:, RC_Make
    GuiControlGet, mx, RC:, RC_MakeX
    top := " " . RC_Squash(mk . " " . mx) . " "
    if (Trim(top) = "")
        return
    ; The same line again with the spaces out of it, because the bold line and
    ; the row can break a name differently - "IS250 Prestige" up top against a
    ; "IS 250 Prestige" row. No word boundaries left to lean on there, so that
    ; test only runs on something long enough not to land inside another word.
    tight := StrReplace(top, " ")
    r := LV_GetCount()
    while (r >= 1) {
        LV_GetText(f, r, 1)
        LV_GetText(v, r, 2)
        v := RC_Squash(v)
        vt := StrReplace(v, " ")
        dupe := InStr(top, " " . v . " ") || (StrLen(vt) >= 6 && InStr(tight, vt))
        if (v != "" && StrLen(v) > 2 && !InStr(KEEP, "," . f . ",") && dupe) {
            LV_Delete(r)
            if (RC_RedRow > r)
                RC_RedRow -= 1
            if (RC_WipeRow > r)
                RC_WipeRow -= 1
        }
        r -= 1
    }
}

; The states and the shops SHOUT, and they shout inconsistently - "SILVER",
; "cvt", "6sp auto". The window says them the way a person writes them, with
; the short forms that really are initials left alone. Anything with a digit
; in it - 4JJ1, 1.5L, 255/65, MY19-20 - is a code, not a word, and is left
; exactly as it came.
RC_TitleWord(word) {
    ; Named ACRO, not UP: the shouted copy of the word below is called "up",
    ; and names here are case-blind, so the two would be one variable.
    static ACRO := ",CVT,AT,MT,DCT,DSG,AMT,AWD,RWD,FWD,2WD,4WD,SUV,LPG,GT,EV,BEV,PHEV,MHEV,HEV,ABS,LWB,SWB,VIN,USA,LED,"
    if (word = "")
        return ""
    if RegExMatch(word, "\d")
        return word

    ; Split words joined by a slash or a dash and do each half - "T/DIESEL",
    ; "HI-RIDE" - then put them back together the way they were.
    if RegExMatch(word, "[/\-]") {
        out := ""
        pos := 1
        while (pos <= StrLen(word)) {
            ch := SubStr(word, pos, 1)
            if (ch = "/" || ch = "-") {
                out .= ch
                pos += 1
                continue
            }
            e := RegExMatch(word, "[/\-]", , pos)
            part := (e ? SubStr(word, pos, e - pos) : SubStr(word, pos))
            out .= RC_TitleWord(part)
            pos += StrLen(part)
        }
        return out
    }

    up := word
    StringUpper, up, up
    if InStr(ACRO, "," . up . ",")
        return up
    ; Two letters in capitals is a badge - SX, LS, XL - and stays as it is.
    if (StrLen(word) <= 2 && word == up)
        return word
    StringLower, low, word
    StringUpper, first, % SubStr(low, 1, 1)
    return first . SubStr(low, 2)
}

; A whole line of words put right.
RC_TitleCase(s) {
    out := ""
    for i, word in StrSplit(RegExReplace(Trim(s), "\s+", " "), " ")
        out .= (out = "" ? "" : " ") . RC_TitleWord(word)
    return out
}

; The last pass over the finished list: the bodies spelt out and ordered, the
; shouted words put right. The rego, the VIN, the expiry, the engine number
; and the sizes are codes and are never touched.
RC_PrettyRows(hint := "") {
    ; Not called CASE - that is a keyword, and a variable by that name is not
    ; the same thing to the parser.
    static WORDS := ",Colour,Version,Series,Runflat,Factory spec,"
    static BODY  := ",Body type,Cab/Body,"
    Gui, RC:Default
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        LV_GetText(v, A_Index, 2)
        if (v = "")
            continue
        if InStr(BODY, "," . f . ",")
            v2 := RC_BodyText(v, hint)
        else if InStr(WORDS, "," . f . ",")
            v2 := RC_TitleCase(v)
        else
            continue
        ; "==" and not "!=": plain comparison here is case-blind, so SILVER
        ; and Silver would count as the same string and the row would never
        ; be rewritten - which is the whole point of this pass.
        if !(v2 == v)
            LV_Modify(A_Index, "Col2", v2)
    }
}

; Down to bare words for comparing - no case, no punctuation, single spaces.
RC_Squash(s) {
    s := RegExReplace(s, "[^A-Za-z0-9\.]+", " ")
    StringLower, s, s
    return Trim(RegExReplace(s, "\s+", " "))
}

; Enter or the Search button lands here. This is where the states are walked,
; so the status line can say which one is being asked at the time.
RC_OnSearch() {
    global RC_ORDER, RC_CACHE, RC_LastKey, RC_EzyErr, RC_T0, RC_SPEED
    Gui, RC:Default
    RC_T0 := A_TickCount
    GuiControlGet, plate, RC:, RC_Plate
    plate := RC_Norm(plate)

    ; Seventeen characters is a VIN, anything shorter is a plate. Only VicRoads
    ; will take a VIN - the other four states only have a box for a plate.
    isVIN := (StrLen(plate) = 17)

    LV_Delete()
    RC_HideToast()
    RC_RedRow := 0
    RC_WipeRow := 0
    RC_ModelPick := 0
    RC_WipeReset()
    RC_SetMake("", "")
    if (plate = "") {
        RC_Done(false, "Type a plate or VIN", "")
        return
    }
    if (!isVIN && !RegExMatch(plate, "^[0-9A-Z]{1,8}$")) {
        RC_Done(false, "Not a plate or VIN", "")
        RC_SelectPlate()
        return
    }

    ; Asked already today? The whole answer is kept, so the second asking is
    ; painted straight back without a single request going out. A copy taken
    ; on Fast is only half an answer though - it never asked the fitment shop
    ; - so switching to Full and asking again walks the chain properly rather
    ; than handing back the thin copy.
    RC_LastKey := plate
    if (RC_CACHE.HasKey(plate) && SubStr(RC_CACHE[plate].when, 1, 8) = SubStr(A_Now, 1, 8)
        && (RC_CACHE[plate].speed + 0) >= RC_SPEED) {
        RC_CacheShow(plate)
        return
    }

    mode   := isVIN ? "vin" : "plate"
    tried  := ""
    errors := ""
    RC_EzyErr := ""

    ; VicRoads first - free, instant, and it takes a VIN as happily as a
    ; plate. Anything it does not hold goes to EzyParts: one login, and the
    ; register itself answers for every state, VIN included. The other state
    ; readers only walk when EzyParts is down or silent, so nothing is lost
    ; to the portal having a bad day.
    if RC_Walk(["VIC"], plate, mode, tried, errors)
        return

    if (isVIN) {
        if RC_FillEzyVin(plate)
            return
        msg := "No record of that VIN in VIC or on EzyParts."
    } else {
        if RC_FillEzyPlate(plate)
            return
        if RC_Walk(["SA", "ACT", "WA", "QLD"], plate, mode, tried, errors)
            return
        msg := "No record of " . plate . " in " . tried . " or on EzyParts."
    }
    ; "Not found" and "could not ask" are different answers, and the bottom
    ; line says which without naming anyone: how many were asked, and how many
    ; of those never came back. The full sentence still goes to the day book.
    if (RC_EzyErr != "")
        errors .= (errors = "" ? "" : "; ") . RC_EzyErr
    if (errors != "")
        msg .= " Trouble on the way: " . errors
    asked := RC_Count(tried, ",")
    bad   := RC_Count(errors, ";")
    if (asked = 0)
        asked := 1
    detail := asked . "/" . asked . " tried"
    if (bad)
        detail := asked . "  " . Chr(0xB7) . " " . bad . " no answer"
    RC_Done(false, "No record", detail)
    RC_SelectPlate()
}

; Walk the given states' own websites in order, filling the list from the
; first that knows the plate. True when one answered, false when every one
; was empty or broken - what broke is appended to errors either way.
RC_Walk(order, plate, mode, ByRef tried, ByRef errors) {
    Gui, RC:Default
    for i, st in order {
        ; Say what we are doing, then let the window repaint before we block on
        ; the network for a second or two.
        RC_Progress(1, "plate")
        Sleep, 20

        text := RC_State(st, plate, mode)

        ; A leading "!" is the state itself failing, not the plate being absent.
        ; Note it, keep going - another state may still have the car.
        if (SubStr(text, 1, 1) = "!") {
            errors .= (errors = "" ? "" : "; ") . st . ": " . SubStr(text, 2)
            tried  .= (tried = "" ? "" : ", ") . st
            continue
        }

        tried .= (tried = "" ? "" : ", ") . st

        ; Empty means that state simply has no such plate. Try the next one.
        if (text = "")
            continue

        ; The VIN is the whole point of the search, so it goes second in the
        ; list, straight onto the clipboard, and up in the toast.
        label := ""
        vin   := RC_FindVIN(text, label)
        make  := ""
        RC_Fill(text, (mode = "vin") ? "" : plate, vin, make, st)

        note := "Found in " . st . ". Checked: " . tried . "."
        if (vin != "") {
            Clipboard := vin
            ; The list keeps the state's own wording. The toast has one line, so
            ; it just says whether the whole VIN came back or only part of one.
            RC_ShowToast(((StrLen(vin) = 17) ? "VIN copied" : "Partial VIN copied") . "   " . vin)
            RC_TipAtMouse(vin)
        } else {
            note .= " No VIN in what " . st . " gives back."
        }
        RC_Done(true, "Success")
        RC_SelectPlate()
        RC_CacheSave(plate, note)
        return true
    }
    return false
}

; Put the answer in the list. Only the rows worth reading are kept, and the
; labels each state uses are close enough to match by pattern rather than by
; exact wording. Anything else the state sent is dropped on the floor.
RC_Fill(text, plate, vin := "", ByRef make := "", st := "") {
    global RC_RedRow, RC_WipeRow, RC_ModelPick
    Gui, RC:Default
    RC_RedRow := 0
    RC_WipeRow := 0
    RC_ModelPick := 0
    make := ""
    ; Whatever the tyre shops end up saying about the body, kept for the last
    ; pass over the list - the state's own word for it is only ever "UTIL".
    bodyHint := ""

    ; Split the state's answer back into label / value pairs to pick from.
    labels := []
    values := []
    for i, line in StrSplit(text, "`n", "`r") {
        p := InStr(line, ": ")
        if !p
            continue
        labels.Push(Trim(SubStr(line, 1, p - 1)))
        values.Push(Trim(SubStr(line, p + 2)))
    }

    ; The make goes in bold above the list, not in it.
    make := RC_Pick(labels, values, "i)^make\b")

    reg := RC_Pick(labels, values, "i)registration\s+(number|plate)|^plate\b|^registration$")
    LV_Add("", "Registration", (reg != "") ? reg : plate)

    if (vin = "")
        vin := RC_Pick(labels, values, "i)\b(vin|chassis)\b")
    if (vin != "")
        LV_Add("", "VIN/Chassis", vin)

    ; Expiry carries the state's own wording - Victoria says "Current -
    ; 16/05/2027" - so the date is dug out of it only to decide the colour.
    exp := RC_Pick(labels, values, "i)expir|\bdue\b")
    if (exp != "") {
        row := LV_Add("", "Expiry", exp)
        ymd := RC_ExpiryDate(exp)
        if (ymd != "" && ymd < SubStr(A_Now, 1, 8))
            RC_RedRow := row
    }

    rest := [ ["Year",          "i)^year|year of manufacture|build year"]
            , ["Body type",     "i)body"]
            , ["Colour",        "i)colou?r"]
            , ["Engine number", "i)engine"] ]
    for i, r in rest {
        val := RC_Pick(labels, values, r[2])
        if (val != "")
            LV_Add("", r[1], val)
    }

    ; Three wiper rows, always present so the list does not change height. What
    ; goes in them depends on how many fitments the make and year turn up.
    RC_WipeRow := LV_Add("", "Wiper driver", "")
    LV_Add("", "Wiper passenger", "")
    LV_Add("", "Wiper rear", "")
    year := RC_Pick(labels, values, "i)^year|year of manufacture|build year")
    body := RC_Pick(labels, values, "i)body")

    ; Some maker will name the car from its VIN, which is the one thing the
    ; states never say. Worth the extra request - it usually turns the whole
    ; dropdown into a single answer. Kia answers for its own cars; Hyundai and
    ; Genesis have no such page, but the US regulator's decoder knows most of
    ; them. Any other make, or no VIN, and this is skipped.
    vinModel := ""
    vinYear  := ""
    genTag   := ""
    mkX      := ""
    trm      := ""
    if (vin != "" && InStr(make, "KIA")) {
        RC_Progress(2, "build")
        vinModel := RC_KiaVin(vin, vinYear)

        ; The parts catalogue knows the rest of the build - engine, fuel and
        ; trim. The whole line goes in the list, and the engine and fuel go up
        ; top in the brackets beside the make.
        spec := RC_KiaSpec(vin)
        if (spec != "") {
            LV_Insert(1, "", "Factory spec", spec)
            if (RC_RedRow)
                RC_RedRow += 1
            RC_WipeRow += 1
            mkX := RC_FuelOf(spec)

            ; The tail of the catalogue line is the trim - everything after
            ; the engine, minus gearbox and driveline words: "2020 Cerato
            ; 1.6L AT GT" ends in GT. Electric ones have no engine size, so
            ; those read from after the model word instead.
            tail := ""
            if RegExMatch(spec, "i)\d+(?:\.\d+)?L\s+(.+)$", t)
                tail := t1
            else if RegExMatch(spec, "i)^\d{4}\s+\S+\s+(.+)$", t)
                tail := t1
            tail := RegExReplace(tail, "i)\b(AT|MT|CVT|DCT|AUTO|MAN|MANUAL|DSL|CRDI|TGDI|GDI|MPI|HEV|PHEV|AWD|4WD|2WD|FWD|RWD)\b", " ")
            trm := Trim(RegExReplace(tail, "\s+", " "))
            trm := RegExReplace(trm, "i)\bGT-?LINE\b", "GT-Line")

            ; When the manual page has nothing, the catalogue line still
            ; names the year and the model.
            if (vinModel = "" && RegExMatch(spec, "^(\d{4})\s+(\S+)", sm)) {
                vinYear := sm1
                vinModel := sm2
            }
        }
    } else if (vin != "" && InStr(make, "HYUNDAI")) {
        ; Hyundai's own site answers a VIN with the factory build line -
        ; generation, trim, engine and gearbox - through the open API behind
        ; its owners' pages. Cars too old for it fall back to reading the
        ; VIN directly - Hyundai spells the model line in the fourth
        ; character.
        RC_Progress(2, "build")
        hX := ""
        hTrim := ""
        vinModel := RC_HmcVin(vin, genTag, hX, hTrim, vinYear)
        if (vinModel != "") {
            mkX := hX
            trm := hTrim
        } else {
            vinModel := RC_HyuVin(vin, year, body, genTag)
        }
    } else if (vin != "" && InStr(make, "GENESIS")) {
        ; Genesis is Hyundai underneath, and Hyundai's own VIN answer covers
        ; both badges - generation, trim, engine and all. NHTSA only gets a
        ; word in when Hyundai stays silent.
        RC_Progress(2, "build")
        hX := ""
        hTrim := ""
        vinModel := RC_HmcVin(vin, genTag, hX, hTrim, vinYear)
        if (vinModel != "") {
            mkX := hX
            trm := hTrim
        } else {
            RC_Progress(2, "build")
            nExtra := ""
            nTrim  := ""
            vinModel := RC_NhtsaVin(vin, vinYear, nExtra, nTrim)

            ; The American answer is only trusted when its year sits near the
            ; rego's - when it guesses, it guesses a different decade.
            if (vinModel != "" && vinYear != "" && year + 0 > 0 && Abs(vinYear - year) > 2) {
                vinModel := ""
                vinYear := ""
                nExtra := ""
                nTrim := ""
            }
            mkX := nExtra
            trm := nTrim
        }
    }

    ; Isuzu names nothing itself, so the tyre shops that answer a rego do the
    ; talking: Mobile Tyre Shop first - it knows the most, right down to the
    ; chassis code, the model-year range and both tyre sizes - then JAX when
    ; the shop has never met the plate. Both hand back the model, the trim
    ; and the year. When both are silent the body type still names the model -
    ; Isuzu builds exactly two cars, the ute is a D-MAX and the SUV is an
    ; MU-X. The year alone cannot always name the generation - 2019 and 2020
    ; sit in two of them at once - but the VIN can: characters seven and eight
    ; carry the engine, and Isuzu's own engine guide names them. 54 is the
    ; 4JA1 and 77 the 4JH1 of the first ute, 85 the 4JJ1 and 86 the 4JK1 of
    ; the second, 87 the 4JJ3 of the current one. Every one of them burns
    ; diesel, so the engine code also fills the brackets beside the make.
    if (InStr(make, "ISUZU")) {
        ; A search that started from a VIN has no plate of its own, but the
        ; state's answer names the rego - that one asks the shops just as well.
        rego := (plate != "") ? plate : RC_Norm(reg)
        if (rego != "" && st != "" && RC_SPEED = 2) {
            RC_Progress(3, "fitment")
            jX := ""
            jTrim := ""
            jYear := ""
            jCab := ""
            jInfo := ""
            vinModel := RC_MtsRego(rego, st, jX, jTrim, jYear, jCab, jMake, jInfo)
            if (vinModel = "") {
                RC_Progress(3, "fitment")
                jInfo := ""
                vinModel := RC_JaxRego(rego, st, jX, jTrim, jYear, jCab)
            }
            if (vinModel != "") {
                vinYear := jYear
                mkX := jX
                trm := jTrim
            }

            ; Everything the shop knew gets its own row, slid in just above
            ; the wiper rows so the red expiry row above keeps its place. A
            ; JAX answer only carries the cab, so that goes in on its own.
            if IsObject(jInfo)
                RC_MtsRows(jInfo)
            else if (jCab != "") {
                LV_Insert(RC_WipeRow, "", "Cab/Body", jCab)
                RC_WipeRow += 1
            }
            bodyHint := IsObject(jInfo) ? jInfo.name . " " . jInfo.cab : jCab
        }
        if (vinModel = "") {
            if RegExMatch(body, "i)util|\bute\b")
                vinModel := "D-MAX"
            else if RegExMatch(body, "i)suv|wagon")
                vinModel := "MU-X"
        }
        ; Isuzu's own VIN sheet settles whatever the shops left open - the
        ; model, the exact build year, the generation, the engine and the
        ; driveline all sit in the VIN itself. The trim does not, so the
        ; shops above still have the last word on that.
        iEng := ""
        iDrive := ""
        iYr := ""
        iGen := ""
        iModel := RC_IsuzuVin(vin, iEng, iDrive, iYr, iGen)
        if (iModel != "") {
            if (vinModel = "")
                vinModel := iModel
            if (iYr != "")
                vinYear := iYr
            if (iGen != "")
                genTag := "(" . iGen
            if (mkX = "") {
                mkX := iEng
                if (iDrive != "")
                    mkX .= (mkX != "" ? ", " : "") . iDrive
            }
            ; The VIN names the driveline even when the shops did not.
            if (iDrive != "")
                bodyHint .= " " . iDrive
        } else if (vinModel != "" && StrLen(vin) = 17) {
            ; Not a Thai-built MPA VIN - the old engine-code guess still runs.
            d := SubStr(vin, 7, 2)
            if (d = "85" || d = "86")
                genTag := (vinModel = "MU-X") ? "(RF" : "(RT"
            else if (d = "87" || d = "40")
                genTag := (vinModel = "MU-X") ? "(RJ" : "(RG"
            else if ((d = "54" || d = "77") && vinModel = "D-MAX")
                genTag := "(RA"
            litre := (d = "54" || d = "86") ? "2.5L" : (d = "40" || d = "77" || d = "85" || d = "87") ? "3.0L" : ""
            if (mkX = "")
                mkX := litre . " Diesel"
        }
    }

    ; BYD sorts itself out by body type and, for the SUVs, by the VIN.
    if (vinModel = "" && InStr(make, "BYD")) {
        bFuel := ""
        vinModel := RC_BydVin(vin, year, body, bFuel)
        mkX := bFuel
    }

    ; The tyre shops are asked on every plate the state answered, not only
    ; when something came back blank - the chassis code, the model-year range,
    ; the gearbox and the tyre sizes come from nowhere else. Mobile Tyre Shop
    ; first, JAX second, Autobarn as the very last resort. Whatever the maker's
    ; own sources already named stays; the shops only fill blanks. Not for
    ; Isuzu: it already asked them above, with the VIN as the last word.
    if (st != "" && RC_SPEED = 2 && !InStr(make, "ISUZU")) {
        rego := (plate != "") ? plate : RC_Norm(reg)
        if (rego != "") {
            sX := ""
            sTrim := ""
            sYear := ""
            sCab := ""
            sInfo := ""
            RC_Progress(3, "fitment")
            sModel := RC_MtsRego(rego, st, sX, sTrim, sYear, sCab, sMake, sInfo)
            if (sModel = "") {
                RC_Progress(3, "fitment")
                sInfo := ""
                sModel := RC_JaxRego(rego, st, sX, sTrim, sYear, sCab)
            }
            if (sModel = "") {
                RC_Progress(3, "fitment")
                sModel := RC_AbVin(rego, st, sX, sTrim)
            }
            if (vinModel = "" && sModel != "") {
                vinModel := sModel
                if (sYear != "")
                    vinYear := sYear
            }
            if (sX != "" && mkX = "")
                mkX := sX
            if (sTrim != "" && trm = "")
                trm := sTrim

            ; The shop's rows go in above the wipers. JAX and Autobarn only
            ; carry the cab, so that goes in on its own when they answered.
            if IsObject(sInfo)
                RC_MtsRows(sInfo)
            else if (sCab != "") {
                LV_Insert(RC_WipeRow, "", "Cab/Body", sCab)
                RC_WipeRow += 1
            }
            bodyHint := IsObject(sInfo) ? sInfo.name . " " . sInfo.cab : sCab
        }
    }

    ; The states register a Genesis as a HYUNDAI, but the badge and the wiper
    ; workbook both say GENESIS. The VIN tells the two apart - Hyundais start
    ; KMH, a Genesis starts KMT or KMU - so the make is put right here, after
    ; the lookups above have already used the registered name.
    if (InStr(make, "HYUNDAI") && (SubStr(vin, 1, 3) = "KMT" || SubStr(vin, 1, 3) = "KMU"))
        make := "GENESIS"

    ; The make goes up in bold with the car spelled out beside it in
    ; ordinary weight - model and trim first, then the engine and fuel.
    if (trm != "" && !InStr(" " . vinModel . " ", " " . trm . " "))
        tag := RC_NiceName(vinModel . " " . trm)
    else
        tag := RC_NiceName(vinModel)
    if (mkX != "")
        tag .= (tag != "" ? ", " : "") . mkX
    tag := RC_TagTail(tag, make, bodyHint . " " . mkX . " " . trm . " " . body)
    RC_SetMake(make, tag, st)

    RC_WipeFind(make, year, body, vinModel, vinYear, genTag, trm)
    RC_WipeShow()
    RC_WipeOnline((plate != "") ? plate : RC_Norm(reg), st)

    ; The state only ever says "UTIL"; whichever shop answered knows whether
    ; that is a tub or a cab chassis, so its words are handed over as the hint.
    RC_PrettyRows(bodyHint)
    RC_DropDupes()
    RC_FitList()
}

; First value whose label matches the pattern, or "" if the state did not send
; anything like it.
RC_Pick(labels, values, pattern) {
    for i, lb in labels {
        if RegExMatch(lb, pattern)
            return values[i]
    }
    return ""
}

; Pull a date out of whatever the state wrote around it and hand it back as
; YYYYMMDD so it can be compared against today. "" if there is no date in there.
RC_ExpiryDate(val) {
    static MON := "janfebmaraprmayjunjulaugsepoctnovdec"
    if RegExMatch(val, "(\d{1,2})\s*[/\-.]\s*(\d{1,2})\s*[/\-.]\s*(\d{2,4})", m) {
        d := m1, mo := m2, y := m3
    } else if RegExMatch(val, "i)(\d{1,2})\s*[-\s]\s*([A-Za-z]{3})[A-Za-z]*\s*[-,\s]\s*(\d{2,4})", m) {
        d := m1, y := m3
        name := m2
        StringLower, name, name
        mo := (InStr(MON, name) + 2) // 3
    } else {
        return ""
    }
    if (StrLen(y) = 2)
        y += 2000
    if (mo < 1 || mo > 12 || d < 1 || d > 31)
        return ""
    return Format("{:04}{:02}{:02}", y, mo, d)
}

; Windows paints the list one row at a time and asks about each. Every row is
; left alone bar the expiry one when the rego has run out, which goes red.
RC_OnNotify(wParam, lParam) {
    global RC_hLV, RC_RedRow
    static NM_CUSTOMDRAW := -12
    static CDDS_PREPAINT := 1, CDDS_ITEMPREPAINT := 0x10001
    static CDRF_DODEFAULT := 0, CDRF_NEWFONT := 2, CDRF_NOTIFYITEMDRAW := 0x20

    if (RC_hLV = 0 || RC_RedRow = 0)
        return
    if (NumGet(lParam + 0, 0, "Ptr") != RC_hLV)
        return
    if (NumGet(lParam + 0, 2 * A_PtrSize, "Int") != NM_CUSTOMDRAW)
        return

    ; NMLVCUSTOMDRAW is packed differently under 32 and 64 bit.
    stageOff := (A_PtrSize = 8) ? 24 : 12
    itemOff  := (A_PtrSize = 8) ? 56 : 36
    textOff  := (A_PtrSize = 8) ? 80 : 48

    stage := NumGet(lParam + 0, stageOff, "UInt")
    if (stage = CDDS_PREPAINT)
        return CDRF_NOTIFYITEMDRAW
    if (stage = CDDS_ITEMPREPAINT) {
        if (NumGet(lParam + 0, itemOff, "UPtr") + 1 = RC_RedRow) {
            NumPut(0x2D2DA3, lParam + 0, textOff, "UInt")   ; COLORREF is BGR
            return CDRF_NEWFONT
        }
    }
    return CDRF_DODEFAULT
}

; Find whatever passes for a VIN in a state's answer. Victoria hands over the
; whole 17 characters; Access Canberra only gives the last four. Both are worth
; copying, so take the longest one on offer and let the caller say which it got.
RC_FindVIN(text, ByRef label) {
    best  := ""
    label := ""
    for i, line in StrSplit(text, "`n", "`r") {
        p := InStr(line, ": ")
        if !p
            continue
        lb := Trim(SubStr(line, 1, p - 1))
        if !RegExMatch(lb, "i)\b(vin|chassis)\b")
            continue
        val := Trim(SubStr(line, p + 2))
        ; Anything with punctuation or spaces in it is prose, not a number.
        if !RegExMatch(val, "^[0-9A-Za-z]{4,17}$")
            continue
        if (StrLen(val) > StrLen(best)) {
            best  := val
            label := lb
        }
    }
    return best
}

; The green bar. It stays up until the next search clears it, so the VIN it is
; showing is still on screen while the copy gets pasted somewhere else.
RC_ShowToast(msg) {
    ; "VIN copied   MPAT..." - the words go on the pill, the VIN beside it.
    label := msg, val := ""
    if (p := InStr(msg, "   ")) {
        label := SubStr(msg, 1, p - 1)
        val := LTrim(SubStr(msg, p))
    }
    ; The pill is a narrow one so the VIN can start where the box above it
    ; starts, so the word on it is cut to what the pill can hold. The VIN is
    ; right beside it - nothing is lost by not repeating "VIN".
    label := InStr(label, "Partial") ? "Partial" : "Copied"
    GuiControl, RC:, RC_Toast, %label%
    GuiControl, RC:, RC_ToastVal, %val%
    GuiControl, RC:Show, RC_ToastBar
    GuiControl, RC:Show, RC_Toast
    GuiControl, RC:Show, RC_ToastVal
}

RC_HideToast() {
    GuiControl, RC:Hide, RC_Toast
    GuiControl, RC:Hide, RC_ToastBar
    GuiControl, RC:Hide, RC_ToastVal
}

; A second copy of the VIN right under the cursor, so it can be read without
; looking away from wherever it is about to be pasted. Gone in two seconds.
RC_TipAtMouse(vin) {
    ; Both have to be screen coordinates. Left on the default, MouseGetPos
    ; answers relative to the active window and the tip lands nowhere near the
    ; cursor.
    CoordMode, Mouse, Screen
    CoordMode, ToolTip, Screen
    MouseGetPos, mx, my
    ToolTip, %vin%, mx + 16, my + 16
    SetTimer, RC_KillTip, -2000
}

RC_KillTip() {
    ToolTip
}

; Double-click a row to copy that value.
RC_OnList() {
    if (A_GuiEvent != "DoubleClick" || A_EventInfo = 0)
        return
    Gui, RC:Default
    LV_GetText(val, A_EventInfo, 2)
    if (val != "") {
        Clipboard := val
        RC_Done(true, "Copied", "")
    }
}

; Put the caret back in the plate box with the old plate selected, so the next
; one can be typed straight over the top.
RC_SelectPlate() {
    global RC_hEdit
    GuiControl, RC:Focus, RC_Plate
    SendMessage, 0x00B1, 0, -1, , ahk_id %RC_hEdit%   ; EM_SETSEL - select all
}

RCGuiClose:
RCGuiEscape:
    Gui, RC:Hide
return

; Bring the window back, with whatever is on the clipboard as a starting point.
^!r::
    plate := RC_Norm(Clipboard)
    if RegExMatch(plate, "^[0-9A-Z]{1,8}$") || (StrLen(plate) = 17)
        GuiControl, RC:, RC_Plate, %plate%
    Gui, RC:Show
    RC_SelectPlate()
return

; Page Down brings the window to the top from anywhere - or back up from the
; tray if it was closed away - with the old plate selected, ready to be typed
; straight over. Closing the window only hides it, so this keeps working.
XButton2::
RC_TrayShow:
    Gui, RC:Show
    RC_SelectPlate()
return


; --- one plate, one state --------------------------------------------------
; Every RC_<state> below answers the same three ways:
;   ""            that state has no such plate - move on to the next
;   "!something"  that state could not be asked - note it and move on
;   anything else the answer, as "Label: value" lines

RC_State(state, plate, mode := "plate") {
    if (state = "VIC")
        return RC_VIC(plate, mode)
    ; Only Victoria has a VIN box. Everyone else would just be asked nonsense.
    if (mode = "vin")
        return ""
    if (state = "SA")
        return RC_SA(plate)
    if (state = "ACT")
        return RC_ACT(plate)
    if (state = "WA")
        return RC_WA(plate)
    if (state = "QLD")
        return RC_QLD(plate)
    return "!no lookup written for " . state
}

; Plates get typed with spaces and dashes as often as not.
RC_Norm(s) {
    s := Trim(s, " `t`r`n")
    s := RegExReplace(s, "[^0-9A-Za-z]", "")
    StringUpper, s, s
    return s
}


; --- VIC - VicRoads --------------------------------------------------------
; 1. GET the enquiry page. WinHTTP holds the session cookie.
; 2. Read the hidden fields straight out of the form on that page - the
;    anti-forgery token, the uid, and the item ids. They change every session,
;    so nothing is hardcoded.
; 3. POST those same fields back with the plate filled in.

RC_VIC(plate, mode := "plate") {
    global RC_VIC_HOST, RC_VIC_PATH

    if !RC_Open(RC_VIC_HOST)
        return "!could not connect"

    page := RC_Send("GET", RC_VIC_PATH)
    if (page = "") {
        RC_Close()
        return "!no answer loading the form"
    }

    form := RC_FormBlock(page, "id=""RegistrationNumbercar""")
    if (form = "") {
        RC_Close()
        return "!the page has changed, no search form found"
    }

    body   := RC_VICPost(form, plate, mode)
    result := RC_Send("POST", RC_VIC_PATH, body, "", "https://" . RC_VIC_HOST . RC_VIC_PATH)
    RC_Close()

    if (result = "")
        return "!no answer when searching"

    out := RC_DtDd(result)
    if (out != "")
        return out

    ; No pairs came back, so this is either "no such plate" or a complaint about
    ; one. Either way Victoria has nothing - let the next state have a go.
    return ""
}

; Copy every field of the form back to VicRoads, with the plate dropped in.
; The form carries a box for every kind of identifier and a dropdown saying
; which one was filled in. A plate goes in "RegistrationNumbercar", a VIN in
; "VIN", and the dropdown is set to match.
RC_VICPost(form, plate, mode := "plate") {
    box  := (mode = "vin") ? "VIN" : "RegistrationNumbercar"
    pick := (mode = "vin") ? "vin" : "registration"
    data := ""
    pos  := 1
    while (pos := RegExMatch(form, "i)<input\b[^>]*>", tag, pos)) {
        pos += StrLen(tag)
        nm := RC_Attr(tag, "name")
        if (nm = "")
            continue
        ty := RC_Attr(tag, "type")
        if (ty = "submit" || ty = "button" || ty = "checkbox" || ty = "radio")
            continue
        val := RC_Dec(RC_Attr(tag, "value"))
        if (RC_Attr(tag, "id") = box)
            val := plate
        data := RC_Add(data, nm, val)
    }
    pos := 1
    while (pos := RegExMatch(form, "i)<select\b[^>]*>", tag, pos)) {
        pos += StrLen(tag)
        nm := RC_Attr(tag, "name")
        if (nm = "")
            continue
        id  := RC_Attr(tag, "id")
        val := (id = "VehicleType") ? "car" : (id = "VehicleIdentifier") ? pick : ""
        data := RC_Add(data, nm, val)
    }
    return data
}


; --- SA - EzyReg -----------------------------------------------------------
; The page is a JavaScript wizard, but the wizard only calls one endpoint and
; that endpoint wants plain JSON. No token, no captcha. Load the page once so
; the session cookie exists, then ask it straight out.

RC_SA(plate) {
    global RC_SA_HOST
    static START := "/account/check-registration.htm"
    static API   := "/r/veh/an/checkRegistration"

    if !RC_Open(RC_SA_HOST)
        return "!could not connect"

    RC_Send("GET", START)

    body := "{""plateNumber"":""" . plate . """,""registrationType"":""VEHICLE""}"
    hdrs := "Accept: application/json, text/javascript, */*; q=0.01`r`n"
          . "X-Requested-With: XMLHttpRequest"
    json := RC_Send("POST", API, body, "application/json"
        , "https://" . RC_SA_HOST . START, hdrs)
    RC_Close()

    if (json = "")
        return "!no answer when searching"

    ; Its way of saying no is a messages array with a plain-English description.
    if InStr(json, """severity"":""ERROR""") || InStr(json, """messages"":[{")
        return ""

    return RC_Json(json)
}


; --- ACT - Access Canberra -------------------------------------------------
; A Wicket wizard in three steps. Step one is the privacy tick and the plate.
; Step two lists what matched. Step three is the detail page, and that is the
; one worth reading - make, colour, expiry, insurer, stolen flags.

RC_ACT(plate) {
    global RC_ACT_HOST
    ; Not called PAGE: AutoHotkey does not tell upper case from lower, so a
    ; static called PAGE and a variable called page are the same box.
    static BASE  := "/regosoawicket/public/reg/"
    static START := "/regosoawicket/public/reg/FindRegistrationPage"

    if !RC_Open(RC_ACT_HOST)
        return "!could not connect"

    page := RC_Send("GET", START)
    if (page = "") {
        RC_Close()
        return "!no answer loading the form"
    }

    ; The form action carries the jsessionid and the page version, both fresh
    ; every visit.
    if !RegExMatch(page, "i)action=""\./(FindRegistrationPage[^""]*)""", m) {
        RC_Close()
        return "!the page has changed, no search form found"
    }

    body := RC_Add("", "privacy:privacyCheck", "on")
    body := RC_Add(body, "view:plateNumber", plate)
    body := RC_Add(body, "buttons:next", "Next >")
    list := RC_Send("POST", BASE . m1, body, "", "https://" . RC_ACT_HOST . START)

    if (list = "") {
        RC_Close()
        return "!no answer when searching"
    }
    if InStr(list, "No matching Registration details") {
        RC_Close()
        return ""
    }

    ; The matched row links through to the detail page. Follow it.
    if RegExMatch(list, "i)\./(FindRegistrationPage\?[^""]*registrationDetailsList-0-select)", m) {
        detail := RC_Send("GET", BASE . m1)
        if (detail != "") {
            out := RC_LabelInputs(detail)
            if (out != "") {
                RC_Close()
                return out
            }
        }
    }
    RC_Close()

    ; No detail page, so read the summary row off the list instead.
    return RC_Table(list, "Search result for plate number")
}


; --- WA - DoTDirect --------------------------------------------------------
; Wicket again, but this form posts over AJAX. The answer to that post is not
; the result - it is a redirect to a freshly built page. Follow it.

RC_WA(plate) {
    global RC_WA_HOST
    static BASE := "/webExternal/registration/"

    if !RC_Open(RC_WA_HOST)
        return "!could not connect"

    page := RC_Send("GET", BASE)
    if (page = "") {
        RC_Close()
        return "!no answer loading the form"
    }

    form := RC_FormBlock(page, "name=""registrationRequestForm""")
    if (form = "") {
        RC_Close()
        return "!the page has changed, no search form found"
    }

    ; The Send button's onclick holds the URL its AJAX post goes to. The page
    ; version in it moves every visit, so it has to be read, not guessed.
    if !RegExMatch(page, "i)\./(\?\d+-\d+\.IBehaviorListener\.\d+-[A-Za-z_\-]*registrationRequestForm-searchButton)", m) {
        RC_Close()
        return "!the page has changed, no search button found"
    }

    ; Wicket wants its own hidden field handed back, whatever it is called.
    hidden := ""
    if RegExMatch(form, "i)<input[^>]*type=""hidden""[^>]*>", tag)
        hidden := RC_Attr(tag, "name")

    body := (hidden = "") ? "" : RC_Add("", hidden, "")
    body := RC_Add(body, "plateField", plate)
    body := RC_Add(body, "searchButton", "1")
    hdrs := "Wicket-Ajax: true`r`nWicket-Ajax-BaseURL: ?0`r`nX-Requested-With: XMLHttpRequest"

    ajax := RC_Send("POST", BASE . m1, body, "", "https://" . RC_WA_HOST . BASE . "?0", hdrs)
    if (ajax = "") {
        RC_Close()
        return "!no answer when searching"
    }

    if !RegExMatch(ajax, "is)<redirect>\s*(?:<!\[CDATA\[)?\s*\.?/?([^\]<]+?)\s*(?:\]\]>)?\s*</redirect>", m) {
        RC_Close()
        return "!the search did not lead anywhere"
    }

    result := RC_Send("GET", BASE . m1)
    RC_Close()

    if (result = "")
        return "!no answer reading the result"
    if InStr(result, "no registration details for the plate number")
        return ""

    return RC_Loose(result, "Vehicle Licence Check Enquiry", "DoTDirect Home")
}


; --- QLD - TMR Check Rego --------------------------------------------------
; JSF. Every page carries a ViewState that the next post has to hand back, and
; the terms have to be accepted before the search page will show itself.

RC_QLD(plate) {
    global RC_QLD_HOST
    static SEARCH := "/checkrego/application/VehicleSearch.xhtml"
    static TERMS  := "/checkrego/application/TermAndConditions.xhtml"

    if !RC_Open(RC_QLD_HOST)
        return "!could not connect"

    ; Asking for the search page lands us on the terms instead.
    page := RC_Send("GET", SEARCH)
    if (page = "") {
        RC_Close()
        return "!no answer loading the form"
    }

    win := RC_Hidden(page, "javax.faces.ClientWindow")
    vs  := RC_Hidden(page, "javax.faces.ViewState")

    ; Only accept the terms if we were actually shown them.
    if InStr(page, "id=""tAndCForm""") {
        if (vs = "") {
            RC_Close()
            return "!the page has changed, no view state found"
        }
        body := RC_Add("", "tAndCForm_SUBMIT", "1")
        body := RC_Add(body, "tAndCForm:confirmButton", "")
        body := RC_Add(body, "javax.faces.ViewState", vs)
        body := RC_Add(body, "javax.faces.ClientWindow", win)
        page := RC_Send("POST", TERMS . "?dswid=" . win, body, ""
            , "https://" . RC_QLD_HOST . TERMS)
        if (page = "") {
            RC_Close()
            return "!no answer accepting the terms"
        }
        vs := RC_Hidden(page, "javax.faces.ViewState")
    }

    if !InStr(page, "vehicleSearchForm:plateNumber") {
        RC_Close()
        return "!could not reach the search page"
    }

    body := RC_Add("", "vehicleSearchForm_SUBMIT", "1")
    body := RC_Add(body, "vehicleSearchForm:plateNumber", plate)
    body := RC_Add(body, "vehicleSearchForm:referenceId", "")
    body := RC_Add(body, "vehicleSearchForm:confirmButton", "")
    body := RC_Add(body, "javax.faces.ViewState", vs)
    body := RC_Add(body, "javax.faces.ClientWindow", win)

    result := RC_Send("POST", SEARCH . "?dswid=" . win, body, ""
        , "https://" . RC_QLD_HOST . SEARCH)
    RC_Close()

    if (result = "")
        return "!no answer when searching"
    if InStr(result, "Registration not found")
        return ""

    return RC_Loose(result, "Vehicle details", "Need Help?")
}


; --- the WinHTTP session ---------------------------------------------------
; One session handle per state, so WinHTTP carries that state's cookies from
; one request to the next by itself.

RC_Open(host) {
    global RC_hSess, RC_hConn, RC_UA
    RC_Close()
    RC_hSess := DllCall("winhttp\WinHttpOpen", "wstr", RC_UA
        , "uint", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr")
    if !RC_hSess
        return false
    ; Short enough that a dead site hands the window back in seconds, long
    ; enough that a slow one still gets its say.
    DllCall("winhttp\WinHttpSetTimeouts", "ptr", RC_hSess
        , "int", 6000, "int", 6000, "int", 10000, "int", 12000)
    RC_hConn := DllCall("winhttp\WinHttpConnect", "ptr", RC_hSess
        , "wstr", host, "ushort", 443, "uint", 0, "ptr")
    if !RC_hConn {
        RC_Close()
        return false
    }
    return true
}

RC_Close() {
    global RC_hSess, RC_hConn
    if RC_hConn
        DllCall("winhttp\WinHttpCloseHandle", "ptr", RC_hConn)
    if RC_hSess
        DllCall("winhttp\WinHttpCloseHandle", "ptr", RC_hSess)
    RC_hConn := 0
    RC_hSess := 0
}

RC_Send(method, path, body := "", ctype := "", referer := "", extra := "", hConn := 0) {
    global RC_hConn
    static SECURE  := 0x00800000    ; WINHTTP_FLAG_SECURE
    static ADD_HDR := 0x20000000    ; WINHTTP_ADDREQ_FLAG_ADD
    static MAXLEN  := 4194304       ; 4 MB is far more than these pages need

    ; The shared connection unless the caller brought its own - EzyParts does,
    ; so its login can outlive everything the shared one is opened and closed
    ; for in between.
    if (hConn = 0)
        hConn := RC_hConn

    hReq := DllCall("winhttp\WinHttpOpenRequest", "ptr", hConn
        , "wstr", method, "wstr", path, "ptr", 0, "ptr", 0, "ptr", 0
        , "uint", SECURE, "ptr")
    if !hReq
        return ""

    hdrs := "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8`r`n"
          . "Accept-Language: en-AU,en;q=0.9`r`n"
          . "Upgrade-Insecure-Requests: 1"
    if (method = "POST") {
        hdrs .= "`r`nContent-Type: " . (ctype = "" ? "application/x-www-form-urlencoded" : ctype)
        if (referer != "")
            hdrs .= "`r`nOrigin: " . RegExReplace(referer, "^(https?://[^/]+).*$", "$1")
    }
    if (referer != "")
        hdrs .= "`r`nReferer: " . referer
    if (extra != "")
        hdrs .= "`r`n" . extra

    DllCall("winhttp\WinHttpAddRequestHeaders", "ptr", hReq
        , "wstr", hdrs, "uint", -1, "uint", ADD_HDR)

    len := 0
    if (body != "") {
        VarSetCapacity(post, StrPut(body, "UTF-8"), 0)
        len := StrPut(body, &post, "UTF-8") - 1
    }

    ok := DllCall("winhttp\WinHttpSendRequest", "ptr", hReq, "ptr", 0, "uint", 0
        , "ptr", len ? &post : 0, "uint", len, "uint", len, "ptr", 0)
    if (!ok || !DllCall("winhttp\WinHttpReceiveResponse", "ptr", hReq, "ptr", 0)) {
        DllCall("winhttp\WinHttpCloseHandle", "ptr", hReq)
        return ""
    }

    VarSetCapacity(out, MAXLEN, 0)
    total := 0
    Loop {
        avail := 0
        if !DllCall("winhttp\WinHttpQueryDataAvailable", "ptr", hReq, "uint*", avail)
            break
        if (avail = 0)
            break
        if (total + avail > MAXLEN - 1)
            avail := MAXLEN - 1 - total
        if (avail <= 0)
            break
        read := 0
        if !DllCall("winhttp\WinHttpReadData", "ptr", hReq
            , "ptr", &out + total, "uint", avail, "uint*", read)
            break
        if (read = 0)
            break
        total += read
    }
    NumPut(0, out, total, "UChar")
    DllCall("winhttp\WinHttpCloseHandle", "ptr", hReq)
    return StrGet(&out, total, "UTF-8")
}


; --- reading the pages -----------------------------------------------------

; Pull out the one <form> on the page that contains the given marker.
RC_FormBlock(html, marker) {
    for i, part in StrSplit(html, "<form") {
        if InStr(part, marker) {
            e := InStr(part, "</form>")
            return e ? SubStr(part, 1, e - 1) : part
        }
    }
    return ""
}

; The value of a hidden input, by name. JSF repeats the same one a dozen times
; over, so the first is as good as any.
RC_Hidden(html, name) {
    if RegExMatch(html, "i)<input[^>]*name=""" . name . """[^>]*>", tag)
        return RC_Dec(RC_Attr(tag, "value"))
    if RegExMatch(html, "i)<input[^>]*name='" . name . "'[^>]*>", tag)
        return RC_Dec(RC_Attr(tag, "value"))
    return ""
}

; VicRoads lists its answer as label/value pairs in <dt>/<dd> tags.
RC_DtDd(html) {
    out := ""
    pos := 1
    while (pos := RegExMatch(html, "is)<dt\b[^>]*>(.*?)</dt>\s*<dd\b[^>]*>(.*?)</dd>", m, pos)) {
        pos += StrLen(m)
        label := RC_Text(m1)
        value := RC_Text(m2)
        if (label = "" && value = "")
            continue
        out .= label . ": " . value . "`n"
    }
    return Trim(out, "`n")
}

; Access Canberra's detail page is <label for="x"> against <input id="x" value>.
RC_LabelInputs(html) {
    out := ""
    pos := 1
    while (pos := RegExMatch(html, "is)<label[^>]*\bfor=""([^""]+)""[^>]*>(.*?)</label>", m, pos)) {
        pos += StrLen(m)
        id    := m1
        label := Trim(RC_Text(m2), " :")
        if (label = "")
            continue
        if !RegExMatch(html, "is)<input[^>]*\bid=""" . id . """[^>]*>", tag)
            continue
        value := Trim(RC_Dec(RC_Attr(tag, "value")))
        if (value = "")
            continue
        out .= label . ": " . value . "`n"
    }
    return Trim(out, "`n")
}

; A single-row table read as its headings against its cells.
RC_Table(html, marker) {
    p := InStr(html, marker)
    if !p
        return ""
    block := SubStr(html, p)
    e := InStr(block, "</table>")
    if e
        block := SubStr(block, 1, e)

    heads := []
    pos := 1
    while (pos := RegExMatch(block, "is)<th\b[^>]*>(.*?)</th>", m, pos)) {
        pos += StrLen(m)
        heads.Push(RC_Text(m1))
    }
    out := ""
    n   := 0
    pos := 1
    while (pos := RegExMatch(block, "is)<td\b[^>]*>(.*?)</td>", m, pos)) {
        pos += StrLen(m)
        n++
        value := RC_Text(m1)
        if (value = "")
            continue
        label := (n <= heads.Length()) ? heads[n] : "Detail"
        out .= label . ": " . value . "`n"
    }
    return Trim(out, "`n")
}

; Last resort for pages whose result layout has not been pinned down. Cut the
; page down to the part between two landmarks, then keep the lines that read
; like a label against a value.
RC_Loose(html, startMark, endMark) {
    block := html
    p := InStr(block, startMark)
    if p
        block := SubStr(block, p)
    e := InStr(block, endMark)
    if (e > 1)
        block := SubStr(block, 1, e - 1)

    out := RC_LabelInputs(block)
    if (out != "")
        return out
    out := RC_DtDd(block)
    if (out != "")
        return out

    text := RC_Text(block)
    out  := ""
    for i, line in StrSplit(text, "`n", "`r") {
        line := Trim(line)
        if (StrLen(line) < 3 || StrLen(line) > 120)
            continue
        if !RegExMatch(line, "^[^:]{2,60}:\s*\S")
            continue
        out .= RegExReplace(line, "\s*:\s*", ": ", , 1) . "`n"
    }
    return Trim(out, "`n")
}

; EzyReg answers in JSON. Nothing nested matters to us, so read the flat
; name/value pairs and tidy the names up for the list.
RC_Json(json) {
    out := ""
    pos := 1
    while (pos := RegExMatch(json, "\""([A-Za-z][A-Za-z0-9_]*)\""\s*:\s*(\""((?:[^\""\\]|\\.)*)\""|-?\d+(?:\.\d+)?|true|false)", m, pos)) {
        pos += StrLen(m)
        key := m1
        val := (SubStr(m2, 1, 1) = """") ? m3 : m2
        val := StrReplace(val, "\/", "/")
        val := StrReplace(val, "\""", """")
        val := StrReplace(val, "\\", "\")
        if (val = "")
            continue
        ; plateNumber -> Plate Number
        label := RegExReplace(key, "([a-z0-9])([A-Z])", "$1 $2")
        StringUpper, first, % SubStr(label, 1, 1)
        label := first . SubStr(label, 2)
        out .= label . ": " . val . "`n"
    }
    return Trim(out, "`n")
}

RC_Add(data, nm, val) {
    return (data = "" ? "" : data . "&") . RC_Enc(nm) . "=" . RC_Enc(val)
}

; Pull one attribute out of a tag. The leading space matters - without it
; "name" would also match "data-application-name".
RC_Attr(tag, attr) {
    if RegExMatch(tag, "i)\s" . attr . "\s*=\s*""([^""]*)""", m)
        return m1
    if RegExMatch(tag, "i)\s" . attr . "\s*=\s*'([^']*)'", m)
        return m1
    return ""
}

RC_Dec(s) {
    s := StrReplace(s, "&quot;", """")
    s := StrReplace(s, "&#39;", "'")
    s := StrReplace(s, "&#039;", "'")
    s := StrReplace(s, "&lt;", "<")
    s := StrReplace(s, "&gt;", ">")
    s := StrReplace(s, "&amp;", "&")
    return s
}

RC_Enc(s) {
    VarSetCapacity(buf, StrPut(s, "UTF-8"), 0)
    n   := StrPut(s, &buf, "UTF-8") - 1
    out := ""
    Loop, %n%
    {
        c  := NumGet(buf, A_Index - 1, "UChar")
        ch := Chr(c)
        ; The colon is left alone on purpose. Wicket names its fields
        ; "view:plateNumber" and will not see the field at all if the colon
        ; arrives as %3A.
        if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            || ch = "-" || ch = "_" || ch = "." || ch = "~" || ch = ":")
            out .= ch
        else
            out .= "%" . Format("{:02X}", c)
    }
    return out
}

RC_Text(html) {
    html := RegExReplace(html, "is)<(script|style)\b.*?</\1>", "")
    html := RegExReplace(html, "is)<!--.*?-->", "")
    html := RegExReplace(html, "i)<(br|/p|/div|/li|/tr|/h[1-6]|/label|/dd|/td|/th)\b[^>]*>", "`n")
    html := RegExReplace(html, "s)<[^>]*>", " ")
    html := StrReplace(html, "&nbsp;", " ")
    html := RC_Dec(html)
    html := RegExReplace(html, "[ `t]+", " ")
    out := ""
    for i, line in StrSplit(html, "`n", "`r") {
        line := Trim(line)
        if (line != "")
            out .= (out = "" ? "" : "`n") . line
    }
    return out
}

; --- wipers ----------------------------------------------------------------
;
; The states name the make and the year of a car but never its model, so the
; workbook cannot be looked up directly. Everything that make built in that year
; is offered instead and the dropdown settles it. When every candidate carries
; the same three sizes the question makes no difference and it answers itself.

; Read the table in once, at startup.
RC_WipeLoad() {
    global RC_WIPE
    RC_WIPE := []
    for i, line in StrSplit(RC_WipeData(), "`n", "`r") {
        if (line = "")
            continue
        f := StrSplit(line, "|")
        if (f.Length() < 7)
            continue
        RC_WIPE.Push({ brand: f[1], model: f[2], y1: f[3] + 0, y2: f[4] + 0
                     , drv: f[5], pas: f[6], rear: f[7], body: RC_BodyOf(f[2]) })
    }
}

; Every fitment that could be this car, newest generation first. The body type
; only narrows it when the workbook line names a body itself - most do not, and
; a line that stays quiet about it has to stay in the running.
RC_WipeFind(make, year, body, model := "", modelYear := "", genTag := "", trimTag := "") {
    global RC_Cands, RC_ModelPick, RC_WIPE
    RC_Cands := []
    RC_ModelPick := 0
    if (make = "" || year + 0 = 0) {
        RC_WipeReset()
        return
    }
    RC_Cands := RC_WipeYear(make, year, body)

    ; A named model cuts the list down to that one car. Kia quotes the model
    ; year and the states quote the build year, and the two can sit a year
    ; apart, so the other year gets a go if the first turns nothing up. A name
    ; the workbook has never heard of leaves the list alone rather than emptying
    ; it.
    if (model != "") {
        narrow := RC_WipeByName(RC_Cands, model)
        if (narrow.Length() = 0 && modelYear + 0 != 0 && modelYear + 0 != year + 0)
            narrow := RC_WipeByName(RC_WipeYear(make, modelYear, body), model)
        if (narrow.Length() > 0)
            RC_Cands := narrow
    }

    ; A generation read out of the VIN trims the list to that generation's
    ; rows. A tag that matches nothing leaves the list alone, same as a name
    ; the workbook has never heard of.
    if (genTag != "") {
        narrow := []
        for i, ix in RC_Cands
            if InStr(RC_WIPE[ix].model, genTag)
                narrow.Push(ix)
        if (narrow.Length() > 0)
            RC_Cands := narrow
    }

    ; A trim splits the rows that name trims - Isuzu's RG rows differ only by
    ; the trims in their brackets. Tried a word at a time, since the shops say
    ; "SX Hi-Ride" where the workbook just says SX. A trim the workbook never
    ; mentions leaves the list alone, same as everything above.
    if (trimTag != "") {
        Loop, Parse, trimTag, %A_Space%
        {
            ; A single letter would land as a substring of nearly every row.
            if (StrLen(A_LoopField) < 2)
                continue
            narrow := []
            for i, ix in RC_Cands
                if InStr(RC_WIPE[ix].model, A_LoopField)
                    narrow.Push(ix)
            if (narrow.Length() > 0) {
                RC_Cands := narrow
                break
            }
        }
    }

    ; Newest first, so the likely answer sits at the top of the dropdown.
    RC_Cands := RC_SortCands(RC_Cands)

    ; The leading bar matters - without it GuiControl adds to the list the
    ; control was built with instead of replacing it, and the prompt turns up
    ; twice.
    list := "|Pick a model"
    for i, ix in RC_Cands {
        w := RC_WIPE[ix]
        list .= "|" . w.model . "  " . w.y1 . "-" . w.y2
    }
    GuiControl, RC:, RC_Model, %list%

    ; One candidate, or several that agree anyway, means nothing to ask.
    if (RC_Cands.Length() = 1 || (RC_Cands.Length() > 1 && RC_WipeAgree())) {
        RC_ModelPick := 1
        GuiControl, RC:Choose, RC_Model, 2
    } else {
        GuiControl, RC:Choose, RC_Model, 1
    }
}

; Everything that make built in that year, before any model name is applied.
RC_WipeYear(make, year, body) {
    global RC_WIPE
    out  := []
    want := RC_BodyOf(body)
    year += 0
    for i, w in RC_WIPE {
        if !InStr(make, w.brand)
            continue
        if (year < w.y1 || year > w.y2)
            continue
        if (want != "" && w.body != "" && w.body != want)
            continue
        out.Push(i)
    }
    return out
}

; The lines that are the model named, ignoring the body word and the generation
; code around it - Kia says "Cerato", the workbook says "Cerato Sedan (BD)".
RC_WipeByName(cands, model) {
    global RC_WIPE
    out  := []
    want := RC_BaseName(model)
    if (want = "")
        return out
    for i, ix in cands {
        if (RC_BaseName(RC_WIPE[ix].model) = want)
            out.Push(ix)
    }
    return out
}

; A model name with the generation code and the body word taken back off it.
RC_BaseName(model) {
    s := RegExReplace(model, "\([^)]*\)", "")
    s := RegExReplace(s, "i)\b(sedan|hatchback|hatch|wagon|coupe|suv)\b", "")
    s := RegExReplace(s, "\s+", " ")
    StringLower, s, s
    return Trim(s)
}

; Kia Australia names a car from its VIN. One form post, no token and no
; session, and the answer carries the model and the model year:
;     <span class="vTitle">2020 Cerato</span>
; Only Kias, and only ones sold here after 2009 - anything else comes back as
; the same "not found" page and this hands back nothing.
RC_KiaVin(vin, ByRef year) {
    static HOST := "dashboard.kia.com.au"
    static PATH := "/kia/cps/kia/kia_manual_download.jsp"
    year := ""
    if (StrLen(vin) != 17)
        return ""
    if !RC_Open(HOST)
        return ""
    page := RC_Send("POST", PATH . "?find=true", "vin=" . RC_Enc(vin)
                  , "application/x-www-form-urlencoded"
                  , "https://" . HOST . PATH)
    RC_Close()
    if !RegExMatch(page, "is)class=""vTitle"">\s*(\d{4})\s+([^<]+?)\s*</span>", m)
        return ""
    year := m1
    return Trim(m2)
}

; The US regulator's VIN decoder, for the makes that offer nothing themselves.
; Free JSON API, no token and no captcha, and it knows Hyundai and Genesis
; models because those same cars are sold in America. Cars never sold there
; come back with an empty model, and this hands back nothing - the dropdown
; then asks as it always did.
RC_NhtsaVin(vin, ByRef year, ByRef extra := "", ByRef trim := "") {
    static HOST := "vpic.nhtsa.dot.gov"
    year := ""
    extra := ""
    if (StrLen(vin) != 17)
        return ""
    if !RC_Open(HOST)
        return ""
    page := RC_Send("GET", "/api/vehicles/DecodeVinValues/" . RC_Enc(vin) . "?format=json")
    RC_Close()
    if !RegExMatch(page, "i)""Model""\s*:\s*""([^""]+)""", m)
        return ""
    if RegExMatch(page, "i)""ModelYear""\s*:\s*""(\d{4})""", y)
        year := y1

    ; The same answer names the fuel and the engine size. America says
    ; Gasoline, the brackets say Petrol, and a hybrid shows up in the
    ; electrification level rather than the fuel.
    fuel := ""
    if RegExMatch(page, "i)""ElectrificationLevel""\s*:\s*""([^""]+)""", el) {
        if RegExMatch(el1, "i)plug")
            fuel := "Plug-in hybrid"
        else if RegExMatch(el1, "i)HEV|hybrid")
            fuel := "Hybrid"
        else if RegExMatch(el1, "i)BEV|electric")
            fuel := "Electric"
    }
    if (fuel = "" && RegExMatch(page, "i)""FuelTypePrimary""\s*:\s*""([^""]+)""", f)) {
        if RegExMatch(f1, "i)gasoline|petrol")
            fuel := "Petrol"
        else if RegExMatch(f1, "i)diesel")
            fuel := "Diesel"
        else if RegExMatch(f1, "i)electric")
            fuel := "Electric"
    }
    eng := ""
    if RegExMatch(page, "i)""DisplacementL""\s*:\s*""(\d+(\.\d+)?)""", d)
        eng := Round(d1, 1) . "L"
    if (fuel != "")
        extra := (eng != "" && fuel != "Electric") ? eng . " " . fuel : fuel

    ; The decoder names the trim too - "2.0T Elite", "3.5T Sport". When it
    ; cannot pin one it lists every trim the model has, comma-separated -
    ; that is a menu, not this car, so it is dropped. A single value is the
    ; real trim; the leading engine token repeats the brackets and goes, and
    ; what is left is the trim word on its own.
    trim := ""
    if (RegExMatch(page, "i)""Trim""\s*:\s*""([^""]+)""", tm) && !InStr(tm1, ",") && !InStr(tm1, "/")) {
        t := RegExReplace(tm1, "i)^\s*\d(?:\.\d)?\s*T?\b", "")
        trim := Trim(RegExReplace(t, "\s+", " "))
    }
    return Trim(m1)
}

; The Kia parts catalogue names the whole build from the VIN - year, model,
; engine, transmission and trim in one line: "2020 Cerato 1.6L AT GT". Same
; deal as the manual page: one post, no token and no session. Only the official
; store answers plain HTTP - the dealer copies of this site sit behind a bot
; check.
RC_KiaSpec(vin) {
    static HOST := "parts.kia.com.au"
    if (StrLen(vin) != 17)
        return ""
    if !RC_Open(HOST)
        return ""
    body := "{""VinNumber"":""" . vin . """,""AbsolutePath"":""%2Fdefault.aspx"",""QueryString"":""""}"
    page := RC_Send("POST", "/wm.aspx/CreateVinLinks", body, "application/json; charset=utf-8")
    RC_Close()
    if !RegExMatch(page, "vehicleDescription\\"":\\""([^\\""]+)", m)
        return ""
    return m1
}

; The catalogue line boiled down to what fits in brackets beside the make:
; engine size and fuel. Kia's wording says HYBRID or PHEV when it is one, CRDi
; or DSL when it burns diesel, and nothing at all when it is petrol. The
; electric ones have no engine size and carry EV in the model name instead.
RC_FuelOf(spec) {
    fuel := ""
    if RegExMatch(spec, "i)plug.?in|PHEV")
        fuel := "Plug-in hybrid"
    else if RegExMatch(spec, "i)hybrid|\bHEV\b")
        fuel := "Hybrid"
    else if RegExMatch(spec, "i)CRDI|\bDSL\b|diesel")
        fuel := "Diesel"
    else if RegExMatch(spec, "i)\bEV\d|electric|\bBEV\b")
        fuel := "Electric"
    eng := ""
    if RegExMatch(spec, "i)\b(\d+\.\d+)\s*L\b", e)
        eng := e1 . "L"
    if (fuel = "")
        fuel := (eng != "") ? "Petrol" : ""
    if (eng != "" && fuel != "Electric")
        return eng . " " . fuel
    return fuel
}

; Hyundai's VIN carries the model in plain sight: the first three characters
; say which factory family - KMH cars, KM8 the bigger SUVs, KMF the vans - and
; the fourth names the model line. A few letters were reused across the years,
; and there the rego year or the body type settles it. Built from real VINs of
; every common line; a letter not listed hands back nothing and the dropdown
; asks as it always did.
RC_HyuVin(vin, year, body, ByRef gen := "") {
    gen := ""
    if (StrLen(vin) != 17)
        return ""
    wmi := SubStr(vin, 1, 3)
    m   := SubStr(vin, 4, 1)
    m2  := SubStr(vin, 5, 1)
    year += 0
    if (wmi = "KMF") {
        if (m = "Y")
            return RegExMatch(body, "i)van") ? "Staria Load" : "Staria"
        if (m = "W")
            return "iLoad"
        return ""
    }
    if (wmi = "KM8") {
        if (m = "J") {
            gen := "(TL"
            return "Tucson"
        }
        if (m = "S")
            return "Santa Fe"
        if (m = "R")
            return "Palisade"
        if (m = "K")
            return "IONIQ 5"
        return ""
    }
    if (wmi != "KMH")
        return ""
    if (m = "B")
        return (m2 = "T") ? "Getz" : "i20"
    if (m = "C")
        return (year >= 2016 && InStr("678", m2)) ? "IONIQ" : "Accent"
    if (m = "D")
        return (year >= 2007 && RegExMatch(body, "i)hatch|wagon|\bhbk\b")) ? "i30" : "Elantra"
    if (m = "E")
        return "Sonata"
    if (m = "G")
        return (year > 0 && year <= 2012) ? "Grandeur" : "Genesis"
    if (m = "H")
        return (year > 0 && year <= 2010) ? "Tiburon" : "i30"
    if (m = "J") {
        if (m2 = "U")
            return "ix35"
        gen := (m2 = "M") ? "(JM" : ((year >= 2020) ? "(NX4" : "")
        return "Tucson"
    }
    if (m = "K")
        return "Kona"
    if (m = "L")
        return InStr("0123456789", m2) ? "Sonata" : ((year > 0 && year <= 2019) ? "i40" : "i30")
    if (m = "N")
        return (year > 0 && year <= 2008) ? "Terracan" : ""
    if (m = "R")
        return "Venue"
    if (m = "T")
        return "Veloster"
    if (m = "V")
        return (year > 0 && year <= 2001) ? "Excel" : ""
    if (m = "W")
        return "iMax"
    if (m = "Y")
        return "Staria"
    return ""
}

; Hyundai's own site answers a VIN with the factory build line through the
; open API behind its owners' pages - "NX4.V1 TUCSON ELITE 2.0D AUTO" - the
; generation code first, then the model, with the trim, engine and gearbox
; around them in either order. Cars from before the mid-2000s come back
; blank, and those fall to the character-reading above.
RC_HmcVin(vin, ByRef gen, ByRef extra, ByRef trim, ByRef my := "") {
    static HOST := "www.hyundai.com"
    gen := ""
    extra := ""
    trim := ""
    if (StrLen(vin) != 17)
        return ""
    if !RC_Open(HOST)
        return ""
    page := RC_Send("GET", "/content/api/au/hyundai/v3/vin/search?vin=" . RC_Enc(vin))
    RC_Close()
    if !RegExMatch(page, """modelDescription"":""([^""]+)""", d)
        return ""
    desc := d1
    model := ""
    if RegExMatch(page, """modelName"":""([^""]+)""", n)
        model := n1
    if (RegExMatch(page, """modelYear"":""(\d{4})""", y) && y1 != "0000")
        my := y1

    ; The generation code is the first word - NF, OS.V4, NX4.V1 - and its
    ; stem is what the wiper table's brackets carry.
    rest := desc
    if RegExMatch(rest, "^([A-Z]{2,4}\d*)(\.\w+)?\s+", g) {
        gen := "(" . g1
        rest := SubStr(rest, StrLen(g) + 1)
    }
    if (model = "")
        model := RegExMatch(rest, "^\S+", w) ? w : ""

    ; Engine size sits as one token - 3.3L, 2.0D, 1.6T - with the fuel in
    ; its last letter or spelled out nearby.
    litre := ""
    eL := ""
    if RegExMatch(desc, "\b(\d\.\d)([LDPT])\b", e) {
        litre := e1
        eL := e2
    }
    fuel := ""
    if RegExMatch(desc, "i)PHEV|PLUG")
        fuel := "Plug-in hybrid"
    else if RegExMatch(desc, "i)\bHEV\b")
        fuel := "Hybrid"
    else if RegExMatch(desc, "i)ELECTRIC|\bEV\b")
        fuel := "Electric"
    else if (eL = "D" || InStr(desc, "CRDI"))
        fuel := "Diesel"
    else if (litre != "")
        fuel := "Petrol"
    if (fuel = "Electric")
        extra := "Electric"
    else if (litre != "")
        extra := litre . "L " . fuel
    else
        extra := fuel

    ; Whatever sits around the model that is not the engine, the gearbox or
    ; the driveline is the trim.
    p := InStr(rest, model)
    if (p)
        rest := SubStr(rest, p + StrLen(model))
    rest := RegExReplace(rest, "\b\d\.\d[LDPT]\b", " ")
    rest := RegExReplace(rest, "i)\b(AUTO|MANUAL|MAN|CVT|DCT|AMT|AT|MT|AWD|4WD|2WD|FWD|RWD|HEV|PHEV|EV|LIFTBACK|SEDAN|HATCH|WAGON|COUPE|VAN)\b", " ")
    trim := Trim(RegExReplace(rest, "\s+", " "))
    trim := RegExReplace(trim, "i)\bPRE?M\b", "Premium")
    trim := RegExReplace(trim, "i)\bS\.?ROOF\b", "Sunroof")
    return model
}

; BYD names itself mostly by body type. The only ute is the Shark 6 - it even
; has its own maker code, LPE. The only sedans are the Seal and, from 2026,
; the plug-in Seal 6. The Dolphin was the only hatch until the Atto 1 arrived
; in 2025, so a hatch is only named up to 2024. The SUVs all share one body
; but the VIN's seventh and eighth characters split them: CB is the Atto 3,
; C4 the Sealion 6 and CD the Sealion 7, read off real cars. The fuel comes
; free with the model - only the Sealion 6, Seal 6 and Shark 6 burn petrol at
; all, as plug-in hybrids; the rest are electric.
RC_BydVin(vin, year, body, ByRef fuel) {
    fuel := ""
    if (SubStr(vin, 1, 3) = "LPE" || RegExMatch(body, "i)util|\bute\b")) {
        fuel := "Plug-in hybrid"
        return "Shark 6"
    }
    if RegExMatch(body, "i)\bsed") {
        if (year + 0 >= 2026) {
            fuel := "Plug-in hybrid"
            return "Seal 6"
        }
        fuel := "Electric"
        return "Seal"
    }
    if (year + 0 > 0 && year + 0 <= 2024 && RegExMatch(body, "i)hatch|\bhbk\b")) {
        fuel := "Electric"
        return "Dolphin"
    }
    if (SubStr(vin, 1, 3) = "LGX" && RegExMatch(body, "i)suv|wagon")) {
        p := SubStr(vin, 7, 2)
        if (p = "CB") {
            fuel := "Electric"
            return "Atto 3"
        }
        if (p = "C4") {
            fuel := "Plug-in hybrid"
            return "Sealion 6"
        }
        if (p = "CD") {
            fuel := "Electric"
            return "Sealion 7"
        }
    }
    return ""
}

; Autobarn's online shop answers a rego and its state with the exact build
; from the national vehicle database - model, series, years and the full
; engine line - in plain JSON, no login and no puzzle. Its first answer can
; arrive empty while the shop's cookie lands, so an empty answer is asked
; once more before giving up.
RC_AbVin(plate, state, ByRef extra, ByRef trim := "", ByRef year := "", ByRef make := "") {
    static HOST := "autobarn.com.au"
    extra := ""
    trim := ""
    year := ""
    make := ""
    if (plate = "" || state = "")
        return ""
    if !RC_Open(HOST)
        return ""
    path := "/ab/resources/vehicle/vehicle-search?rego=" . RC_Enc(plate) . "&state=" . RC_Enc(state)
    page := RC_Send("GET", path)
    if !InStr(page, """vehicles""")
        page := RC_Send("GET", path)
    RC_Close()
    if !InStr(page, """vehicles""")
        return ""

    ; Several builds can share the answer - trim variants of the same car.
    ; The shortest model name is the plain one.
    model := ""
    pos := 1
    while (pos := RegExMatch(page, """model"":""([^""]+)""", m, pos)) {
        if (model = "" || StrLen(m1) < StrLen(model))
            model := m1
        pos += StrLen(m)
    }
    if (model = "")
        return ""

    ; The make and the year sit plainly in the answer - the year as a range,
    ; "07/2020 ~ ON", of which the four-digit start is the one wanted.
    if RegExMatch(page, """make"":""([^""]+)""", mk)
        make := Trim(mk1)
    if RegExMatch(page, """year"":""[^""]*?(\d{4})", yr)
        year := yr1

    ; The trim hides in the description line, between the model and the
    ; engine size - "05~08 HYUNDAI SONATA ELITE 3.3L PETROL" - and only in
    ; the builds that name one. Different builds can name different trims,
    ; so up to two distinct ones are kept, slash-separated.
    pos := 1
    while (pos := RegExMatch(page, """desc"":""([^""]+)""", d, pos)) {
        pos += StrLen(d)
        cut := InStr(d1, model)
        if (cut = 0)
            continue
        t := SubStr(d1, cut + StrLen(model))
        t := RegExReplace(t, "i)\s*\d+(\.\d+)?L\b.*$")
        t := RegExReplace(t, "i)\s*\b(PETROL|DIESEL|ELECTRIC|HYBRID|PLUG.?IN|LPG)\b.*$")
        t := Trim(t)
        if (t = "" || InStr("/" . trim . "/", "/" . t . "/"))
            continue
        trim .= (trim != "" ? "/" : "") . t
        if InStr(trim, "/")
            break
    }

    ; Engine size out of the engine line, fuel out of whichever line names it.
    eng := ""
    if (RegExMatch(page, """engine"":""([^""]+)""", e) && RegExMatch(e1, "i)(\d+\.\d+)\s*L", g))
        eng := g1 . "L"
    if (eng = "" && RegExMatch(page, "i)(\d+\.\d+)\s*L\b", g))
        eng := g1 . "L"
    fuel := ""
    if RegExMatch(page, "i)plug.?in")
        fuel := "Plug-in hybrid"
    else if RegExMatch(page, "i)hybrid")
        fuel := "Hybrid"
    else if RegExMatch(page, "i)\bDIE\b|diesel")
        fuel := "Diesel"
    else if RegExMatch(page, "i)\belectric\b")
        fuel := "Electric"
    else if RegExMatch(page, "i)petrol|\bULP\b|\bPULP\b|\bPET\b|MPFI|\bEFI\b")
        fuel := "Petrol"
    if (fuel != "")
        extra := (eng != "" && fuel != "Electric") ? eng . " " . fuel : fuel
    else if (eng != "")
        extra := eng
    return model
}

; The wiper workbook only holds the fitments somebody typed into it, so a car
; it has never met leaves the three rows empty. Autobarn knows them all: hand
; its shop the vehicle it just found from the rego and it answers with the
; whole fitment list for that car - battery, filters, brake pads and, among
; them, the wiper blades. The sizes are in there twice over: Tridon's grade is
; the size in words ("560mm"), and every other brand's part number ends in it
; (TB560, BBA425). True when at least one blade came back.
RC_AbWipers(plate, state, ByRef drv, ByRef pas, ByRef rear) {
    static HOST := "autobarn.com.au"
    drv := "", pas := "", rear := ""
    if (plate = "" || state = "")
        return false
    if !RC_Open(HOST)
        return false

    ; Same two-goes rule as RC_AbVin - the first answer can arrive empty while
    ; the shop's cookie lands.
    path := "/ab/resources/vehicle/vehicle-search?rego=" . RC_Enc(plate) . "&state=" . RC_Enc(state)
    page := RC_Send("GET", path)
    if !InStr(page, """vehicles""")
        page := RC_Send("GET", path)
    ; The first build in the answer. Its own fields carry braces of their own -
    ; the engine line ends "{130kW}" - so the object is closed off by what
    ; follows it, the next build or the end of the list, not by the first "}".
    if !RegExMatch(page, "s)""vehicles"":\[\s*\{(.*?)\}\s*(?:,\s*\{|\])", v) {
        RC_Close()
        return false
    }

    ; The shop wants the whole vehicle handed back to it, not just its id -
    ; a part of it and the answer is a 500.
    car := v1
    body := "intent=setVehicle&searchStrategy=REGO"
    for i, f in ["id", "make", "model", "year", "series", "seriesChassis"
               , "desc", "details", "engine", "lngDsc", "hasMID", "rego", "regoState"]
        body .= "&" . f . "=" . RC_Enc(RC_JsonStr(car, f))
    parts := RC_Send("POST", "/ab/resources/vehicle/vehicle-search?/setVehicle", body
        , "application/x-www-form-urlencoded", "https://" . HOST . "/")
    RC_Close()
    if !InStr(parts, """partList""")
        return false

    ; One entry per part: the fitments it answers, then its part number.
    pos := 1
    while (pos := RegExMatch(parts, """fitmentDatas"":\[(.*?)\],""partNumber"":""([^""]+)""", p, pos)) {
        pos += StrLen(p)
        num := p2
        fit := 1
        while (fit := RegExMatch(p1, "\{[^{}]*\}", f, fit)) {
            fit += StrLen(f)
            if !RegExMatch(f, """subCatDescription"":""Wiper Blade - (Driver|Passenger|Rear)""", w)
                continue
            ; A blade the shop itself calls short or long is not the size the
            ; car left the factory with.
            if RegExMatch(f, "i)""footnote"":\[""[^""]*(short|long)")
                continue
            size := RC_AbSize(f, num)
            if (size = "")
                continue
            if (w1 = "Driver")
                drv := RC_AbBest(drv, size, f)
            else if (w1 = "Passenger")
                pas := RC_AbBest(pas, size, f)
            else
                rear := RC_AbBest(rear, size, f)
        }
    }
    return (drv != "" || pas != "" || rear != "")
}

; The size of one blade: Tridon spells it out in the grade, everybody else
; leaves it on the end of the part number. Three digits, and a blade is
; between 250 and 900 millimetres - anything else is a washer additive or a
; refill pack that shares the shelf.
RC_AbSize(fitment, partNumber) {
    if RegExMatch(fitment, """grade"":\[""(\d{3})mm""", g)
        return g1
    if RegExMatch(partNumber, "^[A-Z]+(\d{3})$", n)
        if (n1 >= 250 && n1 <= 900)
            return n1
    return ""
}

; Two brands can name two sizes for the same wiper. Tridon's own answer - the
; one that spells the size out - is the factory size, so it wins; otherwise
; the first one seen stays.
RC_AbBest(have, size, fitment) {
    if (have = "" || InStr(fitment, "mm""]"))
        return size
    return have
}

; One string field out of a flat JSON object.
RC_JsonStr(blob, field) {
    if RegExMatch(blob, """" . field . """:""([^""]*)""", m)
        return StrReplace(m1, "\/", "/")
    return ""
}

; EzyParts - Burson's trade portal - reads the national register itself, so
; it knows every state and hands back what the tyre shops cannot: the VIN
; and the rego expiry, with the build beside them. It wants a login first;
; the account details live at the top of this file. The login is done once
; and the session then lives for the life of the script on its own pair of
; winhttp handles, so the next search skips straight to the lookup. When
; the portal forgets the session, RC_EzyGet notices and logs in again.
; RC_EzyErr carries the reason in words whenever this hands back false.
RC_EzyOpen() {
    global RC_EZY_ACCT, RC_EZY_USER, RC_EZY_PASS, RC_EZY_HOST, RC_EZY_BASE
    global RC_EzyS, RC_EzyC, RC_EzyErr, RC_UA
    RC_EzyErr := ""
    if (RC_EzyC)
        return true
    if (RC_EZY_USER = "" || RC_EZY_PASS = "") {
        RC_EzyErr := "no EzyParts login set"
        return false
    }

    RC_EzyS := DllCall("winhttp\WinHttpOpen", "wstr", RC_UA
        , "uint", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr")
    if (RC_EzyS)
        DllCall("winhttp\WinHttpSetTimeouts", "ptr", RC_EzyS
            , "int", 6000, "int", 6000, "int", 10000, "int", 12000)
    RC_EzyC := RC_EzyS ? DllCall("winhttp\WinHttpConnect", "ptr", RC_EzyS
        , "wstr", RC_EZY_HOST, "ushort", 443, "uint", 0, "ptr") : 0
    if (!RC_EzyC) {
        RC_EzyDrop()
        RC_EzyErr := "could not reach EzyParts"
        return false
    }

    ; The login page deals the CSRF token along with the session cookie.
    page := RC_Send("GET", RC_EZY_BASE . "/login", "", "", "", "", RC_EzyC)
    tok := RC_Hidden(page, "CSRFToken")
    if (tok = "") {
        RC_EzyDrop()
        RC_EzyErr := (page = "") ? "EzyParts is not answering" : "EzyParts login page has changed"
        return false
    }

    ; The site's own script glues account and user together as "acct_user"
    ; before the form goes in - done here the same way.
    post := "acc_no=" . RC_Enc(RC_EZY_ACCT)
          . "&username=" . RC_Enc(RC_EZY_USER)
          . "&j_username=" . RC_Enc(RC_EZY_ACCT . "_" . RC_EZY_USER)
          . "&j_password=" . RC_Enc(RC_EZY_PASS)
          . "&doc360_login=false"
          . "&CSRFToken=" . RC_Enc(tok)
    page := RC_Send("POST", RC_EZY_BASE . "/j_spring_security_check", post, ""
        , "https://" . RC_EZY_HOST . RC_EZY_BASE . "/login", "", RC_EzyC)

    ; Landing back on a page with the login form means the details were not
    ; taken - only the login page carries that form action.
    if InStr(page, "j_spring_security_check") {
        RC_EzyDrop()
        RC_EzyErr := "EzyParts refused the login"
        return false
    }
    return true
}

; Forget the EzyParts session. The next RC_EzyOpen starts from the login page.
RC_EzyDrop() {
    global RC_EzyS, RC_EzyC
    if RC_EzyC
        DllCall("winhttp\WinHttpCloseHandle", "ptr", RC_EzyC)
    if RC_EzyS
        DllCall("winhttp\WinHttpCloseHandle", "ptr", RC_EzyS)
    RC_EzyC := 0
    RC_EzyS := 0
}

; One GET against the standing EzyParts session. A kept session can still be
; forgotten by the portal overnight - the tell is being handed the login form
; instead of an answer - so that one case logs in again and asks once more.
RC_EzyGet(path, ref) {
    global RC_EzyC
    if !RC_EzyOpen()
        return ""
    page := RC_Send("GET", path, "", "", ref, "", RC_EzyC)
    if InStr(page, "j_spring_security_check") {
        RC_EzyDrop()
        if !RC_EzyOpen()
            return ""
        page := RC_Send("GET", path, "", "", ref, "", RC_EzyC)
    }
    return page
}

; The first car out of an EzyParts "vehicles" list. The objects hold no
; nested braces, so the first closing brace ends the first car. The model
; field carries the trim in it - "D-MAX LS-U, SX SPACECAB" - and the details
; line carries the cab words. count says how many builds the list held.
RC_EzyFirst(page, ByRef make, ByRef model, ByRef yrRange, ByRef engine, ByRef cab, ByRef count) {
    make := ""
    model := ""
    yrRange := ""
    engine := ""
    cab := ""
    count := 0
    p := InStr(page, """vehicles"":[{")
    if (!p)
        return false
    q := InStr(page, "}", , p)
    car := SubStr(page, p, q - p + 1)
    if RegExMatch(car, """make"":""([^""]+)""", m)
        make := Trim(m1)
    if RegExMatch(car, """model"":""([^""]+)""", m)
        model := Trim(m1)
    if RegExMatch(car, """year"":""([^""]+)""", m)
        yrRange := Trim(m1)
    if RegExMatch(car, """engine"":""([^""]+)""", m)
        engine := Trim(m1)
    if RegExMatch(car, """details"":""([^""]+)""", m)
        cab := RC_CabWords(m1)
    StringUpper, make, make
    StrReplace(page, """desc"":", "", count)
    return (make != "")
}

; The engine line reads like "3.5L  PET G6DS V6 24v DOHC VVT I/C Twin Turbo
; Direct Inj {279kW}" - more than the header wants. The litres, the turbo
; and the fuel are kept; the valvetrain lore is not.
RC_EzyEngine(engine) {
    out := ""
    if RegExMatch(engine, "^\s*([\d.]+)L", m)
        out := m1 . "L"
    if InStr(engine, "Twin Turbo")
        out .= " Twin Turbo"
    else if InStr(engine, "Turbo")
        out .= " Turbo"
    if InStr(engine, " PET ")
        out .= " Petrol"
    else if InStr(engine, " DIE ")
        out .= " Diesel"
    return Trim(out)
}

; A plate VicRoads does not hold, asked of EzyParts state by state - one
; login, one GET each, and the register answers with the VIN, the build and
; the year. JAX is only rung afterwards, and only for an Isuzu, whose trim
; the register never quite pins down. True once the list is filled.
RC_FillEzyPlate(plate) {
    global RC_PROBE, RC_EZY_HOST, RC_EZY_BASE, RC_RedRow, RC_WipeRow, RC_ModelPick
    global RC_EzyErr
    Gui, RC:Default
    if !RC_EzyOpen()
        return false

    ref := "https://" . RC_EZY_HOST . RC_EZY_BASE . "/workbench"
    hit := ""
    hitSt := ""
    answered := 0
    for i, st in RC_PROBE {
        RC_Progress(1, "plate")
        Sleep, 10
        page := RC_EzyGet(RC_EZY_BASE . "/vehicle/rego/search?state=" . RC_Enc(st) . "&rego=" . RC_Enc(plate) . "&ac=3", ref)
        if (page != "")
            answered += 1
        ; The wrong state answers "results":"0" with an apology; the right
        ; one carries a car, or at the least the VIN.
        if (InStr(page, """vehicles"":[{") || RegExMatch(page, """vin"":""[A-Z0-9]")) {
            hit := page
            hitSt := st
            break
        }
    }
    if (hit = "") {
        ; No car is one thing; no answer at all is another, and the status
        ; line should not pass one off as the other.
        if (answered = 0 && RC_EzyErr = "")
            RC_EzyErr := "EzyParts is not answering"
        return false
    }

    make := ""
    model := ""
    yrRange := ""
    eng := ""
    cab := ""
    cnt := 0
    RC_EzyFirst(hit, make, model, yrRange, eng, cab, cnt)

    ; The register's own fields sit after the "vehicles" list closes - the
    ; VIN and the build year live there even when the list came back bare.
    tail := SubStr(hit, InStr(hit, "]", , InStr(hit, """vehicles"":[")))
    vin := ""
    year := ""
    if RegExMatch(tail, """vin"":""([A-Z0-9]{5,17})""", m)
        vin := m1
    if RegExMatch(tail, """year"":""(\d{4})""", m)
        year := m1

    ; A bare list with a VIN still names the build - the fitment search
    ; reads it straight off the VIN.
    if (make = "" && vin != "") {
        page := RC_EzyGet(RC_EZY_BASE . "/vehicle/t/search?text=" . RC_Enc(vin) . "&rego=" . RC_Enc(plate), ref)
        RC_EzyFirst(page, make, model, yrRange, eng, cab, cnt)
    }

    ; The fuller answer carries the expiry date, when the state shares it.
    expiry := ""
    page := RC_EzyGet(RC_EZY_BASE . "/vehicle/rego/search/more?state=" . RC_Enc(hitSt) . "&rego=" . RC_Enc(plate) . "&ac=3", ref)
    if RegExMatch(page, """registrationStatusExpiry"":""([^""]+)""", m)
        expiry := Trim(m1)

    ; The states register a Genesis as a HYUNDAI; the VIN tells them apart.
    if (InStr(make, "HYUNDAI") && (SubStr(vin, 1, 3) = "KMT" || SubStr(vin, 1, 3) = "KMU"))
        make := "GENESIS"

    ; Genesis is Hyundai underneath, and Hyundai's own VIN answer covers
    ; both badges - generation, trim, engine and all.
    trim := ""
    sX := RC_EzyEngine(eng)
    gen := ""
    if (vin != "" && (InStr(make, "HYUNDAI") || InStr(make, "GENESIS"))) {
        RC_Progress(2, "build")
        hX := ""
        hTrim := ""
        hYear := ""
        hModel := RC_HmcVin(vin, gen, hX, hTrim, hYear)
        if (hModel != "") {
            model := hModel
            trim := hTrim
            if (hX != "")
                sX := hX
            if (year = "")
                year := hYear
        }
    }

    ; The tyre shops are asked on every plate, not only when EzyParts came up
    ; short. They are the only source for the chassis code, the model-year
    ; range, the gearbox and the tyre sizes, so even a car EzyParts has fully
    ; named has more to learn. Mobile Tyre Shop is asked first, JAX second.
    ;
    ; Isuzu is the one make whose model and trim they overrule: EzyParts sells
    ; three trims on one build line and only a fitment database says which one
    ; the plate wears. For everything else the shops fill blanks and no more.
    if (plate != "" && hitSt != "" && RC_SPEED = 2) {
        RC_Progress(3, "fitment")
        jX := ""
        jTrim := ""
        jYear := ""
        jCab := ""
        jMake := ""
        jInfo := ""
        jModel := RC_MtsRego(plate, hitSt, jX, jTrim, jYear, jCab, jMake, jInfo)
        if (jModel = "") {
            RC_Progress(3, "fitment")
            jInfo := ""
            jModel := RC_JaxRego(plate, hitSt, jX, jTrim, jYear, jCab, jMake)
        }
        if (jModel != "") {
            beats := (InStr(make, "ISUZU") || model = "")
            if (beats)
                model := jModel
            if (beats || trim = "")
                trim := jTrim
            if (make = "")
                make := jMake
            ; The cab words already have a Body type row of their own here,
            ; so the shop's own copy of them is dropped before its rows go in.
            if (jCab != "") {
                cab := jCab
                if IsObject(jInfo)
                    jInfo.cab := ""
            }
            if (jX != "" && sX = "")
                sX := jX
            if (year = "")
                year := jYear
        }
    }

    ; Isuzu's own VIN sheet settles what EzyParts and JAX left open - the
    ; exact build year, the generation, the engine and the driveline are
    ; all in the VIN itself. Only the trim is not, and that stays theirs.
    if (InStr(make, "ISUZU")) {
        iEng := ""
        iDrive := ""
        iYr := ""
        iGen := ""
        iModel := RC_IsuzuVin(vin, iEng, iDrive, iYr, iGen)
        if (iModel != "") {
            if (model = "")
                model := iModel
            if (iYr != "")
                year := iYr
            if (iGen != "")
                gen := "(" . iGen
            if (sX = "" && iEng != "")
                sX := iEng
            if (iDrive != "" && !InStr(sX . " " . model . " " . trim, iDrive))
                sX .= (sX != "" ? ", " : "") . iDrive
        }
    }

    RC_RedRow := 0
    RC_WipeRow := 0
    RC_ModelPick := 0
    LV_Add("", "Registration", plate)
    if (vin != "")
        LV_Add("", "VIN/Chassis", vin)
    if (expiry != "") {
        row := LV_Add("", "Expiry", RC_EzyDate(expiry))
        if (StrReplace(expiry, "-", "") < SubStr(A_Now, 1, 8))
            RC_RedRow := row
    }
    if (year != "")
        LV_Add("", "Year", year)
    else if (yrRange != "")
        LV_Add("", "Year", yrRange)
    if (cab != "")
        LV_Add("", "Body type", cab)
    RC_WipeRow := LV_Add("", "Wiper driver", "")
    LV_Add("", "Wiper passenger", "")
    LV_Add("", "Wiper rear", "")
    RC_MtsRows(jInfo)

    if (trim != "" && !InStr(" " . model . " ", " " . trim . " "))
        tag := RC_NiceName(model . " " . trim)
    else
        tag := RC_NiceName(model)
    if (sX != "")
        tag .= (tag != "" ? ", " : "") . sX
    tag := RC_TagTail(tag, make, (IsObject(jInfo) ? jInfo.name : "")
        . " " . cab . " " . sX . " " . trim)
    RC_SetMake(make, tag, hitSt)

    if (make != "")
        RC_WipeFind(make, year, cab, model, year, gen, trim)
    RC_WipeShow()
    RC_WipeOnline(plate, hitSt)

    RC_PrettyRows(IsObject(jInfo) ? jInfo.name . " " . cab : cab)
    RC_DropDupes()
    RC_FitList()

    note := "Found in " . hitSt . " via EzyParts."
    if (make = "")
        note := "Found in " . hitSt . " via EzyParts, but it names no build."
    if (vin != "") {
        Clipboard := vin
        RC_ShowToast(((StrLen(vin) = 17) ? "VIN copied" : "Partial VIN copied") . "   " . vin)
        RC_TipAtMouse(vin)
        note .= " VIN on the clipboard."
    } else {
        note .= " No VIN given back."
    }
    RC_Done(true, "Success")
    RC_SelectPlate()
    RC_CacheSave(plate, note)
    return true
}

; A VIN VicRoads does not hold, asked of EzyParts' fitment search, which
; reads the build straight off the VIN for any make. The register never
; hands a plate back for a VIN, so there is no rego row and no expiry -
; and more than one build can fit the one code, so the count is said when
; it is more than one. True once the list is filled.
RC_FillEzyVin(vin) {
    global RC_EZY_HOST, RC_EZY_BASE, RC_RedRow, RC_WipeRow, RC_ModelPick
    global RC_EzyErr
    Gui, RC:Default
    if !RC_EzyOpen()
        return false
    RC_Progress(1, "plate")
    Sleep, 10
    page := RC_EzyGet(RC_EZY_BASE . "/vehicle/t/search?text=" . RC_Enc(vin)
        , "https://" . RC_EZY_HOST . RC_EZY_BASE . "/workbench")
    if (page = "" && RC_EzyErr = "")
        RC_EzyErr := "EzyParts is not answering"

    make := ""
    model := ""
    yrRange := ""
    eng := ""
    cab := ""
    cnt := 0
    if !RC_EzyFirst(page, make, model, yrRange, eng, cab, cnt)
        return false

    year := ""
    if RegExMatch(yrRange, "(\d{4})", m)
        year := m1

    ; Genesis is Hyundai underneath, and Hyundai's own VIN answer covers
    ; both badges - generation, trim, engine and the exact model year.
    trim := ""
    sX := RC_EzyEngine(eng)
    gen := ""
    if (InStr(make, "HYUNDAI") || InStr(make, "GENESIS")) {
        RC_Progress(2, "build")
        hX := ""
        hTrim := ""
        hYear := ""
        hModel := RC_HmcVin(vin, gen, hX, hTrim, hYear)
        if (hModel != "") {
            model := hModel
            trim := hTrim
            if (hX != "")
                sX := hX
            if (hYear != "")
                year := hYear
        }
    }

    ; An Isuzu VIN names its own build - year, generation, engine and
    ; driveline - with EzyParts' fitment row keeping the trim.
    if (InStr(make, "ISUZU")) {
        iEng := ""
        iDrive := ""
        iYr := ""
        iGen := ""
        iModel := RC_IsuzuVin(vin, iEng, iDrive, iYr, iGen)
        if (iModel != "") {
            if (model = "")
                model := iModel
            if (iYr != "")
                year := iYr
            if (iGen != "")
                gen := "(" . iGen
            if (sX = "" && iEng != "")
                sX := iEng
            if (iDrive != "" && !InStr(sX . " " . model . " " . trim, iDrive))
                sX .= (sX != "" ? ", " : "") . iDrive
        }
    }

    RC_RedRow := 0
    RC_WipeRow := 0
    RC_ModelPick := 0
    LV_Add("", "VIN/Chassis", vin)
    if (yrRange != "")
        LV_Add("", "Year", yrRange)
    if (cab != "")
        LV_Add("", "Body type", cab)
    RC_WipeRow := LV_Add("", "Wiper driver", "")
    LV_Add("", "Wiper passenger", "")
    LV_Add("", "Wiper rear", "")

    if (trim != "" && !InStr(" " . model . " ", " " . trim . " "))
        tag := RC_NiceName(model . " " . trim)
    else
        tag := RC_NiceName(model)
    if (sX != "")
        tag .= (tag != "" ? ", " : "") . sX
    tag := RC_TagTail(tag, make, cab . " " . sX . " " . trim)
    RC_SetMake(make, tag)

    if (make != "")
        RC_WipeFind(make, year, cab, model, year, gen, trim)
    RC_WipeShow()

    RC_PrettyRows(cab)
    RC_DropDupes()
    RC_FitList()

    note := "EzyParts knows the VIN."
    if (cnt > 1)
        note := "EzyParts knows the VIN - " . cnt . " builds fit it, the first is shown."
    note .= " No plate: the register gives none back for a VIN."
    RC_Done(true, "Success")
    RC_SelectPlate()
    RC_CacheSave(vin, note)
    return true
}

; EzyParts hands dates back as "2026-09-30"; the list reads them the way the
; states write them.
RC_EzyDate(ymd) {
    p := StrSplit(ymd, "-")
    if (p.Length() = 3)
        return p[3] . "/" . p[2] . "/" . p[1]
    return ymd
}

; Isuzu Ute's own VIN sheet, read straight off the VIN with no lookup at all.
; Thai-built Isuzus - every D-MAX and MU-X sold here - start MPA: position
; four is the model line (T ute, U wagon), six the driveline (R 4x2, S 4x4),
; seven and eight the engine, ten the build year as a letter. The year names
; the generation: the ute is TF to 2011, RT to 2020, RG after; the wagon is
; RF to 2020, RJ after. No year letter known means the engine's era decides.
; The trim is not in the VIN, so JAX and EzyParts still have the last word
; on that. Returns the model name, or "" for a VIN that is not theirs.
RC_IsuzuVin(vin, ByRef eng, ByRef drive, ByRef yr, ByRef gen) {
    eng := ""
    drive := ""
    yr := ""
    gen := ""
    if (StrLen(vin) != 17 || SubStr(vin, 1, 3) != "MPA")
        return ""
    c := SubStr(vin, 4, 1)
    model := (c = "T") ? "D-MAX" : (c = "U") ? "MU-X" : ""
    if (model = "")
        return ""
    c := SubStr(vin, 6, 1)
    drive := (c = "R") ? "4x2" : (c = "S") ? "4x4" : ""
    d := SubStr(vin, 7, 2)
    eng := (d = "40") ? "4JJ3 3.0L T/Diesel"
         : (d = "41") ? "RZ4F 2.2L T/Diesel"
         : (d = "85") ? "4JJ1 3.0L T/Diesel"
         : (d = "87") ? "R4ZE 1.9L T/Diesel"
         : (d = "54") ? "4JA1 2.5L T/Diesel"
         : (d = "77") ? "4JH1 3.0L T/Diesel"
         : (d = "86") ? "4JK1 2.5L T/Diesel" : ""
    y := SubStr(vin, 10, 1)
    p := InStr("89ABCDEFGHJKLMNPRST", y, true)
    if (p > 0)
        yr := 2007 + p
    if (yr != "") {
        if (model = "D-MAX")
            gen := (yr <= 2011) ? "TF" : (yr <= 2020) ? "RT" : "RG"
        else
            gen := (yr <= 2020) ? "RF" : "RJ"
    } else if (d = "85" || d = "86") {
        gen := (model = "MU-X") ? "RF" : "RT"
    } else if (d = "87" || d = "40" || d = "41") {
        gen := (model = "MU-X") ? "RJ" : "RG"
    } else if (d = "54" || d = "77") {
        gen := "RA"
    }
    return model
}

; JAX Tyres answers a rego and its state with the exact build from its fitment
; database - the model, the series line with the trim in it, the year range
; and the whole engine line - as plain JSON from the API behind its search
; widget. No token, no session, no puzzle. The series line reads like
; "GUN126R 4x4 SR Cab Chassis" - a chassis code, the driveline, the trim and
; the body - and only the trim is wanted, so the rest is peeled away.
RC_JaxRego(plate, state, ByRef extra, ByRef trim, ByRef year, ByRef cab := "", ByRef make := "") {
    static HOST := "www.jaxtyres.com.au"
    extra := ""
    trim := ""
    year := ""
    cab := ""
    make := ""
    if (plate = "" || state = "")
        return ""
    if !RC_Open(HOST)
        return ""
    body := "{""state"":""" . state . """,""regoNumber"":""" . plate . """}"
    page := RC_Send("POST", "/api/vehicle/regocheck", body, "application/json"
        , "https://" . HOST . "/", "Accept: application/json")
    RC_Close()
    if !InStr(page, """Success"":true")
        return ""

    ; The make hides in the badge image - ".../media/Genesis.png" - the only
    ; place JAX names it. Kept even when the build fields below are empty.
    if RegExMatch(page, """ImageUrl"":""[^""]*/([^""/]+)\.png""", im) {
        make := RegExReplace(im1, "%20", " ")
        StringUpper, make, make
    }

    if !RegExMatch(page, """VehicleModal"":""([^""]+)""", m)
        return ""
    model := Trim(m1)
    if (model = "")
        return ""

    ; The years come as a range - "2019-2020" - and the first is the one the
    ; wiper table wants.
    if RegExMatch(page, """VehicleYears"":""(\d{4})", y)
        year := y1

    ; The trim out of the series line: the chassis code carries digits and
    ; goes first, then the driveline and body words go, and what stays is the
    ; trim - "SR", "LS-U", "X-Terrain". The body words themselves - the cab,
    ; the doors, the ride height - are worth keeping, so they are collected
    ; in their own line before the peeling starts.
    if RegExMatch(page, """VehicleName"":""([^""]+)""", n) {
        cab := RC_CabWords(n1)
        t := Trim(n1)
        t := RegExReplace(t, "^\S*\d\S*\s+", "")
        t := RegExReplace(t, "i)\b(4x4|4x2|AWD|4WD|2WD|FWD|RWD|Crew|Space|Dual|Single|Extended|King|Cab|Chassis|Utility|Ute|Pick.?Up|Tray|Wagon|Van|Sedan|Hatch|Coupe|SUV|Hi.?Rider?|Low.?Rider?|MY\d+(\.\d+)?(-\d+)?|\d+dr|\d+D)\b", " ")
        trim := Trim(RegExReplace(t, "\s+", " "))
    }

    ; The engine line - "6sp man 2.8L 4cyl T/Diesel" - boiled down to what
    ; fits in the brackets beside the make.
    if RegExMatch(page, """VehicleVersion"":""([^""]+)""", v) {
        ver := v1
        eng := ""
        if RegExMatch(ver, "i)\b(\d+\.\d+)L\b", e)
            eng := e1 . "L"
        fuel := ""
        if RegExMatch(ver, "i)plug.?in|PHEV")
            fuel := "Plug-in hybrid"
        else if RegExMatch(ver, "i)hybrid|\bHEV\b")
            fuel := "Hybrid"
        else if RegExMatch(ver, "i)diesel|\bTD\b|CRD")
            fuel := "Diesel"
        else if RegExMatch(ver, "i)electric|\bBEV\b")
            fuel := "Electric"
        else if (eng != "")
            fuel := "Petrol"
        if (fuel != "")
            extra := (eng != "" && fuel != "Electric") ? eng . " " . fuel : fuel
        else if (eng != "")
            extra := eng
    }
    return model
}

; Mobile Tyre Shop answers the same question through the search endpoint
; behind its own widget - one form post, no token. The answer is a big blob
; of JSON and the car sits in one corner of it as "suitable_for_vehicle",
; with the model on its own and the full build line - "Isuzu Ute D-Max 4x4
; SX Hi-Ride 2D Space Cab Chassis MY12" - to peel the trim out of. No engine
; anywhere in it, so extra comes back empty and the VIN decode fills that.
RC_MtsRego(plate, state, ByRef extra, ByRef trim, ByRef year, ByRef cab := "", ByRef make := "", ByRef info := "") {
    static HOST := "mobiletyreshop.com.au"
    static PAGE := "/find-by-rego/"
    extra := ""
    trim := ""
    year := ""
    cab := ""
    make := ""
    info := {}
    if (plate = "" || state = "")
        return ""
    if !RC_Open(HOST)
        return ""
    body := "action=mt_search&rego=" . RC_Enc(plate) . "&state=" . RC_Enc(state)
    hdrs := "Accept: application/json, text/javascript, */*; q=0.01`r`n"
          . "X-Requested-With: XMLHttpRequest"
    ; Two searches close together and the shop hands the second one an empty
    ; shell - same 200, same shape, no car in it - so an empty answer is
    ; waited on and asked once more before it is believed. It costs a second
    ; on a plate the shop really does not know, and saves the whole build on
    ; one it does.
    Loop, 2 {
        page := RC_Send("POST", "/wp-admin/admin-ajax.php?ref=search", body, ""
            , "https://" . HOST . PAGE, hdrs)
        model := RC_MtsParse(page, extra, trim, year, cab, make, info)
        if (model != "")
            break
        if (A_Index = 1)
            Sleep, 900
    }
    RC_Close()
    return model
}

; The car out of Mobile Tyre Shop's answer. Kept apart from the asking so the
; peeling can be tried on a saved answer without a request going out.
RC_MtsParse(page, ByRef extra, ByRef trim, ByRef year, ByRef cab, ByRef make, ByRef info) {
    extra := ""
    trim := ""
    year := ""
    cab := ""
    make := ""
    info := {}

    ; An unknown plate answers with the vehicle set to null, and a wrong
    ; state with the vehicle's shell left empty. Only the vehicle's own
    ; corner of the blob is read - further along sit the tyres, which have
    ; makes and models of their own.
    p := InStr(page, """suitable_for_vehicle"":{")
    if !p
        return ""
    car := SubStr(page, p, 900)
    if !RegExMatch(car, """model"":""([^""]+)""", m)
        return ""
    model := Trim(m1)
    if (model = "")
        return ""
    if RegExMatch(car, """model_year"":""(\d{4})""", y)
        year := y1
    if RegExMatch(car, """car_make"":""([^""]+)""", mk) {
        make := mk1
        StringUpper, make, make
    }
    info.make := make
    info.model := model
    info.year := year

    ; Both axles come back as their own little object - width, profile, rim
    ; and load index. A car whose back tyres differ from its front ones is
    ; flagged staggered, and then both sizes matter.
    if RegExMatch(car, """front"":\{[^}]*\}", fm)
        info.front := RC_MtsTyre(fm)
    if RegExMatch(car, """rear"":\{[^}]*\}", rm)
        info.rear := RC_MtsTyre(rm)
    info.staggered := (info.front != "" && info.rear != "" && info.front != info.rear)
    info.runflat := InStr(car, """runflat"":true") ? "Yes" : ""

    ; The build line holds the rest of the car: everything before the dash
    ; names it - make, chassis code, model, trim, body - and everything
    ; after it is the driveline, with the model-year range on the end.
    ;   "Mercedes-Benz H247 GLA-Class GLA200 4D SUV
    ;    - 7sp auto 1.3L 4cyl T/Petrol Electric (MHEV) MY23-26"
    if RegExMatch(car, """name"":""([^""]+)""", n) {
        full := StrReplace(n1, "\/", "/")
        info.name := full
        if RegExMatch(full, "i)\bMY\d+(\.\d+)?(-\d+)?\b", my)
            info.my := my

        head := full
        if (d := InStr(full, " - ")) {
            head := SubStr(full, 1, d - 1)
            v := SubStr(full, d + 3)
            v := RegExReplace(v, "i)\bMY\d+(\.\d+)?(-\d+)?\b", "")
            info.version := Trim(RegExReplace(v, "\s+", " "))
        }

        ; The maker's own code for the shape - H247, RG - sits between the
        ; make and the model, and is the only word there carrying digits.
        cut := InStr(head, model)
        if (cut > 1) {
            Loop, Parse, % Trim(SubStr(head, 1, cut - 1)), %A_Space%
                if RegExMatch(A_LoopField, "^[A-Z]{1,3}\d{2,4}[A-Z]?$")
                    info.chassis := A_LoopField
        }

        ; The trim sits in the build line after the model, with the driveline
        ; and body words around it - same peeling as JAX, and the same keeping
        ; of the cab, door and ride words in their own line. An engine token
        ; in it - "3.5T" - goes to the brackets beside the make.
        if (cut) {
            t := SubStr(head, cut + StrLen(model))
            cab := RC_CabWords(t)
            if RegExMatch(t, "i)\b(\d+\.\d+)(T\b)?", e)
                extra := e1 . "L" . (e2 != "" ? " Turbo" : "")
            t := RegExReplace(t, "i)\b(4x4|4x2|AWD|4WD|2WD|FWD|RWD|Crew|Space|Dual|Single|Extended|King|Cab|Chassis|Utility|Ute|Pick.?Up|Tray|Wagon|Van|Sedan|Hatch|Coupe|SUV|Hi.?Rider?|Low.?Rider?|MY\d+(\.\d+)?(-\d+)?|\d+\.\d+T?|\d+dr|\d+D)\b", " ")
            trim := Trim(RegExReplace(t, "\s+", " "))
        }
        info.trim := trim
        info.cab := cab
        info.drive := RC_DriveOf(full)

        ; No engine named in the build line for some cars, but the driveline
        ; after the dash always has one - "1.3L 4cyl" - so it fills in.
        if (extra = "" && info.version != "" && RegExMatch(info.version, "i)(\d+\.\d+)L\s*(\d+cyl)?", e2))
            extra := e21 . "L" . (e22 != "" ? " " . e22 : "")
    }
    return model
}

; Everything the tyre shop knew, slid in above the wiper rows in the order it
; reads best - what the car is, then what it runs on. Whatever came back empty
; is skipped, so a thin answer does not leave blank rows behind. The rear tyre
; only earns a row of its own when it differs from the front.
RC_MtsRows(info) {
    global RC_WipeRow
    if !IsObject(info)
        return
    rows := [ ["Series",      info.trim]
            , ["Chassis code", info.chassis]
            , ["Model years", info.my]
            , ["Version",     info.version]
            , ["Cab/Body",    info.cab] ]

    ; One size on all four corners is the usual thing, and the row says so
    ; outright - otherwise there is no telling whether the rear was left out
    ; or is simply the same. A staggered car gets the two rows instead.
    if (info.staggered) {
        rows.Push(["Tyres FR", info.front])
        rows.Push(["Tyres RR", info.rear])
    } else {
        rows.Push(["Tyres FR & RR", info.front])
    }
    rows.Push(["Runflat", info.runflat])
    for i, r in rows {
        if (r[2] = "")
            continue
        LV_Insert(RC_WipeRow, "", r[1], r[2])
        RC_WipeRow += 1
    }
}

; One axle's tyre out of the vehicle blob - "255/65 R17 110". The load index
; only joins it when the shop named one.
RC_MtsTyre(blob) {
    w := "", pr := "", rim := "", li := ""
    if RegExMatch(blob, """width"":""(\d+)""", m)
        w := m1
    if RegExMatch(blob, """profile"":""(\d+)""", m)
        pr := m1
    if RegExMatch(blob, """rim"":""(\d+)""", m)
        rim := m1
    if RegExMatch(blob, """load_index"":""(\d+)""", m)
        li := m1
    if (w = "" || pr = "" || rim = "")
        return ""
    return w . "/" . pr . " R" . rim . (li != "" ? " " . li : "")
}

; The body row, written the way it reads best: the body itself first, the
; door count after it - "SUV 4D", not "4D SUV" - the state's shorthand spelt
; out, and a ute told apart as a tub or a cab chassis. The hint is whatever
; else is known about the build - the tyre shop's cab words - for when the
; state only said "UTIL".
RC_BodyText(text, hint := "") {
    if (text = "")
        return ""

    ; The states abbreviate; the window does not.
    static LONG := { "UTIL": "Utility", "UTILITY": "Utility", "UTE": "Ute"
                   , "SED": "Sedan", "SDN": "Sedan", "WAG": "Wagon", "WGN": "Wagon"
                   , "HBK": "Hatch", "HCH": "Hatch", "CPE": "Coupe", "CONV": "Convertible"
                   , "PVAN": "Van", "PV": "Van", "MBUS": "Bus", "CCHAS": "Cab chassis"
                   , "C/CHAS": "Cab chassis", "TRUCK": "Truck", "SUV": "SUV" }
    out := ""
    doors := ""
    for i, word in StrSplit(RegExReplace(Trim(text), "\s+", " "), " ") {
        ; The door count is pulled out wherever it was written and put back
        ; on the end.
        if RegExMatch(word, "i)^(\d+)\s*(D|DR|DOOR)$", d) {
            doors := d1 . "D"
            continue
        }
        up := word
        StringUpper, up, up
        if LONG.HasKey(up)
            word := LONG[up]
        else
            word := RC_TitleWord(word)
        out .= (out = "" ? "" : " ") . word
    }
    if (doors != "")
        out .= (out = "" ? "" : " ") . doors

    ; The build line is the one that really knows - "UTIL" on its own says
    ; nothing about the back of the car, so it is only allowed to answer when
    ; it uses a word that settles it. A ute nobody has described stays a plain
    ; "Utility" rather than being called a tub on a guess.
    style := RC_BodyStyle(hint)
    if (style = "")
        style := RC_BodyStyle(out, true)
    if (style != "" && !InStr(RC_Squash(out), RC_Squash(style)))
        out .= " / " . style
    return out
}

; The tail of the bold line: which wheels the car drives, and - for an Isuzu,
; where the difference is the whole point of the truck - whether the back of
; it is a tub or a cab chassis. Both are only ever added once, so a line that
; already says "4x2" is left alone.
RC_TagTail(tag, make, source) {
    dr := RC_DriveOf(source)
    if (dr != "" && !InStr(" " . RC_Squash(tag) . " ", " " . RC_Squash(dr) . " "))
        tag .= (tag != "" ? ", " : "") . dr
    if InStr(make, "ISUZU") {
        style := RC_BodyStyle(source)
        if (style != "" && !InStr(RC_Squash(tag), RC_Squash(style)))
            tag .= (tag != "" ? ", " : "") . style
    }
    return tag
}

; Which wheels the car drives, out of whatever line names it - the shop's
; build line says "4x2", Autobarn says "RWD", the Isuzu VIN says both. The
; first one found is the answer; they never disagree in practice.
RC_DriveOf(text) {
    if !RegExMatch(text, "i)\b(4x4|4x2|AWD|4WD|2WD|FWD|RWD)\b", m)
        return ""
    d := m1
    StringUpper, d, d
    if (d = "4X4")
        return "4x4"
    if (d = "4X2")
        return "4x2"
    return d
}

; Is that field already in the list?
RC_HasRow(field) {
    Gui, RC:Default
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        if (f = field)
            return true
    }
    return false
}

; One row slid in just above the wiper rows, the same place the tyre shop's
; own rows go, so the red expiry row above keeps its place.
RC_RowAboveWipers(field, value) {
    global RC_WipeRow
    Gui, RC:Default
    if (value = "" || RC_WipeRow = 0 || RC_HasRow(field))
        return
    LV_Insert(RC_WipeRow, "", field, value)
    RC_WipeRow += 1
}

; A ute is either a tub or a cab chassis, and which one it is changes what
; can be fitted to the back of it. The build line says so in its own words -
; "Cab Chassis", or "Utility" / "Ute" / "Pick Up" for a tub - so the plain
; word is put on the end of the body row. Anything that is not a ute at all
; is left alone.
RC_BodyStyle(text, strict := false) {
    if RegExMatch(text, "i)\bcab\s*chas(sis)?\b|\bc/chas\b|\bchassis\b")
        return "Cab chassis"
    ; Strict leaves out the bare words - "Ute", "Utility" - that a state uses
    ; for both kinds, and only answers to a word that means a tub.
    if (strict)
        return RegExMatch(text, "i)\b(pick.?up|tub|tray.?back)\b") ? "Tub" : ""
    if RegExMatch(text, "i)\b(ute|utility|pick.?up|tub|tray.?back)\b")
        return "Tub"
    return ""
}

; The cab, door and ride-height words out of a build line, in the order they
; were printed - "Space Cab Chassis 2D", "Crew Cab Utility Hi-Ride". These are
; the same words the trim peeling throws away, kept for their own row.
RC_CabWords(text) {
    out := ""
    pos := 1
    while (pos := RegExMatch(text, "i)\b(Crew|Space|Dual|Single|Extended|King|Cab|Chassis|Pick.?Up|Tray|Utility|Ute|Wagon|Van|SUV|Sedan|Hatch|Coupe|Hi.?Rider?|Low.?Rider?|\d+D|\d+dr)\b", c, pos)) {
        pos += StrLen(c)
        out .= (out = "" ? "" : " ") . c1
    }
    return out
}

; The make sits in bold with the car spelled out in ordinary weight on its
; own line beneath - stacked, so neither line can crowd the other off the
; window whatever the length.
RC_SetMake(bold, bracket, state := "") {
    Gui, RC:Default
    bracket := RC_TrimCase(RC_NoEcho(bracket))
    ; The badge has two lines to itself, so a long make - MERCEDES-BENZ -
    ; wraps rather than being cut off. Only a very long one drops a size.
    Gui, Font, % "s" . (StrLen(bold) > 16 ? 11 : 13) . " w600", Segoe UI
    GuiControl, RC:Font, RC_Make
    GuiControl, RC:, RC_Make, % (bold != "") ? bold : A_Space
    ; The state the car is registered in trails the build, dotted off it. A
    ; VIN search that never named a state simply goes without.
    if (state != "")
        bracket := (bracket != "" ? bracket . " " : "") . Chr(0xB7) . " " . state
    GuiControl, RC:, RC_MakeX, %bracket%
    GuiControl, % (bracket != "") ? "RC:Show" : "RC:Hide", RC_MakeX
}

; Some sources hand the trim back with the model word still in it, so the
; line ends up saying it twice - "RAV4 GX GX Hybrid". Whatever repeats what
; came straight before it goes. Spaces do not count, so "IS250 IS 250" is the
; same echo as "GX GX"; neither does case, nor a comma on the end, so "GX, GX"
; is caught as well. Up to three words either side, which covers every way a
; model name gets broken up - only the run right before is compared, so a word
; that honestly turns up twice further along the line is left alone.
RC_NoEcho(text) {
    static MAXRUN := 3
    words := StrSplit(RegExReplace(Trim(text), "\s+", " "), " ")
    kept := []
    i := 1
    while (i <= words.Length()) {
        skip := 0
        ; The longest echo wins, so "IS 250" is taken as one before "IS" is
        ; tried on its own.
        n := MAXRUN + 1
        while (--n >= 1 && !skip) {
            if (i + n - 1 > words.Length())
                continue
            ahead := ""
            Loop, %n%
                ahead .= RC_Bare(words[i + A_Index - 1])
            if (ahead = "")
                continue
            m := MAXRUN + 1
            while (--m >= 1) {
                if (kept.Length() < m)
                    continue
                behind := ""
                Loop, %m%
                    behind .= RC_Bare(kept[kept.Length() - m + A_Index])
                if (behind != "" && behind = ahead) {
                    skip := n
                    break
                }
            }
        }
        if (skip) {
            i += skip
            continue
        }
        kept.Push(words[i])
        i += 1
    }
    out := ""
    for i, w in kept
        out .= (out = "" ? "" : " ") . w
    return out
}

; One word stripped back to what it says, for comparing it against another
; written a different way. The comma or semicolon that only ever trails goes,
; and so does the hyphen a model name is split on - "CX-5" and "CX 5" are the
; one name, and the run either side of it squashes to the same thing.
RC_Bare(word) {
    return RegExReplace(RegExReplace(word, "[,;]+$"), "-", "")
}

; Tidies the case of the build line for display. Plain lowercase words get a
; capital first letter, long shouted words are brought down to title case, and
; anything short or holding a digit - LS-U, RT, 4cyl, 3.0L - is left as sent.
RC_TrimCase(s) {
    out := ""
    Loop, Parse, s, %A_Space%
    {
        w := A_LoopField
        if RegExMatch(w, "^[a-z\-/]+$")
            StringUpper, w, w, T
        else if RegExMatch(w, "^[A-Z\-/]{5,}$")
            StringUpper, w, w, T
        out .= (out = "" ? "" : " ") . w
    }
    return out
}

; Autobarn shouts its model names - COROLLA - so words of four or more plain
; capitals fold to their usual shape. Anything carrying a digit, a dash or a
; small letter - D-MAX, CX-5, iLoad - is left exactly as printed.
RC_NiceName(s) {
    out := ""
    Loop, Parse, s, %A_Space%
    {
        w := A_LoopField
        if RegExMatch(w, "^[A-Z]{4,}$") {
            StringLower, w, w
            StringUpper, f, % SubStr(w, 1, 1)
            w := f . SubStr(w, 2)
        }
        out .= (out = "" ? "" : " ") . w
    }
    return out
}

; Descending by first year, keeping the workbook's own order inside a year.
RC_SortCands(cands) {
    global RC_WIPE
    out := []
    for i, ix in cands {
        at := out.Length() + 1
        for j, jx in out {
            if (RC_WIPE[ix].y1 > RC_WIPE[jx].y1) {
                at := j
                break
            }
        }
        out.InsertAt(at, ix)
    }
    return out
}

; True when every candidate carries the same three sizes.
RC_WipeAgree() {
    global RC_WIPE, RC_Cands
    first := RC_WIPE[RC_Cands[1]]
    for i, ix in RC_Cands {
        w := RC_WIPE[ix]
        if (w.drv != first.drv || w.pas != first.pas || w.rear != first.rear)
            return false
    }
    return true
}

; Put the three sizes in the list, or say why they are not there.
RC_WipeShow() {
    global RC_WIPE, RC_Cands, RC_ModelPick, RC_WipeRow
    Gui, RC:Default
    if (RC_WipeRow = 0)
        return
    if (RC_ModelPick >= 1 && RC_ModelPick <= RC_Cands.Length()) {
        w := RC_WIPE[RC_Cands[RC_ModelPick]]
        LV_Modify(RC_WipeRow,     "Col2", w.drv)
        LV_Modify(RC_WipeRow + 1, "Col2", w.pas)
        LV_Modify(RC_WipeRow + 2, "Col2", (w.rear != "") ? w.rear : "none")
        return
    }
    ; Sizes already in the rows came from Autobarn, which only gets asked when
    ; the workbook had nothing. Do not paint over them.
    LV_GetText(now, RC_WipeRow, 2)
    if (RC_Cands.Length() = 0 && now != "" && now != "no fitment listed" && now != "pick a model above")
        return
    msg := (RC_Cands.Length() = 0) ? "no fitment listed" : "pick a model above"
    LV_Modify(RC_WipeRow,     "Col2", msg)
    LV_Modify(RC_WipeRow + 1, "Col2", msg)
    LV_Modify(RC_WipeRow + 2, "Col2", msg)
}

; The workbook knew nothing, so the shop gets asked. Only worth a request when
; there is a plate and a state to ask with, and only for the rows it answers -
; a car with no rear wiper listed keeps its "no fitment listed" there.
RC_WipeOnline(plate, state) {
    global RC_Cands, RC_WipeRow, RC_SPEED
    Gui, RC:Default
    ; Fast never leaves the register - the workbook still answers whatever it
    ; holds, but nothing is asked for over the wire.
    if (RC_SPEED != 2)
        return false
    if (RC_WipeRow = 0 || RC_Cands.Length() > 0 || plate = "" || state = "")
        return false
    RC_Progress(4, "wipers")

    ; The rows say what is happening while the shop is being asked, rather
    ; than sitting there reading "no fitment listed" for the second or two
    ; it takes - that reads like an answer when it is not one yet.
    Loop, 3
        LV_Modify(RC_WipeRow + A_Index - 1, "Col2", "loading ...")
    Sleep, 10
    drv := "", pas := "", rear := ""
    if !RC_AbWipers(plate, state, drv, pas, rear) {
        Loop, 3
            LV_Modify(RC_WipeRow + A_Index - 1, "Col2", "no fitment listed")
        return false
    }
    ; Whatever the shop had no answer for goes back to saying so.
    Loop, 3
        LV_Modify(RC_WipeRow + A_Index - 1, "Col2", "no fitment listed")
    if (drv != "")
        LV_Modify(RC_WipeRow,     "Col2", RC_WipeSize(drv))
    if (pas != "")
        LV_Modify(RC_WipeRow + 1, "Col2", RC_WipeSize(pas))
    if (rear != "")
        LV_Modify(RC_WipeRow + 2, "Col2", RC_WipeSize(rear))
    return true
}

; Millimetres out of the shop, written the way the workbook writes them -
; "22 in / 550 mm" - so the two sources read the same in the same row.
RC_WipeSize(mm) {
    if (mm = "")
        return ""
    return Round(mm / 25.4) . " in / " . mm . " mm"
}

; Empty the dropdown back to its prompt.
RC_WipeReset() {
    global RC_Cands, RC_ModelPick
    RC_Cands := []
    RC_ModelPick := 0
    GuiControl, RC:, RC_Model, |Pick a model
    GuiControl, RC:Choose, RC_Model, 1
}

; The dropdown changed. Entry one is the prompt, so the candidates start at two.
RC_OnModel() {
    global RC_ModelPick, RC_LastKey, RC_CACHE
    Gui, RC:Default
    GuiControlGet, choice, RC:, RC_Model
    RC_ModelPick := choice - 1
    RC_WipeShow()
    ; The pick is part of the answer, so the kept copy learns it too.
    if (RC_LastKey != "" && RC_CACHE.HasKey(RC_LastKey))
        RC_CacheSave(RC_LastKey, RC_CACHE[RC_LastKey].note, RC_CACHE[RC_LastKey].speed)
}

; --- the day's answers, kept -----------------------------------------------

; Put away everything the window is showing, under the plate or VIN that was
; asked, so the same asking later in the day is answered from here.
RC_CacheSave(key, note, speed := -1) {
    global RC_CACHE, RC_RedRow, RC_WipeRow, RC_ModelPick, RC_Cands, RC_SPEED
    ; How far the chain was walked to get this, so a later Full search knows
    ; not to settle for a copy taken on Fast. A re-save that is only a model
    ; pick says which setting the rows came from; everything else is now.
    if (speed < 0)
        speed := RC_SPEED
    if (key = "")
        return
    Gui, RC:Default
    rows := []
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        LV_GetText(v, A_Index, 2)
        rows.Push([f, v])
    }
    cands := []
    for i, ix in RC_Cands
        cands.Push(ix)
    GuiControlGet, mk, RC:, RC_Make
    GuiControlGet, mx, RC:, RC_MakeX
    ; A first sighting goes in the day book; a model pick on a car already
    ; kept is only an update, not another lookup.
    if !RC_CACHE.HasKey(key)
        RC_LogLine(key, Trim(mk))
    RC_CACHE[key] := { when: A_Now, rows: rows, red: RC_RedRow, wipe: RC_WipeRow
        , pick: RC_ModelPick, cands: cands, make: Trim(mk), makeX: Trim(mx), note: note
        , speed: speed }
    RC_RecentAdd(key, Trim(mk))
}

; Paint a kept answer back into the window - list, make, dropdown, red row,
; VIN on the clipboard - without one request going out. The caller has
; already emptied the window the way a fresh search does.
RC_CacheShow(key) {
    global RC_CACHE, RC_RedRow, RC_WipeRow, RC_ModelPick, RC_Cands, RC_WIPE
    Gui, RC:Default
    c := RC_CACHE[key]
    for i, r in c.rows
        LV_Add("", r[1], r[2])
    RC_RedRow := c.red
    RC_WipeRow := c.wipe
    RC_Cands := []
    for i, ix in c.cands
        RC_Cands.Push(ix)
    RC_ModelPick := c.pick

    ; The dropdown is rebuilt the same way RC_WipeFind builds it, from the
    ; same candidates, and the pick is put back where it was.
    list := "|Pick a model"
    for i, ix in RC_Cands {
        w := RC_WIPE[ix]
        list .= "|" . w.model . "  " . w.y1 . "-" . w.y2
    }
    GuiControl, RC:, RC_Model, %list%
    GuiControl, RC:Choose, RC_Model, % (RC_ModelPick >= 1) ? RC_ModelPick + 1 : 1
    RC_SetMake(c.make, c.makeX)
    RC_WipeShow()
    RC_FitList()

    ; The VIN lands on the clipboard again, same as a fresh search would.
    vin := ""
    for i, r in c.rows
        if (r[1] = "VIN/Chassis")
            vin := r[2]
    if (vin != "") {
        Clipboard := vin
        RC_ShowToast(((StrLen(vin) = 17) ? "VIN copied" : "Partial VIN copied") . "   " . vin)
        RC_TipAtMouse(vin)
    }

    note := c.note . " (kept from earlier today)"
    RC_Done(true, "Success", "kept")
    RC_SelectPlate()
    RC_LogLine(key, c.make)
    RC_RecentAdd(key, c.make)
}

; --- the last ten, and the day book ----------------------------------------

; Put a search at the top of the recent list, keep the list to ten, and
; rebuild the dropdown to match.
RC_RecentAdd(key, make) {
    global RC_LASTTEN
    Gui, RC:Default
    for i, r in RC_LASTTEN {
        if (r.key = key) {
            RC_LASTTEN.RemoveAt(i)
            break
        }
    }
    RC_LASTTEN.InsertAt(1, { key: key, make: make })
    while (RC_LASTTEN.Length() > 10)
        RC_LASTTEN.RemoveAt(RC_LASTTEN.Length())
    list := "|Recent lookups"
    for i, r in RC_LASTTEN
        list .= "|" . r.key . ((r.make != "") ? "  -  " . r.make : "")
    GuiControl, RC:, RC_Recent, %list%
    GuiControl, RC:Choose, RC_Recent, 1
}

; A recent lookup was picked - run it again. The kept copy answers, so
; nothing goes out over the wire. The dropdown snaps back to its prompt.
RC_OnRecent() {
    global RC_LASTTEN
    Gui, RC:Default
    GuiControlGet, choice, RC:, RC_Recent
    GuiControl, RC:Choose, RC_Recent, 1
    if (choice <= 1 || choice - 1 > RC_LASTTEN.Length())
        return
    GuiControl, RC:, RC_Plate, % RC_LASTTEN[choice - 1].key
    RC_OnSearch()
}

; One line per lookup in RegoCheck.log beside the script: when, what, and
; the make that came back. Append-only; delete the file to start it over.
RC_LogLine(key, make) {
    global RC_LOG
    line := A_YYYY . "-" . A_MM . "-" . A_DD . " " . A_Hour . ":" . A_Min
          . "  " . key . ((make != "") ? "  " . make : "") . "`n"
    FileAppend, %line%, %RC_LOG%
}

; Which body a workbook line is about, or "" when it does not say. The same
; reading is used on what the state calls the body, so the two can be compared.
RC_BodyOf(text) {
    if RegExMatch(text, "i)\bsedan\b")
        return "Sedan"
    if RegExMatch(text, "i)hatch")
        return "Hatch"
    if RegExMatch(text, "i)wagon")
        return "Wagon"
    if RegExMatch(text, "i)coupe")
        return "Coupe"
    return ""
}

; The table itself, out of the Wipertech workbook. One line per fitment:
;   brand | model and generation | first year | last year | driver | passenger | rear
; An empty last field means the car has no rear wiper.
RC_WipeData() {
    data =
(LTrim Join`n
Kia|Carens (RS)|2000|2007|24 in / 600 mm|19 in / 475 mm|14 in / 350 mm
Kia|Carnival (UP, FL)|1999|2001|24 in / 600 mm|24 in / 600 mm|16 in / 400 mm
Kia|Carnival (KV)|2001|2006|24 in / 600 mm|24 in / 600 mm|16 in / 400 mm
Kia|Carnival (VQ)|2005|2015|26 in / 650 mm|18 in / 450 mm|16 in / 400 mm
Kia|Carnival (YP)|2014|2020|26 in / 650 mm|18 in / 450 mm|
Kia|Carnival (KA4)|2020|2026|26 in / 650 mm|20 in / 500 mm|12 in / 300 mm
Kia|Cerato Coupe (TD)|2009|2013|24 in / 600 mm|20 in / 500 mm|
Kia|Cerato Coupe (YD)|2013|2018|26 in / 650 mm|14 in / 350 mm|
Kia|Cerato Hatch (LD)|2004|2008|24 in / 600 mm|16 in / 400 mm|14 in / 350 mm
Kia|Cerato Hatch (TD)|2009|2013|24 in / 600 mm|20 in / 500 mm|14 in / 350 mm
Kia|Cerato Hatch (YD)|2013|2018|26 in / 650 mm|14 in / 350 mm|13 in / 325 mm
Kia|Cerato Hatch (BD)|2018|2025|26 in / 650 mm|16 in / 400 mm|14 in / 350 mm
Kia|Cerato Sedan (LD)|2004|2009|24 in / 600 mm|16 in / 400 mm|
Kia|Cerato Sedan (TD)|2009|2013|24 in / 600 mm|20 in / 500 mm|
Kia|Cerato Sedan (YD)|2013|2018|26 in / 650 mm|14 in / 350 mm|
Kia|Cerato Sedan (BD)|2018|2025|26 in / 650 mm|16 in / 400 mm|
Kia|Clarus (K9A)|1996|2001|21 in / 525 mm|19 in / 475 mm|
Kia|Credos (K9A)|1996|2001|21 in / 525 mm|19 in / 475 mm|
Kia|EV3 (SV)|2024|2026|26 in / 650 mm|18 in / 450 mm|
Kia|EV4 Sedan (CT1)|2026|2027|26 in / 650 mm|16 in / 400 mm|
Kia|EV5 (OV)|2024|2026|24 in / 600 mm|18 in / 450 mm|10 in / 250 mm
Kia|EV6 (CV)|2021|2026|26 in / 650 mm|16 in / 400 mm|
Kia|EV6 GT (CV)|2021|2026|26 in / 650 mm|16 in / 400 mm|
Kia|EV9 (MV)|2023|2026|26 in / 650 mm|18 in / 450 mm|12 in / 300 mm
Kia|Grand Carnival (VQ)|2005|2015|26 in / 650 mm|18 in / 450 mm|16 in / 400 mm
Kia|K4|2024|2026|26 in / 650 mm|16 in / 400 mm|
Kia|Magentis (MG)|2005|2010|24 in / 600 mm|18 in / 450 mm|
Kia|Mentor Hatch (FA)|1997|2000|22 in / 550 mm|18 in / 450 mm|18 in / 450 mm
Kia|Mentor Sedan (FB)|1996|2001|21 in / 525 mm|19 in / 475 mm|
Kia|Niro (DE)|2016|2022|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Kia|Niro (SG2)|2022|2025|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Kia|Niro Plus (DE PVE)|2022|2025|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Kia|Optima (GD)|2001|2006|22 in / 550 mm|20 in / 500 mm|
Kia|Optima (TF)|2010|2015|24 in / 600 mm|18 in / 450 mm|
Kia|Optima (JF)|2015|2019|26 in / 650 mm|18 in / 450 mm|12 in / 300 mm
Kia|Picanto (TA)|2011|2017|22 in / 550 mm|16 in / 400 mm|12 in / 300 mm
Kia|Picanto (JA)|2017|2026|24 in / 600 mm|14 in / 350 mm|
Kia|Pregio (CT, TB)|1997|2006|21 in / 525 mm|18 in / 450 mm|15 in / 375 mm
Kia|Pro Cee'd Hatch (JD)|2013|2018|26 in / 650 mm|14 in / 350 mm|12 in / 300 mm
Kia|Rio Hatch (DC)|2000|2005|21 in / 525 mm|18 in / 450 mm|13 in / 325 mm
Kia|Rio Hatch (JB)|2005|2011|22 in / 550 mm|16 in / 400 mm|14 in / 350 mm
Kia|Rio Hatch (UB)|2011|2017|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Kia|Rio Hatch (YB, SC, FB)|2017|2024|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Kia|Rio Sedan (DC)|2000|2005|21 in / 525 mm|18 in / 450 mm|
Kia|Rio Sedan (JB)|2005|2011|22 in / 550 mm|16 in / 400 mm|
Kia|Rio Sedan (UB)|2011|2017|26 in / 650 mm|16 in / 400 mm|
Kia|Rondo (UN)|2006|2013|26 in / 650 mm|16 in / 400 mm|14 in / 350 mm
Kia|Rondo (RP)|2013|2018|28 in / 700 mm|28 in / 700 mm|12 in / 300 mm
Kia|Seltos (SP2)|2019|2026|24 in / 600 mm|18 in / 450 mm|12 in / 300 mm
Kia|Shuma (FB)|1997|2001|21 in / 525 mm|19 in / 475 mm|
Kia|Sorento (BL, JC)|2002|2011|24 in / 600 mm|18 in / 450 mm|14 in / 350 mm
Kia|Sorento (XM)|2009|2015|24 in / 600 mm|20 in / 500 mm|11 in / 275 mm
Kia|Sorento (UM)|2015|2020|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Kia|Sorento (MQ4)|2020|2026|26 in / 650 mm|18 in / 450 mm|12 in / 300 mm
Kia|Soul (AM)|2009|2014|24 in / 600 mm|20 in / 500 mm|11 in / 275 mm
Kia|Soul (PS)|2014|2018|24 in / 600 mm|20 in / 500 mm|11 in / 275 mm
Kia|Spectra Hatch (FB)|2001|2004|21 in / 525 mm|19 in / 475 mm|18 in / 450 mm
Kia|Spectra Sedan (FB)|2001|2004|21 in / 525 mm|19 in / 475 mm|
Kia|Sportage (NB)|1994|2003|20 in / 500 mm|20 in / 500 mm|16 in / 400 mm
Kia|Sportage (KM)|2004|2010|24 in / 600 mm|16 in / 400 mm|
Kia|Sportage (SL)|2010|2015|24 in / 600 mm|18 in / 450 mm|12 in / 300 mm
Kia|Sportage (QL)|2015|2022|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Kia|Sportage (NQ5)|2021|2026|26 in / 650 mm|18 in / 450 mm|12 in / 300 mm
Kia|Stinger (CK)|2017|2024|26 in / 650 mm|18 in / 450 mm|
Kia|Stonic (YB)|2017|2026|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Kia|Tasman (TK)|2025|2026|22 in / 550 mm|22 in / 550 mm|
Isuzu|D-MAX (RA, RC)|2002|2012|22 in / 550 mm|19 in / 475 mm|
Isuzu|D-MAX (RT)|2012|2020|22 in / 550 mm|19 in / 475 mm|
Isuzu|D-MAX (RG, LS-U, X-Terrain, Blade)|2019|2026|23 in / 575 mm|16 in / 400 mm|
Isuzu|D-MAX (RG, SX, LS-M)|2019|2026|23 in / 575 mm|16 in / 400 mm|
Isuzu|MU-X (RF)|2013|2021|22 in / 550 mm|17 in / 425 mm|12 in / 300 mm
Isuzu|MU-X (RJ)|2020|2026|22 in / 550 mm|16 in / 400 mm|10 in / 250 mm
BYD|Atto 1|2025|2026|24 in / 600 mm|16 in / 400 mm|
BYD|Atto 2|2024|2026|24 in / 600 mm|19 in / 475 mm|11 in / 275 mm
BYD|Atto 3|2022|2025|24 in / 600 mm|17 in / 425 mm|11 in / 275 mm
BYD|Atto 3 EVO|2026|2026|24 in / 600 mm|17 in / 425 mm|11 in / 275 mm
BYD|Dolphin|2021|2025|25 in / 625 mm|15 in / 375 mm|8 in / 200 mm
BYD|E6|2011|2021|26 in / 650 mm|14 in / 350 mm|14 in / 350 mm
BYD|Seal|2022|2025|24 in / 600 mm|18 in / 450 mm|
BYD|Seal 6 Sedan|2026|2026|24 in / 600 mm|18 in / 450 mm|
BYD|Seal 6 Touring|2026|2026|26 in / 650 mm|19 in / 480 mm|11 in / 280 mm
BYD|Sealion 5|2025|2026|24 in / 600 mm|18 in / 450 mm|12 in / 300 mm
BYD|Sealion 6|2023|2026|25 in / 625 mm|19 in / 475 mm|9 in / 225 mm
BYD|Sealion 7|2024|2026|25 in / 625 mm|18 in / 450 mm|
BYD|Sealion 8|2026|2027|27 in / 675 mm|19 in / 475 mm|
BYD|Shark 6|2025|2027|22 in / 550 mm|18 in / 450 mm|
Hyundai|Accent Hatch (LC)|2000|2005|20 in / 500 mm|18 in / 450 mm|18 in / 450 mm
Hyundai|Accent Hatch (MC)|2005|2010|22 in / 550 mm|16 in / 400 mm|14 in / 350 mm
Hyundai|Accent Hatch (RB)|2010|2019|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Hyundai|Accent Sedan (LC)|1999|2005|20 in / 500 mm|18 in / 450 mm|
Hyundai|Accent Sedan (MC)|2005|2010|22 in / 550 mm|16 in / 400 mm|
Hyundai|Accent Sedan (RB)|2010|2017|26 in / 650 mm|16 in / 400 mm|
Hyundai|Coupe (RD)|1996|2002|20 in / 500 mm|16 in / 400 mm|18 in / 450 mm
Hyundai|Elantra Hatch (XD, Series 1)|2000|2003|19 in / 475 mm|17 in / 425 mm|19 in / 475 mm
Hyundai|Elantra Hatch (XD, Series 2)|2003|2006|20 in / 500 mm|18 in / 450 mm|19 in / 475 mm
Hyundai|Elantra LaVita (FC)|2001|2010|22 in / 550 mm|16 in / 400 mm|13 in / 325 mm
Hyundai|Elantra N-Line Sedan (CN7)|2020|2026|26 in / 650 mm|16 in / 400 mm|
Hyundai|Elantra Sedan (XD, Series 1)|2000|2003|19 in / 475 mm|17 in / 425 mm|
Hyundai|Elantra Sedan (XD, Series 2)|2003|2006|20 in / 500 mm|18 in / 450 mm|
Hyundai|Elantra Sedan (HD)|2005|2011|24 in / 600 mm|18 in / 450 mm|
Hyundai|Elantra Sedan (MD)|2010|2016|26 in / 650 mm|14 in / 350 mm|
Hyundai|Elantra Sedan (AD)|2015|2020|26 in / 650 mm|16 in / 400 mm|
Hyundai|Elantra Sedan (CN7)|2020|2026|24 in / 600 mm|18 in / 450 mm|
Hyundai|Excel Hatch (X1)|1985|1990|18 in / 450 mm|18 in / 450 mm|18 in / 450 mm
Hyundai|Excel Hatch (X2)|1990|1994|18 in / 450 mm|18 in / 450 mm|16 in / 400 mm
Hyundai|Excel Hatch (X3)|1994|2000|19 in / 475 mm|17 in / 425 mm|19 in / 475 mm
Hyundai|Excel Sedan (X1)|1985|1990|18 in / 450 mm|18 in / 450 mm|
Hyundai|Excel Sedan (X2)|1990|1994|18 in / 450 mm|18 in / 450 mm|
Hyundai|Excel Sedan (X3)|1994|2000|19 in / 475 mm|17 in / 425 mm|
Hyundai|Genesis (DH)|2014|2017|26 in / 650 mm|16 in / 400 mm|
Hyundai|Getz (TB, Series 1)|2002|2005|22 in / 550 mm|16 in / 400 mm|14 in / 350 mm
Hyundai|Getz (TB, Series 2)|2005|2010|22 in / 550 mm|15 in / 375 mm|14 in / 350 mm
Hyundai|Grandeur (XG)|1998|2005|22 in / 550 mm|20 in / 500 mm|
Hyundai|Grandeur (TG)|2005|2011|24 in / 600 mm|20 in / 500 mm|
Hyundai|H100|1993|2004|18 in / 450 mm|18 in / 450 mm|17 in / 425 mm
Hyundai|H100 Bus|1993|2004|18 in / 450 mm|18 in / 450 mm|17 in / 425 mm
Hyundai|i20 (PB, PBT)|2008|2015|24 in / 600 mm|15 in / 375 mm|12 in / 300 mm
Hyundai|i20 N (BC3, BI3)|2020|2026|24 in / 600 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|i30 Hatch (FD)|2007|2012|24 in / 600 mm|18 in / 450 mm|12 in / 300 mm
Hyundai|i30 Hatch (GD)|2011|2017|26 in / 650 mm|14 in / 350 mm|13 in / 325 mm
Hyundai|i30 Hatch (PD)|2016|2025|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|i30 N Hatch (PD)|2017|2025|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|i30 N Sedan (CN7)|2021|2026|24 in / 600 mm|18 in / 450 mm|
Hyundai|i30 N-Line Hatch (PD)|2017|2025|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|i30 N-Line Sedan (CN7)|2020|2026|26 in / 650 mm|16 in / 400 mm|
Hyundai|i30 N-Line Sedan-Hatch (PD)|2017|2020|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|i30 Sedan (CN7)|2020|2026|24 in / 600 mm|18 in / 450 mm|
Hyundai|i30 Wagon (FD)|2007|2012|24 in / 600 mm|18 in / 450 mm|12 in / 300 mm
Hyundai|i30 Wagon (GD)|2012|2017|26 in / 650 mm|14 in / 350 mm|13 in / 325 mm
Hyundai|i40 Sedan (VF)|2012|2019|26 in / 650 mm|16 in / 400 mm|
Hyundai|i40 Wagon (VF)|2011|2019|26 in / 650 mm|16 in / 400 mm|14 in / 350 mm
Hyundai|i45 (YF)|2009|2015|26 in / 650 mm|18 in / 450 mm|
Hyundai|iLoad (TQ)|2007|2021|24 in / 600 mm|20 in / 500 mm|14 in / 350 mm
Hyundai|iMax (TQ)|2008|2021|24 in / 600 mm|20 in / 500 mm|16 in / 400 mm
Hyundai|Inster (AX)|2024|2026|22 in / 550 mm|16 in / 400 mm|11 in / 275 mm
Hyundai|IONIQ (AE)|2016|2022|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Hyundai|IONIQ 5 (NE)|2021|2026|26 in / 650 mm|18 in / 450 mm|
Hyundai|IONIQ 6 (CE)|2022|2025|26 in / 650 mm|18 in / 450 mm|
Hyundai|IONIQ 9 (ME)|2025|2026|26 in / 650 mm|20 in / 500 mm|
Hyundai|ix35 (LM, EL)|2009|2015|24 in / 600 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|Kona (OS)|2017|2023|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Hyundai|Kona (SX2)|2023|2026|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|Kona N (OS)|2021|2023|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Hyundai|Lantra Sedan (J2)|1995|2000|20 in / 500 mm|18 in / 450 mm|
Hyundai|Lantra Wagon (J2)|1995|2000|20 in / 500 mm|18 in / 450 mm|13 in / 325 mm
Hyundai|Matrix (FC)|2001|2010|22 in / 550 mm|16 in / 400 mm|13 in / 325 mm
Hyundai|NEXO (FE)|2018|2025|26 in / 650 mm|16 in / 400 mm|14 in / 350 mm
Hyundai|Palisade (LX2)|2018|2025|26 in / 650 mm|20 in / 500 mm|12 in / 300 mm
Hyundai|S Coupe (SLC)|1990|1996|19 in / 475 mm|17 in / 425 mm|
Hyundai|Santa Fe (SM)|2000|2006|22 in / 550 mm|20 in / 500 mm|13 in / 325 mm
Hyundai|Santa Fe (CM)|2006|2012|24 in / 600 mm|18 in / 450 mm|14 in / 350 mm
Hyundai|Santa Fe (DM)|2012|2019|26 in / 650 mm|14 in / 350 mm|13 in / 325 mm
Hyundai|Santa Fe (TM)|2018|2019|26 in / 650 mm|16 in / 400 mm|12 in / 300 mm
Hyundai|Santa Fe (TMA)|2019|2023|26 in / 650 mm|16 in / 400 mm|13 in / 325 mm
Hyundai|Santa Fe (MX5)|2024|2026|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Hyundai|Sonata (Y3)|1992|2000|20 in / 500 mm|18 in / 450 mm|
Hyundai|Sonata (EF)|1998|2005|22 in / 550 mm|20 in / 500 mm|
Hyundai|Sonata (NF)|2005|2010|24 in / 600 mm|20 in / 500 mm|
Hyundai|Sonata (LF)|2014|2019|26 in / 650 mm|18 in / 450 mm|
Hyundai|Sonata (DN8)|2020|2026|26 in / 650 mm|18 in / 450 mm|
Hyundai|Staria (US4)|2021|2026|26 in / 650 mm|18 in / 450 mm|13 in / 325 mm
Hyundai|Staria Load (US4)|2021|2026|26 in / 650 mm|18 in / 450 mm|13 in / 325 mm
Hyundai|Terracan (HP)|2001|2006|21 in / 525 mm|19 in / 475 mm|15 in / 375 mm
Hyundai|Tiburon (GK)|2001|2009|22 in / 550 mm|18 in / 450 mm|20 in / 500 mm
Hyundai|Trajet (FO)|2000|2008|24 in / 600 mm|20 in / 500 mm|16 in / 400 mm
Hyundai|Tucson (JM)|2004|2010|24 in / 600 mm|16 in / 400 mm|
Hyundai|Tucson (TL)|2015|2023|26 in / 650 mm|16 in / 400 mm|14 in / 350 mm
Hyundai|Tucson (NX4)|2020|2026|26 in / 650 mm|16 in / 400 mm|11 in / 275 mm
Hyundai|Veloster (FS)|2011|2017|26 in / 650 mm|18 in / 450 mm|9 in / 225 mm
Hyundai|Veloster (JS)|2018|2020|26 in / 650 mm|18 in / 450 mm|
Hyundai|Venue (QX)|2019|2026|24 in / 600 mm|18 in / 450 mm|12 in / 300 mm
Genesis|G70 Sedan (IK)|2017|2025|26 in / 650 mm|18 in / 450 mm|
Genesis|G80 Sedan (DH)|2016|2019|26 in / 650 mm|16 in / 400 mm|
Genesis|G80 Sedan (RG3)|2020|2026|26 in / 650 mm|16 in / 400 mm|
Genesis|GV60 SUV (JW)|2021|2026|26 in / 650 mm|18 in / 450 mm|
Genesis|GV70 SUV (JK)|2021|2026|26 in / 650 mm|18 in / 450 mm|11 in / 275 mm
Genesis|GV80 SUV (JX)|2020|2026|26 in / 650 mm|18 in / 450 mm|12 in / 300 mm
)
    return data
}




; ============================================================================
;  EMBEDDED ICON BLOCK  -  paste this whole block into ANY AHK v1 script.
;  Then call  SetEmbeddedIcon()  once, near the top (before creating GUIs).
;  Every GUI you create afterwards uses this icon automatically. No path.

;CALL IT BY  SetEmbeddedIcon() OR #Include EmbeddedIcon.ahk
; ============================================================================

SetEmbeddedIcon() {
    global __EMBED_ICON_PATH
    if (__EMBED_ICON_PATH != "" && FileExist(__EMBED_ICON_PATH))
        return __EMBED_ICON_PATH                      ; already decoded once

    b64 := __EmbeddedIconB64()
    file := A_Temp . "\__embedded_" . A_ScriptName . ".ico"

    ; --- base64 -> binary ---
    if !DllCall("Crypt32\CryptStringToBinary", "Str", b64, "UInt", 0, "UInt", 0x1
              , "Ptr", 0, "UIntP", size, "Ptr", 0, "Ptr", 0)
        return ""
    VarSetCapacity(bin, size, 0)
    DllCall("Crypt32\CryptStringToBinary", "Str", b64, "UInt", 0, "UInt", 0x1
          , "Ptr", &bin, "UIntP", size, "Ptr", 0, "Ptr", 0)

    ; --- write temp .ico ---
    f := FileOpen(file, "w")
    f.RawWrite(bin, size)
    f.Close()

    __EMBED_ICON_PATH := file
    Menu, Tray, Icon, %file%                          ; tray + default GUI icon
    return file
}

; Optional: force the icon onto a specific GUI that's already shown.
; Usage:  ApplyEmbeddedIcon("MyGuiTitle")   or   ApplyEmbeddedIcon(hwnd)
ApplyEmbeddedIcon(target) {
    file := SetEmbeddedIcon()
    if (file = "")
        return
    hIcon := DllCall("LoadImage", "Ptr", 0, "Str", file, "UInt", 1
                   , "Int", 0, "Int", 0, "UInt", 0x10, "Ptr")   ; LR_LOADFROMFILE
    hwnd := target
    if target is not integer
        WinGet, hwnd, ID, %target%
    SendMessage, 0x80, 0, %hIcon%,, ahk_id %hwnd%     ; WM_SETICON small
    SendMessage, 0x80, 1, %hIcon%,, ahk_id %hwnd%     ; WM_SETICON big
}

__EmbeddedIconB64() {
    static s := "
( LTrim Join
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
AAAAHfsfpnYYHI3/T/0AAAAASUVORK5CYII=
)"
    return s
}
; ============================================================================
;  END EMBEDDED ICON BLOCK
; ====================================================