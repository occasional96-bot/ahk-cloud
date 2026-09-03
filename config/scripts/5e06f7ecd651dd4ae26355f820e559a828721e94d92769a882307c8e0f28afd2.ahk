#NoEnv
#SingleInstance, Force
SetBatchLines, -1
SetEmbeddedIcon()

#NoEnv
; #SingleInstance is OFF on purpose: this one file is both the RegoCheck
; window and its CatalogProbe workers, and the workers are relaunches of this
; same script - any #SingleInstance setting would have them and the window
; knocking each other over. Sweeps keep their own mutex; the window closes its
; own older instance by hand below, which is what Force used to do for it.
#SingleInstance, Off
SetBatchLines, -1

; =============================================================================
; RegoCheckSolo.ahk - the whole tool in ONE file.  ** GENERATED - DO NOT EDIT **
;
; Assembled by build_solo.ps1 from RegoCheck.ahk, CatalogProbe.ahk and
; lib\AudosHttp.ahk, so a single copy of this file is a working install.
; Edit those three and rebuild; anything changed here is overwritten.
;
; The catalog probe still runs as separate short-lived processes - that part
; is non-negotiable, Chrome hands its tab strip to a UI Automation client
; exactly once per process - but the worker processes are THIS script
; relaunched with a mode word:
;
;   RegoCheckSolo.ahk                       the window
;   RegoCheckSolo.ahk ABC123                the window, that plate searched
;   RegoCheckSolo.ahk sweep                 one catalog sweep, write the file, exit
;   RegoCheckSolo.ahk select <brand>        front that catalog's tab, exit
;   RegoCheckSolo.ahk search <brand> <vin>  ...and look the VIN up in it, exit
;
; A plate spelt exactly "sweep", "select" or "search" would be taken for a
; mode word. No Australian plate is, so the words are left plain.
; =============================================================================

; ===== CatalogProbe.ahk - brand tables and globals =====
; Kia and Hyundai are the hard pair: both are the SAME web app - Microcat EPC
; on microcat-apac.superservice.com - so neither the host nor the shape of the
; title separates them. They are told apart by whichever of these fits:
;
;   1. With NO vehicle loaded the title names the brand outright:
;        "Microcat EPC - Hyundai"
;   2. With a vehicle loaded the title turns into
;        "<MODEL> | <catalog code> | <VIN> | <year> | <date> | <code>"
;      where the catalog code is no help - Kia's reads KAUSPTC05 and
;      Hyundai's KAUSPDV19, both starting KAUS - but the VIN is decisive, so
;      the brand comes off its world manufacturer identifier.
;   3. The URL is the ground truth and settles it either way. Its vehicle
;      token is base64 that spells the brand out next to the VIN - "KIA" for
;      Kia, "HYW" for Hyundai - and the subscription it carries differs per
;      brand as well. Only the tab that is currently showing hands its URL to
;      UI Automation, so this is used to CONFIRM a jump landed on the right
;      tab, not to light the boxes.
;
; The other two name themselves plainly and need none of that.
global CP_BRANDS := ["kia", "hyundai", "isuzu", "byd"]

; Matched against the raw title, case-insensitive, on word boundaries - a
; plain "kia" substring would also match Nokia.
global CP_WORDS := { kia:     ["\bkia\b"]
                   , hyundai: ["\bhyundai\b", "\bgenesis\b"]
                   , isuzu:   ["\bisuzu\b", "\bpentana\b"]
                   , byd:     ["\bbyd\b"] }

; What the brand looks like inside the URL's vehicle token, once the base64
; is undone. Used to confirm a jump landed where it was aimed.
global CP_URLMARK := { kia: "KIA", hyundai: "HYW", isuzu: "ISUZU", byd: "BYD" }

; VIN prefixes. Genesis - KMT, KMU - counts as Hyundai: the states register
; those as HYUNDAI and it is the same dealership either way.
global CP_WMI := { kia:     ["KNA", "KNB", "KNC", "KND", "KNE", "KNF", "KNG", "KNH"
                            , "KNM", "U5Y", "U6Y", "3KP", "5XY", "5XX", "LJD", "MS0"]
                 , hyundai: ["KMH", "KMF", "KMJ", "KMC", "KME", "KMT", "KMU", "TMA"
                            , "TMB", "TMK", "NLH", "5NP", "5NM", "5NT", "LBE", "MAL", "95P"]
                 , isuzu:   ["MPA", "MP1", "MP2", "JAA", "JAL", "JAC", "JAB", "MP5"]
                 , byd:     ["LC0", "LGX", "LC6"] }

; Words that must NOT be in a title for a brand match to count. The browser's
; own new-tab page and a search results page can both carry a brand name.
global CP_VETO := ["googlesearch", "newtab", "bing", "duckduckgo", "youtube"]

; The VIN box on Microcat is found by id, because it has no name to match on
; and is a ComboBox - an autocomplete - rather than an edit. The list is
; deliberately narrow: Microcat's OTHER box, globalSearchInput, is the wide
; one across the top, and on a page with a car loaded it searches parts WITHIN
; that car, so a VIN typed there would search the wrong thing and still look
; like it worked. genericSearchInput exists only on the Identify Vehicle page,
; which is exactly why failing to find it is the signal to go there.
global CP_BOXIDS := ["genericSearchInput"]

global CP_OUT := A_ScriptDir . "\CatalogProbe.txt"
global CP_TRACE := ""
global CP_pUia := 0


; ---- worker dispatch --------------------------------------------------------
; A relaunch with one of these words does its job and exits before any of the
; window code runs. The CP_* globals above are all these modes need.
if (A_Args.Length() >= 3 && A_Args[1] = "search") {
    CP_Search(A_Args[2], A_Args[3])
    ExitApp
}
if (A_Args.Length() >= 2 && A_Args[1] = "select") {
    CP_Select(A_Args[2])
    ExitApp
}
if (A_Args.Length() >= 1 && A_Args[1] = "sweep") {
    ; The sweep mutex. Owned for this process's whole life; Windows drops it
    ; on exit, so a crashed sweep cannot wedge the next one out.
    DllCall("CreateMutex", "ptr", 0, "int", true, "str", "AudosCatalogProbeSweep")
    if (DllCall("GetLastError") != 0)   ; ERROR_ALREADY_EXISTS - one is running
        ExitApp
    CP_Main()
    ExitApp
}

; ---- the window from here on ------------------------------------------------
; Close any older instance of this script by hand - #SingleInstance is Off, so
; nothing else will. Worker processes carry the same hidden main-window title;
; one caught mid-run here is aborted, which costs nothing - the next sweep is
; seconds away and a search would belong to the window being replaced anyway.
RCS_prevDHW := A_DetectHiddenWindows
RCS_prevTMM := A_TitleMatchMode
DetectHiddenWindows, On
SetTitleMatchMode, 1
RCS_self := DllCall("GetCurrentProcessId")
WinGet, RCS_list, List, %A_ScriptFullPath% ahk_class AutoHotkey
Loop, %RCS_list%
{
    RCS_w := RCS_list%A_Index%
    WinGet, RCS_pid, PID, ahk_id %RCS_w%
    if (RCS_pid = RCS_self)
        continue
    WinClose, ahk_id %RCS_w%, , 2
}
DetectHiddenWindows, %RCS_prevDHW%
SetTitleMatchMode, %RCS_prevTMM%

; The two hotkeys are registered here rather than written as ^!r:: labels,
; because a static hotkey label registers in EVERY process this script starts
; - a worker sweeping in the background would swallow PgDn and conjure up a
; blank window. The Hotkey command only runs in this, the window mode.
Hotkey, ^!r, RC_HkRecall
Hotkey, PgDn, RC_TrayShow

; ===== RegoCheck.ahk =====

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
global RC_LastStatus := 0   ; HTTP status of the last RC_Send (0 = no reply)

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

; The last ten searches that found a car, newest first - and the day book
; they are quietly written into, one line per lookup, next to the script.
; The Recent dropdown that used to show these is gone; the list stays for
; the day book and for whatever wants it next.
global RC_LASTTEN := []
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
global RC_T0    := 0
global RC_INI   := A_ScriptDir . "\RegoCheck.ini"
global RC_List     := ""
global RC_Make     := ""
global RC_MakeX    := ""

; The VIN band's controls - the strip, the value on it, the copied pill -
; and the four dealership-brand checkboxes under it. Gui control variables
; must be global when the Gui is built inside a function.
global RC_VinBand := ""
global RC_VinTxt  := ""
global RC_SearchBar := ""
global RC_SearchTxt := ""
global RC_LoadBar   := ""
global RC_hSB       := 0
global RC_CopyBtn := ""
global RC_EpcBar := ""
global RC_EpcTxt := ""
global RC_ChkKia := ""
global RC_ChkHyu := ""
global RC_ChkIsu := ""
global RC_ChkByd := ""

; Which dealership catalogs CatalogProbe.ahk last found open in a browser.
; Keyed by brand - kia, hyundai, isuzu, byd - each holding what the tab was
; showing. RC_CAT_WHEN is the stamp on the file already read in, so an
; unchanged file is not parsed again; RC_CAT_SPAWN is when a probe was last
; started, so one cannot be started on top of another.
global RC_CAT       := {}
global RC_CAT_WHEN  := ""
global RC_CAT_SPAWN := 0
global RC_CAT_FILE  := A_ScriptDir . "\CatalogProbe.txt"
; The worker is this same script, relaunched with a mode word.
global RC_CAT_EXE   := A_ScriptFullPath
global RC_CAT_BOX   := { kia: "RC_ChkKia", hyundai: "RC_ChkHyu"
                       , isuzu: "RC_ChkIsu", byd: "RC_ChkByd" }

; The VIN the band is showing - what the Copy button copies - and the state
; the car was found registered in, for the tag and the status bar.
global RC_VinVal   := ""
global RC_FoundIn  := ""

; Shown in the title bar. Goes up by one every time the script changes.
global RC_VER := "4.0"

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
    Gui, RC:New, -MaximizeBox -Resize +HwndRC_hGui, Rego check
    Gui, RC:Default
    Gui, Margin, 12, 12
    Gui, Font, s10, Segoe UI

    ; The box takes the whole top line - no label; the window's own title
    ; already says what goes in it. 17 characters so a whole VIN fits.
    Gui, Font, s11, Segoe UI
    Gui, Add, Edit,   x12 y12 w304 h30 vRC_Plate HwndRC_hEdit Uppercase Limit17
    Gui, Font, s10, Segoe UI
    ; Buttons cannot be recoloured, so the blue Search "button" is a Progress
    ; painted the accent blue with white bold text laid over it. Enter still
    ; searches through a real Default button parked out of sight off-screen.
    Gui, Add, Button, x-200 y-200 w1 h1 Default gRC_OnSearch, S
    Gui, Add, Progress, x324 y12 w84 h30 Background0067C0 vRC_SearchBar HwndRC_hSearchBtn Disabled
    Gui, Font, s10 w600 cFFFFFF, Segoe UI
    Gui, Add, Text, x324 y12 w84 h30 Center 0x200 BackgroundTrans gRC_OnSearch vRC_SearchTxt, Search
    Gui, Font, s10 w400 cDefault, Segoe UI
    rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", 85, "Int", 31, "Int", 8, "Int", 8, "Ptr")
    DllCall("SetWindowRgn", "Ptr", RC_hSearchBtn, "Ptr", rgn, "Int", true)

    ; The VIN band sits right under the search box, the same height as the
    ; edit above it so the left column reads as one aligned stack. One line:
    ; the small VIN label, the value, the copied pill, and the copy icon at
    ; the band's right end. Strip and pill are Progress controls as flat
    ; colour.
    Gui, Add, Progress, x12 y50 w304 h30 BackgroundE8F1FA vRC_VinBand Disabled
    Gui, Font, s8 c4A6A90, Segoe UI
    Gui, Add, Text, x22 y59 w26 h13 BackgroundTrans, VIN
    Gui, Font, s11 w700 c003E73, Consolas
    ; Double-clicking the value copies it, same as the copy button beside it.
    Gui, Add, Text, x52 y56 w148 h18 BackgroundTrans gRC_OnVinDbl vRC_VinTxt, %A_Space%
    Gui, Font, s10 w400 cDefault, Segoe UI
    ; The copy button - the two-squares glyph - filling the band's right end,
    ; the same size as the EPC button under Search. Hovering it says what it
    ; does; the feedback for pressing it is the VIN tooltip at the cursor.
    Gui, Font, s12, Segoe UI Symbol
    Gui, Add, Button, x232 y50 w84 h30 gRC_OnCopy vRC_CopyBtn, % Chr(0x29C9)
    Gui, Font, s10 w400 cDefault, Segoe UI

    ; The EPC button, directly under Search and the same size, in the catalog
    ; green. It jumps the detected make's catalog - the make read off the
    ; VIN's WMI, the same way CatalogProbe reads it - and searches the VIN
    ; there. Same Progress-with-text-overlay trick as Search.
    Gui, Add, Progress, x324 y50 w84 h30 Background0F6E56 vRC_EpcBar HwndRC_hEpcBtn Disabled
    Gui, Font, s10 w600 cFFFFFF, Segoe UI
    Gui, Add, Text, x324 y50 w84 h30 Center 0x200 BackgroundTrans gRC_OnEpc vRC_EpcTxt, EPC
    Gui, Font, s10 w400 cDefault, Segoe UI
    rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", 85, "Int", 31, "Int", 8, "Int", 8, "Ptr")
    DllCall("SetWindowRgn", "Ptr", RC_hEpcBtn, "Ptr", rgn, "Int", true)

    ; The make in bold on its own line, the build spelled out underneath in
    ; ordinary weight. The state lives in the status bar only.
    Gui, Font, s13 w600, Segoe UI
    Gui, Add, Text, x12 y88 w396 h24 vRC_Make, %A_Space%
    Gui, Font, s10 w400 c606060, Segoe UI
    Gui, Add, Text, x12 y114 w396 h34 Hidden vRC_MakeX, %A_Space%
    Gui, Font, s10 w400 cDefault, Segoe UI

    ; Tall enough for the header and every row the tyre shops can fill at
    ; once. If it is any shorter a scrollbar appears, which then eats the
    ; width and brings a second scrollbar along the bottom with it.
    Gui, Add, ListView, x12 y150 w396 h348 vRC_List HwndRC_hLV gRC_OnList -Multi +Grid NoSortHdr, Field|Value

    ; The dealership brands, centred under the list. These are lights, not
    ; settings: a tick means CatalogProbe found that brand's parts catalog
    ; open in Chrome or Edge, and clicking one brings that tab to the front
    ; and searches the VIN in it. The tick is put back the way the probe left
    ; it on every click, so they cannot be toggled by hand. RC_FitList slides
    ; the row up and down with the bottom of the list.
    Gui, Add, Checkbox, x70 y506 w52 h20 vRC_ChkKia gRC_OnCatKia, Kia
    Gui, Add, Checkbox, x134 y506 w76 h20 vRC_ChkHyu gRC_OnCatHyu, Hyundai
    Gui, Add, Checkbox, x222 y506 w62 h20 vRC_ChkIsu gRC_OnCatIsu, Isuzu
    Gui, Add, Checkbox, x296 y506 w54 h20 vRC_ChkByd gRC_OnCatByd, BYD

    ; Wide enough for the longest field name - "Tyres (front & rear)" - with
    ; the rest left for the values, which are mostly short.
    LV_ModifyCol(1, 138)
    LV_ModifyCol(2, 240)

    ; Row colouring is not something a ListView does on its own - Windows has to
    ; be asked, row by row, while it paints. RC_OnNotify answers.
    OnMessage(0x004E, "RC_OnNotify")

    ; Mouse moves feed the copy button's hover tooltip.
    OnMessage(0x0200, "RC_MouseTip")

    ; A real status bar closes the window: what happened, how long it took,
    ; and which speed it ran at. It keeps itself glued to the bottom edge
    ; whenever RC_FitList resizes the window. The right cell doubles as the
    ; speed switch - "Fast v" - and clicking it pops the little mode menu;
    ; the click lands in RC_OnNotify as an NM_CLICK from the bar.
    Gui, Add, StatusBar, HwndRC_hSB
    SB_SetParts(266, 64)

    ; A blue progress bar - the app's accent blue, rounded ends - that rides
    ; on the status bar's first cell while a search runs, one notch per step,
    ; the counter in the middle cell. It disappears for the tick. Made a child
    ; of the status bar itself, so it stays glued inside the first cell
    ; however the window resizes.
    Gui, Add, Progress, x2 y556 w260 h17 c0067C0 BackgroundE8E8E8 Hidden vRC_LoadBar HwndRC_hLoadBar Disabled
    DllCall("SetParent", "Ptr", RC_hLoadBar, "Ptr", RC_hSB)
    DllCall("MoveWindow", "Ptr", RC_hLoadBar, "Int", 2, "Int", 3, "Int", 260, "Int", 17, "Int", 1)
    rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", 261, "Int", 18, "Int", 12, "Int", 12, "Ptr")
    DllCall("SetWindowRgn", "Ptr", RC_hLoadBar, "Ptr", rgn, "Int", true)

    ; The band opens on a quiet dash so it never sits there broken-looking
    ; before the first search.
    RC_SetVin("")

    ; Built at full size but left out of sight, so starting the script does not
    ; interrupt whatever is on screen. Page Down brings it up when it is wanted.
    Gui, Show, Hide w420 h560, Rego check v%RC_VER%

    ; How much the frame - border and title bar - adds to the drawing area.
    ; RC_FitList resizes with WinMove, which counts the frame in, so the two
    ; numbers have to be known before the first answer arrives.
    prev := A_DetectHiddenWindows
    DetectHiddenWindows, On
    WinGetPos, , , ow, oh, ahk_id %RC_hGui%
    DetectHiddenWindows, %prev%
    RC_PadW := ow - 420
    RC_PadH := oh - 560

    RC_SpeedLoad()
    RC_Ready()

    ; The catalog lights. One sweep runs straight away so the row is honest
    ; before the window is first shown, then every few seconds after that.
    RC_CatTick()
    SetTimer, RC_CatTick, 6000
}

; Every start is a Fast start. Full is a per-sitting choice - most askings
; only want the VIN, so the window always opens on the quick setting no
; matter how it was left.
RC_SpeedLoad() {
    global RC_SPEED, RC_STEPS
    RC_SPEED := 1
    RC_STEPS := 3
}

; The status bar's right cell names the speed in force, with a chevron to
; say it can be clicked.
RC_ModeCell() {
    global RC_SPEED
    ; SB_SetText only talks to the thread's default Gui - a menu pick's
    ; thread has none until it is named, and the cell silently stays stale.
    Gui, RC:Default
    SB_SetText("  " . ((RC_SPEED = 2) ? "Full" : "Fast") . " " . Chr(0x25BE), 3)
}

; The right cell was clicked: a two-item menu pops where the mouse is, the
; current speed ticked. Picking writes the choice out like the old radios
; did, so the next start still knows it.
RC_ModeMenu() {
    global RC_SPEED
    Menu, RC_Mode, Add, Fast, RC_ModePick
    Menu, RC_Mode, Add, Full, RC_ModePick
    Menu, RC_Mode, % (RC_SPEED = 2) ? "Uncheck" : "Check", Fast
    Menu, RC_Mode, % (RC_SPEED = 2) ? "Check" : "Uncheck", Full
    Menu, RC_Mode, Show
}

RC_ModePick(ItemName) {
    global RC_SPEED, RC_STEPS, RC_INI
    RC_SPEED := (ItemName = "Full") ? 2 : 1
    RC_STEPS := (RC_SPEED = 2) ? 5 : 3
    IniWrite, %RC_SPEED%, %RC_INI%, RegoCheck, Speed
    RC_ModeCell()
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

; Waiting for a plate. Just the invitation, in the status bar.
RC_Ready() {
    global RC_SPEED
    Gui, RC:Default
    GuiControl, RC:Hide, RC_LoadBar
    SB_SetText("  Type a plate or VIN and press Enter.", 1)
    SB_SetText("", 2)
    RC_ModeCell()
}

; One notch along. The word says what is being fetched, never who from.
RC_Progress(n, word) {
    global RC_STEPS, RC_hGui, RC_hSB
    Gui, RC:Default
    if (n > RC_STEPS)
        n := RC_STEPS
    GuiControl, RC:, RC_LoadBar, % Round(n / RC_STEPS * 100)
    GuiControl, RC:Show, RC_LoadBar
    SB_SetText("", 1)
    SB_SetText("  " . n . "/" . RC_STEPS, 2)
    Sleep, 10
}

; The end of it: the word - "Found in VIC" when a state answered - the time
; it took, and the speed it ran at, one status bar cell each.
RC_Done(ok, word, detail := "") {
    global RC_T0, RC_SPEED, RC_FoundIn
    Gui, RC:Default
    GuiControl, RC:Hide, RC_LoadBar
    mark := ok ? Chr(0x2713) : Chr(0x2715)
    ; "Success" becomes the state's name when one answered; other words -
    ; "Copied" off a double-click - say what they came to say.
    if (ok && word = "Success" && RC_FoundIn != "")
        word := "Found in " . RC_FoundIn
    if (detail != "")
        word .= "  " . Chr(0xB7) . " " . detail
    SB_SetText("  " . mark . "  " . word, 1)
    SB_SetText(RC_T0 ? "  " . Round((A_TickCount - RC_T0) / 1000, 1) . " s" : "", 2)
    RC_ModeCell()
}

; The list is built at its tallest, then trimmed to whatever the answer
; actually filled - and everything under it, right down to the bottom edge of
; the window, comes up to meet it. A short answer gets a short window; a long
; one grows until the list would be taller than a screenful of rows.
RC_FitList() {
    global RC_hLV, RC_hGui, RC_PadW, RC_PadH
    ; The list starts at 150 and the base window puts its bottom at 498;
    ; under it sit the catalog tick boxes and then the status bar, which
    ; docks itself to the bottom edge on every resize. The tick boxes are
    ; slid to follow the list's bottom below.
    static LIST_Y := 150, BASE_B := 498, BASE_H := 560
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

    ; The catalog tick boxes ride 8px under the list, wherever it ends.
    cbY := LIST_Y + h + 8
    GuiControl, RC:MoveDraw, RC_ChkKia, y%cbY%
    GuiControl, RC:MoveDraw, RC_ChkHyu, y%cbY%
    GuiControl, RC:MoveDraw, RC_ChkIsu, y%cbY%
    GuiControl, RC:MoveDraw, RC_ChkByd, y%cbY%

    prev := A_DetectHiddenWindows
    DetectHiddenWindows, On
    WinGetPos, wx, wy, , , ahk_id %RC_hGui%
    WinMove, ahk_id %RC_hGui%, , wx, wy, 420 + RC_PadW, BASE_H + delta + RC_PadH
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
    ; The VIN lives on the band above the list now, not in a row.
    if (vin != "")
        RC_SetVin(vin)

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

    ; Three wiper rows on Full. Fast skips them entirely - but the anchor
    ; still has to point past the last row so the extra rows the VIN decode
    ; turns up know where to land.
    if (RC_SPEED = 2) {
        RC_WipeRow := LV_Add("", "Wiper driver", "")
        LV_Add("", "Wiper passenger", "")
        LV_Add("", "Wiper rear", "")
    } else
        RC_WipeRow := LV_GetCount() + 1
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

    ; Wipers belong to Full only - Fast hands back the register and stops.
    if (RC_SPEED = 2) {
        RC_WipeFind(make, year, body, vinModel, vinYear, genTag, trm)
        RC_WipeShow()
        RC_WipeOnline((plate != "") ? plate : RC_Norm(reg), st, make)
    }

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

; Windows paints the list one row at a time and asks about each. Two rows are
; not left alone: the expiry goes red when the rego has run out, and the VIN's
; value is painted bold - it is the one thing most askings are after, so it
; should stand out of the column.
RC_OnNotify(wParam, lParam) {
    global RC_hLV, RC_RedRow, RC_hSB
    static NM_CUSTOMDRAW := -12, NM_CLICK := -2
    static CDDS_PREPAINT := 1, CDDS_ITEMPREPAINT := 0x10001, CDDS_SUBITEMPREPAINT := 0x30001
    static CDRF_DODEFAULT := 0, CDRF_NEWFONT := 2, CDRF_NOTIFYITEMDRAW := 0x20, CDRF_NOTIFYSUBITEMDRAW := 0x20
    static hBold := 0

    ; The status bar reports its clicks here too. Only the right cell - the
    ; speed - answers; NMMOUSE carries the cell index right after the header.
    if (RC_hSB && NumGet(lParam + 0, 0, "Ptr") = RC_hSB) {
        if (NumGet(lParam + 0, 2 * A_PtrSize, "Int") = NM_CLICK) {
            if (NumGet(lParam + 0, 3 * A_PtrSize, "UPtr") = 2)
                RC_ModeMenu()
        }
        return
    }

    if (RC_hLV = 0)
        return
    if (NumGet(lParam + 0, 0, "Ptr") != RC_hLV)
        return
    if (NumGet(lParam + 0, 2 * A_PtrSize, "Int") != NM_CUSTOMDRAW)
        return

    ; NMLVCUSTOMDRAW is packed differently under 32 and 64 bit.
    stageOff := (A_PtrSize = 8) ? 24 : 12
    hdcOff   := (A_PtrSize = 8) ? 32 : 16
    itemOff  := (A_PtrSize = 8) ? 56 : 36
    textOff  := (A_PtrSize = 8) ? 80 : 48
    subOff   := (A_PtrSize = 8) ? 88 : 56

    stage := NumGet(lParam + 0, stageOff, "UInt")
    if (stage = CDDS_PREPAINT)
        return CDRF_NOTIFYITEMDRAW
    if (stage = CDDS_ITEMPREPAINT) {
        if (RC_RedRow && NumGet(lParam + 0, itemOff, "UPtr") + 1 = RC_RedRow) {
            NumPut(0x2D2DA3, lParam + 0, textOff, "UInt")   ; COLORREF is BGR
            return CDRF_NEWFONT
        }
        ; Every other row is asked about cell by cell, for the VIN below.
        return CDRF_NOTIFYSUBITEMDRAW
    }
    if (stage = CDDS_SUBITEMPREPAINT) {
        ; Only the value cell - the second column - of the VIN row goes bold.
        if (NumGet(lParam + 0, subOff, "Int") != 1)
            return CDRF_DODEFAULT
        row := NumGet(lParam + 0, itemOff, "UPtr") + 1
        Gui, RC:Default
        LV_GetText(f, row, 1)
        if (f != "VIN/Chassis")
            return CDRF_DODEFAULT
        ; The bold face is the list's own font with the weight turned up,
        ; made once and kept for the life of the script.
        if (hBold = 0) {
            SendMessage, 0x31, 0, 0, , ahk_id %RC_hLV%   ; WM_GETFONT
            VarSetCapacity(lf, 92, 0)                     ; LOGFONTW
            DllCall("GetObject", "Ptr", ErrorLevel, "Int", 92, "Ptr", &lf)
            NumPut(700, lf, 16, "Int")                    ; lfWeight = FW_BOLD
            hBold := DllCall("CreateFontIndirect", "Ptr", &lf, "Ptr")
        }
        DllCall("SelectObject", "Ptr", NumGet(lParam + 0, hdcOff, "Ptr"), "Ptr", hBold)
        return CDRF_NEWFONT
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

; The VIN band's value. Empty puts a quiet dash there so the strip never
; looks broken between searches.
RC_SetVin(vin) {
    global RC_VinVal
    RC_VinVal := vin
    GuiControl, RC:, RC_VinTxt, % (vin != "") ? vin : Chr(0x2014)
}

; Double-click on the VIN value itself - same as pressing the copy button.
RC_OnVinDbl() {
    if (A_GuiEvent = "DoubleClick")
        RC_OnCopy()
}

; The Copy button. The tooltip at the cursor is the whole of the feedback -
; it shows exactly what landed on the clipboard, including the short end ACT
; hands back.
RC_OnCopy() {
    global RC_VinVal
    if (RC_VinVal = "")
        return
    Clipboard := RC_VinVal
    RC_TipAtMouse(RC_VinVal)
}

; Hovering the copy button says what it does. WM_MOUSEMOVE arrives here for
; the whole window; the tooltip goes up when the pointer lands on the button
; and is put away when it leaves - and only then, so it cannot swat the
; two-second VIN tip shown anywhere else.
RC_MouseTip() {
    static over := false
    if (A_Gui != "RC")
        return
    if (A_GuiControl = "RC_CopyBtn") {
        if (!over) {
            over := true
            ToolTip, Copy VIN
        }
    } else if (over) {
        over := false
        ToolTip
    }
}

; Kept under its old name - every fill path calls this the moment a VIN
; lands on the clipboard. The message it was built around still carries the
; VIN after three spaces; the band takes it.
RC_ShowToast(msg) {
    val := ""
    if (p := InStr(msg, "   "))
        val := LTrim(SubStr(msg, p))
    if (val != "")
        RC_SetVin(val)
}

RC_HideToast() {
    RC_SetVin("")
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

; Double-click a row to copy that value - stripped of any spaces either end,
; with a tip beside the cursor saying exactly what landed on the clipboard.
RC_OnList() {
    if (A_GuiEvent != "DoubleClick" || A_EventInfo = 0)
        return
    Gui, RC:Default
    LV_GetText(val, A_EventInfo, 2)
    val := Trim(val, " `t`r`n")
    if (val != "") {
        Clipboard := val
        RC_Done(true, "Copied", "")
        RC_TipAtMouse(val)
    }
}

; Put the caret back in the plate box with the old plate selected, so the next
; one can be typed straight over the top. Every path that shows the window
; comes through here, so it is also where the catalog lights get a fresh look
; rather than waiting up to six seconds for the timer to come round.
RC_SelectPlate() {
    global RC_hEdit
    GuiControl, RC:Focus, RC_Plate
    SendMessage, 0x00B1, 0, -1, , ahk_id %RC_hEdit%   ; EM_SETSEL - select all
    RC_CatTick()
}

RCGuiClose:
RCGuiEscape:
    Gui, RC:Hide
return

; Bring the window back, with whatever is on the clipboard as a starting point.
; A plain label, not ^!r:: - the Hotkey command up top binds it in window
; mode only, so the worker processes never register it.
RC_HkRecall:
    plate := RC_Norm(Clipboard)
    if RegExMatch(plate, "^[0-9A-Z]{1,8}$") || (StrLen(plate) = 17)
        GuiControl, RC:, RC_Plate, %plate%
    Gui, RC:Show
    RC_SelectPlate()
return

; Page Down brings the window to the top from anywhere - or back up from the
; tray if it was closed away - with the old plate selected, ready to be typed
; straight over. Closing the window only hides it, so this keeps working.
; PgDn is bound to RC_TrayShow by the Hotkey command up top, window mode only.
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
    ; Short enough that a dead site hands the window back in seconds, long
    ; enough that a slow one still gets its say.
    RC_hSess := AH_Open(RC_UA, 6000, 6000, 10000, 12000)   ; lib\AudosHttp.ahk
    if !RC_hSess
        return false
    RC_hConn := AH_Connect(RC_hSess, host, 443)
    if !RC_hConn {
        RC_Close()
        return false
    }
    return true
}

RC_Close() {
    global RC_hSess, RC_hConn
    AH_Close(RC_hConn)
    AH_Close(RC_hSess)
    RC_hConn := 0
    RC_hSess := 0
}

RC_Send(method, path, body := "", ctype := "", referer := "", extra := "", hConn := 0) {
    global RC_hConn, RC_LastStatus

    ; The shared connection unless the caller brought its own - EzyParts does,
    ; so its login can outlive everything the shared one is opened and closed
    ; for in between.
    if (hConn = 0)
        hConn := RC_hConn

    ; RegoCheck's own header policy - each state's site is fussy in its own
    ; way, so this stays here rather than in the shared library.
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

    return AH_Request(hConn, method, path, hdrs, body, RC_LastStatus)   ; lib\AudosHttp.ahk
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

    ; Newest first, so the likely answer sits at the front.
    RC_Cands := RC_SortCands(RC_Cands)

    ; There is no dropdown to ask any more: the newest candidate answers.
    ; When the rows genuinely disagree that is a best guess - and for the
    ; makes the shop is keen on, a blank size still falls through to
    ; Autobarn in RC_WipeOnline.
    if (RC_Cands.Length() >= 1)
        RC_ModelPick := 1
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

    RC_EzyS := AH_Open(RC_UA, 6000, 6000, 10000, 12000)   ; lib\AudosHttp.ahk
    RC_EzyC := AH_Connect(RC_EzyS, RC_EZY_HOST, 443)
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
    AH_Close(RC_EzyC)
    AH_Close(RC_EzyS)
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
        RC_SetVin(vin)
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
    if (RC_SPEED = 2) {
        RC_WipeRow := LV_Add("", "Wiper driver", "")
        LV_Add("", "Wiper passenger", "")
        LV_Add("", "Wiper rear", "")
    } else
        RC_WipeRow := LV_GetCount() + 1
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

    ; Wipers belong to Full only - Fast hands back the register and stops.
    if (RC_SPEED = 2) {
        if (make != "")
            RC_WipeFind(make, year, cab, model, year, gen, trim)
        RC_WipeShow()
        RC_WipeOnline(plate, hitSt, make)
    }

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
    RC_SetVin(vin)
    if (yrRange != "")
        LV_Add("", "Year", yrRange)
    if (cab != "")
        LV_Add("", "Body type", cab)
    if (RC_SPEED = 2) {
        RC_WipeRow := LV_Add("", "Wiper driver", "")
        LV_Add("", "Wiper passenger", "")
        LV_Add("", "Wiper rear", "")
    } else
        RC_WipeRow := LV_GetCount() + 1

    if (trim != "" && !InStr(" " . model . " ", " " . trim . " "))
        tag := RC_NiceName(model . " " . trim)
    else
        tag := RC_NiceName(model)
    if (sX != "")
        tag .= (tag != "" ? ", " : "") . sX
    tag := RC_TagTail(tag, make, cab . " " . sX . " " . trim)
    RC_SetMake(make, tag)

    ; Wipers belong to Full only - Fast hands back the register and stops.
    if (RC_SPEED = 2) {
        if (make != "")
            RC_WipeFind(make, year, cab, model, year, gen, trim)
        RC_WipeShow()
    }

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
; own line beneath. The state the car is registered in shows only in the
; status bar's "Found in" - the little tag that used to sit on the make's
; line is gone.
RC_SetMake(bold, bracket, state := "") {
    global RC_FoundIn
    Gui, RC:Default
    bracket := RC_TrimCase(RC_NoEcho(bracket))
    ; A long make - MERCEDES-BENZ - drops a size instead of being cut off.
    Gui, Font, % "s" . (StrLen(bold) > 16 ? 11 : 13) . " w600", Segoe UI
    GuiControl, RC:Font, RC_Make
    GuiControl, RC:, RC_Make, % (bold != "") ? bold : A_Space
    GuiControl, RC:, RC_MakeX, %bracket%
    GuiControl, % (bracket != "") ? "RC:Show" : "RC:Hide", RC_MakeX
    RC_FoundIn := state
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
        ; A size left blank in the workbook row must not wipe out a size the
        ; shop already answered with - blank loses to anything with digits.
        LV_GetText(now, RC_WipeRow, 2)
        if (w.drv != "" || !RegExMatch(now, "\d"))
            LV_Modify(RC_WipeRow,     "Col2", w.drv)
        LV_GetText(now, RC_WipeRow + 1, 2)
        if (w.pas != "" || !RegExMatch(now, "\d"))
            LV_Modify(RC_WipeRow + 1, "Col2", w.pas)
        LV_GetText(now, RC_WipeRow + 2, 2)
        if (w.rear != "" || !RegExMatch(now, "\d"))
            LV_Modify(RC_WipeRow + 2, "Col2", (w.rear != "") ? w.rear : "none")
        return
    }
    ; Sizes already in the rows came from Autobarn, which gets asked when the
    ; workbook had nothing - or, for the makes it is keen on, when the workbook
    ; had candidates but no settled size. Do not paint over them either way.
    ; With the dropdown gone a candidate is always auto-picked, so reaching
    ; here means the workbook had nothing at all.
    LV_GetText(now, RC_WipeRow, 2)
    if (now != "" && now != "no fitment listed")
        return
    LV_Modify(RC_WipeRow,     "Col2", "no fitment listed")
    LV_Modify(RC_WipeRow + 1, "Col2", "no fitment listed")
    LV_Modify(RC_WipeRow + 2, "Col2", "no fitment listed")
}

; The workbook knew nothing, so the shop gets asked. Only worth a request when
; there is a plate and a state to ask with, and only for the rows it answers -
; a car with no rear wiper listed keeps its "no fitment listed" there.
; For Kia, Hyundai (Genesis with it) and Isuzu the shop is also asked when the
; workbook DID have candidates but still put no size in the driver row - too
; many models to pick from, or a fitment typed in with the size left blank.
RC_WipeOnline(plate, state, make := "") {
    global RC_Cands, RC_WipeRow, RC_SPEED
    Gui, RC:Default
    ; Fast never leaves the register - the workbook still answers whatever it
    ; holds, but nothing is asked for over the wire.
    if (RC_SPEED != 2)
        return false
    if (RC_WipeRow = 0 || plate = "" || state = "")
        return false
    if (RC_Cands.Length() > 0) {
        keen := InStr(make, "KIA") || InStr(make, "HYUNDAI") || InStr(make, "GENESIS") || InStr(make, "ISUZU")
        ; A real size has digits in it; "pick a model above" and an empty row
        ; do not, and both mean the workbook never settled on an answer.
        LV_GetText(now, RC_WipeRow, 2)
        if (!keen || RegExMatch(now, "\d"))
            return false
    }
    RC_Progress(4, "wipers")

    ; What the workbook already wrote, kept aside - a size it did manage on
    ; one row must not be painted over just because the shop had nothing for
    ; that row.
    LV_GetText(old1, RC_WipeRow,     2)
    LV_GetText(old2, RC_WipeRow + 1, 2)
    LV_GetText(old3, RC_WipeRow + 2, 2)

    ; The rows say what is happening while the shop is being asked, rather
    ; than sitting there reading "no fitment listed" for the second or two
    ; it takes - that reads like an answer when it is not one yet.
    Loop, 3
        LV_Modify(RC_WipeRow + A_Index - 1, "Col2", "loading ...")
    Sleep, 10
    drv := "", pas := "", rear := ""
    got := RC_AbWipers(plate, state, drv, pas, rear)
    ; Shop first, then whatever size the workbook had, then the plain truth.
    LV_Modify(RC_WipeRow,     "Col2", (drv != "") ? RC_WipeSize(drv)
        : (RegExMatch(old1, "\d") ? old1 : "no fitment listed"))
    LV_Modify(RC_WipeRow + 1, "Col2", (pas != "") ? RC_WipeSize(pas)
        : (RegExMatch(old2, "\d") ? old2 : "no fitment listed"))
    LV_Modify(RC_WipeRow + 2, "Col2", (rear != "") ? RC_WipeSize(rear)
        : (RegExMatch(old3, "\d") ? old3 : "no fitment listed"))
    return got ? true : false
}

; Millimetres out of the shop, written the way the workbook writes them -
; "22 in / 550 mm" - so the two sources read the same in the same row.
RC_WipeSize(mm) {
    if (mm = "")
        return ""
    return Round(mm / 25.4) . " in / " . mm . " mm"
}

; Forget the candidates. There is no dropdown any more - the newest
; candidate answers on its own - so this is only the two variables.
RC_WipeReset() {
    global RC_Cands, RC_ModelPick
    RC_Cands := []
    RC_ModelPick := 0
}

; --- the day's answers, kept -----------------------------------------------

; Put away everything the window is showing, under the plate or VIN that was
; asked, so the same asking later in the day is answered from here.
RC_CacheSave(key, note, speed := -1) {
    global RC_CACHE, RC_RedRow, RC_WipeRow, RC_ModelPick, RC_Cands, RC_SPEED
    global RC_VinVal, RC_FoundIn
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
        , speed: speed, vin: RC_VinVal, st: RC_FoundIn }
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
    RC_SetMake(c.make, c.makeX, c.st)
    RC_WipeShow()
    RC_FitList()

    ; The VIN goes back on the band and the clipboard, same as a fresh
    ; search would put it.
    vin := c.vin
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

; --- the catalog lights ----------------------------------------------------
;
; The four brand boxes say which dealership parts catalogs are open in Chrome
; or Edge right now. The looking is done by CatalogProbe.ahk, a separate
; script started hidden every few seconds - see the long note at the top of
; that file for why it cannot be done in here. All this end does is read what
; the last one wrote and light the boxes.

; One turn of the wheel: take in whatever the last probe left, then start the
; next one. Reading first and spawning second means nothing is ever waited on.
RC_CatTick() {
    global RC_hGui, RC_CAT_SPAWN
    ; Nothing to light while the window is away, and no reason to be starting
    ; processes on someone else's machine time either.
    if (!RC_hGui || !DllCall("IsWindowVisible", "ptr", RC_hGui))
        return
    RC_CatRead()
    ; A probe takes well under a second. If one is somehow still going, let it
    ; finish rather than piling another on top.
    if (A_TickCount - RC_CAT_SPAWN < 4000)
        return
    RC_CAT_SPAWN := A_TickCount
    RC_CatSpawn()
}

RC_CatSpawn(args := "sweep") {
    global RC_CAT_EXE
    if !FileExist(RC_CAT_EXE)
        return
    cmd := """" . A_AhkPath . """ """ . RC_CAT_EXE . """" . (args != "" ? " " . args : "")
    try Run, %cmd%, , Hide
}

; Parse the probe's file and light the boxes. The stamp on the first line says
; whether this is anything new - an unchanged file is dropped without being
; picked apart, which is most of the time.
RC_CatRead() {
    global RC_CAT, RC_CAT_WHEN, RC_CAT_FILE
    if !FileExist(RC_CAT_FILE)
        return
    txt := ""
    try FileRead, txt, %RC_CAT_FILE%
    if (txt = "")
        return

    found := {}
    when := ""
    Loop, Parse, txt, `n, `r
    {
        if (A_LoopField = "")
            continue
        f := StrSplit(A_LoopField, A_Tab)
        key := f[1]
        if (key = "when") {
            when := f[2]
            ; Same file as last time - nothing has changed, so nothing to do.
            if (when != "" && when = RC_CAT_WHEN)
                return
            continue
        }
        if (key = "tabs" || key = "seen")
            continue
        ; brand<TAB>1<TAB>vin<TAB>hwnd<TAB>exe<TAB>title
        if (f[2] = 1)
            found[key] := { vin: f[3], hwnd: f[4], exe: f[5], title: f[6] }
    }
    RC_CAT_WHEN := when
    RC_CAT := found
    RC_CatPaint()
}

RC_CatPaint() {
    global RC_CAT, RC_CAT_BOX
    Gui, RC:Default
    for brand, box in RC_CAT_BOX
        GuiControl, RC:, %box%, % RC_CAT.HasKey(brand) ? 1 : 0
}

; The boxes are lights, so a click must not leave the tick where the click put
; it. The state goes straight back to what the probe found, and the click is
; spent on jumping to the tab instead.
RC_OnCatKia() {
    RC_CatJump("kia", "Kia")
}
RC_OnCatHyu() {
    RC_CatJump("hyundai", "Hyundai")
}
RC_OnCatIsu() {
    RC_CatJump("isuzu", "Isuzu")
}
RC_OnCatByd() {
    RC_CatJump("byd", "BYD")
}

; The green EPC button: work out whose car this is and jump straight to that
; make's catalog with the VIN. No guessing from the make line - the VIN's
; world manufacturer identifier is read the same way CatalogProbe reads it,
; so the button and the search always agree on the brand.
RC_OnEpc() {
    global RC_VinVal
    static LABEL := { kia: "Kia", hyundai: "Hyundai", isuzu: "Isuzu", byd: "BYD" }
    if (RC_VinVal = "") {
        SB_SetText("  " . Chr(0x2715) . "  No VIN to look up - run a search first", 1)
        return
    }
    brand := RC_BrandOfVin(RC_VinVal)
    if (brand = "") {
        SB_SetText("  " . Chr(0x2715) . "  No catalog here for a " . SubStr(RC_VinVal, 1, 3) . " VIN", 1)
        return
    }
    RC_CatJump(brand, LABEL[brand])
}

; The brand off the VIN's first three characters. Genesis - KMT, KMU - counts
; as Hyundai: the states register those as HYUNDAI and it is the same
; dealership either way. Kept in step with CP_WMI in CatalogProbe.ahk.
RC_BrandOfVin(vin) {
    static WMI := { kia:     " KNA KNB KNC KND KNE KNF KNG KNH KNM U5Y U6Y 3KP 5XY 5XX LJD MS0 "
                  , hyundai: " KMH KMF KMJ KMC KME KMT KMU TMA TMB TMK NLH 5NP 5NM 5NT LBE MAL 95P "
                  , isuzu:   " MPA MP1 MP2 JAA JAL JAC JAB MP5 "
                  , byd:     " LC0 LGX LC6 " }
    p := " " . SubStr(vin, 1, 3) . " "
    for brand, list in WMI
        if InStr(list, p)
            return brand
    return ""
}

; Bring that brand's catalog tab to the front, with the VIN on the clipboard
; ready to paste into whatever the catalog asks for.
RC_CatJump(brand, label) {
    global RC_CAT, RC_VinVal
    Gui, RC:Default
    RC_CatPaint()
    ; The status bar is written straight here rather than through RC_Done -
    ; that would put the time since the last SEARCH started in the middle
    ; cell, which has nothing to do with a catalog jump and only grows.
    if (!RC_CAT.HasKey(brand)) {
        SB_SetText("  " . Chr(0x2715) . "  No " . label . " catalog open in Chrome or Edge", 1)
        return
    }
    ; The VIN goes on the clipboard either way, so it is there to paste if the
    ; catalog asks for something the search could not fill in.
    if (RC_VinVal != "")
        Clipboard := RC_VinVal
    ; With a VIN in hand the catalog is not just opened, it is searched.
    RC_CatSpawn((RC_VinVal != "" ? "search " . brand . " " . RC_VinVal
                                 : "select " . brand))
    ; What the catalog is already showing is worth saying - it is often the
    ; car that was looked up before this one.
    on := RC_CAT[brand].vin
    say := "Opened the " . label . " catalog"
    if (RC_VinVal != "")
        say .= "  " . Chr(0xB7) . " searching " . RC_VinVal
    else if (on != "")
        say .= "  " . Chr(0xB7) . " showing " . on
    SB_SetText("  " . Chr(0x2713) . "  " . say, 1)
}

; --- the last ten, and the day book ----------------------------------------

; Put a search at the top of the recent list and keep the list to ten. The
; dropdown that used to show it is gone; the list itself stays kept.
RC_RecentAdd(key, make) {
    global RC_LASTTEN
    for i, r in RC_LASTTEN {
        if (r.key = key) {
            RC_LASTTEN.RemoveAt(i)
            break
        }
    }
    RC_LASTTEN.InsertAt(1, { key: key, make: make })
    while (RC_LASTTEN.Length() > 10)
        RC_LASTTEN.RemoveAt(RC_LASTTEN.Length())
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










; ===== lib\AudosHttp.ahk, inlined =====
;==============================================================================
; AudosHttp - WinHTTP transport shared by the non-Chrome Audos tools
; Shared by the Audos tools - #Include this, don't copy/paste it.
;
; This owns the MECHANICS only: open a session, connect, fire a request, read
; the body back. It deliberately knows nothing about headers, cookies, logins
; or retries - each tool keeps its own header policy and builds the header
; string itself, then hands it here. That way sharing this file cannot change
; how any individual site is talked to.
;
; A session handle is also a cookie jar, so one handle per site keeps the
; sites' sessions apart.
;==============================================================================

; Fresh session (= fresh cookie jar). Timeouts are ms: resolve, connect, send,
; receive. Returns 0 on failure.
AH_Open(ua, tResolve := 10000, tConnect := 10000, tSend := 20000, tRecv := 30000) {
    h := DllCall("winhttp\WinHttpOpen", "wstr", ua
        , "uint", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr")
    if !h
        return 0
    DllCall("winhttp\WinHttpSetTimeouts", "ptr", h
        , "int", tResolve, "int", tConnect, "int", tSend, "int", tRecv)
    return h
}

AH_Connect(hSess, host, port := 443) {
    if !hSess
        return 0
    return DllCall("winhttp\WinHttpConnect", "ptr", hSess
        , "wstr", host, "ushort", port, "uint", 0, "ptr")
}

AH_Close(h) {
    if h
        DllCall("winhttp\WinHttpCloseHandle", "ptr", h)
}

; Fire one request on an existing connection handle and return the body as
; UTF-8 text ("" on any transport failure). `hdrs` is the caller's complete
; header block, CRLF-separated, no trailing CRLF. `status` comes back with the
; HTTP status code (0 = never got a reply), which is how a expired session
; (401/403) is told apart from a dead server (500) or a dead connection (0).
AH_Request(hConn, method, path, hdrs, body, ByRef status) {
    static SECURE   := 0x00800000    ; WINHTTP_FLAG_SECURE
    static ADD_HDR  := 0x20000000    ; WINHTTP_ADDREQ_FLAG_ADD
    static MAXLEN   := 4194304       ; 4 MB - far more than these pages need
    static Q_STATUS := 19            ; WINHTTP_QUERY_STATUS_CODE
    static Q_NUMBER := 0x20000000    ; WINHTTP_QUERY_FLAG_NUMBER

    status := 0
    if !hConn
        return ""

    hReq := DllCall("winhttp\WinHttpOpenRequest", "ptr", hConn
        , "wstr", method, "wstr", path, "ptr", 0, "ptr", 0, "ptr", 0
        , "uint", SECURE, "ptr")
    if !hReq
        return ""

    if (hdrs != "")
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

    code := 0, csize := 4
    DllCall("winhttp\WinHttpQueryHeaders", "ptr", hReq, "uint", Q_STATUS | Q_NUMBER
        , "ptr", 0, "uint*", code, "uint*", csize, "ptr", 0)
    status := code

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

; ===== CatalogProbe.ahk - the worker functions =====


; Bring one brand's catalog tab to the front. The tab is found again from
; scratch rather than trusted from the last sweep, so a tab that has since
; been closed or dragged to another window is still handled.
;
; Two passes. The first takes tabs whose title names the brand, which is all
; of them in normal use. The second is for a Microcat tab whose title gives
; nothing away - an unfamiliar VIN, say - and picks those apart by URL, which
; means actually selecting one to see it. Whatever was on screen goes back if
; neither pass finds anything.
CP_Select(brand) {
    for pass, loose in [false, true] {
        for i, exe in ["msedge.exe", "chrome.exe"] {
            WinGet, list, List, % "ahk_exe " . exe
            Loop, %list%
            {
                h := list%A_Index%
                if (h = "" || !DllCall("IsWindowVisible", "ptr", h))
                    continue
                if CP_SelectIn(h, brand, loose) {
                    ; A minimised window changes tab quite happily, but you
                    ; would never see it happen, so it is restored first.
                    WinGet, st, MinMax, ahk_id %h%
                    if (st = -1)
                        WinRestore, ahk_id %h%
                    WinActivate, ahk_id %h%
                    return true
                }
            }
        }
    }
    return false
}


; A step-by-step record of the last search, written beside the script. A
; search that goes wrong does so silently - the right page with an empty box
; looks identical to a page that was never touched - so it says what it did.
CP_Trace(line) {
    global CP_TRACE
    if (CP_TRACE = "")
        return
    FormatTime, t, , HH:mm:ss
    FileAppend, % t . "  " . line . "`n", %CP_TRACE%, UTF-8
}


; Bring the catalog to the front and look the VIN up in it.
;
; Click Identify Vehicle, put the VIN in the box, press Enter. Each step is
; checked before the next one starts and the whole thing is tried again from
; the top if it does not take, because every one of these failures is silent:
; the right page with an empty box looks exactly like a page nothing happened
; to. The trace file beside the script says which step it was on.
CP_Search(brand, vin) {
    global CP_TRACE
    CP_TRACE := A_ScriptDir . "\CatalogProbe.trace.txt"
    CP_Del(CP_TRACE)

    vin := CP_Upper(Trim(vin))
    CP_Trace("search " . brand . " " . vin)
    if (vin = "")
        return false
    if (!CP_Select(brand)) {
        CP_Trace("select FAILED - no tab for that brand")
        return false
    }

    h := WinExist("A")
    CP_Trace("selected, active window " . h)
    if (!h)
        return false

    ; A tab that has just been switched to is not necessarily drawn yet, and
    ; nothing below can find an element on a page that has not rendered.
    if (!CP_PageReady(h))
        CP_Trace("page never settled - carrying on anyway")

    ; Three goes at the whole sequence. An element found while Angular is
    ; still re-rendering is a dead node moments later, and acting on a dead
    ; node fails quietly, so a failed attempt starts over rather than
    ; struggling on with handles it already has.
    Loop, 3
    {
        CP_Trace("--- attempt " . A_Index)
        if CP_SearchOnce(h, vin, brand) {
            CP_Trace("done")
            return true
        }
        Sleep, 900
    }
    CP_Trace("giving up")
    return false
}


; One go at it: nav link, box, VIN, submit.
CP_SearchOnce(hwnd, vin, brand) {
    ; 1. The VIN box lives behind a nav step. Microcat keeps it on the
    ;    Identify Vehicle page; BYD TIS keeps it on the EPC tab's filter
    ;    panel. A page already showing the box answers the click by staying
    ;    put, and Isuzu has no such link at all, so a failed invoke is only
    ;    worth noting.
    nav := (brand = "byd") ? "EPC" : "Identify Vehicle"
    if CP_Invoke(hwnd, nav)
        CP_Trace("invoked " . nav)
    else
        CP_Trace("no " . nav . " link on this page")

    ; 2. Wait for the box rather than for a fixed time - the page decides how
    ;    long it takes, and after a navigation it can be several seconds.
    box := 0
    Loop, 40
    {
        box := CP_VinBox(hwnd)
        if (box)
            break
        Sleep, 250
    }
    if (!box) {
        CP_Trace("VIN box NEVER APPEARED")
        return false
    }
    CP_Trace("VIN box found")
    CP_Flash(box)

    ; 3. Focus, then fill. Focus first every time: the value goes in through
    ;    the box that holds the keyboard, and the Enter below has to land
    ;    there too rather than on whatever the page had selected.
    ok := CP_Fill(box, vin)
    CP_Rel(box)
    if (!ok)
        return false

    ; 4. BYD's form does not submit on Enter - it has its own Search button.
    ;    Everyone else takes Enter in the box, and BYD gets it too if the
    ;    button cannot be found, since it is the only move left.
    if (brand = "byd" && CP_Invoke(hwnd, "Search"))
        CP_Trace("clicked Search")
    else {
        SendInput, {Enter}
        CP_Trace("entered")
    }
    ; 5. Prove the catalog actually took it. The tab renames itself to the
    ;    loaded vehicle, VIN and all, so that is the receipt.
    if CP_Loaded(hwnd, vin) {
        CP_Trace("vehicle loaded")
        return true
    }
    CP_Trace("Enter went in but no vehicle came up")
    return false
}


; Put the VIN in the box and prove it is in there.
;
; Through the ValuePattern first - no keystrokes to go astray - but these are
; framework-bound inputs and a value poked straight in fires none of the events
; Angular listens for, so it often reads back empty, or reads back right while
; the page has noticed nothing. Typing is what these pages actually respond to,
; so the value is read back after either way and typing is the fallback.
;
; Nothing is ever typed until the box is confirmed to hold the keyboard.
; Keystrokes sent at a page that is not listening do not land harmlessly - they
; hit whatever shortcuts the app has, and Microcat answered a stray one by
; opening its New session menu.
CP_Fill(box, vin) {
    if (!CP_FocusBox(box)) {
        CP_Trace("could not put the keyboard in the box")
        return false
    }

    ; Empty the box first. A leftover value from the last lookup could ride
    ; along with the new one, and a search for two VINs run together finds
    ; nothing while looking like it ran fine.
    if (CP_Val(box) != "") {
        CP_SetVal(box, "")
        Sleep, 150
        if (CP_Val(box) != "") {
            SendInput, ^a
            Sleep, 80
            SendInput, {Delete}
            Sleep, 150
        }
        CP_Trace(CP_Val(box) = "" ? "cleared the box" : "box would not empty")
    }

    if (CP_SetVal(box, vin)) {
        Sleep, 200
        if (CP_Val(box) = vin) {
            CP_Trace("set through the ValuePattern")
            return true
        }
        CP_Trace("ValuePattern said yes but the box did not keep it")
    } else
        CP_Trace("box has no settable ValuePattern")

    SendInput, ^a
    Sleep, 80
    SendInput, % "{Raw}" . vin
    Sleep, 400
    got := CP_Val(box)
    CP_Trace("typed, box now holds """ . got . """")
    if (got = vin)
        return true
    ; Leave nothing hanging open behind us - a half-typed autocomplete list
    ; sitting over the page is worse than a page that was never touched.
    SendInput, {Escape}
    return false
}


; Did the catalog come back with the vehicle?
;
; Microcat renames its tab to the loaded car - model, catalogue code, VIN - so
; the VIN turning up in the window title is the catalog saying it found it, and
; its absence is a real failure worth another attempt. Isuzu and BYD do not
; rename anything, so there is nothing to hold them to; the brand is read off
; the URL rather than the title, because a Microcat tab with a car loaded has
; dropped the word Microcat from its title entirely.
CP_Loaded(hwnd, vin) {
    if (!InStr(CP_ActiveUrl(hwnd), "microcat"))
        return true
    Loop, 30
    {
        WinGetTitle, t, ahk_id %hwnd%
        if InStr(t, vin)
            return true
        Sleep, 400
    }
    return false
}


; Wait until the page has something on it. A tab just switched to may not have
; rendered, and an empty tree looks the same as a page missing what we want.
CP_PageReady(hwnd) {
    Loop, 25
    {
        if (CP_ActiveUrl(hwnd) != "")
            return true
        Sleep, 200
    }
    return false
}


; Click a named thing on the page. Through UI Automation's Invoke where the
; element has one - no mouse, no keystrokes, works on a window that is not
; even in front. Plenty of clickable things expose no InvokePattern at all -
; BYD's EPC nav is a plain Text - and those get the real mouse, pointer put
; back after. Flashes a frame round it first so it is plain what was clicked.
CP_Invoke(hwnd, name) {
    ; NAMEPROP, not NAME - AHK variable names ignore case, and NAME would BE
    ; the name parameter.
    static HYPERLINK := 50005, BUTTON := 50000, TEXT := 50020
    static CONTROLTYPE := 30003, SUBTREE := 7, NAMEPROP := 30005, INVOKE := 10000
    uia := CP_Uia()
    if (!uia)
        return false
    for i, ctype in [HYPERLINK, BUTTON, TEXT] {
        el := 0
        if (DllCall(CP_Vt(uia, 6), "ptr", uia, "ptr", hwnd, "ptr*", el) != 0 || !el)
            continue
        found := 0
        arr := CP_Find(uia, el, CONTROLTYPE, ctype, SUBTREE)
        if (arr) {
            n := 0
            DllCall(CP_Vt(arr, 3), "ptr", arr, "int*", n)
            Loop, %n%
            {
                e := 0
                DllCall(CP_Vt(arr, 4), "ptr", arr, "int", A_Index - 1, "ptr*", e)
                if (!e)
                    continue
                w := 0, hh := 0
                CP_Rect(e, w, hh)
                ; Hidden leftovers stay in a web app's tree, and one of those
                ; can be invoked all day without anything happening.
                if (!found && w > 0 && hh > 0 && CP_Str(e, NAMEPROP) = name) {
                    found := e
                    continue                            ; kept, not released
                }
                CP_Rel(e)
            }
            CP_Rel(arr)
        }
        CP_Rel(el)
        if (found) {
            CP_Flash(found)
            pat := 0
            ok := false
            if (DllCall(CP_Vt(found, 16), "ptr", found, "int", INVOKE, "ptr*", pat) = 0 && pat) {
                ok := (DllCall(CP_Vt(pat, 3), "ptr", pat) = 0)
                CP_Rel(pat)
                if (ok)
                    CP_Trace("invoke: own pattern")
            }
            ; No pattern of its own - the wrapper it sits in usually has one.
            ; BYD's EPC nav is a plain Text whose parent Group owns the click.
            if (!ok && CP_InvokeParent(uia, found)) {
                ok := true
                CP_Trace("invoke: parent pattern")
            }
            if (!ok) {
                ok := CP_ClickEl(found)
                if (ok)
                    CP_Trace("invoke: mouse")
            }
            CP_Rel(found)
            if (ok)
                return true
        }
    }
    return false
}


; Invoke the nearest ancestor that has an InvokePattern - the programmatic
; way to click a thing that exposes no pattern itself. A web app's click
; handler usually lives on a wrapper div a level or two above the text that
; names it. Three levels is enough to reach that wrapper and not enough to
; reach some page-sized container whose Invoke means something else.
CP_InvokeParent(uia, el) {
    static INVOKE := 10000
    walker := 0
    DllCall(CP_Vt(uia, 14), "ptr", uia, "ptr*", walker)   ; get_ControlViewWalker
    if (!walker)
        return false
    ok := false
    cur := el
    Loop, 3
    {
        par := 0
        DllCall(CP_Vt(walker, 3), "ptr", walker, "ptr", cur, "ptr*", par)
        if (cur != el)
            CP_Rel(cur)
        cur := par
        if (!par)
            break
        pat := 0
        if (DllCall(CP_Vt(par, 16), "ptr", par, "int", INVOKE, "ptr*", pat) = 0 && pat) {
            ok := (DllCall(CP_Vt(pat, 3), "ptr", pat) = 0)
            CP_Rel(pat)
        }
        if (ok)
            break
    }
    if (cur && cur != el)
        CP_Rel(cur)
    CP_Rel(walker)
    return ok
}


; Physically click the middle of an element - the last-resort fallback for
; clickable things with no InvokePattern anywhere near them. The pointer goes
; back where it was; this runs while somebody is working.
CP_ClickEl(el) {
    VarSetCapacity(rc, 16, 0)
    if (DllCall(CP_Vt(el, 43), "ptr", el, "ptr", &rc) != 0)
        return false
    l := NumGet(rc, 0, "int"), t := NumGet(rc, 4, "int")
    r := NumGet(rc, 8, "int"), b := NumGet(rc, 12, "int")
    if (r - l < 4 || b - t < 4)
        return false
    cx := (l + r) // 2
    cy := (t + b) // 2
    prev := A_CoordModeMouse
    CoordMode, Mouse, Screen
    MouseGetPos, ox, oy
    Click, %cx%, %cy%
    Sleep, 250
    MouseMove, ox, oy, 0
    CoordMode, Mouse, %prev%
    return true
}


; Set a control's value through its ValuePattern. False when it has not got
; one, or has one that refuses to be written.
CP_SetVal(el, text) {
    static VALUEPATTERN := 10002
    pat := 0
    if (DllCall(CP_Vt(el, 16), "ptr", el, "int", VALUEPATTERN, "ptr*", pat) != 0 || !pat)
        return false
    ; IUIAutomationValuePattern: 3 SetValue, 4 get_CurrentValue,
    ; 5 get_CurrentIsReadOnly.
    ro := 0
    DllCall(CP_Vt(pat, 5), "ptr", pat, "int*", ro)
    ok := false
    if (!ro)
        ok := (DllCall(CP_Vt(pat, 3), "ptr", pat, "wstr", text) = 0)
    CP_Rel(pat)
    return ok
}


; Draw a red frame round an element for a moment.
;
; Click-through and never activated - this runs while somebody is working, and
; a window that took the focus here would take it off the very box we are about
; to type into.
CP_Flash(el, ms := 500) {
    static TH := 3, PAD := 2
    VarSetCapacity(rc, 16, 0)
    if (DllCall(CP_Vt(el, 43), "ptr", el, "ptr", &rc) != 0)
        return
    l := NumGet(rc, 0, "int") - PAD, t := NumGet(rc, 4, "int") - PAD
    r := NumGet(rc, 8, "int") + PAD, b := NumGet(rc, 12, "int") + PAD
    w := r - l, h := b - t
    if (w < 6 || h < 6)
        return

    Gui, CPHL:New, +AlwaysOnTop -Caption +ToolWindow +E0x8000020 +HwndhHL
    Gui, CPHL:Color, FF3B30
    Gui, CPHL:Show, NoActivate x%l% y%t% w%w% h%h%
    ; The middle is cut out of the window, leaving just the border - so the
    ; page underneath stays readable.
    outer := DllCall("CreateRectRgn", "int", 0, "int", 0, "int", w, "int", h, "ptr")
    inner := DllCall("CreateRectRgn", "int", TH, "int", TH, "int", w - TH, "int", h - TH, "ptr")
    DllCall("CombineRgn", "ptr", outer, "ptr", outer, "ptr", inner, "int", 4)   ; RGN_DIFF
    DllCall("DeleteObject", "ptr", inner)
    DllCall("SetWindowRgn", "ptr", hHL, "ptr", outer, "int", true)
    Sleep, %ms%
    Gui, CPHL:Destroy
}


; Put the keyboard in a box and prove it landed.
;
; Asking UI Automation for focus is tried first because it moves no mouse, but
; on a framework-bound web input it often reports success while the keyboard
; stays where it was. A real click in the middle of the box is what a person
; does and is what these pages actually listen for, so that is the fallback.
CP_FocusBox(box) {
    if (CP_HasFocus(box))
        return true
    DllCall(CP_Vt(box, 3), "ptr", box)                  ; SetFocus
    if (CP_HasFocus(box))
        return true

    VarSetCapacity(rc, 16, 0)
    if (DllCall(CP_Vt(box, 43), "ptr", box, "ptr", &rc) != 0)
        return false
    l := NumGet(rc, 0, "int"), t := NumGet(rc, 4, "int")
    r := NumGet(rc, 8, "int"), b := NumGet(rc, 12, "int")
    if (r - l < 4 || b - t < 4)
        return false
    ; Click takes its coordinates as plain text - a forced expression per
    ; parameter is a syntax error, not a clever shortcut.
    cx := (l + r) // 2
    cy := (t + b) // 2
    prev := A_CoordModeMouse
    CoordMode, Mouse, Screen
    MouseGetPos, ox, oy
    Click, %cx%, %cy%
    Sleep, 250
    ; Put the pointer back where it was - this runs while somebody is working.
    MouseMove, ox, oy, 0
    CoordMode, Mouse, %prev%
    return CP_HasFocus(box)
}


CP_HasFocus(box) {
    Loop, 10
    {
        if CP_Bool(box, 30008)                          ; HasKeyboardFocus
            return true
        Sleep, 100
    }
    return false
}


; What a control currently holds, through its ValuePattern.
CP_Val(el) {
    static VALUEPATTERN := 10002
    pat := 0
    if (DllCall(CP_Vt(el, 16), "ptr", el, "int", VALUEPATTERN, "ptr*", pat) != 0 || !pat)
        return ""
    v := ""
    s := 0
    if (DllCall(CP_Vt(pat, 4), "ptr", pat, "ptr*", s) = 0 && s) {
        v := StrGet(s, "UTF-16")
        DllCall("oleaut32\SysFreeString", "ptr", s)
    }
    CP_Rel(pat)
    return v
}


; The VIN box on whatever page is showing.
;
; Two ways in, because the catalogs differ. Isuzu's Snap-on EPC calls its box
; "Enter VIN" and BYD's TIS calls its one "Please input all VIN or last 8
; digit", so those are found by name. Microcat names its box nothing at all,
; and it is a ComboBox rather than an edit - an autocomplete - so it is found
; by its id instead, genericSearchInput, the box on the Identify Vehicle page
; that takes a VIN, registration or customer tag.
;
; The id list CP_BOXIDS is declared with the other globals at the top of the
; script, NOT here. A "global x := value" written down among the functions is
; below the ExitApp that ends the auto-execute section, so the assignment
; never runs and the variable is quietly empty - which showed up as Microcat's
; VIN box "never appearing" on a page that plainly had it.
CP_VinBox(hwnd) {
    static EDIT := 50004, COMBOBOX := 50003, CONTROLTYPE := 30003, SUBTREE := 7
    global CP_BOXIDS
    ; By id first, then by what the box calls itself.
    for i, ctype in [COMBOBOX, EDIT] {
        e := CP_PickBox(hwnd, ctype, CP_BOXIDS, "")
        if (e)
            return e
    }
    for i, ctype in [EDIT, COMBOBOX] {
        e := CP_PickBox(hwnd, ctype, "", "i)\bvin\b")
        if (e)
            return e
    }
    return 0
}


; One visible control of a type, matched either by id or by name and help.
CP_PickBox(hwnd, ctype, ids, rx) {
    static CONTROLTYPE := 30003, SUBTREE := 7
    static NAME := 30005, HELP := 30013, CLASSNAME := 30012, AUTOID := 30011
    uia := CP_Uia()
    if (!uia)
        return 0
    el := 0
    if (DllCall(CP_Vt(uia, 6), "ptr", uia, "ptr", hwnd, "ptr*", el) != 0 || !el)
        return 0
    found := 0
    arr := CP_Find(uia, el, CONTROLTYPE, ctype, SUBTREE)
    if (arr) {
        n := 0
        DllCall(CP_Vt(arr, 3), "ptr", arr, "int*", n)
        Loop, %n%
        {
            e := 0
            DllCall(CP_Vt(arr, 4), "ptr", arr, "int", A_Index - 1, "ptr*", e)
            if (!e)
                continue
            ; The browser's own address bar says "Ask Google or type a URL"
            ; and must never be mistaken for a page's search box.
            if (found || CP_Str(e, CLASSNAME) = "OmniboxViewViews") {
                CP_Rel(e)
                continue
            }
            ; Hidden leftovers stay in a web app's tree - the same trap the
            ; IsuzuVIN tool hit - so anything with no width is not real.
            w := 0, hh := 0
            CP_Rect(e, w, hh)
            hit := false
            if (w > 0 && hh > 0) {
                if (IsObject(ids)) {
                    aid := CP_Str(e, AUTOID)
                    for j, want in ids {
                        if (aid == want) {
                            hit := true
                            break
                        }
                    }
                } else if (rx != "")
                    hit := RegExMatch(CP_Str(e, NAME) . " " . CP_Str(e, HELP), rx)
            }
            if (hit) {
                found := e
                continue                                ; kept, not released
            }
            CP_Rel(e)
        }
        CP_Rel(arr)
    }
    CP_Rel(el)
    return found
}


; get_CurrentBoundingRectangle - slot 43 - fills a plain RECT.
CP_Rect(el, ByRef w, ByRef h) {
    w := 0, h := 0
    VarSetCapacity(rc, 16, 0)
    if (DllCall(CP_Vt(el, 43), "ptr", el, "ptr", &rc) != 0)
        return
    w := NumGet(rc, 8, "int") - NumGet(rc, 0, "int")
    h := NumGet(rc, 12, "int") - NumGet(rc, 4, "int")
}


; Does this title look like a Microcat tab whose brand cannot be read off it?
; Either it says Microcat outright, or it has the loaded-vehicle shape -
; pipes with a VIN among them - without a VIN this build recognises.
CP_MaybeCatalog(title) {
    if RegExMatch(title, "i)microcat")
        return true
    return RegExMatch(title, "\|.*\|") && (CP_VinIn(title) != "")
}


; Read the URL of the tab now showing and say whether it agrees the tab
; belongs to this brand. A URL that names a DIFFERENT brand is a no; a URL
; that names none - Isuzu and BYD carry no such token - is not a contradiction
; and the title is left to stand.
CP_UrlAgrees(hwnd, brand) {
    ; The page needs a moment after the switch before its address is readable.
    Loop, 12
    {
        url := CP_ActiveUrl(hwnd)
        if (url != "") {
            said := CP_BrandOfUrl(url)
            return (said = "" || said = brand)
        }
        Sleep, 120
    }
    return true
}


CP_Main() {
    global CP_OUT
    hits := {}          ; brand -> { vin, hwnd, exe, title }
    seen := []

    for i, exe in ["msedge.exe", "chrome.exe"] {
        WinGet, list, List, % "ahk_exe " . exe
        Loop, %list%
        {
            h := list%A_Index%
            if (h = "" || !DllCall("IsWindowVisible", "ptr", h))
                continue
            for j, title in CP_TabTitles(h) {
                seen.Push(title)
                brand := CP_BrandOf(title)
                ; First sighting of a brand wins. A second tab of the same
                ; catalog is the same catalog.
                if (brand != "" && !hits.HasKey(brand))
                    hits[brand] := { vin: CP_VinIn(title), hwnd: h, exe: exe, title: title }
            }
        }
    }

    FormatTime, now, , yyyyMMddHHmmss
    out := "when`t" . now . "`n"
    out .= "tabs`t" . seen.Length() . "`n"
    for i, brand in CP_BRANDS {
        if (!hits.HasKey(brand))
            continue
        r := hits[brand]
        out .= brand . "`t1`t" . r.vin . "`t" . r.hwnd . "`t" . r.exe . "`t" . r.title . "`n"
    }
    for i, t in seen
        out .= "seen`t" . t . "`n"

    ; Written whole, then swapped in, so RegoCheck can never read half a file.
    tmp := CP_OUT . ".new"
    CP_Del(tmp)
    FileAppend, %out%, %tmp%, UTF-8
    CP_Del(CP_OUT)
    FileMove, %tmp%, %CP_OUT%, 1
}


; Which brand a tab title belongs to, or "" for none of them.
CP_BrandOf(title) {
    global CP_BRANDS, CP_WORDS, CP_WMI, CP_VETO
    if (Trim(title) = "")
        return ""
    flat := CP_Norm(title)
    for i, bad in CP_VETO {
        if InStr(flat, bad)
            return ""
    }
    ; The brand named in the title is the sure sign - this is what a Microcat
    ; tab with no vehicle loaded looks like, "Microcat EPC - Hyundai".
    for i, brand in CP_BRANDS {
        for j, word in CP_WORDS[brand] {
            if RegExMatch(title, "i)" . word)
                return brand
        }
    }
    ; Otherwise the VIN, which is how a Microcat tab reads once a car is on
    ; screen and the brand has dropped out of the title.
    return CP_BrandOfVin(CP_VinIn(title))
}


; The brand a VIN belongs to, off its first three characters, or "".
CP_BrandOfVin(vin) {
    global CP_BRANDS, CP_WMI
    if (StrLen(vin) < 3)
        return ""
    wmi := SubStr(vin, 1, 3)
    for i, brand in CP_BRANDS {
        for j, p in CP_WMI[brand] {
            ; "==" - a plain "=" here is case-blind and these are codes.
            if (p == wmi)
                return brand
        }
    }
    return ""
}


; The brand the CURRENT tab's URL says it is, or "" when the URL says nothing.
; This is the only fully deterministic reading: Microcat's vehicle token is
; base64 with the brand spelled out in it, so it settles Kia against Hyundai
; even when the title alone could not.
CP_BrandOfUrl(url) {
    global CP_BRANDS, CP_URLMARK
    if (url = "")
        return ""
    ; The token is the long base64 run in the path. Undo it and read what is
    ; inside; the VIN sits next to the brand in there too.
    plain := ""
    if RegExMatch(url, "/section/([A-Za-z0-9_\-]{24,})", m)
        plain := CP_B64(m1)
    if (plain != "") {
        for i, brand in CP_BRANDS {
            if InStr(plain, CP_URLMARK[brand], true)
                return brand
        }
        ; The VIN in the token is the backstop when the brand word is not one
        ; of the four spellings above.
        if RegExMatch(plain, "([0-9A-HJ-NPR-Z]{17})", v) {
            b := CP_BrandOfVin(v1)
            if (b != "")
                return b
        }
    }
    ; A Microcat tab with no vehicle has no token, but the host still says it
    ; is a Microcat tab - the caller uses that to know a mismatch from a miss.
    return ""
}


; Base64url to plain text, non-printable bytes dropped. Only used to read the
; brand and VIN out of a URL token, so anything unprintable is noise.
CP_B64(s) {
    s := StrReplace(StrReplace(s, "-", "+"), "_", "/")
    while (Mod(StrLen(s), 4))
        s .= "="
    ; CryptStringToBinaryW, CRYPT_STRING_BASE64 = 1
    n := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "wstr", s, "uint", 0, "uint", 1
        , "ptr", 0, "uint*", n, "ptr", 0, "ptr", 0)
        return ""
    VarSetCapacity(buf, n, 0)
    if !DllCall("crypt32\CryptStringToBinaryW", "wstr", s, "uint", 0, "uint", 1
        , "ptr", &buf, "uint*", n, "ptr", 0, "ptr", 0)
        return ""
    out := ""
    Loop, %n%
    {
        b := NumGet(buf, A_Index - 1, "UChar")
        out .= (b >= 32 && b < 127) ? Chr(b) : "`n"
    }
    return out
}


; The first 17-character VIN in a title, or "" if there is not one. Bounded by
; something that is not a VIN character so a longer code cannot be clipped
; down to 17 and passed off as one. I, O and Q are not VIN letters.
CP_VinIn(title) {
    if RegExMatch(title, "i)(^|[^0-9A-Z])([0-9A-HJ-NPR-Z]{17})([^0-9A-Z]|$)", m)
        return CP_Upper(m2)
    return ""
}


CP_Upper(s) {
    StringUpper, s, s
    return s
}


; Lower case, letters and digits only, so spacing and punctuation in a page
; title cannot be the reason a catalog is missed.
CP_Norm(s) {
    StringLower, s, s
    return RegExReplace(s, "[^a-z0-9]", "")
}


; FileDelete throws inside an active try when the file is not there, so every
; delete goes through here. Same trap the IsuzuVIN tool hit.
CP_Del(f) {
    if FileExist(f)
        try FileDelete, %f%
}


; --- the tab titles of one browser window ----------------------------------
; UI Automation by DllCall, no library. Each COM method is reached through its
; slot in the interface's function table, which is what the numbers are. Same
; approach PartsCheck uses to find its own tab.

CP_TabTitles(hwnd) {
    static TAB := 50018, TAB_ITEM := 50019, CONTROLTYPE := 30003
    static SUBTREE := 7, CHILDREN := 2

    names := []
    uia := CP_Uia()
    if (!uia)
        return names

    el := 0
    if (DllCall(CP_Vt(uia, 6), "ptr", uia, "ptr", hwnd, "ptr*", el) != 0 || !el)
        return names

    ; The tabs are the children of the tab strip. Asking the whole window for
    ; every TabItem instead also hands back the tabs a PAGE has drawn for
    ; itself - an Outlook tab alone brings back Home, View, Help and more.
    strips := CP_Find(uia, el, CONTROLTYPE, TAB, SUBTREE)
    if (strips) {
        n := 0
        DllCall(CP_Vt(strips, 3), "ptr", strips, "int*", n)
        Loop, %n%
        {
            strip := 0
            DllCall(CP_Vt(strips, 4), "ptr", strips, "int", A_Index - 1, "ptr*", strip)
            if (!strip)
                continue
            arr := CP_Find(uia, strip, CONTROLTYPE, TAB_ITEM, CHILDREN)
            if (arr) {
                len := 0
                DllCall(CP_Vt(arr, 3), "ptr", arr, "int*", len)
                Loop, %len%
                {
                    tab := 0
                    DllCall(CP_Vt(arr, 4), "ptr", arr, "int", A_Index - 1, "ptr*", tab)
                    if (!tab)
                        continue
                    nm := CP_Name(tab)
                    if (nm != "" && CP_IsBrowserTab(tab))
                        names.Push(nm)
                    CP_Rel(tab)
                }
                CP_Rel(arr)
            }
            CP_Rel(strip)
        }
        CP_Rel(strips)
    }
    CP_Rel(el)
    return names
}


; The same walk as CP_TabTitles, but it tells a matching tab to make itself
; current instead of reading its name, then checks the URL agreed. Selection-
; Item is the pattern a tab exposes for "make me the current tab" - no mouse,
; no keystrokes. Anything selected on the way that turns out to be the wrong
; brand is put back.
CP_SelectIn(hwnd, brand, loose := false) {
    static TAB := 50018, TAB_ITEM := 50019, CONTROLTYPE := 30003
    static SUBTREE := 7, CHILDREN := 2, SELECTIONITEM := 10010, ISSELECTED := 30079

    uia := CP_Uia()
    if (!uia)
        return false
    el := 0
    if (DllCall(CP_Vt(uia, 6), "ptr", uia, "ptr", hwnd, "ptr*", el) != 0 || !el)
        return false

    hit := false
    wasOn := 0                  ; the tab that was showing before any of this
    strips := CP_Find(uia, el, CONTROLTYPE, TAB, SUBTREE)
    if (strips) {
        n := 0
        DllCall(CP_Vt(strips, 3), "ptr", strips, "int*", n)
        Loop, %n%
        {
            strip := 0
            DllCall(CP_Vt(strips, 4), "ptr", strips, "int", A_Index - 1, "ptr*", strip)
            if (!strip)
                continue
            arr := CP_Find(uia, strip, CONTROLTYPE, TAB_ITEM, CHILDREN)
            if (arr) {
                len := 0
                DllCall(CP_Vt(arr, 3), "ptr", arr, "int*", len)
                Loop, %len%
                {
                    tab := 0
                    DllCall(CP_Vt(arr, 4), "ptr", arr, "int", A_Index - 1, "ptr*", tab)
                    if (!tab)
                        continue
                    ; A tab the PAGE drew is never a candidate - picking one
                    ; would be a click inside whatever the page is showing.
                    if (!CP_IsBrowserTab(tab)) {
                        CP_Rel(tab)
                        continue
                    }
                    name := CP_Name(tab)
                    isSel := CP_Bool(tab, ISSELECTED)
                    want := loose ? (CP_BrandOf(name) = "" && CP_MaybeCatalog(name))
                                  : (CP_BrandOf(name) = brand)
                    ; The tab already showing is a candidate like any other.
                    ; Skipping it - which is what holding it aside for the
                    ; restore used to do - meant asking for the catalog you
                    ; were already looking at answered "no such tab".
                    if (want && (isSel || CP_Pick(tab))) {
                        if CP_UrlAgrees(hwnd, brand)
                            hit := true
                    }
                    ; Hold on to whatever was showing, in case every candidate
                    ; turns out to be the wrong brand.
                    if (!hit && isSel && !wasOn) {
                        wasOn := tab
                        continue                       ; kept, not released
                    }
                    CP_Rel(tab)
                    if (hit)
                        break
                }
                CP_Rel(arr)
            }
            CP_Rel(strip)
            if (hit)
                break
        }
        CP_Rel(strips)
    }
    ; Nothing matched here, so leave the window on the tab it started on.
    if (!hit && wasOn)
        CP_Pick(wasOn)
    CP_Rel(wasOn)
    CP_Rel(el)
    return hit
}


; Is this TabItem one of the BROWSER's tabs, or one the page drew for itself?
;
; It matters both ways. A page tab called after a brand would light the wrong
; box, and worse, selecting one would be a click inside somebody's catalog.
; The Microcat page alone contributes Major, General, Options, Illustration
; Index, Search Results, Saved Favourites and Service and Repairs.
;
; The browser's own tabs carry ClassName "Tab". A page's carry whatever the
; site's stylesheet calls them - "mat-ripple mat-tab-label mat-focus-indicator
; ng-star-inserted" for the Angular Material ones Microcat uses - which is
; always either hyphenated or several classes with spaces between, and never
; a bare word.
CP_IsBrowserTab(el) {
    static CLASSNAME := 30012
    cls := CP_Str(el, CLASSNAME)
    if (cls = "")
        return true                 ; nothing said - do not throw it away
    return !(InStr(cls, " ") || InStr(cls, "-"))
}


; One string property off an element.
CP_Str(el, id) {
    VarSetCapacity(var, 24, 0)
    if (DllCall(CP_Vt(el, 10), "ptr", el, "int", id, "ptr", &var) != 0)
        return ""
    val := ""
    if (NumGet(var, 0, "ushort") = 8) {            ; VT_BSTR
        p := NumGet(var, 8, "ptr")
        if (p)
            val := StrGet(p, "UTF-16")
    }
    DllCall("oleaut32\VariantClear", "ptr", &var)
    return val
}


; Tell a tab to become the current one.
CP_Pick(tab) {
    static SELECTIONITEM := 10010
    pat := 0
    if (DllCall(CP_Vt(tab, 16), "ptr", tab, "int", SELECTIONITEM, "ptr*", pat) != 0 || !pat)
        return false
    ok := (DllCall(CP_Vt(pat, 3), "ptr", pat) = 0)
    CP_Rel(pat)
    return ok
}


; One boolean property off an element.
CP_Bool(el, id) {
    VarSetCapacity(var, 24, 0)
    if (DllCall(CP_Vt(el, 10), "ptr", el, "int", id, "ptr", &var) != 0)
        return false
    out := (NumGet(var, 0, "ushort") = 11) && NumGet(var, 8, "short")
    DllCall("oleaut32\VariantClear", "ptr", &var)
    return out
}


; The URL of whichever tab is currently showing in that window. A browser
; document's ValuePattern is its address; only the tab on screen has a
; document at all, which is why this cannot be used to survey the others.
CP_ActiveUrl(hwnd) {
    static DOCUMENT := 50030, CONTROLTYPE := 30003, SUBTREE := 7, VALUEPATTERN := 10002
    uia := CP_Uia()
    if (!uia)
        return ""
    el := 0
    if (DllCall(CP_Vt(uia, 6), "ptr", uia, "ptr", hwnd, "ptr*", el) != 0 || !el)
        return ""
    url := ""
    arr := CP_Find(uia, el, CONTROLTYPE, DOCUMENT, SUBTREE)
    if (arr) {
        n := 0
        DllCall(CP_Vt(arr, 3), "ptr", arr, "int*", n)
        Loop, %n%
        {
            d := 0
            DllCall(CP_Vt(arr, 4), "ptr", arr, "int", A_Index - 1, "ptr*", d)
            if (!d)
                continue
            pat := 0
            if (DllCall(CP_Vt(d, 16), "ptr", d, "int", VALUEPATTERN, "ptr*", pat) = 0 && pat) {
                s := 0
                if (DllCall(CP_Vt(pat, 4), "ptr", pat, "ptr*", s) = 0 && s) {
                    v := StrGet(s, "UTF-16")
                    DllCall("oleaut32\SysFreeString", "ptr", s)
                    if (InStr(v, "://") && url = "")
                        url := v
                }
                CP_Rel(pat)
            }
            CP_Rel(d)
            if (url != "")
                break
        }
        CP_Rel(arr)
    }
    CP_Rel(el)
    return url
}


CP_Uia() {
    global CP_pUia
    if (CP_pUia)
        return CP_pUia
    DllCall("ole32\CoInitialize", "ptr", 0)
    VarSetCapacity(clsid, 16, 0)
    VarSetCapacity(iid, 16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", "{FF48DBA4-60EF-4201-AA87-54103EEF594E}", "ptr", &clsid)
    DllCall("ole32\CLSIDFromString", "wstr", "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}", "ptr", &iid)
    p := 0
    if (DllCall("ole32\CoCreateInstance", "ptr", &clsid, "ptr", 0, "uint", 1
        , "ptr", &iid, "ptr*", p) != 0)
        return 0
    CP_pUia := p
    return p
}


; FindAll for one control type. The caller owns the array and releases it.
CP_Find(uia, root, propId, value, scope) {
    VarSetCapacity(v, 24, 0)
    NumPut(3, v, 0, "ushort")            ; VT_I4
    NumPut(value, v, 8, "int")
    cond := 0
    if (DllCall(CP_Vt(uia, 23), "ptr", uia, "int", propId, "ptr", &v, "ptr*", cond) != 0)
        return 0
    arr := 0
    hr := DllCall(CP_Vt(root, 6), "ptr", root, "int", scope, "ptr", cond, "ptr*", arr)
    CP_Rel(cond)
    return (hr = 0) ? arr : 0
}


CP_Name(el) {
    s := 0
    if (DllCall(CP_Vt(el, 23), "ptr", el, "ptr*", s) != 0 || !s)
        return ""
    name := StrGet(s, "UTF-16")
    DllCall("oleaut32\SysFreeString", "ptr", s)
    return name
}


CP_Vt(p, slot) {
    return NumGet(NumGet(p + 0) + slot * A_PtrSize)
}


CP_Rel(p) {
    if p
        DllCall(NumGet(NumGet(p + 0) + 2 * A_PtrSize), "ptr", p)
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