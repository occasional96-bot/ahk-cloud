#NoEnv
#SingleInstance Force
#NoTrayIcon
SetBatchLines, -1
SetWorkingDir %A_ScriptDir%
SetEmbeddedIcon()

;==============================================================================
; Isuzu VIN Lookup  (IDS / Pentana XT Client -> DC611 Warranty Unit Enquiry)
;
; Pure AutoHotkey v1, single file. Launches a hidden, headless Chrome in the
; background, drives the IDS web client over the Chrome DevTools Protocol (raw
; Winsock WebSocket - WS_* functions at the bottom of this script), logs in,
; runs DC611 for the VIN you paste, and shows the warranty expiry, model,
; paint code, trim, engine, etc.
;
; v2 features:
;   - PERSISTENT Chrome: closing the GUI leaves Chrome running & signed in, so
;     the next launch attaches to the live session and is ready in ~1 second.
;   - KEEPALIVE: every 4 minutes the session is checked and poked (a real RAP
;     request) so it never times out; if it ever drops it re-signs-in itself.
;     The poke also installs an in-page setInterval that keeps poking AFTER
;     the GUI is closed, so the session survives hours of idle overnight.
;   - Result cache (cache\) shows the last known answer instantly, then
;     refreshes live.
;   - Fast typing via CDP Input.insertText (with per-key fallback), polling
;     instead of fixed sleeps, auto-reconnect + one retry on any hiccup.
;==============================================================================

;------------------------- CONFIG (edit here) --------------------------------
global IV_VER  := "3.8"                       ; bump by hand on every change
global CFG_USER := "D7334KT"
global CFG_PW   := "aB7xK2qLlp"
global CFG_PORT := 9412                       ; private CDP port for our Chrome
global CFG_PROFILE := A_ScriptDir "\chrome-profile"
global CFG_HOST := "idserp.iua.net.au"
global CFG_KEEPALIVE := 240000                ; session check/poke every 4 min
global CFG_CACHE := A_ScriptDir "\cache"      ; per-query result cache
;-----------------------------------------------------------------------------

global gSock := 0          ; page-target websocket
global gId   := 0          ; CDP message id counter
global gReady := false
global gBusy := false
global gBatch := false
global gAttached := false  ; true when we reused an already-running session
global gLog := A_ScriptDir "\isuzuvin.log"
global gChromePID := 0
global gPokeMode := ""     ; "rap:..." (native RAP request) or "menu" fallback
global gMx := 0            ; cross-process mutex handle
global gTargetId := ""
global gFailWhy := ""      ; WHY the last lookup came back empty, in plain words
global gCdpDead := false   ; ...and true when the socket died during it
global gLastOk := 0        ; A_TickCount of the last CONFIRMED-live server contact
global gPending := false   ; a lookup typed while the session was still warming up
global gLastPartRes := ""  ; last part result, so a View toggle can redraw it
global gIni := A_ScriptDir "\settings.ini"   ; per-user settings, next to the script
global gShowTrade := false ; show Active / Discount code / Class in the Prices list
global gVinHide := {}      ; vehicle field key -> true for every field hidden.
                           ; MUST be declared before the ini is read below: a
                           ; later `:= {}` would silently wipe what was loaded.
if FileExist(gIni) {       ; IniRead throws on a missing file in this AHK build
    IniRead, tmpShowTrade, %gIni%, View, ShowTradeFields, 0
    gShowTrade := (tmpShowTrade = 1)
    IniRead, tmpHidden, %gIni%, Vehicle, HiddenFields, %A_Space%
    if (tmpHidden != "" && tmpHidden != "ERROR")
        Loop, Parse, tmpHidden, `,
            if (Trim(A_LoopField) != "")
                gVinHide[Trim(A_LoopField)] := true
}
global gSessLog := A_ScriptDir "\session.log"   ; session health history
; ---- supersession (old part number -> replacement) ----
; What was actually typed on the parts tab. DC210 sometimes forwards a
; superseded number to its replacement on its own, without ever putting a
; Repl# on the record we get back - so the walk in ResolveLatest() sees no
; hop and the only evidence that the number changed is that the record on
; screen is not the number in the box. This is that evidence.
global gTypedPart := ""

; IDS keeps a chain: an old number carries Repl#, the new one carries Old#.
; The app follows Repl# forward so the user always sees the current number,
; and says so on one quiet line that clears itself.
global gSupTyped := ""     ; the number the user typed, when we jumped off it
global gSupOlder := []     ; numbers walked past on the way to the current one
global gSupNums  := []     ; link index -> part number, for the clickable line
global gNoJump   := false  ; user clicked an old number: show it exactly as asked
global CFG_MAXHOPS := 3    ; how far to follow Repl# before giving up
global gNewsOn := false      ; the Item News box is on screen (parts tab)
global gNewsText := ""       ; ...and this is what it says
global gPriceOn := false     ; ...and so is the price rail under it
global gTabDY := 0           ; GUI y -> Tab3-relative y, measured at startup
global gRowState := []       ; warehouse row -> stock / wait / dead, for the tint
global gLadNone := false     ; no branch holds it: the line is speaking, not a row
global gLadPart := ""        ; ...and this is the part it is speaking about
global gPillOn := false      ; the verdict pill above the table is showing
global gPillHwnd := 0        ; ...this is its window
global gPillY := 0           ; ...and this is where FitWindow last put it
global gPillW := 0           ; ...this wide, because it is cut to its own text
global gPillH := 0           ; ...and this tall, 20 on one line and 30 on two
global gLadFootOn := false   ; the verdict line under the table is showing
global gLadFootHwnd := 0     ; ...this is its window
global gLadFootY := 0        ; ...and this is where FitWindow last put it
global LVStockHwnd := 0      ; the warehouse list, for its custom-draw notifications
global gPanelsBuilt := false ; the coloured child windows exist
global gPanelsOn := false    ; ...and there is a result worth showing in them
global gVPanelsOn := false   ; the Vehicle tab has a result worth a band
global VBandHwnd := 0

global gPanelHwnd := []      ; every coloured child panel, for z-order fixing
global TabHwnd := 0
; ---- vehicle field visibility ----
; The DC611 record has 26 fields and most people care about four of them.
; Settings > Vehicle fields ticks what shows; the rest are just not drawn.
global gLastVinRes := ""     ; last vehicle result, so a toggle can redraw it
global gVinKeyOf := {}       ; menu item text -> field key
global gVinOrder := ["vin","rego","year","model","model_desc","ride","group","colour_code","colour"
    ,"trim_code","trim","engine","status_code","status","activity","key_number"
    ,"build_date","retail_sale","warranty_start","warranty_expiry","kms","campaign"
    ,"selling_dealer","sold_to_dealer","date_to_dealer","purpose_code","comments"]
global gVinPretty := {vin:"VIN", rego:"Registration", year:"Year", model:"Model code"
    , model_desc:"Model", ride:"Ride height", group:"Group"
    , colour_code:"Paint code", colour:"Paint colour"
    , trim_code:"Trim code", trim:"Trim", engine:"Engine No.", status_code:"Status code"
    , status:"Status", activity:"Activity", key_number:"Key number"
    , build_date:"Build date", retail_sale:"Retail sale", warranty_start:"Warranty start"
    , warranty_expiry:"Warranty EXPIRY", kms:"Warranty kms", selling_dealer:"Selling dealer"
    , sold_to_dealer:"Sold-to dealer", date_to_dealer:"Date to dealer"
    , purpose_code:"Purpose code", comments:"Owner / comments", campaign:"Campaign"}
global BandHwnd := 0

FileCreateDir, %CFG_CACHE%

global gSelfTest := ""
; self-test GUI mode:  AutoHotkeyU64.exe IsuzuVIN.ahk --selftest <VIN>
if (A_Args.Length() >= 1 && A_Args[1] = "--selftest") {
    gSelfTest := (A_Args.Length() >= 2 ? A_Args[2] : "MPATFR85JKT003256")
    BuildGui()
    return
}
; health mode:  AutoHotkeyU64.exe IsuzuVIN.ahk --health
; Attaches to whatever session is running, does the FULL probe (transport,
; visible login form, server liveness), repairs it if it went stale, and writes
; the verdict to session.log + isuzuvin.log. Run it on a schedule to PROVE the
; session stays signed in between uses instead of finding out mid-lookup.
if (A_Args.Length() >= 1 && A_Args[1] = "--health") {
    gBatch := true
    try {
        RunHealth()
    } catch e {
        BLog("EXCEPTION: " e.Message " (line " e.Line ")")
        SLog("health: EXCEPTION " e.Message)
    }
    ExitApp
}
; batch mode:  AutoHotkeyU64.exe IsuzuVIN.ahk <VIN> [kind]
global gDump := false
if (A_Args.Length() >= 1) {
    gBatch := true
    k := (A_Args.Length() >= 2 ? A_Args[2] : "vin")
    if (k = "dump") {
        gDump := true
        k := "vin"
    }
    ; an uncaught error in headless mode would pop an invisible dialog and
    ; leave a zombie process holding the mutex - catch, log, exit clean
    try {
        RunBatch(A_Args[1], k)
    } catch e {
        BLog("EXCEPTION: " e.Message " (line " e.Line ")")
    }
    ExitApp
}

BuildGui()
return

RunBatch(value, kind) {
    global
    SafeDelete(gLog)
    local t0 := A_TickCount
    BLog("== batch " kind " " value " ==")
    if !MxAcquire(60000) {
        BLog("ERROR: another IsuzuVIN instance is busy (mutex timeout)")
        return
    }
    if !EnsureChrome() {
        BLog("ERROR: chrome start failed")
        MxRelease()
        return
    }
    if !OpenPage() {
        BLog("ERROR: openpage failed")
        MxRelease()
        return
    }
    BLog("openpage OK (" (gAttached ? "attached to running session" : "new target") ") +" (A_TickCount-t0) "ms")
    local li
    try {
        li := RecoverSession()
    } catch e {
        BLog("EXCEPTION in login: " e.Message " (line " e.Line ")")
        MxRelease()
        return
    }
    if !li {
        BLog("ERROR: login failed")
        MxRelease()
        return
    }
    BLog("logged in OK +" (A_TickCount-t0) "ms")
    DetectPoke()
    BLog("poke mode=" gPokeMode)
    CleanupForms()
    local reps := (A_Args.Length() >= 3 ? A_Args[3] : 1)
    local res
    Loop, %reps% {
        BLog("--- lookup #" A_Index " ---")
        try {
            res := Lookup(kind, value)
        } catch e {
            BLog("EXCEPTION in lookup: " e.Message " (line " e.Line ")")
            MxRelease()
            return
        }
        BLog("RESULT-BEGIN")
        BLog(res)
        BLog("RESULT-END +" (A_TickCount-t0) "ms")
        CleanupForms()
        if (res != "" && res != "NOTFOUND")
            CacheWrite(kind, value, res)
    }
    MxRelease()
}
BLog(s) {
    global gLog
    FileAppend, % s "`n", %gLog%
}

; One-shot session health probe for schedulers / manual testing. Verdicts:
;   OK        - the running session was still signed in and the server answered
;   REPAIRED  - it had gone stale and was signed back in
;   DOWN      - could not be brought back
;   BUSY      - another IsuzuVIN process held the mutex, nothing was touched
RunHealth() {
    global
    SafeDelete(gLog)
    BLog("== health check ==")
    if !MxAcquire(60000) {
        BLog("HEALTH: BUSY (another instance holds the mutex)")
        SLog("health: BUSY - another instance holds the mutex")
        return
    }
    local was
    try {
        if (!EnsureChrome() || !OpenPage()) {
            BLog("HEALTH: DOWN (no chrome/page)")
            SLog("health: DOWN - no chrome/page")
            return
        }
        was := (gAttached ? "attached to running session" : "new target")
        if (gAttached && IsLoggedIn() && SessionAlive()) {
            gLastOk := A_TickCount
            BLog("HEALTH: OK (" was ", still signed in)")
            SLog("health: OK - still signed in")
        } else if (EnsureReady(0)) {
            BLog("HEALTH: REPAIRED (" was ", session was stale - signed back in)")
            SLog("health: REPAIRED - session was stale, signed back in")
        } else {
            BLog("HEALTH: DOWN (could not sign back in)")
            SLog("health: DOWN - could not sign back in")
            return
        }
        DetectPoke()
        CleanupForms()
        BLog("poke mode=" gPokeMode)
    } finally {
        MxRelease()
    }
}

;=============================== GUI =========================================
BuildGui() {
    global
    Menu, SessMenu, Add, Minimise window (Ctrl+PageDown brings it back), MenuHideWindow
    Menu, SessMenu, Add, Exit (leave Chrome running), MenuExitKeep
    Menu, SessMenu, Add, Exit and stop Chrome, MenuExitKill
    Menu, SessMenu, Add, Check session now, MenuCheck
    Menu, SessMenu, Add, Force fresh sign-in now, MenuRelogin
    Menu, MainMenuBar, Add, &Session, :SessMenu
    ; one home for every preference, instead of a View menu that only ever
    ; held one thing
    Menu, SetMenu, Add, Show trade fields (Parts), MenuToggleTrade
    if (gShowTrade)
        Menu, SetMenu, Check, Show trade fields (Parts)
    for i, k in gVinOrder {
        label := gVinPretty[k] ? gVinPretty[k] : k
        gVinKeyOf[label] := k
        Menu, VinMenu, Add, %label%, MenuToggleVinField
        if (!gVinHide.HasKey(k))
            Menu, VinMenu, Check, %label%
    }
    Menu, VinMenu, Add
    Menu, VinMenu, Add, Show every field again, MenuVinFieldsReset
    Menu, SetMenu, Add
    Menu, SetMenu, Add, Vehicle fields, :VinMenu
    Menu, MainMenuBar, Add, Se&ttings, :SetMenu
    Gui, Main:New, , % "Isuzu Parts & VIN Lookup  v" IV_VER
    Gui, Main:Menu, MainMenuBar
    Gui, Main:Font, s10, Segoe UI
    ; Parts is tab 1 on purpose - it is what the warehouse opens this for.
    ; Controls inside a Tab3 still use GUI coordinates, not tab-relative ones.
    ; WS_CLIPCHILDREN on the window and WS_CLIPSIBLINGS on the tab control are
    ; what stop the tab body repainting straight over the coloured panels.
    Gui, Main:+0x02000000
    Gui, Main:+HwndMainHwnd
    Gui, Main:Add, Tab3, x8 y8 w474 h458 vTabCtl gTabChanged hwndTabHwnd, Parts|Vehicle
    WinSet, Style, +0x4000000, ahk_id %TabHwnd%
    ; Tab3 does not paint its own page: it hangs a #32770 dialog behind the
    ; tab control, one per tab, and THAT is what fills it. The dialog had no
    ; WS_CLIPSIBLINGS, so every repaint of it went over the coloured panels
    ; above it - they were raised, present, and still wiped.
    ;
    ; Clipping alone is not enough. WS_CLIPSIBLINGS clips a window against
    ; whatever is ABOVE it, and the tab control was above the dialog and
    ; covers all of it - so the clipped dialog drew nothing at all and the
    ; page went blank. The dialog has to sit ABOVE the tab control, with the
    ; panels above that. Final order, top down: panels, button, page dialog,
    ; tab control.
    ClipTabPages()

    ; ---------------------------- tab 1: parts -------------------------------
    Gui, Main:Add, Text, x20 y46, Part number:
    Gui, Main:Add, Edit, x20 y66 w330 vPartInput
    ; the Look up button is NOT here - it is shared, and lives outside the
    ; tabs. See the "shared lines" section below for why.
    ; One quiet line under the box: what happened to the number you typed.
    ; Clickable (each old number is a link), and it clears itself after a
    ; few seconds unless it is the standing "this one is superseded" warning.
    Gui, Main:Font, s8, Segoe UI
    Gui, Main:Add, Link, x20 y94 w450 h16 vSupLine gSupClick,
    ; Everything on this tab ends at x470 - the right edge of the Look up
    ; button - and the order down it is: part identity, warehouse table,
    ; verdict line, item news, price rail. Nothing sits above the part title
    ; any more: v2.6 opened with a ladder of coloured rows that named every
    ; branch and its quantity, directly above a table that named every branch
    ; and its quantity. The table won. See "the verdict line" below.
    ; The part header, two lines against a steel rule. The number is only a
    ; receipt for what was typed, so it goes small, grey and monospaced; the
    ; description is the thing being checked - IS THIS THE RIGHT PART - so it
    ; is the big black line. Until v2.7 both were one bold string of the same
    ; size and colour, which made neither of them findable.
    ; The rule is a Progress bar with its bar at zero: a 3px control filled
    ; with nothing but its own background colour. Themed progress bars ignore
    ; a custom background, hence -Theme around it and +Theme straight after.
    Gui, Main:-Theme
    Gui, Main:Add, Progress, x20 y112 w3 h36 Background2C4A66 vPartRule Hidden
    Gui, Main:+Theme
    ; The tag rides on the NUMBER's line, not the description's: descriptions
    ; run to 40 characters ("MOTOR ASM; FRT WINDSHIELD WIPER") and every one
    ; of them was being clipped by the tag's column, in v2.7 and in every
    ; version before it.
    Gui, Main:Font, s8 Bold, Consolas
    Gui, Main:Add, Text, x31 y112 w300 vPartNum c6E7B87,
    Gui, Main:Font, s8 Bold, Segoe UI
    Gui, Main:Add, Text, x356 y112 w114 Right vPartTag,
    Gui, Main:Font, s12 Bold, Segoe UI
    Gui, Main:Add, Text, x31 y125 w439 vPartTitle,
    Gui, Main:Font, s8 Norm, Segoe UI
    ; w300, not w450: the right of this row belongs to the verdict pill
    Gui, Main:Add, Text, x20 y150 w300 vTradeLine c6E7B87,
    Gui, Main:Font, s10 Norm, Consolas
    ; h is a placeholder: ListFit() resizes this to the rows it actually
    ; holds, because gridlines are drawn across the empty tail of a list that
    ; is taller than its contents and read as blank warehouse rows.
    ; The last column is nameless and 22px wide: it holds the state glyph for
    ; the row - tick, hourglass or a quiet dot. The row it belongs to is
    ; tinted behind it by OnNotify().
    Gui, Main:Add, ListView, x20 y180 w450 h26 Grid -Multi vLVStock hwndLVStockHwnd, Whs|Branch|Available|On order|Min sell|Pack
    ; 444 total, against a client width of 446 (450 less 2px of border each
    ; side). It used to stop at 428 to keep 17px clear for a vertical
    ; scrollbar, and that reserve showed as a dead strip past Pack on every
    ; part - paid for on all of them to protect a case that does not happen:
    ; Isuzu answers with three warehouses, and ListFit's cap now has room for
    ; ten before one is needed. The strip is gone into Branch, which is the
    ; only column with a name long enough to want it.
    LV_ModifyCol(1, 34)
    LV_ModifyCol(2, 124)
    LV_ModifyCol(3, 78)
    LV_ModifyCol(4, 72)
    LV_ModifyCol(5, 70)
    LV_ModifyCol(6, 44)
    ; and the nameless one on the end, added rather than named in the column
    ; list above: a TRAILING empty column title is dropped by the parser, so
    ; "...|Pack|" built six columns and quietly ate every glyph written to the
    ; seventh. A leading empty title survives, which is why this worked while
    ; the glyph sat on the left.
    LV_InsertCol(7, 22)
    ; Item News, straight off DC210's News F20 screen. Titled the way IDS
    ; titles it, so the two screens can be talked about as one thing. Hidden
    ; until there IS news - most parts have none, and an empty box on every
    ; lookup would just be the dead space v2.1 spent its time removing.
    ; A read-only Edit, not a Text: the news usually names another part
    ; number, and that number has to be selectable to be any use.
    Gui, Main:Font, s8 Bold, Segoe UI
    Gui, Main:Add, Text, x20 y244 w450 vNewsHdr c7A5600 Hidden, GENERAL TECHNICAL INFORMATION
    Gui, Main:Font, s10 Norm, Consolas
    ; s10, and near-black on the parchment rather than the brown it is
    ; written in - this is safety text about windscreens and calibration,
    ; read across a warehouse desk, not decoration.
    Gui, Main:Add, Edit, x20 y260 w450 h58 ReadOnly -WantReturn Hidden vNewsBox c4A3200 BackgroundFFF7E8,
    ; The price rail: four figures on the bottom edge of the tab, in about the
    ; same grey as the session line under it. These are reference numbers -
    ; nobody opens this app to read them - so they get a 16px rail instead of
    ; the 58px panel they used to have, and they sit below everything that IS
    ; read. FitWindow() drops the whole rail to the content bottom.
    Gui, Main:Add, Text, x20 y322 w450 h2 0x10 vPriceRule Hidden
    Gui, Main:Font, s7 Norm, Segoe UI
    ; columns sit 106 apart, not 110: the last figure used to run under .EXC
    Gui, Main:Add, Text, x20 y330 w34 vPriceLbl1 cA2A2A2 Hidden, LIST
    Gui, Main:Add, Text, x126 y330 w38 vPriceLbl2 cA2A2A2 Hidden, TRADE
    Gui, Main:Add, Text, x232 y330 w38 vPriceLbl3 cA2A2A2 Hidden, DAILY
    Gui, Main:Add, Text, x338 y330 w38 vPriceLbl4 cA2A2A2 Hidden, STOCK
    Gui, Main:Add, Text, x426 y330 w40 Right vPriceExc cB4B4B4 Hidden, .EXC
    Gui, Main:Font, s8 Norm, Consolas
    Gui, Main:Add, Text, x56 y328 w60 vPrice1 c3E3E3E Hidden,
    Gui, Main:Add, Text, x162 y328 w60 vPrice2 c3E3E3E Hidden,
    Gui, Main:Add, Text, x268 y328 w60 vPrice3 c3E3E3E Hidden,
    Gui, Main:Add, Text, x374 y328 w56 vPrice4 c3E3E3E Hidden,

    ; --------------------------- tab 2: vehicle ------------------------------
    Gui, Main:Tab, 2
    Gui, Main:Font, s10, Segoe UI
    Gui, Main:Add, Text, x20 y46, VIN / Rego / Serial / Engine:
    ; the input row stops at x350 so the shared Look up button sits in the
    ; same place on both tabs
    Gui, Main:Add, Edit, x20 y66 w236 vVinInput
    Gui, Main:Add, DropDownList, x262 y66 w88 vKindInput Choose1, VIN|Rego|Serial|Engine
    ; y100..130 is the warranty band - another coloured child window
    Gui, Main:Font, s11 Bold, Segoe UI
    Gui, Main:Add, Text, x20 y138 w450 vVinTitle,
    Gui, Main:Font, s9 Norm, Segoe UI
    ; its own row, and the full width, because it carries three facts now:
    ; the model description, the rego, and high ride / low ride
    Gui, Main:Add, Text, x20 y160 w450 vVinSub c47535F,
    Gui, Main:Font, s10, Consolas
    Gui, Main:Add, ListView, x20 y182 w450 h26 Grid -Multi vLV, Field|Value
    LV_ModifyCol(1, 140)
    LV_ModifyCol(2, 280)

    ; ------------- shared lines, outside the tabs (both tabs see them) -------
    Gui, Main:Tab
    ; ONE Look up button for both tabs, and deliberately OUTSIDE the tab
    ; control. Two reasons, both learned the hard way:
    ;   - WM_DRAWITEM is sent to a control's parent, and a control inside a
    ;     Tab3 is parented to the tab's own window, not to this GUI - so an
    ;     owner-drawn button in there never reaches OnDrawItem and paints as
    ;     a blank hole. Outside the tabs, the parent is Main, and it paints.
    ;   - one button means one Default button, so Enter works on both tabs
    ;     without the pair that used to be swapped on every tab change.
    Gui, Main:Font, s10, Segoe UI
    Gui, Main:Add, Button, x360 y65 w110 h27 gDoLookup Default vLookBtn hwndLookHwnd, &Look up
    OwnerDrawButton(LookHwnd)
    OnMessage(0x2B, "OnDrawItem")      ; WM_DRAWITEM
    OnMessage(0x4E, "OnNotify")        ; WM_NOTIFY - warehouse row colours
    ; No status strip under the results. The band, the title and the price
    ; row already say what came back, so a sentence repeating them plus a
    ; stopwatch was three lines of duplication. The session line below is now
    ; the only footer, and SetStatus writes progress and failures into it.
    Gui, Main:Font, s8, Segoe UI
    Gui, Main:Add, Text, x12 y504 w470 vSess c808080, Starting...
    ; Launching this does not put a window in your face. It opens minimised on
    ; the taskbar and signs in from there, so by the time you actually want it -
    ; taskbar button or Ctrl+PageDown - the session is already up.
    ; Minimize still creates and SIZES the window, so every measurement below
    ; (gTabDY, control positions) works exactly as it did when it was shown.
    Gui, Main:Show, Minimize w490 h530
    ; A control inside a Tab3 is CREATED in GUI coordinates and MOVED in
    ; coordinates relative to the tab's display area - the two differ by the
    ; height of the tab row plus the tab border. Everything FitWindow moved
    ; was landing that far down the window, which is where the gap above the
    ; news label came from. Measure the difference once rather than trusting
    ; a hard-coded 34: it is a theme and font-size question, not a constant.
    GuiControl, Main:Move, NewsHdr, y100
    GuiControlGet, tp, Main:Pos, NewsHdr
    gTabDY := tpY - 100
    GuiControl, Main:Move, NewsHdr, % "y" (244 - gTabDY)
    BuildPanels()      ; child windows need their parent to exist first
    GuiControl, Main:Focus, PartInput
    ; kick off session setup shortly after the window paints
    SetTimer, InitSession, -300
}

; A Win32 Text control always paints itself on ITS OWN window background, so
; the only honest way to get a green band behind dark green text is to put a
; green window there. These are real child windows of Main: they move, clip and
; hide with it. They know nothing about tabs, though, so PanelsShow() must hide
; them whenever the Vehicle tab is in front or they float over it.
BuildPanels() {
    global
    gPanelHwnd := []
    ; the button is a sibling of the tab control too, so it needs the same
    ; z-order treatment or the tab body paints over it
    gPanelHwnd.Push(LookHwnd)
    ; --- the verdict line ---
    ; One window, under the warehouse table, saying the one thing the table
    ; cannot: what happens next. A Text control paints on its own window's
    ; background, so a line that has to be green has to BE a green window.
    ; --- the verdict pill, above the table and hard right ---
    ; The band between the part title and the table was 30px of nothing. It is
    ; the answer's place now: one chip, in the state's own colour, saying what
    ; the tinted row says but saying it before the eye reaches the numbers.
    ; A child GUI and not a Text control, for the same reason as every other
    ; coloured strip here - a Win32 Text control paints on its parent's
    ; background, so a coloured ground has to be a window of its own.
    Gui, Pill:New, -Caption +Border +ParentMain +HwndPillTmp
    Gui, Pill:Color, FFFFFF
    Gui, Pill:Font, s10 Norm, Segoe UI Symbol
    Gui, Pill:Add, Text, x6 y1 w18 h18 Center vPillGlyph
    Gui, Pill:Font, s8 Bold, Segoe UI
    Gui, Pill:Add, Text, x26 y4 w88 vPillWord
    Gui, Pill:Font, s7 Norm, Segoe UI
    Gui, Pill:Add, Text, x26 y17 w88 vPillEta
    gPillHwnd := PillTmp
    gPanelHwnd.Push(PillTmp)

    Gui, LadF:New, -Caption +Border +ParentMain +HwndLadFTmp
    Gui, LadF:Color, FFFFFF
    Gui, LadF:Font, s11 Norm, Segoe UI Symbol
    Gui, LadF:Add, Text, x8 y2 w20 h20 Center vLadGF
    Gui, LadF:Font, s9 Bold, Segoe UI
    Gui, LadF:Add, Text, x32 y4 w406 vLadNF
    gLadFootHwnd := LadFTmp
    gPanelHwnd.Push(LadFTmp)
    ; --- warranty band, the Vehicle tab's answer to the verdict band ---
    Gui, VBand:New, -Caption +Border +ParentMain +HwndVBandHwnd
    Gui, VBand:Color, F2F2F2
    Gui, VBand:Font, s11, Segoe UI Symbol
    Gui, VBand:Add, Text, x9 y4 w22 h20 Center vVBandGlyph,
    Gui, VBand:Font, s9 Bold, Segoe UI
    Gui, VBand:Add, Text, x34 y6 w330 vVBandWord,
    Gui, VBand:Add, Text, x368 y6 w72 Right vVBandQty,
    gPanelHwnd.Push(VBandHwnd)
    ; Branch cards used to sit here, then a four-cell price panel under the
    ; part title. The cards printed figures the warehouse table already held,
    ; and the panel gave the prices the loudest type on the screen - for
    ; numbers nobody opens this app to read. Both went: the prices are a grey
    ; rail on the bottom edge now (the PriceRail controls in BuildGui).
    gPanelsBuilt := true
}

; The panels are only correct in one place: Parts tab, with a result in hand.
; Pass true/false to change that, or "" to just re-apply it after a tab switch.
; Parts panels on/off. "" means "leave the decision alone, just re-apply it",
; which is what a tab switch needs.
PanelsShow(on) {
    global gPanelsOn
    if (on != "")
        gPanelsOn := on
    ApplyPanels()
}

; the Vehicle tab's warranty band, same idea
VPanelsShow(on) {
    global gVPanelsOn
    if (on != "")
        gVPanelsOn := on
    ApplyPanels()
}

ApplyPanels() {
    global gPanelsBuilt, gPanelsOn, gVPanelsOn, gPillOn, gPillY, gPillW, gPillH
    if (!gPanelsBuilt)
        return
    GuiControlGet, tsel, Main:, TabCtl
    if (gVPanelsOn && tsel = "Vehicle")
        Gui, VBand:Show, x20 y100 w450 h30 NoActivate
    else
        Gui, VBand:Hide
    ; hard right, so it lands on the same edge as LATEST above it and the
    ; glyph column below it
    ; right edge pinned at 470 whatever the width is, so it lines up with
    ; LATEST above it and the last column below it. The band is always 30, so
    ; a 20-tall pill is centred in it rather than left hanging at the top.
    if (gPanelsOn && gPillOn && tsel = "Parts") {
        px := 470 - gPillW
        py := gPillY + (30 - gPillH) // 2
        Gui, Pill:Show, % "x" px " y" py " w" gPillW " h" gPillH " NoActivate"
    } else {
        Gui, Pill:Hide
    }
    PanelsRaise()
    ; the line sits wherever FitWindow left the bottom of the table
    if (gPanelsOn && gLadFootOn && tsel = "Parts") {
        Gui, LadF:Show, % "x20 y" gLadFootY " w450 h24 NoActivate"
        PanelsRaise()
    } else {
        Gui, LadF:Hide
    }
}

; The panels are SIBLINGS of the tab control, not children of it, so whoever
; sits higher in the z-order wins the pixels. Showing a window does not move
; it above the tab body, which is exactly why the band was invisible: present,
; reported visible, and painted straight over. HWND_TOP after every show.
; The second tab's page dialog does not exist yet when the window is built,
; and a page that arrives unclipped paints over the button and the bands. So
; this runs again before every raise, not once at startup.
ClipTabPages() {
    global MainHwnd
    hDlg := 0
    Loop {
        hDlg := DllCall("FindWindowEx", "Ptr", MainHwnd, "Ptr", hDlg
                      , "Str", "#32770", "Ptr", 0, "Ptr")
        if (!hDlg)
            break
        ; DllCall, not WinSet: WinSet on the page dialog threw "1" from inside
        ; the lookup thread, and the throw aborted the rest of the redraw -
        ; the field table came back empty and the button disappeared with it
        st := DllCall("GetWindowLong" (A_PtrSize = 8 ? "Ptr" : "")
                    , "Ptr", hDlg, "Int", -16, "Ptr")
        DllCall("SetWindowLong" (A_PtrSize = 8 ? "Ptr" : "")
              , "Ptr", hDlg, "Int", -16, "Ptr", st | 0x4000000)
        DllCall("SetWindowPos", "Ptr", hDlg, "Ptr", 0
              , "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
    }
}

PanelsRaise() {
    global gPanelHwnd, LookHwnd
    ; pages first, panels second - whatever is raised last ends up on top
    ClipTabPages()
    ; Raising a window does not repaint it, and whatever was drawn over it
    ; while it was underneath stays gone: the band came up green and wordless,
    ; the owner-drawn button came up as an empty hole. Raise, then ask each
    ; one to paint itself again.
    for i, h in gPanelHwnd {
        if (!h)
            continue
        DllCall("SetWindowPos", "Ptr", h, "Ptr", 0
              , "Int", 0, "Int", 0, "Int", 0, "Int", 0
              , "UInt", 0x13)       ; SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE
        ; RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_UPDATENOW - the text
        ; controls inside a panel are children, and InvalidateRect on the
        ; panel alone leaves them holding whatever was painted over them
        DllCall("RedrawWindow", "Ptr", h, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
    }
}

; A Win32 button paints itself, in the system's colours, and no amount of
; GuiControl will change that. BS_OWNERDRAW hands the painting to us instead:
; Windows then sends WM_DRAWITEM to the button's PARENT every time it needs a
; repaint, and we fill it steel and write the caption in white.
OwnerDrawButton(h) {
    st := DllCall("GetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "Ptr", h, "Int", -16, "Ptr")
    DllCall("SetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "Ptr", h, "Int", -16
          , "Ptr", (st & ~0xF) | 0xB)      ; BS_OWNERDRAW in the low nibble
    DllCall("InvalidateRect", "Ptr", h, "Ptr", 0, "Int", 1)
}

; Colours here are COLORREF, which is 0x00BBGGRR - the bytes run backwards
; from the hex everywhere else in this file. 0x6B4617 is #17466B.
OnDrawItem(wParam, lParam, msg, hwnd) {
    global LookHwnd
    ; DRAWITEMSTRUCT - the handle members are what shift between 32 and 64 bit
    if (A_PtrSize = 8)
        oHwnd := 24, oDC := 32, oRc := 40
    else
        oHwnd := 20, oDC := 24, oRc := 28
    if (NumGet(lParam + 0, oHwnd, "Ptr") != LookHwnd)
        return
    hdc   := NumGet(lParam + 0, oDC, "Ptr")
    state := NumGet(lParam + 0, 16, "UInt")   ; ODS_SELECTED 0x1, DISABLED 0x4
    face := (state & 0x4) ? 0xBEB4A8 : (state & 0x1) ? 0x52330F : 0x6B4617
    edge := (state & 0x4) ? 0xA89C8E : 0x52330F
    hb := DllCall("CreateSolidBrush", "UInt", face, "Ptr")
    DllCall("FillRect", "Ptr", hdc, "Ptr", lParam + oRc, "Ptr", hb)
    DllCall("DeleteObject", "Ptr", hb)
    hb := DllCall("CreateSolidBrush", "UInt", edge, "Ptr")
    DllCall("FrameRect", "Ptr", hdc, "Ptr", lParam + oRc, "Ptr", hb)
    DllCall("DeleteObject", "Ptr", hb)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)          ; TRANSPARENT
    DllCall("SetTextColor", "Ptr", hdc, "UInt", (state & 0x4) ? 0xF0F0F0 : 0xFFFFFF)
    VarSetCapacity(txt, 260 * 2, 0)
    DllCall("GetWindowText", "Ptr", LookHwnd, "Str", txt, "Int", 256)
    ; DT_CENTER|DT_VCENTER|DT_SINGLELINE, and no DT_NOPREFIX so &L underlines
    DllCall("DrawText", "Ptr", hdc, "Str", txt, "Int", -1
          , "Ptr", lParam + oRc, "UInt", 0x25)
    return true
}

; A list is only as tall as the rows it holds. Gridlines are drawn across the
; whole control, so a list taller than its contents shows ruled empty rows -
; which read as warehouses, or fields, that came back blank.
ListFit(ctl, rows, maxH) {
    global
    local hLV, hHdr, rc, rowH, hdrH, h, r0, r1, ok0, ok1
    GuiControlGet, hLV, Main:Hwnd, %ctl%
    VarSetCapacity(rc, 16, 0)
    hHdr := DllCall("SendMessage", "Ptr", hLV, "UInt", 0x101F, "Ptr", 0, "Ptr", 0, "Ptr")
    DllCall("GetWindowRect", "Ptr", hHdr, "Ptr", &rc)
    hdrH := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    if (hdrH <= 0)
        hdrH := 22
    ; How tall is one row? Ask the control - but CHECK THE ANSWER.
    ;
    ; LVM_GETITEMRECT sometimes returns FALSE here even with items in the
    ; list, and the old code ignored the return value and read the buffer
    ; anyway. The buffer still held the header rectangle from the GetWindowRect
    ; above it, so a failed call silently reported rowH = hdrH = 24 against a
    ; real row height of 19, and the list was sized for 3 rows plus most of a
    ; fourth: a tall table with ruled empty space under the last warehouse.
    ; It looked like the app was still loading something.
    ;
    ; Three defences, in order:
    ;   - the return value is read, and a failed call measures nothing
    ;   - the pitch between two rows is preferred when there are two, since it
    ;     is the number actually wanted and cannot be confused with anything
    ;   - a measurement outside 12..40 is refused, and the last good one for
    ;     this control is used instead
    static good := {}
    rowH := 0
    if (rows > 1) {
        VarSetCapacity(r0, 16, 0), VarSetCapacity(r1, 16, 0)
        NumPut(0, r0, 0, "Int")     ; LVIR_BOUNDS
        NumPut(0, r1, 0, "Int")
        ok0 := DllCall("SendMessage", "Ptr", hLV, "UInt", 0x100E, "Ptr", 0, "Ptr", &r0)
        ok1 := DllCall("SendMessage", "Ptr", hLV, "UInt", 0x100E, "Ptr", 1, "Ptr", &r1)
        if (ok0 && ok1)
            rowH := NumGet(r1, 4, "Int") - NumGet(r0, 4, "Int")
    }
    if (rowH <= 0 && rows > 0) {
        VarSetCapacity(r0, 16, 0)
        NumPut(0, r0, 0, "Int")
        if DllCall("SendMessage", "Ptr", hLV, "UInt", 0x100E, "Ptr", 0, "Ptr", &r0)
            rowH := NumGet(r0, 12, "Int") - NumGet(r0, 4, "Int")
    }
    if (rowH < 12 || rowH > 40)
        rowH := good[ctl] ? good[ctl] : 20
    else
        good[ctl] := rowH
    h := hdrH + rows * rowH + 4
    if (h > maxH)
        h := maxH
    GuiControl, Main:Move, %ctl%, % "h" h
    FitWindow()
}

; Both tabs end in a list, the list is only as tall as its rows, so the window
; is only as tall as the list. The session line moves with it.
; Without this the parts tab carried 150px of empty grey under the warehouse
; rows - room kept for a vehicle record that was not even on screen.
FitWindow() {
    global
    local tsel, top, bottom, ch, base
    GuiControlGet, tsel, Main:, TabCtl
    if (tsel = "Parts") {
        ; Nothing sits above the part title now, so the tab starts at 112.
        ; These moves still happen rather than being left to BuildGui: the
        ; controls have to come back after a Vehicle-tab visit moved them.
        base := 112
        GuiControl, Main:Move, PartRule,  % "y" (base - gTabDY)
        GuiControl, Main:Move, PartNum,   % "y" (base - gTabDY)
        GuiControl, Main:Move, PartTag,   % "y" (base - gTabDY)
        GuiControl, Main:Move, PartTitle, % "y" (base + 13 - gTabDY)
        GuiControl, Main:Move, TradeLine, % "y" (base + 38 - gTabDY)
        ; the pill shares that row, hard right. It is a child of the window
        ; and not of the tab, so it takes the coordinate untouched - no
        ; gTabDY, unlike every GuiControl move around it.
        ; the band is 30 tall whatever the pill is, so the table does not
        ; move under a part that happens to have an ETA on it
        gPillY := base + 34
        GuiControl, Main:Move, LVStock,   % "y" (base + 68 - gTabDY)
        top := base + 68
        GuiControlGet, lv, Main:Pos, LVStock
    } else {
        top := 182
        GuiControlGet, lv, Main:Pos, LV
    }
    bottom := top + lvH
    if (tsel = "Parts") {
        ; the verdict line, directly under the table it is talking about
        if (gLadFootOn) {
            gLadFootY := bottom + 8
            bottom := bottom + 32
        }
        ; news next - when there is news it is the bottom of what gets read
        ; every move below is inside the tab, so it goes through gTabDY
        if (gNewsOn) {
            GuiControl, Main:Move, NewsHdr, % "y" (bottom + 12 - gTabDY)
            GuiControl, Main:Move, NewsBox, % "y" (bottom + 28 - gTabDY)
            GuiControlGet, nb, Main:Pos, NewsBox
            bottom := bottom + 28 + nbH
        }
        ; then the rail, on whatever that bottom turned out to be
        if (gPriceOn) {
            GuiControl, Main:Move, PriceRule, % "y" (bottom + 12 - gTabDY)
            Loop, 4 {
                GuiControl, Main:Move, PriceLbl%A_Index%, % "y" (bottom + 20 - gTabDY)
                GuiControl, Main:Move, Price%A_Index%, % "y" (bottom + 18 - gTabDY)
            }
            GuiControl, Main:Move, PriceExc, % "y" (bottom + 20 - gTabDY)
            bottom := bottom + 36
        }
    }
    ; the parts list already starts below everything else on its tab, and the
    ; vehicle one starts below the warranty band, so the list bottom IS the
    ; content bottom on both. The floor is only a guard against a zero.
    if (bottom < 200)
        bottom := 200
    GuiControl, Main:Move, TabCtl, % "h" (bottom - 4)
    GuiControl, Main:Move, Sess,   % "y" (bottom + 14)
    ch := bottom + 38
    ; FitWindow runs on startup and on every tab/result change, including while
    ; the window is minimised. Gui,Show is the only way to set the height, so
    ; ask the window itself whether it is minimised and re-assert that state -
    ; a plain Show here would pop it open on top of whatever you were doing.
    ; The live IsIconic beats a flag: nothing can drift out of step with it.
    if (MainHwnd && DllCall("IsIconic", "Ptr", MainHwnd))
        Gui, Main:Show, % "Minimize w490 h" ch
    else
        Gui, Main:Show, % "NoActivate w490 h" ch
    ; the verdict line just moved, so re-place it rather than only raise it
    ApplyPanels()
}

; one call sets the whole band: ground, ink, glyph, sentence, quantity
; One setter for both bands. g is the GUI name and also the control-name
; prefix, so "Band" drives BandGlyph/BandWord/... and "VBand" drives
; VBandGlyph/VBandWord/...
PanelBandSet(g, hwnd, state, word, right) {
    bg  := (state = "yes") ? "E4F2E4" : (state = "no") ? "F7E6E6" : "F2F2F2"
    ink := (state = "yes") ? "1B7F1B" : (state = "no") ? "B00000" : "5A5A5A"
    Gui, %g%:Color, %bg%
    for i, part in ["Glyph", "Word", "Qty"] {
        n := g . part
        GuiControl, %g%:+c%ink%, %n%
    }
    n := g "Glyph"
    GuiControl, %g%:, %n%, % SupGlyph(state)
    n := g "Word"
    GuiControl, %g%:, %n%, %word%
    n := g "Qty"
    GuiControl, %g%:, %n%, %right%
    ; the ground changed under every control, so repaint the whole panel
    if (hwnd)
        WinSet, Redraw, , ahk_id %hwnd%
}

; -------------------------------------------------------- the verdict line
; The verdict band answered "is it in Melbourne". Nobody is asking that. The
; question on the counter is "when can the customer have it", and against
; that question a two-week transfer from Brisbane was being drawn as a red
; failure. v2.6 answered it with a ladder of coloured rows above the part
; title - which then said branch, quantity, branch, quantity a second time in
; the warehouse table three inches below. The table won.
; So the state now lives ON the warehouse row - glyph column plus a tint,
; drawn by OnNotify:
;   green, heavy tick   - Melbourne holds it, it is on the shelf
;   amber, hourglass    - that branch holds it, about two weeks to get here
;   quiet grey dot      - this branch is not the one to ring
; and the line UNDER the table exists only for an answer no row can give:
;   red, heavy cross    - nothing anywhere, factory order 6 to 8 weeks
;   amber, hourglass    - ...unless the news says DIRECT SHIP ITEM, which is
;                         a different wait entirely: 2 to 3 weeks, not 6 to 8
;   grey question mark  - no such part number
; Row states are "stock" / "wait" / "dead"; the line uses "none" / "ask".
LadGlyph(state) {
    if (!A_IsUnicode)
        return (state = "stock") ? "OK" : (state = "wait") ? "~" : (state = "none") ? "X" : "-"
    if (state = "stock")
        return Chr(0x2714)      ; heavy check mark
    if (state = "wait")
        return Chr(0x231B)      ; hourglass
    if (state = "none")
        return Chr(0x2716)      ; heavy multiplication x
    if (state = "ask")
        return "?"
    return Chr(0x25CF)          ; a dead branch gets a quiet dot
}

LadBg(state) {
    if (state = "stock")
        return "E4F2E4"
    if (state = "wait")
        return "FDF1DC"
    if (state = "none")
        return "F7E6E6"
    if (state = "ask")
        return "F2F2F2"
    return "FFFFFF"
}

; the glyph carries a touch more saturation than the words beside it - it is
; the thing being spotted from across the room, the words are read after
LadInk(state, which) {
    ; "eta" is the small second line inside the pill: the same hue, lifted
    ; towards its own background so it reads as a footnote to the word above
    ; it rather than as a second thing to read.
    if (state = "stock")
        return (which = "glyph") ? "1B7F1B" : (which = "eta") ? "4E8C4E" : "166B16"
    if (state = "wait")
        return (which = "glyph") ? "C07800" : (which = "eta") ? "B07C2E" : "9A5600"
    if (state = "none")
        return (which = "glyph") ? "C33333" : (which = "eta") ? "C05A5A" : "A50E0E"
    if (state = "ask")
        return "5A5A5A"
    return (which = "glyph") ? "CFCFCF" : "8A8A8A"
}

; A ListView has no per-row colour anywhere in its AHK interface, and the
; control paints itself in the system's colours. NM_CUSTOMDRAW is the way in:
; before it paints, the list asks its parent what to do, and we answer twice -
; once for the row (ground and ink) and once for the glyph column - the last
; one, subitem 6 - which carries a touch more saturation than the numbers
; beside it.
; Every early return here is a BARE return: a value returned from a WM_NOTIFY
; monitor becomes the message result, and swallowing the notifications meant
; for the Link control or the vehicle list would break both.
OnNotify(wParam, lParam, msg, hwnd) {
    global LVStockHwnd, gRowState
    if (NumGet(lParam + 0, "Ptr") != LVStockHwnd)
        return
    if (NumGet(lParam + 2 * A_PtrSize, "Int") != -12)          ; NM_CUSTOMDRAW
        return
    oStage := (A_PtrSize = 8) ? 24 : 12
    oItem  := (A_PtrSize = 8) ? 56 : 36
    oText  := (A_PtrSize = 8) ? 80 : 48
    oBack  := (A_PtrSize = 8) ? 84 : 52
    oSub   := (A_PtrSize = 8) ? 88 : 56
    stage := NumGet(lParam + oStage, "UInt")
    if (stage = 1)                                             ; CDDS_PREPAINT
        return 0x20                                     ; CDRF_NOTIFYITEMDRAW
    row := NumGet(lParam + oItem, "UPtr") + 1
    st := gRowState[row]
    if (st = "")
        st := "dead"
    if (stage = 0x10001) {                                ; CDDS_ITEMPREPAINT
        if (st != "dead") {
            NumPut(LadBGR(LadInk(st, "text")), lParam + oText, "UInt")
            NumPut(LadBGR(LadBg(st)),          lParam + oBack, "UInt")
        }
        return 0x20                                  ; CDRF_NOTIFYSUBITEMDRAW
    }
    if (stage != 0x30001)                    ; CDDS_SUBITEM|CDDS_ITEMPREPAINT
        return
    ; Every branch here sets clrText, none of them may fall through: the
    ; struct is REUSED for each subitem, so whatever colour the last one
    ; asked for is still sitting in it. Leaving it alone painted the whole
    ; dead row in the grey meant only for its dot.
    ; The numbers on a dead row stay black - they are still read. Only its
    ; glyph goes grey, so the lit row is the only thing on screen with colour.
    if (NumGet(lParam + oSub, "Int") = 6)
        NumPut(LadBGR(st = "dead" ? "B4B4B4" : LadInk(st, "glyph")), lParam + oText, "UInt")
    else if (st = "dead")
        NumPut(0xFF000000, lParam + oText, "UInt")             ; CLR_DEFAULT
    else
        NumPut(LadBGR(LadInk(st, "text")), lParam + oText, "UInt")
    return 0x2                                                 ; CDRF_NEWFONT
}

; RRGGBB text -> the BBGGRR integer GDI wants. Via a variable and += 0: a hex
; STRING comes back blank from concatenation in an expression and is rejected
; outright by the bitwise operators.
LadBGR(hex) {
    v := "0x" hex
    v += 0
    return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

; state "" hides the line, anything else shows it with that text
; The pill takes the same state names as the row tint did: "stock", "wait",
; "none". An empty state hides it - a part number that does not exist has
; nothing to summarise.
;
; It carries the wait now, on a small second line, because the banner that
; used to carry it under the table is gone. One object holds the whole answer:
; what the part is doing, and how long it takes.
;
; IN STOCK gets no second line - there is nothing to wait for - so the pill is
; 20 tall on that state and 30 on the others, and the glyph re-centres itself
; between them.
;
; The width is measured, not guessed. It was a fixed number per state while
; the four strings were fixed, and then one of them became a branch name -
; Brisbane, Headquarters, or a bare warehouse number nobody has mapped - and
; a guessed width would clip whichever one nobody thought of.
; PillTextW() asks the font itself, so any wording change is safe.
PillSet(state, word, eta := "") {
    global gPillOn, gPillHwnd, gPillW, gPillH
    gPillOn := (state != "")
    if (!gPillOn)
        return
    ; text starts at x26, and 9 of padding on the right of the longer line
    ww := PillTextW("PillWord", word)
    we := (eta != "") ? PillTextW("PillEta", eta) : 0
    gPillW := 35 + ((ww > we) ? ww : we)
    gPillH := (eta != "") ? 30 : 20
    gl := LadInk(state, "glyph")
    tx := LadInk(state, "text")
    et := LadInk(state, "eta")
    Gui, Pill:Color, % LadBg(state)
    GuiControl, Pill:+c%gl%, PillGlyph
    GuiControl, Pill:+c%tx%, PillWord
    GuiControl, Pill:+c%et%, PillEta
    ; the text block is the pill less the glyph on its left and the padding
    ; on its right, so a long ETA is not clipped by a control that never moved
    tw := gPillW - 35
    GuiControl, Pill:Move, PillGlyph, % "y" ((eta != "") ? 6 : 1)
    GuiControl, Pill:Move, PillWord, % "y4 w" tw
    GuiControl, Pill:Move, PillEta, % "y17 w" tw
    GuiControl, Pill:, PillGlyph, % LadGlyph(state)
    GuiControl, Pill:, PillWord, %word%
    GuiControl, Pill:, PillEta, %eta%
    if (gPillHwnd)
        WinSet, Redraw, , ahk_id %gPillHwnd%
}

; How wide is this string in the font that control is actually using? Asked of
; the control's own HFONT, so it stays right if the font is ever changed in
; BuildPanels rather than here.
PillTextW(ctl, text) {
    if (text = "")
        return 0
    GuiControlGet, h, Pill:Hwnd, %ctl%
    if (!h)
        return 0
    hFont := DllCall("SendMessage", "Ptr", h, "UInt", 0x31, "Ptr", 0, "Ptr", 0, "Ptr")
    hDC := DllCall("GetDC", "Ptr", h, "Ptr")
    old := DllCall("SelectObject", "Ptr", hDC, "Ptr", hFont, "Ptr")
    VarSetCapacity(sz, 8, 0)
    DllCall("GetTextExtentPoint32", "Ptr", hDC, "Str", text, "Int", StrLen(text), "Ptr", &sz)
    w := NumGet(sz, 0, "Int")
    DllCall("SelectObject", "Ptr", hDC, "Ptr", old)
    DllCall("ReleaseDC", "Ptr", h, "Ptr", hDC)
    return w + 2          ; 2 for ClearType overhang past the reported extent
}

LadFootSet(state, text) {
    global gLadFootOn, gLadFootHwnd
    gLadFootOn := (state != "")
    if (!gLadFootOn)
        return
    gl := LadInk(state, "glyph")
    tx := LadInk(state, "text")
    Gui, LadF:Color, % LadBg(state)
    GuiControl, LadF:+c%gl%, LadGF
    GuiControl, LadF:+c%tx%, LadNF
    GuiControl, LadF:, LadGF, % LadGlyph(state)
    GuiControl, LadF:, LadNF, %text%
    if (gLadFootHwnd)
        WinSet, Redraw, , ahk_id %gLadFootHwnd%
}

; Reads the warehouse rows - already sorted Melbourne first - and works out
; which one is worth acting on. Melbourne wins if it holds any; otherwise the
; first branch that does, and that one is a backorder; otherwise nobody does.
; Leaves gRowState for the custom draw and writes the line under the table.
; The lead times are ours, not IDS's: DC210 returns no ETA of any kind, so
; these two strings are the promise the app makes on the branch's behalf.
LadderSet(ordered, news := "", part := "") {
    global gRowState, gLadNone, gLadPart
    gLadPart := part
    pick := 0
    pickState := ""
    for i, r in ordered {
        if (!WhsHasStock(r.avail))
            continue
        if (WhsRank(r.whs) = 1) {
            pick := i
            pickState := "stock"
            break
        }
        if (!pick) {
            pick := i
            pickState := "wait"
        }
    }
    gRowState := []
    gLadNone := false
    for i, r in ordered
        gRowState.Push((i = pick) ? pickState : "dead")
    if (!ordered.Length()) {
        PillSet("", "", "")
        LadFootSet("ask", "No warehouse detail came back for this part")
        return
    }
    if (!pick) {
        gLadNone := true
        LadFootNone(news)
        return
    }
    if (pickState = "stock")
        PillSet("stock", "IN STOCK")
    else {
        ; Not ON ORDER - the branch's own name. The amber state means one
        ; other branch has it on the shelf, and which branch that is IS the
        ; answer: it says who to ring without reading the table for it.
        nm := WhsName(ordered[pick].whs)
        if (nm = "")
            nm := "WHS " ordered[pick].whs
        PillSet("wait", Format("{:U}", nm), "ETA about 2 weeks")
    }
    ; A branch that can supply it has already said so on its own row - the
    ; tint, the tick, the hourglass and the quantity are all right there. The
    ; line only speaks for the answer that belongs to no row at all.
    LadFootSet("", "")
}

; --------------------------------------------------- the direct-ship list
; 716 part numbers lifted from "IUA Accessory List - 09MY-25.5MY V19 - Sep26",
; every row on every sheet whose ORDERING ROUTE column reads DIRECT SHIP.
; They are here rather than in a file beside the script because this tool is
; handed to people as one .ahk and nothing else - a second file is a second
; thing to lose.
;
; Why it is needed at all: a direct-ship part shows Nil at every warehouse,
; which is the same picture DC210 paints for a part that has to be built. The
; news bulletin says DIRECT SHIP ITEM on some of them and says nothing on the
; rest, so the news alone gets it wrong more often than it gets it right.
;
; To refresh it when a new list is issued: pull column PART NUMBER from every
; sheet where ORDERING ROUTE says DIRECT SHIP, uppercase, strip spaces,
; de-duplicate, sort, and regenerate the block below. Nothing else changes.
;
; One string with a pipe on both ends of every number, so InStr("|X|") cannot
; match a longer number that merely contains X. Built once, on first use.
DirectShipList() {
    static s := ""
    if (s != "")
        return s
    s .= "|08A0TMAT02|08A0TMAT03|08A0TMAT04|08A0TMAT05|08A0TMAT07|08A0TMAT08"
    s .= "|08A0TMAT09|08A0TMAT11|08A0TMP504|08A0TMP520|08A0TMP877|08A0TMP936"
    s .= "|08C0TMAT41|08C0TMAT42|08C0TMAT43|08C0TMAT51|08C0TMAT52|08C0TMAT53"
    s .= "|08C0TMAT61|08C0TMAT62|08C0TMAT63|08D0ARCN01|08D0EGSB01|08D0THRR03"
    s .= "|08D0THRR04|08D0THRR05|08D0THRR06|08D1ARCN01|08D1ARCN02|08D1ARCN03"
    s .= "|08D1ARCN04|08D1ARCN05|08D1ARCN06|08D1ARCN07|08D1ARCN08|08D1ARCN09"
    s .= "|08D1ARCN10|08D1ARCN11|08D1ARCN12|08D1EGHT01|08D1EGHT02|08D2ARCN01"
    s .= "|08D2ARCN02|08D2ARCN03|08D2ARCN04|08D2ARCN05|08D2ARCN06|08D2ARCN07"
    s .= "|08D2ARCN08|08D2ARCN09|08D2ARCN10|08D2ARCN11|08D2ARCN12|08D2EGHT01"
    s .= "|08D2EGHT02|08D3ARCN01|08D3ARCN02|08D3ARCN03|08D3ARCN04|08D3ARCN05"
    s .= "|08D3ARCN06|08D3ARCN07|08D3ARCN08|08D3ARCN09|08D3ARCN10|08D3ARCN11"
    s .= "|08D3ARCN12|08D3EGHT01|08D3EGHT02|08D4ARCN01|08D4ARCN02|08D4ARCN03"
    s .= "|08D4ARCN04|08D4ARCN05|08D4ARCN06|08D4ARCN07|08D4ARCN08|08D4ARCN09"
    s .= "|08D4ARCN10|08D4ARCN11|08D4ARCN12|08D4EGHT01|08D4EGHT02|08D5ARCN01"
    s .= "|08D5ARCN02|08D5ARCN03|08D5ARCN04|08D5ARCN05|08D5ARCN06|08D5ARCN07"
    s .= "|08D5ARCN08|08D5ARCN09|08D5ARCN10|08D5ARCN11|08D5ARCN12|08D5EGHT01"
    s .= "|08D5EGHT02|08D6EGHT02|08D7ARCN01|08D7ARCN02|08D7ARCN03|08D7ARCN04"
    s .= "|08D7ARCN05|08D7ARCN06|08D7ARCN07|08D7ARCN08|08D7ARCN09|08D7ARCN10"
    s .= "|08D7ARCN11|08D7ARCN12|08D7EGHT01|08D7EGHT02|08D8EGHT02|08D9ARCN01"
    s .= "|08D9ARCN02|08D9ARCN03|08D9ARCN04|08D9ARCN05|08D9ARCN06|08D9ARCN07"
    s .= "|08D9ARCN08|08D9EGHT02|08E0TMAT41|08E0TMAT42|08E0TMAT43|08E0TMAT51"
    s .= "|08E0TMAT52|08E0TMAT53|08E0TMAT61|08E0TMAT62|08E0TMAT63|08S0TMAT41"
    s .= "|08S0TMAT42|08S0TMAT43|08S0TMAT51|08S0TMAT52|08S0TMAT53|08S0TMAT61"
    s .= "|08S0TMAT62|08S0TMAT63|12010|32140|32144|32145"
    s .= "|33114|33118|5411686010|5411689001|5411689001D|5411689011"
    s .= "|5411689011D|5411689021|5411689021D|5411689031|5411689031D|5411689041"
    s .= "|5411689041D|5411689051|5411689051D|5411689061|5411689061D|5411689071"
    s .= "|5411689071D|5421686010|5421689001|5421689001D|5421689011|5421689011D"
    s .= "|5421689021|5421689021D|5421689031|5421689031D|5421689041|5421689041D"
    s .= "|5421689051|5421689051D|5421689061|5421689061D|5421689071|5421689071D"
    s .= "|5421689131|5421689141|5422621010|5422621030|5422621042|5422621052"
    s .= "|5422621062|5422622010|5422622030|5422622042|5422622052|5422622062"
    s .= "|5422623010|5422623030|5422623042|5422623052|5422623062|5422624010"
    s .= "|5422624030|5422624042|5422624052|5422624062|5422624242|5422624252"
    s .= "|5422624262|5422625000|5422625010|5422625020|5422625030|5422625042"
    s .= "|5422625052|5422625062|5422626000|5422626010|5422626020|5422626040"
    s .= "|5422626100|5422627010|5422627030|5422627042|5422627052|5422627062"
    s .= "|5422628010|5422628030|5422628042|5422628052|5422628062|5422628110"
    s .= "|5422628130|5422628142|5422628152|5422628162|5422629042|5422629052"
    s .= "|5422629062|5422629510|5422629530|5422629542|5422629552|5422629562"
    s .= "|5422811010|5422812010|5422813110|5422813210|5422814310|5422815010"
    s .= "|5422816010|5422818210|5422912010|5422912020|5422915010|5431689001"
    s .= "|5431689001D|5431689011|5431689011D|5431689021|5431689021D|5431689031"
    s .= "|5431689031D|5431689041|5431689041D|5431689051|5431689051D|5431689061"
    s .= "|5431689061D|5431689071|5431689071D|5432912010|5432915010|5441681000"
    s .= "|5441682000|5441683000|5441684000|5441685000|5441687000|5441688000"
    s .= "|5441688100|5441689000|5441689010|5441689030|5441689050|5441689060"
    s .= "|5441689070|5441689080|5441689100|5441689110|5441689120|5441689500"
    s .= "|5443636061|5443636110|5443636120|5443636130|5443636210|5443936010"
    s .= "|5452636010|5452636020|5452636030|5452915010|5452916010|5463636140"
    s .= "|5463636220|5463636230|5522621010|5522622010|5522622030|5522623110"
    s .= "|5522623130|5522623142|5522623152|5522623162|5522624010|5522624030"
    s .= "|5522625010|5522625030|5522626050|5522627010|5522627030|5522628110"
    s .= "|5522628130|5522629510|5522629530|5541683100|5541686010|5622621020"
    s .= "|5622622020|5622623120|5622623220|5622624320|5622625020|5622628220"
    s .= "|5622629020|5641621020|5641622020|5641623120|5641623220|5641624320"
    s .= "|5641625020|5641628220|5641629020|5643636012|570|572"
    s .= "|5722623210|5722623230|5722623242|5722623252|5722623262|5722624310"
    s .= "|5722624330|5722624342|5722624352|5722624362|5722628210|5722628230"
    s .= "|5722628242|5722628252|5722628262|5741683200|5741684300|5741688200"
    s .= "|5743631020|5743632020|5743633120|5743633220|5743634320|5743635020"
    s .= "|5743638220|576|5763631020|5763631120|5763632020|5763633120"
    s .= "|5763635020|5763637220|5763638220|5822626001|5822626002|5822626003"
    s .= "|5822626004|5822626500|5867632010|5867632020|5867632080|5867632090"
    s .= "|5867632100|5867632110|5867632130|5867632140|5867632150|5867632160"
    s .= "|5867632170|5867632180|5867632190|5867632200|5867632210|5867632230"
    s .= "|5867632240|5867632250|5867632260|5867632270|5867632281|5867632291"
    s .= "|5867632301|5867632311|5867632331|5867632341|5867632351|5867632361"
    s .= "|5867632371|5867632380|5867632390|5867632961|5867632971|5867632981"
    s .= "|5867632991|5867633011|5867633021|5867633031|5867633041|5867633051"
    s .= "|5867633061|5867633071|5867633081|5867633091|5867633111|5867633121"
    s .= "|5867633131|5867633141|5867633151|5867633220|5867633270|5867633280"
    s .= "|5867633290|5867633300|5867633310|5867633320|5867633330|5867633340"
    s .= "|5867633350|5867633370|5867633380|5867641190|5867641510|5867641570"
    s .= "|5867645280|5867645290|5867645300|5867645310|5867645320|5867645330"
    s .= "|5867645340|5867645350|5867645360|5867645370|5867645380|5867645390"
    s .= "|5867645400|5867645410|5867645420|5867648400|5867648410|5867648420"
    s .= "|5867648430|5867648440|5867648450|5867648460|5867648470|5867648480"
    s .= "|5867648490|5867648500|5867648510|5867648520|5867648530|5867648540"
    s .= "|5867648550|5867648560|5867648570|5867648580|5867648590|5867648600"
    s .= "|5867648610|5867648620|5867648630|5867648640|5867648650|5867648660"
    s .= "|5867648670|5867648680|5867648690|5867648700|5867648710|5867648720"
    s .= "|5867648730|5867648740|5867648750|5867648760|5867648770|5867648780"
    s .= "|5867648790|5867648800|5867648810|5867648820|5867648830|5867648840"
    s .= "|5867648850|5867648860|5867648870|5867648880|5867648890|5867648940"
    s .= "|5867658200|5867658210|5867658220|5867658280|5867658290|5943636110"
    s .= "|6111686110|6111686110D|6111686120|6111686120D|6111686130|6111686130D"
    s .= "|6111686140|6111686140D|6111686150|6111686150D|6111686210|6111686210D"
    s .= "|6111686220|6111686220D|6111686230|6111686230D|6111686240|6111686240D"
    s .= "|6111686250|6111686250D|6121686110|6121686110D|6121686120|6121686120D"
    s .= "|6121686130|6121686130D|6121686140|6121686140D|6121686150|6121686150D"
    s .= "|6121686210|6121686210D|6121686220|6121686220D|6121686230|6121686230D"
    s .= "|6121686240|6121686240D|6121686250|6121686250D|6122621060|6122621160"
    s .= "|6122622160|6122623160|6122624360|6122625160|6122626060|6122628260"
    s .= "|6122912010|6122915010|6122915020|6122916010|6131686110|6131686110D"
    s .= "|6131686120|6131686120D|6131686130|6131686130D|6131686140|6131686140D"
    s .= "|6131686150|6131686150D|6131686210|6131686210D|6131686220|6131686220D"
    s .= "|6131686230|6131686230D|6131686240|6131686240D|6131686250|6131686250D"
    s .= "|6132912010|6132915010|6132915020|6141621050|6141621150|6141622150"
    s .= "|6141623150|6141624350|6141625150|6141626050|6141628250|6141681010"
    s .= "|6141681110|6141682110|6141683110|6141684310|6141685110|6141686410"
    s .= "|6141686420|6141686430|6141686440|6141686450|6141686460|6141686470"
    s .= "|6141686480|6141686490|6141686500|6141686510|6141688210|6142636010"
    s .= "|6143636010|6143636020|6143636031|6143636041|6143636050|6143936010"
    s .= "|6151636020|6152636020|6152636051|6152636060|6152636070|6152915010"
    s .= "|6152915020|6152916010|6152916040|6152916070|6152916100|6152916110"
    s .= "|6152916120|6152916130|62110|62111|62113|6322621260"
    s .= "|6322623360|6322624460|6341621250|6341624450|6341681210|6341684410"
    s .= "|6441683310|9PMFDMAX4|A0556M0010|A0556M0020|A0556M0081|A0562R0100-000"
    s .= "|A0562R0100-527|A0562R0100-554|A0562R0100-564|A0562R0100-568|A0562R0100-569|A0562R0100-575"
    s .= "|A0562R0100-587|A0562R0100-588|A0562R0110-000|A0562R0110-527|A0562R0110-554|A0562R0110-564"
    s .= "|A0562R0110-568|A0562R0110-569|A0562R0110-575|A0562R0110-587|A0562R0110-588|A0562S0100-401"
    s .= "|A0562S0110-401|A0575S0200-401|A1390M0050|A1390M0080|A1924M0010|A1924M0020"
    s .= "|CVC-IU-DX20-FSIEB|CVC-IU-DX20-FSIEC|CVC-IU-DX20-HFSIEB|CVC-IU-DX20-HFSIEC|CVC-IU-DX20-SIEB|CVC-IU-DX20-SIEC"
    s .= "|CVC-IU-MX25-HVFSIEB|CVC-IU-MX25-HVFSIEC|CVNG-HI-DC2012-FIEB|CVNG-HI-DC2012-FIEC|CVNG-HI-DC2012-IEB|CVNG-HI-DC2012-IEC"
    s .= "|CVNG-IU-DX20-FSIEB|CVNG-IU-DX20-FSIEC|CVNG-IU-DX20-HFSIEB|CVNG-IU-DX20-HFSIEC|CVNG-IU-DX20-SIEB|CVNG-IU-DX20-SIEC"
    s .= "|CVNG-IU-MX25-HVFSIEB|CVNG-IU-MX25-HVFSIEC|EVO-10-S-103253|IUA1410-LB2-RC|IUA43RS3.5|IUA44RS3.5"
    s .= "|JA9671|JC-01257|JC-01335|JC-01519|JC-01690|JC-01695N"
    s .= "|JC-01806|JC-02183|JC-02188|JC-02309|JC-04622|LB350"
    s .= "|RBC050|WAG-H08-0003569"
    s .= "|"
    return s
}

; Is this the kind of part that never sees a warehouse shelf?
IsDirectShipPart(part) {
    part := StrReplace(Trim(part), " ", "")
    if (part = "")
        return false
    ; InStr is case-blind by default, which is what we want: IDS returns these
    ; in upper case and the list is stored that way, but a lower-case one
    ; typed by hand should still match.
    return InStr(DirectShipList(), "|" part "|") ? true : false
}

; Nothing anywhere - but "nothing anywhere" has two meanings, and the
; warehouse rows cannot tell them apart. A direct-ship part does not come
; through a branch at all: it ships from the supplier, and that is 2 to 3
; weeks, not the 6 to 8 a factory order takes. Same absence on the shelf, less
; than half the wait, so it is drawn as a wait (amber, hourglass) and not as a
; failure. Both times are ours, not IDS's: DC210 returns no ETA of any kind.
; Two ways to know, and either one is enough:
;   - the part is in the IUA accessory list above, which is the reliable one
;   - the news bulletin says DIRECT SHIP ITEM, which catches anything the list
;     has not caught up with yet
; The news usually lands AFTER the result is drawn - cached news arrives with
; it, live news a moment later - so NewsShow() calls this again every time the
; text changes, and gLadNone says whether the line is ours to rewrite.
LadFootNone(news) {
    global gLadPart
    ; no line under the table any more: the pill says it, and saying it twice
    ; on one screen was the same duplication the ladder was deleted for
    LadFootSet("", "")
    if (IsDirectShipPart(gLadPart) || InStr(news, "DIRECT SHIP"))
        PillSet("wait", "DIRECT SHIP", "ETA 2 weeks")
    else
        PillSet("none", "BACKORDER", "ETA 6-8 weeks")
}

; no such part: no branches to rank, one grey line saying why
LadderNotFound() {
    global gRowState, gLadNone, gLadPart
    gRowState := []
    PillSet("", "", "")
    gLadNone := false
    gLadPart := ""
    LadFootSet("ask", "No such part number")
}

LadderClear() {
    global gRowState, gLadNone, gLadPart
    gRowState := []
    PillSet("", "", "")
    gLadNone := false
    gLadPart := ""
    LadFootSet("", "")
}

; clear the four price cells back to blank
ClearPartPanels() {
    Loop, 4
        GuiControl, Main:, Price%A_Index%,
    GuiControl, Main:, TradeLine,
    PriceRailShow(false)
    LadderClear()
}

; the rail is hidden until there is a record to price, so a cleared screen
; does not carry four empty labels and a hairline
PriceRailShow(on) {
    global gPriceOn
    gPriceOn := on
    if (on) {
        GuiControl, Main:Show, PriceRule
        GuiControl, Main:Show, PriceExc
        Loop, 4 {
            GuiControl, Main:Show, PriceLbl%A_Index%
            GuiControl, Main:Show, Price%A_Index%
        }
    } else {
        GuiControl, Main:Hide, PriceRule
        GuiControl, Main:Hide, PriceExc
        Loop, 4 {
            GuiControl, Main:Hide, PriceLbl%A_Index%
            GuiControl, Main:Hide, Price%A_Index%
        }
    }
}

; The Item News box. "" hides it, label included; anything else shows it and
; sizes it to every line it holds, so nothing is ever scrolled out of sight.
; The count has to come from the control, not from the text: one bulletin
; line wraps to two or three at 450px wide, and counting `n gave a box that
; was short by exactly the wrapped rows - the "cut off at the bottom" bug.
NewsShow(text) {
    global gNewsOn, gNewsText, gLadNone
    text := Trim(text, " `t`r`n")
    ; Repainting the same words is not free: the box is resized and the whole
    ; window with it, so an identical repaint reads as a flicker for no
    ; reason. A result is drawn twice on a repeat lookup - saved copy, then
    ; the live one - and both carry the same cached news.
    if (text = gNewsText)
        return
    gNewsText := text
    ; the news can change what the line under the table says - see LadFootNone
    if (gLadNone)
        LadFootNone(text)
    if (text = "") {
        gNewsOn := false
        GuiControl, Main:Hide, NewsHdr
        GuiControl, Main:Hide, NewsBox
        GuiControl, Main:, NewsBox,
        FitWindow()
        return
    }
    GuiControl, Main:, NewsBox, % StrReplace(text, "`n", "`r`n")
    GuiControlGet, hNews, Main:Hwnd, NewsBox
    ; EM_GETLINECOUNT counts DISPLAY lines on a wrapping Edit, which is the
    ; number we actually need
    SendMessage, 0xBA, 0, 0, , ahk_id %hNews%       ; EM_GETLINECOUNT
    lines := ErrorLevel
    if (lines < 1)
        lines := 1
    lh := NewsLineHeight(hNews, lines)
    ; A bulletin long enough to run off the screen is the one case left for a
    ; scrollbar. Everything short of that is shown whole.
    maxH := A_ScreenHeight - 420
    if (maxH < 120)
        maxH := 120
    h := lines * lh + 8
    if (h > maxH) {
        h := maxH
        GuiControl, Main:+0x200000, NewsBox        ; WS_VSCROLL
    } else {
        GuiControl, Main:-0x200000, NewsBox
    }
    GuiControl, Main:Move, NewsBox, % "h" h
    gNewsOn := true
    GuiControl, Main:Show, NewsHdr
    GuiControl, Main:Show, NewsBox
    FitWindow()
}

; Height of one line in the news Edit, asked of the control rather than
; assumed, so a display at 125% does not clip the last row.
NewsLineHeight(hNews, lines) {
    if (lines > 1) {
        SendMessage, 0xBB, 1, 0, , ahk_id %hNews%   ; EM_LINEINDEX, line 2
        idx := ErrorLevel
        SendMessage, 0xD6, 0, 0, , ahk_id %hNews%   ; EM_POSFROMCHAR
        y0 := (ErrorLevel >> 16) & 0xFFFF
        SendMessage, 0xD6, %idx%, 0, , ahk_id %hNews%
        y1 := (ErrorLevel >> 16) & 0xFFFF
        if (y0 > 0x7FFF)
            y0 -= 0x10000
        if (y1 > 0x7FFF)
            y1 -= 0x10000
        if (y1 - y0 > 0)
            return y1 - y0
    }
    return 17
}

; News changes about as often as a part number does, so it is cached beside
; the part result: a repeat lookup shows it instantly and the live walk only
; has to confirm it.
NewsCacheRead(part) {
    if (part = "")
        return ""
    f := CacheFile("news", part)
    if !FileExist(f)          ; FileRead throws on a missing file
        return ""
    FileRead, t, %f%
    return Trim(t, "`r`n")
}

NewsCacheWrite(part, text) {
    if (part = "")
        return
    f := CacheFile("news", part)
    SafeDelete(f)
    if (text != "")
        FileAppend, %text%, %f%
}

; Active / Discount code / Class are trade detail, not what the warehouse reads
; off the screen. Off by default, remembered per user in settings.ini.
MenuToggleTrade:
    gShowTrade := !gShowTrade
    if (gShowTrade)
        Menu, SetMenu, Check, Show trade fields (Parts)
    else
        Menu, SetMenu, Uncheck, Show trade fields (Parts)
    IniWrite, % (gShowTrade ? 1 : 0), %gIni%, View, ShowTradeFields
    if (gLastPartRes != "")
        ShowResult(gLastPartRes, "part")
return

; A ticked field is a shown field - the tick reads as "I want this", which is
; the way round people expect a settings list to work.
MenuToggleVinField:
    k := gVinKeyOf[A_ThisMenuItem]
    if (k = "")
        return
    if (gVinHide.HasKey(k)) {
        gVinHide.Delete(k)
        Menu, VinMenu, Check, % A_ThisMenuItem
    } else {
        gVinHide[k] := true
        Menu, VinMenu, Uncheck, % A_ThisMenuItem
    }
    SaveVinHide()
    if (gLastVinRes != "")
        ShowResult(gLastVinRes, "vin")
return

MenuVinFieldsReset:
    gVinHide := {}
    for i, k in gVinOrder {
        label := gVinPretty[k] ? gVinPretty[k] : k
        Menu, VinMenu, Check, %label%
    }
    SaveVinHide()
    if (gLastVinRes != "")
        ShowResult(gLastVinRes, "vin")
return

; Clicking an old number looks it up EXACTLY as clicked - no jump forward -
; so someone can check what a customers paperwork actually says.
SupClick:
    if (gBusy)
        return
    ; a link with no id or href reports only its index, and it arrives in
    ; A_EventInfo - A_GuiControlEvent is blank, which silently ate the click
    idx := A_EventInfo
    if (idx = "")
        idx := A_GuiControlEvent
    if idx is not integer
        return
    n := gSupNums[idx]
    if (n = "")
        return
    gNoJump := true
    GuiControl, Main:, PartInput, %n%
    GuiControl, Main:Focus, PartInput
    SetTimer, DoLookup, -10
return

; the jump notice has done its job after a few seconds; the standing
; "superseded" warning never gets this timer set on it
SupFade:
    GuiControl, Main:, SupLine,
    gSupNums := []
return

; put the caret in the box the user is about to type into
TabChanged:
    GuiControlGet, tsel, Main:, TabCtl
    PanelsShow("")     ; coloured panels are not tab-aware on their own
    FitWindow()        ; the two tabs do not need the same height
    ; the Look up button is shared and lives outside the tabs, so there is no
    ; default button to move any more - PanelsShow() has already raised it
    GuiControl, Main:Focus, % (tsel = "Parts" ? "PartInput" : "VinInput")
    if (gReady && !gBusy)
        SetStatus(tsel = "Parts" ? "Type a part number and press Enter." : "Type a VIN, rego, serial or engine number and press Enter.")
return

InitSession:
    gBusy := true
    ; gBusy MUST clear even if setup throws, or every later lookup is stuck
    ; on "Busy - wait a moment" until the app is restarted
    try {
        tInit := A_TickCount
        SetStatus("Starting up - you can type while it warms up.")
        SetSessState("working", "starting the background browser...")
        if !EnsureChrome() {
            SetStatus("Could not start the background browser. Close the app and open it again.")
            SetSessState("down", "background browser would not start")
            return
        }
        if !OpenPage() {
            SetStatus("Could not open the Isuzu site. Check your internet connection.")
            SetSessState("down", "cannot reach Isuzu")
            return
        }
        if (gAttached && IsLoggedIn() && SessionAlive()) {
            gReady := true
            gLastOk := A_TickCount
            SLog("startup: reused running session")
            SetStatus("Ready. Type a part number and press Enter.")
        } else {
            SetStatus("Signing in...")
            SetSessState("working", "signing in...")
            if !RecoverSession() {
                SetStatus("Sign-in failed. The IDS password may have changed, or the account is locked.")
                SetSessState("down", "sign-in failed")
                return
            }
            gReady := true
            gLastOk := A_TickCount
            SLog("startup: signed in fresh")
            SetStatus("Ready. Type a part number and press Enter.")
        }
        CleanupForms()
        DetectPoke()
        SetSessState("ready", "signed in, kept awake automatically")
        SetTimer, KeepAlive, %CFG_KEEPALIVE%
        if (gSelfTest != "") {
            stv := gSelfTest
            ; --selftest part:8982488221 tests the Parts tab
            if (SubStr(stv, 1, 5) = "part:") {
                stv := SubStr(stv, 6)
                GuiControl, Main:Choose, TabCtl, 1
                GuiControl, Main:, PartInput, %stv%
            } else {
                GuiControl, Main:Choose, TabCtl, 2
                GuiControl, Main:, VinInput, %stv%
            }
            SetTimer, DoLookup, -500
        } else if (gPending) {
            ; someone typed and pressed Enter while we were still signing in
            gPending := false
            SetTimer, DoLookup, -50
        }
    } catch e {
        SLog("startup error: " e.Message " (line " e.Line ")")
        SetStatus("Something went wrong starting up: " e.Message ". Close the app and open it again.")
        SetSessState("down", "startup failed")
    } finally {
        gBusy := false
    }
return

DoLookup:
    Gui, Main:Submit, NoHide
    ; the tab picks both the field and the kind - one Look up button per tab,
    ; both land here, and Enter anywhere fires the default button
    if (TabCtl = "Parts") {
        kind := "part"
        v := Trim(PartInput)
    } else {
        v := Trim(VinInput)
        kind := "vin"
        if (KindInput = "Rego")
            kind := "rego"
        else if (KindInput = "Serial")
            kind := "serial"
        else if (KindInput = "Engine")
            kind := "engine"
    }
    if (v = "") {
        SetStatus(kind = "part" ? "Type a part number first." : "Type a VIN, rego, serial or engine number first.")
        return
    }
    ; Typed during warm-up? Remember it and run it the moment sign-in finishes,
    ; instead of making the user notice the app was not ready and press again.
    if (gBusy) {
        if (!gReady) {
            gPending := true
            SetStatus("Signing in - your lookup will run as soon as that is done...")
        } else {
            SetStatus("One moment - finishing the last lookup...")
        }
        return
    }
    gBusy := true
    lkT0 := A_TickCount
    ; the saved copy is drawn before any walk happens, so last time's trail
    ; must not still be sitting in the globals when it is
    gSupTyped := ""
    gSupOlder := []
    gTypedPart := (kind = "part") ? v : ""
    ; --- cached result first (instant), then live refresh ---
    cf := CacheFile(kind, v)
    cached := ""
    if FileExist(cf) {
        FileRead, cached, %cf%
        cached := Trim(cached, "`r`n")
    }
    if (cached != "") {
        ShowResult(cached, kind)
        FileGetTime, cft, %cf%
        FormatTime, cfts, %cft%, dd/MM HH:mm
        SetStatus("Showing your saved copy from " cfts " - checking Isuzu for the latest...")
    } else {
        ClearResults(kind)
        SetStatus("Looking up " v " ...")
    }
    if !MxAcquire(30000) {
        SetStatus("Another lookup is already running - try again in a moment.")
        gBusy := false
        return
    }
    ; mutex + busy flag ALWAYS released, even if the drive throws mid-lookup -
    ; a leaked mutex/flag blocked every later lookup until the app restarted
    try {
        ; Make sure the session is healthy BEFORE driving it. The old guard
        ; only pinged CDP and looked for a login form, so a stale SERVER
        ; session (page still alive, server session dead) sailed straight
        ; through and was caught only by the lookup itself coming back empty
        ; - a wasted attempt plus a reconnect. EnsureReady() also proves the
        ; server is answering (SessionAlive) and re-signs-in in place first.
        if !EnsureReady(60000) {
            SLog("lookup blocked, " kind " " v ": the session was not usable and could not be recovered")
            SetStatus(cached != "" ? "Showing the saved copy - could not reach Isuzu just now." : "Could not reach Isuzu. Check your internet and try again.")
            return
        }
        CleanupForms()
        res := Lookup(kind, v)
        if (res = "") {
            ; Both attempts are logged with the stage that failed, and the
            ; reconnect between them is logged too - because "reconnect said
            ; no" and "reconnect worked and the second try failed the same
            ; way" are different faults that used to print the same sentence.
            SLog("lookup fail 1 of 2, " kind " " v ": " gFailWhy)
            SetStatus("That did not come back - retrying...")
            rok := Reconnect()
            SLog("reconnect after that failure: " (rok ? "ok" : "FAILED"))
            if (rok) {
                CleanupForms()
                res := Lookup(kind, v)
                if (res = "")
                    SLog("lookup fail 2 of 2, " kind " " v ": " gFailWhy)
            } else {
                gFailWhy := "could not reconnect to Chrome or sign back in"
            }
        }
        if (gSelfTest != "")
            FileAppend, % "DOLOOKUP res len=" StrLen(res) " [" SubStr(res,1,60) "]`n", %gLog%
        if (res != "")
            gLastOk := A_TickCount   ; server answered - health probe can coast
        if (res = "NOTFOUND") {
            ShowResult("", kind)
            SafeDelete(cf)
            SessRestore()
        } else if (res != "") {
            ; cache what was actually fetched under the number that was typed,
            ; THEN walk forward - so an old number stays a valid cache key
            CacheWrite(kind, v, res)
            if (kind = "part")
                res := ResolveLatest(res, v)
            ShowResult(res, kind)
            ; The figures are on screen now, so the news walk costs the user
            ; nothing but a second of the app still being busy.
            if (kind = "part") {
                nmap := ParseRes(res)
                if (nmap["part"] != "") {
                    ; No placeholder in the box. There used to be a
                    ; "checking..." line put there while the bulletin was
                    ; fetched, and most parts have no bulletin at all - so the
                    ; box opened, the window grew, nothing came back, and the
                    ; box shut again. Every lookup of every part without news
                    ; flashed a panel open and closed for a second, which read
                    ; as the app glitching rather than as it working.
                    ; The waiting is said on the status line instead, where
                    ; nothing has to resize to say it.
                    SetStatus("Checking technical information...")
                    ntx := NewsFetch()
                    NewsCacheWrite(nmap["part"], ntx)
                    NewsShow(ntx)
                }
            }
            ; timing is for the log now, not for a line on screen
            SLog("lookup " kind " " v " in " Round((A_TickCount - lkT0) / 1000, 1) "s")
            SessRestore()
        } else {
            ; The screen wording is the fault, not a shrug: a lost connection
            ; and an IDS screen that sat there are different problems and the
            ; person at the counter can act on the difference.
            SLog("lookup gave up, " kind " " v ": " gFailWhy)
            LkDump(kind " " v)
            lost := InStr(gFailWhy, "connection died") || InStr(gFailWhy, "could not reconnect")
            what := lost ? "lost the connection to Isuzu" : "Isuzu's screen did not respond"
            SetStatus(cached != "" ? "Showing the saved copy - " what "." : Format("{:U}", SubStr(what, 1, 1)) SubStr(what, 2) ". Try again.")
        }
        CleanupForms()
    } catch e {
        SLog("lookup error: " e.Message " (line " e.Line ")")
        SetStatus("Something went wrong: " e.Message ". Try again.")
    } finally {
        gNoJump := false     ; one lookup only - never sticks to the next one
        MxRelease()
        gBusy := false
    }
return

; periodic session health check + keepalive poke
KeepAlive:
    if (gBusy)
        return
    gBusy := true
    if !MxAcquire(5000) {
        gBusy := false
        return
    }
    try {
        SessionCheck()
    } finally {
        MxRelease()
        gBusy := false
    }
return

; One gate for "can I drive a lookup right now?" - used by the keepalive timer,
; by every lookup, and by the manual Session > Check session now item.
;
; maxAgeMs: if the server was confirmed alive longer ago than this, do the full
; probe; otherwise trust the last stamp and skip the ~300ms SessionAlive() round
; trip (0 = always probe). Everything that proves the SERVER answered - a
; lookup, a keepalive, a check - stamps gLastOk, so back-to-back lookups pay
; for the full probe about once a minute instead of every time.
;
; Order matters: transport (CDP ping), then a visible login form (IsLoggedIn),
; then true server liveness (SessionAlive). A zombie page passes the first two
; and fails only the third - that is exactly the "went stale" case.
EnsureReady(maxAgeMs = 60000) {
    global
    if (CDP_Eval("'pong'") != "pong") {
        SetSessState("working", "reconnecting...")
        SLog("ensure: CDP dead - full reconnect")
        if !Reconnect() {
            gReady := false
            SetSessState("down", "cannot reach Isuzu - check your internet")
            SLog("ensure: reconnect FAILED")
            return false
        }
        CleanupForms()
        gReady := true
        gLastOk := A_TickCount
        SetSessState("ready", "reconnected")
        SLog("ensure: reconnected OK")
        return true
    }
    if (maxAgeMs > 0 && gLastOk && (A_TickCount - gLastOk) < maxAgeMs && IsLoggedIn()) {
        gReady := true
        return true
    }
    if (!IsLoggedIn() || !SessionAlive()) {
        SetSessState("working", "signing back in...")
        SLog("ensure: session stale - re-signing in")
        if !RecoverSession() {
            gReady := false
            SetSessState("down", "sign-in failed - tell Kaine")
            SLog("ensure: re-sign-in FAILED")
            return false
        }
        CleanupForms()
        SLog("ensure: re-signed in OK")
    }
    gReady := true
    gLastOk := A_TickCount
    return true
}

; Session health history on disk, so "did it stay logged in overnight?" is a
; question you answer by reading session.log instead of guessing from a lookup
; that felt slow.
SLog(s) {
    global gSessLog
    FormatTime, ts,, yyyy-MM-dd HH:mm:ss
    if FileExist(gSessLog) {   ; FileGetSize throws on a missing file
        FileGetSize, sz, %gSessLog%, K
        if (sz > 256)
            FileDelete, %gSessLog%
    }
    FileAppend, % ts "  " s "`n", %gSessLog%
}

SessionCheck() {
    global
    if !EnsureReady(0) {
        SetSessState("down", "will try again in " Round(CFG_KEEPALIVE/60000) " min")
        SLog("keepalive: DOWN - will retry in " Round(CFG_KEEPALIVE/60000) " min")
        return false
    }
    CleanupForms()
    Poke()
    gLastOk := A_TickCount
    FormatTime, kats,, HH:mm
    SetSessState("ready", "signed in, last checked " kats)
    SLog("keepalive: alive (" (InStr(gPokeMode,"rap") ? "rap ping" : "menu poke") ")")
    return true
}

; manual "is it still logged in?" probe - full check, never the cached stamp
MenuCheck:
    if (gBusy) {
        SetStatus("Busy - wait a moment...")
        return
    }
    gBusy := true
    if !MxAcquire(15000) {
        gBusy := false
        SetStatus("Another IsuzuVIN process is using the session - try again shortly.")
        return
    }
    try {
        SetStatus("Checking the session...")
        if SessionCheck()
            SetStatus("Session is good - signed in and Isuzu is answering.")
        else
            SetStatus("Session is down - could not sign back in. See session.log.")
    } finally {
        MxRelease()
        gBusy := false
    }
return

MenuRelogin:
    if (gBusy)
        return
    gBusy := true
    if !MxAcquire(15000) {
        gBusy := false
        return
    }
    try {
        SetStatus("Signing in fresh...")
        SetSessState("working", "signing in fresh...")
        if (!NewTab()) {
            SetStatus("Could not open a new Isuzu tab. Check your internet connection.")
            SetSessState("down", "cannot reach Isuzu")
            return
        }
        if EnsureLogin() {
            gReady := true
            gLastOk := A_TickCount
            SetStatus("Ready. Type a part number and press Enter.")
            SetSessState("ready", "signed in fresh")
        } else {
            SetStatus("Sign-in failed. The IDS password may have changed, or the account is locked.")
            SetSessState("down", "sign-in failed")
        }
    } finally {
        MxRelease()
        gBusy := false
    }
return

; Clear whichever result view belongs to this kind of lookup
ClearResults(kind) {
    if (kind = "part") {
        Gui, Main:Default          ; see ShowResultPart - LV_ needs this
        Gui, Main:ListView, LVStock
        LV_Delete()
        ListFit("LVStock", 0, 218)
        GuiControl, Main:, PartNum,
        GuiControl, Main:, PartTitle,
        GuiControl, Main:, PartTag,
        GuiControl, Main:Hide, PartRule
        NewsShow("")
        ClearPartPanels()
        PanelsShow(false)
        SetTimer, SupFade, Off
        GuiControl, Main:, SupLine,
        gSupNums := []
    } else {
        Gui, Main:Default          ; see ShowResultPart - LV_ needs this
        Gui, Main:ListView, LV
        LV_Delete()
        ListFit("LV", 0, 296)
        GuiControl, Main:, VinTitle,
        GuiControl, Main:, VinSub,
        VPanelsShow(false)
    }
}

; res is a string of key=value lines - one parser, used by the display code
; and by the supersession walk
ParseRes(res) {
    map := {}
    Loop, Parse, res, `n, `r
    {
        eq := InStr(A_LoopField, "=")
        if (eq) {
            k := SubStr(A_LoopField, 1, eq-1)
            val := SubStr(A_LoopField, eq+1)
            map[k] := val
        }
    }
    return map
}

ShowResult(res, kind = "") {
    map := ParseRes(res)
    ; kind matters for the empty case too: a part that IDS has no record of
    ; must still report on the Parts tab, not the vehicle one
    if (kind = "part" || map["part"] != "") {
        gLastPartRes := res
        ShowResultPart(map)
        return
    }
    global gVinOrder, gVinPretty, gVinHide, gLastVinRes, VBandHwnd
    gLastVinRes := res
    order := gVinOrder
    pretty := gVinPretty
    Gui, Main:Default              ; see ShowResultPart - LV_ needs this
    Gui, Main:ListView, LV
    LV_Delete()
    if (map["vin"] = "") {
        GuiControl, Main:, VinTitle,
        GuiControl, Main:, VinSub,
        PanelBandSet("VBand", VBandHwnd, "none"
                   , "NO RECORD   " . Chr(0xB7) . "   Isuzu returned nothing for that number.", "")
        VPanelsShow(true)
        SetStatus("No record found for that number.")
        LV_Add("", "(no record)", "Isuzu returned nothing for that")
        ListFit("LV", 1, 296)
        return
    }
    ; worked out here, once, so the line at the top and the field table below
    ; it cannot disagree - and so last_result.txt carries it too
    map["ride"] := RideHeight(map["vin"], map["model"], map["model_desc"])
    GuiControl, Main:, VinTitle, % map["vin"]
    GuiControl, Main:, VinSub, % map["model_desc"]
        . (map["rego"] != "" ? "   " Chr(0xB7) "   rego " map["rego"] : "")
        . (map["ride"] != "" ? "   " Chr(0xB7) "   " map["ride"] : "")
    ShowVehicleBand(map)
    VPanelsShow(true)
    dump := "", shown := 0
    for i, k in order {
        label := pretty[k] ? pretty[k] : k
        ; the export keeps every field - hiding is a reading preference, not
        ; a reason to lose data out of last_result.txt
        dump .= label ": " map[k] "`r`n"
        if (gVinHide.HasKey(k))
            continue
        LV_Add("", label, map[k])
        shown++
    }
    ListFit("LV", shown, 296)
    ; persist last result (handy export + lets you copy/paste)
    SafeDelete(A_ScriptDir "\last_result.txt")
    FileAppend, %dump%, %A_ScriptDir%\last_result.txt
}

; DC210 part result: description, prices, then one row per warehouse
; Isuzu returns warehouse numbers; the warehouse floor thinks in branch names.
; An unmapped number still shows - it just has no name beside it.
WhsName(code) {
    ; normalise first: object keys that look numeric get coerced, and IDS pads
    ; the number ("03"), so compare on the digits themselves
    c := RegExReplace(Trim(code), "^0+", "")
    if (c = "3")
        return "Melbourne"
    if (c = "4")
        return "Brisbane"
    if (c = "1")
        return "Headquarters"
    return ""
}

; display order: Melbourne, Brisbane, Headquarters, then anything unmapped
WhsRank(code) {
    c := RegExReplace(Trim(code), "^0+", "")
    return (c = "3") ? 1 : (c = "4") ? 2 : (c = "1") ? 3 : 9
}

; "27" is stock, "Nil"/""/"0"/"-" is not
WhsHasStock(v) {
    v := Trim(v)
    return !(v = "" || v = "-" || v = "0" || v = "Nil")
}

; one live DC210 read of a part number, cached for next time
PartFetch(num) {
    CleanupForms()          ; leave DC210 the way the next read expects it
    r := Lookup("part", num)
    if (r = "" || r = "NOTFOUND")
        return ""
    CacheWrite("part", num, r)
    return r
}

; Follow Repl# forward until it runs out (or CFG_MAXHOPS), so what gets shown
; is the number that can actually be ordered today. Each hop is a real DC210
; round trip - roughly a second - which is why it is capped.
; Returns the res of the newest record; leaves the trail in gSupTyped/gSupOlder.
ResolveLatest(res, typed) {
    global gNoJump, gSupTyped, gSupOlder, CFG_MAXHOPS
    gSupTyped := ""
    gSupOlder := []
    if (gNoJump)             ; user clicked an old number on purpose
        return res
    m := ParseRes(res)
    hops := 0
    while (hops < CFG_MAXHOPS) {
        r := Trim(m["repl"])
        if (r = "" || r = Trim(m["part"]))
            break
        SetStatus("That number was replaced - fetching " r " ...")
        nxt := PartFetch(r)
        if (nxt = "")
            break
        gSupOlder.Push(Trim(m["part"]))
        res := nxt
        m := ParseRes(res)
        hops++
    }
    if (gSupOlder.Length())
        gSupTyped := Trim(typed)
    return res
}

; add a part number to a list if it is real, new, and not the one on screen
; part numbers get typed with spaces and dashes in them; compare the digits
SupKey(n) {
    return RegExReplace(Trim(n), "[^0-9A-Za-z]", "")
}

SupPush(list, n, part) {
    n := Trim(n)
    if (n = "" || n = part)
        return
    for i, e in list
        if (e = n)
            return
    list.Push(n)
}

; "Replaces <a>123</a> ..." - each number becomes link N, and gSupNums maps
; the index the Link control reports back to the number itself
SupMarkup(list) {
    global gSupNums
    gSupNums := []
    out := ""
    for i, n in list {
        gSupNums.Push(n)
        out .= (out != "" ? "  " Chr(0xB7) "  " : "") "<a>" n "</a>"
    }
    return out
}

ShowResultPart(map) {
    global gShowTrade, gRowState
    Gui, Main:ListView, LVStock
    LV_Delete()
    if (map["part"] = "") {
        GuiControl, Main:, PartNum,
        GuiControl, Main:, PartTitle,
        GuiControl, Main:, PartTag,
        GuiControl, Main:Hide, PartRule
        ClearPartPanels()
        SetTimer, SupFade, Off
        GuiControl, Main:, SupLine,
        LadderNotFound()
        NewsShow("")
        ListFit("LVStock", 0, 218)
        PanelsShow(true)
        return
    }
    GuiControl, Main:, PartNum, % map["part"]
    GuiControl, Main:, PartTitle, % map["desc"]
    GuiControl, Main:Show, PartRule
    ShowSupersession(map)
    ; prices as a strip: four figures, no list rows, no scrolling
    GuiControl, Main:, Price1, % map["list"]
    GuiControl, Main:, Price2, % map["trade"]
    GuiControl, Main:, Price3, % map["daily"]
    GuiControl, Main:, Price4, % map["stock_order"]
    PriceRailShow(true)
    trade := gShowTrade
        ? "Active " map["active"] "        Discount code " map["discount"] "        Class " map["class"]
        : ""
    GuiControl, Main:, TradeLine, %trade%
    dump := map["part"] "  " map["desc"] "`r`n"
        . "List " map["list"] "   Trade " map["trade"] "   Daily order " map["daily"]
        . "   Stock order " map["stock_order"] "`r`n"
    ; stockN=whs|available|on order|min sell|pack, one row per warehouse.
    ; Melbourne first, then Brisbane, then Headquarters - anything else after.
    raw := []
    Loop, 9 {
        s := map["stock" A_Index]
        if (s = "")
            break
        p := StrSplit(s, "|")
        raw.Push({whs: Trim(p[1]), avail: Trim(p[2]), order: Trim(p[3]), min: Trim(p[4]), pack: Trim(p[5])})
    }
    ordered := []
    Loop, 4 {
        want := A_Index
        for j, r in raw
            if (WhsRank(r.whs) = want)
                ordered.Push(r)
    }
    for j, r in raw
        if (WhsRank(r.whs) = 9)
            ordered.Push(r)

    ; the answer first, because each row is drawn holding its own state:
    ; a glyph in the last column and, on the row worth acting on, a tint.
    ; The part number and the saved news go in with it: on a part nobody
    ; holds, direct ship is the difference between 2 to 3 weeks and 6 to 8.
    nws := NewsCacheRead(map["part"])
    LadderSet(ordered, nws, map["part"])
    ; Gui, Main:Default before Gui, Main:ListView - and it is not decoration.
    ;
    ; BuildPanels() ends with Gui, LadF:New / VBand:New / Pill:New, and each of
    ; those makes ITS window the default GUI. A lookup runs on a timer thread,
    ; which starts out with that leftover default, and LV_Add then silently
    ; refuses every row: it returned 0, the list stayed empty, and the table
    ; was drawn as a header over ruled blank space. It cleared itself on the
    ; NEXT lookup, because by then something else had reset the default - so
    ; it looked like a random glitch on the first search after opening the app,
    ; which is exactly the search someone is most likely to be watching.
    ; Naming the window in the command is not enough. The default has to BE
    ; Main before the ListView is chosen.
    Gui, Main:Default
    Gui, Main:ListView, LVStock
    for i, r in ordered {
        name := WhsName(r.whs)
        av := (r.avail != "" ? r.avail : "-")
        LV_Add("", r.whs, name, av, (r.order != "" ? r.order : "-"), r.min
             , r.pack, LadGlyph(gRowState[i]))
        dump .= "Whs " r.whs (name != "" ? " " name : "") ": " av " available"
             . (r.order != "" ? ", " r.order " on order" : "") "`r`n"
    }
    ListFit("LVStock", ordered.Length(), 218)
    if (!ordered.Length())
        LV_Add("", "-", "", "none listed", "", "", "", "")

    PanelsShow(true)
    FitWindow()          ; the table changed height, so the line under it moved
    ; the saved copy of the news, if there is one. The live walk runs after
    ; this and either confirms it or clears it.
    NewsShow(nws)
    SafeDelete(A_ScriptDir "\last_result.txt")
    FileAppend, %dump%, %A_ScriptDir%\last_result.txt
}

; Tick / cross / question mark, with a plain-text fallback on the off chance
; this is running on an ANSI build where the glyphs would come out as boxes.
SupGlyph(state) {
    if (!A_IsUnicode)
        return (state = "yes") ? "OK" : (state = "no") ? "X" : "?"
    return (state = "yes") ? Chr(0x2713) : (state = "no") ? Chr(0x2715) : "?"
}

; The part identity line answers one question that used to need a phone call:
; is this the number I should be quoting?
;   LATEST      - steel, on every current record, so its absence is the signal
;   SUPERSEDED  - amber, with a standing link to the number that replaced it
; Underneath it, one line of history that clears itself after a few seconds.
ShowSupersession(map) {
    global gSupTyped, gSupOlder, gSupNums, gTypedPart
    part := Trim(map["part"])
    repl := Trim(map["repl"])
    SetTimer, SupFade, Off
    gSupNums := []
    if (repl != "" && repl != part) {
        ; showing an old record on purpose - this warning must not fade
        GuiControl, Main:+cA35B00, PartTag
        GuiControl, Main:, PartTag, SUPERSEDED
        gSupNums.Push(repl)
        GuiControl, Main:, SupLine, % "Superseded - the current number is <a>" repl "</a>"
        return
    }
    ; The number on screen is not always the number that was typed - our own
    ; walk can land three parts away, and DC210 forwards some numbers by
    ; itself. Either way it is the one thing on this screen someone can get
    ; wrong without noticing, so the test is simply "is this what was typed",
    ; and when it is not the tag says so in amber and the line under the box
    ; never fades.
    typed := (gSupTyped != "") ? Trim(gSupTyped) : Trim(gTypedPart)
    jumped := (typed != "" && SupKey(typed) != SupKey(part))
    if (jumped) {
        GuiControl, Main:+cA35B00, PartTag
        GuiControl, Main:, PartTag, NEW NUMBER
    } else {
        GuiControl, Main:+c17466B, PartTag
        GuiControl, Main:, PartTag, LATEST
    }
    ; Newest first - the order someone traces working back from a number in
    ; hand. The two sources run opposite ways: the walk collected numbers
    ; oldest-first, while Old# is already newer than Oldest.
    olds := []
    Loop, % gSupOlder.Length()
        SupPush(olds, gSupOlder[gSupOlder.Length() - A_Index + 1], part)
    SupPush(olds, map["old"], part)
    SupPush(olds, map["oldest"], part)
    if (jumped) {
        ; the typed number leads the line AND stays clickable, so someone can
        ; go straight back to what the paperwork actually says. No fade: this
        ; is the one thing on the screen that can be got wrong unnoticed.
        gSupNums.Push(typed)
        lead := "You typed <a>" typed "</a> - now showing " part "."
        rest := []
        for i, n in olds
            if (SupKey(n) != SupKey(typed))
                rest.Push(n)
        if (rest.Length())
            lead .= "  Also replaces " SupMarkup(rest)
        GuiControl, Main:, SupLine, %lead%
        return
    }
    if (!olds.Length()) {
        GuiControl, Main:, SupLine,
        return
    }
    ; plain history has done its job after a few seconds
    GuiControl, Main:, SupLine, % "Replaces " SupMarkup(olds)
    SetTimer, SupFade, -9000
}

; IDS writes dates as dd/MM/yy. Returns YYYYMMDD for comparing, or "" if the
; field is not a date at all (blank, dashes, whatever else turns up).
IdsDate(s) {
    s := Trim(s)
    if !RegExMatch(s, "^(\d{1,2})/(\d{1,2})/(\d{2,4})$", m)
        return ""
    d := m1, mo := m2, y := m3
    if (StrLen(y) = 2)
        y := (y + 0 < 70) ? "20" y : "19" y
    if (StrLen(mo) = 1)
        mo := "0" mo
    if (StrLen(d) = 1)
        d := "0" d
    return y mo d
}

; 150000 -> 150,000
Commas(n) {
    n := Trim(n)
    if !RegExMatch(n, "^\d+$")
        return n
    out := ""
    while (StrLen(n) > 3) {
        out := "," SubStr(n, -2) out
        n := SubStr(n, 1, StrLen(n) - 3)
    }
    return n out
}

; ------------------------------------------------------ high ride / low ride
; Isuzu does not put ride height in the VIN and does not put it in the DC611
; record either. It lives in the model code, and only by convention: the last
; three digits are the variant, and the low-ride variants have always been
; 002, 004, 024 and 025.
;
; Where that comes from: the IUA "VIN ID Breakdown" sheet lists the pre-18MY
; low-ride model codes outright -
;   GORZA002 GORZA004 GORB024 GORB025 IOR2002 IOR2004 IOR3002 IOR3004
;   IOR4002 IOR4004 IOR5002 IOR5004 IOR6002 IOR6004 IOR7002 IOR7004
;   IOR8002 IOR9002
; eighteen codes across nine prefixes, and every one of them ends in one of
; those four numbers. No list has been issued for 18MY on, so the same four
; are carried forward. Two records already looked up say the carry-forward
; holds - same suffix, same body, same grade, years apart:
;   TOR0002 = 4X2 SINGLE CAB C/C SX AUTO   (002 was single cab C/C pre-18MY)
;   TOR3025 = 4X2 SPACE CAB C/C SX AUTO    (025 was space cab C/C pre-18MY)
;
; Two gates come BEFORE the suffix, because the suffix on its own lies:
;   - 4x4 is high ride by construction. TOR3004 is a 4X4 SINGLE CAB C/C and
;     ends 004; without the gate it would read Low Ride.
;   - the MU-X is a wagon on the high-ride chassis, 4x2 or 4x4 alike.
; Both are read off the VIN, which the sheet does define: char 4 is the model
; line (T pickup, U light-duty MPV) and char 6 is the drive system (R 4x2,
; S 4x4). With no usable VIN the model description carries the same two facts
; in words, so it is the fallback.
;
; Returns "High Ride", "Low Ride", or "" when there is not enough to say -
; and "" is the honest answer, not a default of High Ride.
RideHeight(vin, model, desc) {
    ; no case folding anywhere below: AHK compares strings case-blind, InStr
    ; is case-blind by default, and the one regex carries the i) flag
    vin := StrReplace(Trim(vin), " ", "")
    model := StrReplace(Trim(model), " ", "")
    desc := Trim(desc)

    line := "", drive := ""
    if (StrLen(vin) >= 6 && SubStr(vin, 1, 3) = "MPA") {
        line := SubStr(vin, 4, 1)
        d := SubStr(vin, 6, 1)
        drive := (d = "S") ? "4X4" : (d = "R") ? "4X2" : ""
    }
    if (drive = "")
        drive := InStr(desc, "4X4") ? "4X4" : (InStr(desc, "4X2") ? "4X2" : "")
    ; a wagon rides high whatever it drives through
    if (line = "U" || InStr(desc, "SUV") || InStr(desc, "WAGON"))
        return "High Ride"
    if (drive = "4X4")
        return "High Ride"
    if (drive = "")
        return ""
    ; a 4x2 ute, so the model code decides - and without one there is no answer
    if (!RegExMatch(model, "i)(\d{3})[A-Z]*$", m))
        return ""
    ; InStr and not "=", because AHK compares two numeric-looking strings as
    ; numbers: m1 = "002" would also be true for a bare "2".
    return InStr("|002|004|024|025|", "|" m1 "|") ? "Low Ride" : "High Ride"
}

; The one thing anyone asks a VIN: is it still under warranty, and is there a
; campaign outstanding on it. Both go in the band, above the field table.
ShowVehicleBand(map) {
    global VBandHwnd
    exp := Trim(map["warranty_expiry"])
    expN := IdsDate(exp)
    km := Commas(Trim(map["kms"]))
    camp := Trim(map["campaign"])
    campOn := (camp != "" && camp != "-" && camp != "0"
            && !RegExMatch(camp, "i)^(no|none|n)$"))
    if (expN = "") {
        state := "none"
        word := "WARRANTY UNKNOWN"
        sub := "No expiry date on the record"
    } else if (expN >= SubStr(A_Now, 1, 8)) {
        state := "yes"
        word := "WARRANTY ACTIVE"
        sub := "Expires " exp (km != "" ? "   " Chr(0xB7) "   " km " km" : "")
    } else {
        state := "no"
        word := "WARRANTY EXPIRED"
        sub := "Expired " exp (km != "" ? "   " Chr(0xB7) "   " km " km" : "")
    }
    if (campOn)
        sub .= "   " Chr(0xB7) "   CAMPAIGN OUTSTANDING"
    PanelBandSet("VBand", VBandHwnd, state
               , word (sub != "" ? "   " Chr(0xB7) "   " sub : ""), Trim(map["year"]))
}

SaveVinHide() {
    global gVinHide, gIni
    out := ""
    for k, v in gVinHide
        out .= (out != "" ? "," : "") k
    IniWrite, % (out != "" ? out : " "), %gIni%, Vehicle, HiddenFields
}

; Progress and failures share the session line - there is no status strip any
; more. Grey, so it never gets mistaken for the coloured session states, and
; SessRestore() puts the session line back the moment a lookup finishes.
SetStatus(s) {
    global gBatch, gLog, gSelfTest
    if (gBatch || gSelfTest != "")
        FileAppend, % A_Now " " s "`n", %gLog%
    if (!gBatch) {
        GuiControl, Main:+c808080, Sess
        GuiControl, Main:, Sess, %s%
    }
}

; put the session line back after a lookup borrowed it for progress text
SessRestore() {
    global gSessState, gSessDetail
    if (gSessState != "")
        SetSessState(gSessState, gSessDetail)
}

; The session line is read by warehouse staff, not developers: one state word,
; plain English after it, and a colour you can judge without reading it.
;   ready   = signed in, lookups will be instant
;   working = busy fixing itself, lookups still work (they just wait)
;   down    = needs a human
SetSessState(state, detail = "") {
    global gBatch, gSessState, gSessDetail
    gSessState := state, gSessDetail := detail
    if (gBatch)
        return
    colour := (state = "ready") ? "c1B7F1B" : (state = "working") ? "cA35B00" : "cB00000"
    word   := (state = "ready") ? "Ready" : (state = "working") ? "Working" : "Not connected"
    GuiControl, Main:+%colour%, Sess
    dot := A_IsUnicode ? Chr(0x25CF) " " : ""
    GuiControl, Main:, Sess, % dot word (detail != "" ? "  -  " detail : "")
}

; The X does not close this app, it minimises it. It comes back INSTANTLY
; because nothing was ever torn down: the Chrome session, the signed-in IDS
; session and the keep-alive timer all keep running behind the minimised
; window. Signing in again costs seconds; minimising costs nothing. Escape and
; the minimise button do the same thing, because they are the same reflex - and
; the taskbar button stays there whichever one you used.
;
; Quitting for real is still one menu item away - Session > Exit - and both
; exits below still exit.
MainGuiClose:
MainGuiEscape:
    WinMinimize, ahk_id %MainHwnd%
return

; Ctrl+PageDown from anywhere: bring it back and put the cursor in it. If it
; is already up but buried behind ERA, this raises it rather than doing
; nothing, which is what someone pressing it actually wants either way.
; It is a system-wide hotkey, so it is taken from Chrome's next-tab and
; Excel's next-sheet for as long as this app is running.
^PgDn::
    Gosub, MenuShowWindow
return

; a label rather than a function, because the tray menu and the Session menu
; both point at it and the rest of the menu handlers here are labels too
MenuShowWindow:
    ; Show alone leaves a minimised window minimised - Restore is what actually
    ; brings it up off the taskbar
    if (MainHwnd && DllCall("IsIconic", "Ptr", MainHwnd))
        Gui, Main:Show, Restore
    else
        Gui, Main:Show
    WinActivate, ahk_id %MainHwnd%
return

; closing the window LEAVES Chrome running (signed in) so next launch is instant
MenuExitKeep:
    if (gSock)
        WS_CloseSocket(gSock)
    ExitApp
return

MenuHideWindow:
    WinMinimize, ahk_id %MainHwnd%
return

MenuExitKill:
    if (gSock)
        WS_CloseSocket(gSock)
    KillChromeNow()
    ExitApp
return

; AHK v1 trap: inside an active `try`, commands that set ErrorLevel THROW -
; FileDelete on a file that isn't there raises exception "1". Every delete
; goes through here so a missing/locked file can never abort a lookup.
SafeDelete(f) {
    try {
        if FileExist(f)
            FileDelete, %f%
    } catch e {
    }
}

;======================= cross-process serialization ==========================
; GUI + batch runs share one Chrome/tab; a named mutex serializes drivers.
MxAcquire(timeoutMs) {
    global gMx
    if (!gMx)
        gMx := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", "Local\IsuzuVIN_CDP", "Ptr")
    r := DllCall("WaitForSingleObject", "Ptr", gMx, "UInt", timeoutMs, "UInt")
    return (r = 0 || r = 0x80)     ; WAIT_OBJECT_0 or WAIT_ABANDONED
}
MxRelease() {
    global gMx
    if (gMx)
        DllCall("ReleaseMutex", "Ptr", gMx)
}

;=============================== cache ========================================
CacheFile(kind, value) {
    global CFG_CACHE
    StringUpper, v, value
    v := RegExReplace(v, "[^A-Z0-9]", "_")
    return CFG_CACHE "\" kind "_" v ".txt"
}
CacheWrite(kind, value, res) {
    cf := CacheFile(kind, value)
    SafeDelete(cf)
    FileAppend, %res%, %cf%
}

;=========================== Chrome management ================================
ChromePath() {
    for i, p in ["C:\Program Files\Google\Chrome\Application\chrome.exe"
                , "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
                , A_AppData "\..\Local\Google\Chrome\Application\chrome.exe"] {
        if FileExist(p)
            return p
    }
    return ""
}

HttpGet(path) {
    global CFG_PORT
    try {
        whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://127.0.0.1:" CFG_PORT path, true)
        whr.Send()
        whr.WaitForResponse(5)
        return whr.ResponseText
    } catch e {
        return ""
    }
}

ReadPid() {
    local p := ""
    if !FileExist(A_ScriptDir "\chrome.pid")   ; missing pid file threw out of FileRead
        return 0
    FileRead, p, %A_ScriptDir%\chrome.pid
    p := Trim(p, " `r`n")
    if p is not integer
        return 0
    Process, Exist, %p%
    return (ErrorLevel = p) ? p : 0
}

KillChromeNow() {
    global gChromePID
    pid := gChromePID ? gChromePID : ReadPid()
    if (pid)
        RunWait, %ComSpec% /c taskkill /PID %pid% /T /F, , Hide
    SafeDelete(A_ScriptDir "\chrome.pid")
}

EnsureChrome() {
    global
    ; already up? (persistent Chrome from a previous run)
    if (InStr(HttpGet("/json/version"), "webSocketDebuggerUrl")) {
        gChromePID := ReadPid()
        return true
    }
    local exe := ChromePath()
    if (exe = "")
        return false
    local args := " --headless=new --disable-gpu"
          . " --remote-debugging-port=" CFG_PORT
          . " --user-data-dir=""" CFG_PROFILE """"
          . " --remote-allow-origins=*"
          . " --window-size=1280,1024"
          . " --no-first-run --no-default-browser-check"
          . " --disable-features=Translate,MediaRouter"
          . " --disable-background-timer-throttling"
          . " --disable-renderer-backgrounding"
          . " --disable-backgrounding-occluded-windows"
    local pid
    Run, %exe%%args%, , Hide, pid
    gChromePID := pid
    SafeDelete(A_ScriptDir "\chrome.pid")
    FileAppend, %pid%, %A_ScriptDir%\chrome.pid
    ; wait until CDP responds
    Loop, 60 {
        Sleep, 300
        if (InStr(HttpGet("/json/version"), "webSocketDebuggerUrl"))
            return true
    }
    return false
}

; attach to an existing IDS tab (warm start) or create a fresh xtapp target
OpenPage() {
    global
    gAttached := false
    ; ---- warm path: reuse a live IDS tab from a previous run ----
    local list := HttpGet("/json/list")
    local pos := 1, blk, wm, wm1, im, im1, s
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (!InStr(blk, CFG_HOST))
            continue
        if (!InStr(blk, """page"""))
            continue
        if !RegExMatch(blk, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/page/[^""]+)""", wm)
            continue
        s := WS_Connect("127.0.0.1", CFG_PORT, wm1)
        if (!s)
            continue
        gSock := s
        if (CDP_Eval("'pong'") = "pong") {
            gAttached := true
            if RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im)
                gTargetId := im1
            CDP_Cmd("Emulation.setDeviceMetricsOverride", "{""width"":1280,""height"":1024,""deviceScaleFactor"":1,""mobile"":false}")
            return true
        }
        ; tab answers no evals = renderer wedged (dead RAP session). Close it
        ; via HTTP or it lingers forever eating memory.
        if (gSock) {
            WS_CloseSocket(gSock)
            gSock := 0
        }
        if RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im)
            HttpGet("/json/close/" im1)
    }
    ; ---- cold path: create a fresh target ----
    local ver := HttpGet("/json/version")
    local bm, bm1
    if !RegExMatch(ver, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/[^""]+)""", bm)
        return false
    local bsock := WS_Connect("127.0.0.1", CFG_PORT, bm1)
    if (!bsock)
        return false
    local id := ++gId
    WS_SendText(bsock, "{""id"":" id ",""method"":""Target.createTarget"",""params"":{""url"":""https://" CFG_HOST "/app?open=xtapp"",""newWindow"":true,""width"":1280,""height"":1024}}")
    local tid := "", r, tm, tm1
    Loop, 30 {
        r := WS_RecvMessage(bsock)
        if (r = "")
            break
        if (InStr(r, """id"":" id) && RegExMatch(r, """targetId""\s*:\s*""([0-9A-Fa-f]+)""", tm)) {
            tid := tm1
            break
        }
    }
    WS_CloseSocket(bsock)
    if (tid = "")
        return false
    gTargetId := tid
    gSock := WS_Connect("127.0.0.1", CFG_PORT, "/devtools/page/" tid)
    if (!gSock)
        return false
    ; deterministic viewport (no Runtime/Page.enable -> no event spam)
    CDP_Cmd("Emulation.setDeviceMetricsOverride", "{""width"":1280,""height"":1024,""deviceScaleFactor"":1,""mobile"":false}")
    return true
}

; full transport recovery: socket -> chrome -> page -> login
Reconnect() {
    global
    if (gSock) {
        WS_CloseSocket(gSock)
        gSock := 0
    }
    if !EnsureChrome()
        return false
    if !OpenPage()
        return false
    return RecoverSession()
}

;=============================== CDP layer ====================================
JsonEsc(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, """", "\""")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

CDP_Cmd(method, paramsJson) {
    global gSock, gId, gCdpDead
    ; A dead socket and a JS expression that returned "" are the SAME empty
    ; string to every caller, so a lost connection used to be indistinguishable
    ; from a button that was not on screen. This flag separates them.
    if (!gSock) {
        gCdpDead := true
        return ""
    }
    id := ++gId
    msg := "{""id"":" id ",""method"":""" method """,""params"":" paramsJson "}"
    if !WS_SendText(gSock, msg)
        return ""
    Loop, 500 {
        r := WS_RecvMessage(gSock)
        if (r = "") {
            ; transport dead or page main thread wedged - kill the socket so
            ; every later CDP call fails INSTANTLY instead of burning a full
            ; recv timeout each (a wedged page turned loops into 25min hangs)
            WS_CloseSocket(gSock)
            gSock := 0
            gCdpDead := true
            return ""
        }
        if (RegExMatch(r, """id""\s*:\s*" id "\b"))
            return r
        ; else it's an event or another id -> keep reading
    }
    return ""
}

; Runtime.evaluate returning a string value; returns the raw value text
CDP_Eval(js) {
    p := "{""expression"":""" JsonEsc(js) """,""returnByValue"":true}"
    r := CDP_Cmd("Runtime.evaluate", p)
    if (r = "")
        return ""
    ; extract "value":"...."  (our JS always returns plain ASCII / base64, no quotes inside)
    if RegExMatch(r, """value""\s*:\s*""([^""]*)""", m)
        return m1
    ; value could be null/number
    if RegExMatch(r, """value""\s*:\s*([0-9]+)", m)
        return m1
    return ""
}

B64Decode(b64) {
    if (b64 = "")
        return ""
    CRYPT_STRING_BASE64 := 1
    sz := 0
    DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", CRYPT_STRING_BASE64, "Ptr", 0, "UIntP", sz, "Ptr", 0, "Ptr", 0)
    if (sz = 0)
        return ""
    VarSetCapacity(bin, sz, 0)
    DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", CRYPT_STRING_BASE64, "Ptr", &bin, "UIntP", sz, "Ptr", 0, "Ptr", 0)
    return StrGet(&bin, sz, "UTF-8")
}

;=========================== input helpers ====================================
Click(x, y) {
    p := "{""type"":""mousePressed"",""x"":" x ",""y"":" y ",""button"":""left"",""clickCount"":1}"
    CDP_Cmd("Input.dispatchMouseEvent", p)
    p := "{""type"":""mouseReleased"",""x"":" x ",""y"":" y ",""button"":""left"",""clickCount"":1}"
    CDP_Cmd("Input.dispatchMouseEvent", p)
}
; fast: whole string in ONE CDP call (fires proper input events)
InsertText(s) {
    CDP_Cmd("Input.insertText", "{""text"":""" JsonEsc(s) """}")
}
; slow fallback: per-character key events
TypeText(s) {
    Loop, Parse, s
    {
        ch := JsonEsc(A_LoopField)
        CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""text"":""" ch """}")
        CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""text"":""" ch """}")
    }
}
KeyPress(key, vk) {
    CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""key"":""" key """,""code"":""" key """,""windowsVirtualKeyCode"":" vk "}")
    CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""key"":""" key """,""code"":""" key """,""windowsVirtualKeyCode"":" vk "}")
}
SelAllDel() {
    CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""modifiers"":2,""key"":""a"",""code"":""KeyA"",""windowsVirtualKeyCode"":65}")
    CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""modifiers"":2,""key"":""a"",""code"":""KeyA"",""windowsVirtualKeyCode"":65}")
    KeyPress("Delete", 46)
}
Coord(js, ByRef x, ByRef y) {
    v := CDP_Eval(js)
    if RegExMatch(v, "^(-?[0-9]+),(-?[0-9]+)$", m) {
        x := m1, y := m2
        return true
    }
    return false
}
; poll a coordinate-returning JS until it resolves (replaces fixed sleeps)
WaitCoord(js, ByRef x, ByRef y, timeoutMs = 6000, stepMs = 200) {
    start := A_TickCount
    Loop {
        if Coord(js, x, y)
            return true
        if (A_TickCount - start > timeoutMs)
            return false
        Sleep, %stepMs%
    }
}

;=============================== login ========================================
; Title alone LIES: it keeps saying "Active user" even after the server throws
; a re-auth panel back up (session challenged, not dead). RAP still answers so
; SessionAlive() also passes - the ONLY honest tell is a VISIBLE password field
; on screen. If one exists we are NOT usable-logged-in, whatever the title says.
; (width>0 filter: RAP leaves hidden stale password inputs in the DOM.)
IsLoggedIn() {
    t := CDP_Eval("document.title")
    if !InStr(t, "Active user")
        return false
    pw := CDP_Eval("''+Array.from(document.querySelectorAll('input[type=password]')).filter(function(x){return x.getBoundingClientRect().width>0;}).length")
    return (pw = "0") ? true : false
}

; Locate the login fields RELATIVE TO THE VISIBLE PASSWORD BOX - never by
; absolute input index. On the cold login page the username/password inputs
; happen to be inputs 0 and 1, but on the mid-session re-auth ("challenge")
; panel the MENU SEARCH BOX is input 0, so index 1 is the USERNAME and the
; old code typed the password into it, failed 3x, and fell back to a slow
; fresh-tab login. Anchor: the one visible input[type=password]; the username
; is the nearest visible, editable, non-password input directly above it and
; left-aligned with it (fallback: nearest such input above it anywhere).
JsLoginField(which, what) {
    js := "(function(){"
        . "var vis=function(x){var r=x.getBoundingClientRect();return r.width>0&&r.height>0;};"
        . "var pw=Array.from(document.querySelectorAll('input[type=password]')).filter(vis)[0];"
        . "if(!pw)return '';"
        . "var pr=pw.getBoundingClientRect();"
        . "var e=pw;"
        . "if('" which "'==='u'){"
        .   "var ok=function(x){return x!==pw&&x.type!=='password'&&!x.readOnly&&!x.disabled&&vis(x)&&x.getBoundingClientRect().top<pr.top;};"
        .   "var all=Array.from(document.querySelectorAll('input')).filter(ok);"
        .   "var aligned=all.filter(function(x){return Math.abs(x.getBoundingClientRect().left-pr.left)<40;});"
        .   "var pick=(aligned.length?aligned:all);"
        .   "pick.sort(function(a,b){return b.getBoundingClientRect().top-a.getBoundingClientRect().top;});"
        .   "e=pick[0];"
        . "}"
        . "if(!e)return '';"
        . (what = "xy"
            ? "var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);"
            : "return e.value||'';")
        . "})()"
    return js
}

; click the field, clear, type text, read the value back; retry up to 3x.
; attempts 1-2 use fast InsertText, attempt 3 falls back to per-key typing.
SetLoginField(which, text) {
    global gBatch
    jsCoord := JsLoginField(which, "xy")
    jsVal   := JsLoginField(which, "val")
    Loop, 3 {
        if !Coord(jsCoord, cx, cy)
            return false
        Click(cx, cy)
        Sleep, 100
        SelAllDel()
        Sleep, 60
        if (A_Index < 3)
            InsertText(text)
        else
            TypeText(text)
        Sleep, 120
        got := CDP_Eval(jsVal)
        if (got == text)
            return true
        if (gBatch)
            BLog("login field " which " attempt " A_Index ": got=""" got """ want=""" text """")
    }
    return false
}

EnsureLogin() {
    global
    local t0 := CDP_Eval("document.title")
    if (gBatch)
        BLog("login: title=" t0)
    if IsLoggedIn()
        return true
    ; wait for login form (VISIBLE password field - RAP keeps hidden stale ones)
    local n := 0
    Loop, 60 {
        n := CDP_Eval("''+Array.from(document.querySelectorAll('input[type=password]')).filter(function(x){return x.getBoundingClientRect().width>0;}).length")
        if (n >= 1)
            break
        Sleep, 250
    }
    if (gBatch)
        BLog("login: pwcount=" n)
    if (n < 1)
        return IsLoggedIn()
    Sleep, 700   ; let the RAP login form settle before typing
    ; fill + verify - fields found relative to the password box, never by index
    if !SetLoginField("u", CFG_USER) {
        if (gBatch)
            BLog("login: FAILED setting username field")
        return false
    }
    if !SetLoginField("p", CFG_PW) {
        if (gBatch)
            BLog("login: FAILED setting password field")
        return false
    }
    local jsS := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){return x.children.length<=1&&(x.innerText||'').trim()==='Sign in'&&x.getBoundingClientRect().width>0;});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    local sx, sy
    if !Coord(jsS, sx, sy) {
        if (gBatch)
            BLog("login: FAILED finding Sign in button")
        return false
    }
    Click(sx, sy)
    if (gBatch)
        BLog("login: clicked Sign in at " sx "," sy)
    local err
    Loop, 50 {
        Sleep, 300
        if IsLoggedIn()
            return true
        ; surface the server's own refusal text (e.g. "Authenticated, but no
        ; company found for user. (412)") instead of timing out blind
        err := CDP_Eval("(function(){var e=Array.from(document.querySelectorAll('div,span')).find(function(x){var r=x.getBoundingClientRect();return r.width>0&&x.children.length===0&&/incorrect|invalid|locked|no company|denied/i.test(x.innerText||'');});return e?(e.innerText||'').trim().substring(0,80):'';})()")
        if (err != "") {
            if (gBatch)
                BLog("login: server refused: " err)
            SetStatus("Sign-in refused: " err)
            return false
        }
    }
    if (gBatch)
        BLog("login: 15s timeout after Sign in click, title=" CDP_Eval("document.title"))
    return IsLoggedIn()
}

; alive check -> normal login -> fresh tab + login.
; TRAP 1: the page title keeps saying "Active user" long after the server has
; killed the session (zombie page) - IsLoggedIn() alone is NOT enough here.
; TRAP 2: NEVER Page.navigate a zombie RAP page - its unload handler fires a
; sync XHR into the dead session and blocks the renderer main thread FOREVER
; (every eval then hangs). Close the tab and open a fresh one instead.
RecoverSession() {
    global
    if (gSock && IsLoggedIn() && SessionAlive()) {
        DetectPoke()   ; (re)install the in-page keepalive on this page
        return true
    }
    ; a real login form on a live page? sign in in place
    if (gSock && !IsLoggedIn() && EnsureLogin()) {
        DetectPoke()
        return true
    }
    ; zombie session or wedged/dead page - fresh tab, fresh sign-in
    if !NewTab()
        return false
    if !EnsureLogin()
        return false
    DetectPoke()   ; fresh page = fresh window = interval must be reinstalled
    return true
}

; drop ALL IDS tabs (even wedged ones - HTTP close works when evals don't)
; and open a brand-new xtapp target
NewTab() {
    global
    if (gSock) {
        WS_CloseSocket(gSock)
        gSock := 0
    }
    local list := HttpGet("/json/list")
    local pos := 1, blk, im, im1
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (InStr(blk, CFG_HOST) && InStr(blk, """page""") && RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im))
            HttpGet("/json/close/" im1)
    }
    gTargetId := ""
    Sleep, 500
    return OpenPage()   ; no IDS tab left -> cold path creates a fresh one
}

; TRUE server liveness. A zombie page still answers JS and shows a logged-in
; title, but the RAP _requestCounter only advances when the SERVER answers a
; send(). Frozen counter after a real send = dead session.
SessionAlive() {
    global gBatch
    jsCnt := "(function(){try{return ''+rwt.remote.Connection.getInstance()._requestCounter;}catch(e){return 'NA';}})()"
    c0 := CDP_Eval(jsCnt)
    if (c0 = "NA" || c0 = "")
        return IsLoggedIn()   ; counter not exposed - fall back to title check
    CDP_Eval(JsRapSend())
    Loop, 12 {
        Sleep, 250
        c1 := CDP_Eval(jsCnt)
        if (c1 != "" && c1 != "NA" && c1 != c0)
            return true
    }
    if (gBatch)
        BLog("sessionalive: counter frozen at " c0 " - server session dead")
    return false
}

;============================ keepalive poke ==================================
; A real RAP request resets the server-side session timer. Preferred: call the
; RAP client's own send() (empty request, no UI side effects). Fallback: poke
; the menu search box (type+clear), which also generates server traffic.
; The same JS also installs an IN-PAGE setInterval keepalive (window.__ivKA)
; that keeps poking even after this script exits - the AHK SetTimer dies with
; the process, but the page timer lives as long as the background Chrome does
; (timer throttling is disabled via launch flags), so a closed GUI no longer
; means the server session times out overnight. A fresh tab auto-reinstalls it
; on the first poke/DetectPoke of the next run.
JsRapSend() {
    global CFG_KEEPALIVE
    return "(function(){if(!window.__ivSend){window.__ivSend=function(){try{if(window.rwt&&rwt.remote&&rwt.remote.Connection&&rwt.remote.Connection.getInstance){rwt.remote.Connection.getInstance().send();return 'sent-conn';}}catch(e){}try{if(window.rwt&&rwt.remote&&rwt.remote.Server&&rwt.remote.Server.getInstance){rwt.remote.Server.getInstance().send();return 'sent-server';}}catch(e){}try{if(window.org&&org.eclipse&&org.eclipse.swt&&org.eclipse.swt.Request&&org.eclipse.swt.Request.getInstance){org.eclipse.swt.Request.getInstance().send();return 'sent-legacy';}}catch(e){}return 'no';};}if(!window.__ivKA){window.__ivKA=setInterval(function(){try{window.__ivSend();}catch(e){}}," CFG_KEEPALIVE ");}return window.__ivSend();})()"
}
DetectPoke() {
    global gPokeMode
    r := CDP_Eval(JsRapSend())
    gPokeMode := InStr(r, "sent") ? ("rap:" r) : "menu"
}
Poke() {
    global gPokeMode
    if (gPokeMode = "")
        DetectPoke()
    if InStr(gPokeMode, "rap") {
        r := CDP_Eval(JsRapSend())
        if InStr(r, "sent")
            return true
        gPokeMode := "menu"
    }
    return MenuPoke()
}
MenuPoke() {
    jsMenu := "(function(){var e=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&r.width>0&&r.top<140&&r.left<400;})[0];if(!e)return'';var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !Coord(jsMenu, mx, my)
        return false
    Click(mx, my)
    InsertText("D")
    Sleep, 350
    SelAllDel()
    KeyPress("Escape", 27)
    return true
}

;=============================== lookup ========================================
; returns key=value lines, "NOTFOUND" for a genuine no-record, "" on error
; Every bail in the two walks below used to be a bare `return ""`, and the
; screen said "Isuzu did not answer" for all of them - the same six words for a
; dead socket, a form that never rendered, a number that would not stay in the
; field and a poll that ran out. Nothing was written to the log either, so the
; one failure worth diagnosing was the one that left no trace. LkFail carries
; the stage back to DoLookup, which logs it and picks the honest message.
LkFail(why) {
    global gFailWhy, gCdpDead
    gFailWhy := why (gCdpDead ? "  [the connection died during this]" : "")
    return ""
}

; The screen we were stuck on, into session.log - not BLog, which only writes
; in batch mode, because the failures worth reading about happen to real users
; on real counters, never to a batch run.
LkDump(tag) {
    local t
    t := B64Decode(CDP_Eval(DumpLeafJS()))
    if (t = "") {
        SLog("dump " tag ": nothing readable - the page did not answer")
        return
    }
    if (StrLen(t) > 3000)
        t := SubStr(t, 1, 3000) "`n...(truncated)"
    SLog("dump " tag " BEGIN`n" t "`ndump " tag " END")
}

Lookup(field, value) {
    global gBatch, gLog, gDump, gFailWhy, gCdpDead
    gFailWhy := "", gCdpDead := false
    if (field = "part")
        return PartLookup(value)
    labelmap := {vin:"Vin Number", serial:"Serial Number", rego:"Registration No.", engine:"Engine Number"}
    ; open DC611 via the Menu search box
    jsMenu := "(function(){var e=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&r.width>0&&r.top<140&&r.left<400;})[0];if(!e)return'';var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !Coord(jsMenu, mx, my)
        return LkFail("DC611: the menu search box was not on screen")
    Click(mx, my)
    SelAllDel()
    InsertText("DC611")
    Sleep, 250
    KeyPress("Enter", 13)
    ; wait for the entry form to render (poll, not fixed sleep)
    lbl := labelmap[field]
    jsField := "(function(){var ins=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),x:r.left,cx:r.left+r.width/2,cy:r.top+r.height/2,w:r.width,ro:e.readOnly};}).filter(function(i){return i.w>0;});var lab=ins.find(function(i){return i.v===" JsQuote(lbl) ";});if(!lab)return'';var c=ins.filter(function(i){return !i.ro&&Math.abs(i.cy-lab.cy)<12&&i.x>lab.x;});c.sort(function(a,b){return a.x-b.x;});if(!c.length)return'';return Math.round(c[0].cx)+','+Math.round(c[0].cy);})()"
    if !WaitCoord(jsField, fx, fy, 6000, 200) {
        ; fallback: retry the menu open with slow per-key typing
        if !Coord(jsMenu, mx, my)
            return LkFail("DC611: the menu search box vanished on the retry")
        Click(mx, my)
        SelAllDel()
        TypeText("DC611")
        Sleep, 300
        KeyPress("Enter", 13)
        if !WaitCoord(jsField, fx, fy, 8000, 250)
            return LkFail("DC611: the " field " entry form never rendered (14s)")
    }
    ; type the query into the field and verify it landed (retry up to 3x)
    entered := false
    Loop, 3 {
        Click(fx, fy)
        SelAllDel()
        Sleep, 60
        if (A_Index < 3)
            InsertText(value)
        else
            TypeText(value)
        Sleep, 120
        jsRead := "(function(){var ins=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),cy:r.top+r.height/2,cx:r.left+r.width/2,w:r.width};}).filter(function(i){return i.w>0;});var m=ins.find(function(i){return Math.abs(i.cx-" fx ")<3&&Math.abs(i.cy-" fy ")<3;});return m?m.v:'';})()"
        got := CDP_Eval(jsRead)
        StringUpper, gU, got
        StringUpper, vU, value
        if (gU = vU) {
            entered := true
            break
        }
        if (gBatch)
            BLog("field entry attempt " A_Index ": got=""" got """")
    }
    if (!entered)
        return LkFail("DC611: the query would not stay in the field (read back """ got """)")
    ; click OK
    jsOK := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='OK';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !Coord(jsOK, ox, oy)
        return LkFail("DC611: no OK button on the entry form")
    Click(ox, oy)
    ; poll for the result screen to render (a 17-char VIN value appears), else
    ; a not-found message, up to ~12s
    txt := ""
    jsReady := "(function(){var vin=Array.from(document.querySelectorAll('input')).some(function(e){var r=e.getBoundingClientRect();if(r.width<=0)return false;var v=(e.value||'').trim();return v.length===17&&/^[A-Za-z0-9]+$/.test(v);});var msg=Array.from(document.querySelectorAll('*')).some(function(x){return x.children.length<=1&&/not found|no record|does not exist|invalid/i.test((x.innerText||''));});return vin?'ok':(msg?'none':'wait');})()"
    jsCamp := "(function(){return Array.from(document.querySelectorAll('input')).some(function(e){var r=e.getBoundingClientRect();return r.width>0&&/unit is part of an outstanding campaign/i.test(e.value||'');})?'1':'0';})()"
    ; IDS shows NO "not found" text for a bad VIN - it just bounces back to the
    ; entry screen with the field CLEARED. A visible editable empty field where
    ; our query used to be, with no result rendered, means "no record".
    jsCleared := "(function(){var ins=Array.from(document.querySelectorAll('input')).filter(function(e){var r=e.getBoundingClientRect();return r.width>0;});var lab=ins.find(function(e){return (e.value||'').trim()===" JsQuote(lbl) ";});if(!lab)return'0';var lr=lab.getBoundingClientRect();var c=ins.filter(function(e){var r=e.getBoundingClientRect();return !e.readOnly&&Math.abs((r.top+r.height/2)-(lr.top+lr.height/2))<12&&r.left>lr.left;});return (c.length&&(c[0].value||'').trim()==='')?'1':'0';})()"
    clearedHits := 0
    campHits := 0
    Loop, 40 {
        Sleep, 300
        st := CDP_Eval(jsReady)
        if (gBatch && gDump)
            BLog("poll " A_Index ": st=" st " cleared=" CDP_Eval(jsCleared))
        if (st = "ok") {
            ; the typed entry field is ALSO a 17-char input, so "ok" can fire
            ; while the entry screen is still up. Only accept a read whose
            ; vin cell actually resolved; otherwise keep polling.
            Sleep, 250   ; let the rest of the fields paint
            ; campaign warning screen? acknowledge it (Enter) to reach the
            ; real record, then keep polling. (checked AFTER the screen has
            ; painted, or the warning can slip past the check)
            if (CDP_Eval(jsCamp) = "1" && campHits < 5) {
                campHits += 1
                if (gBatch)
                    BLog("campaign screen - pressing Enter (" campHits ")")
                KeyPress("Enter", 13)
                Sleep, 400
                continue
            }
            b64 := CDP_Eval(ReadResultJS())
            t := B64Decode(b64)
            ; NOTE: [^\r\n]+ not .+ — AHK v1 treats only \r\n as newline, so
            ; with m) a dot can walk straight across our \n-separated lines.
            if RegExMatch(t, "m)^vin=[^\r\n]+") {
                txt := t
                ; campaign header on the record screen? flag it in the output
                hdr := CDP_Eval("(function(){return Array.from(document.querySelectorAll('input')).some(function(e){var r=e.getBoundingClientRect();return r.width>0&&/outstanding campaign/i.test(e.value||'');})?'1':'0';})()")
                txt .= "`ncampaign=" (hdr = "1" ? "YES - outstanding campaign on this unit" : "")
                if (gDump) {
                    Sleep, 400
                    BLog("DUMP-BEGIN")
                    BLog(B64Decode(CDP_Eval(DumpAllJS())))
                    BLog("DUMP-END")
                }
                break
            }
        } else if (st = "none") {
            txt := "NOTFOUND"
            break
        } else {
            ; entry field cleared by the server + no result = record rejected.
            ; require 3 consecutive sightings (~1s) so a mid-render blank
            ; can't fake a not-found.
            if (CDP_Eval(jsCleared) = "1") {
                clearedHits += 1
                if (clearedHits >= 3) {
                    txt := "NOTFOUND"
                    break
                }
            } else {
                clearedHits := 0
            }
        }
    }
    ; NOTE: DC611 tab is closed by the caller via CleanupForms() AFTER the
    ; result is already displayed, so the user sees data sooner.
    if (txt = "")
        return LkFail("DC611: 12s of polling and the record never rendered (last screen state """ st """)")
    return txt
}

;--------------------- DC210 Item/Order Enquiry (parts) -----------------------
; Same session, different screen: opens DC210 from the menu box, types the part
; number, clicks OK, then reads description/prices/stock LABEL-RELATIVE (find
; the label element, take the input(s) to its right on the same row) - never by
; absolute pixel coordinates, because this form's layout differs per window.
; Returns key=value lines, "NOTFOUND", or "" on error.
PartLookup(value) {
    global gBatch, gLog, gDump
    jsMenu := "(function(){var e=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&r.width>0&&r.top<140&&r.left<400;})[0];if(!e)return'';var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !Coord(jsMenu, mx, my)
        return LkFail("DC210: the menu search box was not on screen")
    Click(mx, my)
    SelAllDel()
    InsertText("DC210")
    Sleep, 250
    KeyPress("Enter", 13)
    ; wait for the Item# entry field: label can be an input (like DC611) or a
    ; plain text element, so check both; entry field = first EDITABLE input to
    ; the label's right on the same row
    jsItem := "(function(){var vis=function(r){return r.width>0&&r.height>0;};var lab=null;var els=document.querySelectorAll('input,div,span,label,td');for(var i=0;i<els.length;i++){var e=els[i];var r=e.getBoundingClientRect();if(!vis(r))continue;var t=(e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();if(t==='Item#'){lab=r;break;}}if(!lab)return'';var ins=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&!x.disabled&&vis(r)&&Math.abs((r.top+r.height/2)-(lab.top+lab.height/2))<12&&r.left>lab.left;});ins.sort(function(a,b){return a.getBoundingClientRect().left-b.getBoundingClientRect().left;});if(!ins.length)return'';var r=ins[0].getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !WaitCoord(jsItem, fx, fy, 6000, 200) {
        ; fallback: retry the menu open with slow per-key typing
        if !Coord(jsMenu, mx, my)
            return LkFail("DC210: the menu search box vanished on the retry")
        Click(mx, my)
        SelAllDel()
        TypeText("DC210")
        Sleep, 300
        KeyPress("Enter", 13)
        if !WaitCoord(jsItem, fx, fy, 8000, 250) {
            if (gBatch) {
                BLog("PART-NOFORM-DUMP-BEGIN")
                BLog(B64Decode(CDP_Eval(DumpLeafJS())))
                BLog("PART-NOFORM-DUMP-END")
            }
            return LkFail("DC210: the Item# form never rendered (14s)")
        }
    }
    ; type the part number and verify it landed (retry up to 3x)
    entered := false
    Loop, 3 {
        Click(fx, fy)
        SelAllDel()
        Sleep, 60
        if (A_Index < 3)
            InsertText(value)
        else
            TypeText(value)
        Sleep, 120
        jsRead := "(function(){var ins=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),cy:r.top+r.height/2,cx:r.left+r.width/2,w:r.width};}).filter(function(i){return i.w>0;});var m=ins.find(function(i){return Math.abs(i.cx-" fx ")<3&&Math.abs(i.cy-" fy ")<3;});return m?m.v:'';})()"
        got := CDP_Eval(jsRead)
        StringUpper, gU, got
        StringUpper, vU, value
        if (gU = vU) {
            entered := true
            break
        }
        if (gBatch)
            BLog("part entry attempt " A_Index ": got=""" got """")
    }
    if (!entered)
        return LkFail("DC210: the part number would not stay in the Item# field (read back """ got """)")
    ; click OK
    jsOK := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='OK';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !Coord(jsOK, ox, oy)
        return LkFail("DC210: no OK button on the Item# form")
    Click(ox, oy)
    ; poll for the result: a non-empty input right of the "List Price" label
    ; means the record rendered; a not-found style message means no record
    jsReady := "(function(){var vis=function(r){return r.width>0&&r.height>0;};var term=Array.from(document.querySelectorAll('div,span,td')).some(function(x){var r=x.getBoundingClientRect();return vis(r)&&x.children.length===0&&/program terminated/i.test((x.innerText||''));});if(term)return 'term';var lab=null;var els=document.querySelectorAll('input,div,span,label,td');for(var i=0;i<els.length;i++){var e=els[i];var r=e.getBoundingClientRect();if(!vis(r))continue;var t=(e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();if(t==='List Price'){lab=r;break;}}if(lab){var ins=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return vis(r)&&Math.abs((r.top+r.height/2)-(lab.top+lab.height/2))<12&&r.left>lab.left&&(x.value||'').trim()!=='';});if(ins.length)return 'ok';}var msg=Array.from(document.querySelectorAll('*')).some(function(x){return x.children.length<=1&&/not found|no record|does not exist|invalid item/i.test((x.innerText||''));});if(msg)return 'none';var il=null;var e2=document.querySelectorAll('input,div,span,label,td');for(var j=0;j<e2.length;j++){var q=e2[j];var qr=q.getBoundingClientRect();if(!vis(qr))continue;var qt=(q.tagName==='INPUT'?(q.value||''):(q.children.length===0?(q.innerText||''):'')).trim();if(qt==='Item#'){il=qr;break;}}if(il){var ii=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return vis(r)&&Math.abs((r.top+r.height/2)-(il.top+il.height/2))<12&&r.left>il.left;});ii.sort(function(a,b){return a.getBoundingClientRect().left-b.getBoundingClientRect().left;});if(ii.length&&(ii[0].value||'').trim()!==''&&(!ii[1]||(ii[1].value||'').trim()===''))return 'empty';}return 'wait';})()"
    txt := ""
    ; "empty" = the DC210 form is up, our number is in Item#, and the record
    ; fields are still blank. That is also what the first moment after clicking
    ; OK looks like, so it only means NOT FOUND once it has held still. A real
    ; record fills in on the first poll (~300ms); 15 polls is 4.5s of margin.
    empties := 0
    Loop, 40 {
        Sleep, 300
        st := CDP_Eval(jsReady)
        if (st = "empty") {
            if (++empties >= 15) {
                if (gBatch)
                    BLog("DC210 form stayed empty - no such item")
                txt := "NOTFOUND"
                break
            }
        } else {
            empties := 0
        }
        if (gBatch)
            BLog("part poll " A_Index ": st=" st)
        if (st = "ok") {
            Sleep, 300   ; let the stock grid paint
            b64 := CDP_Eval(PartReadJS())
            t := B64Decode(b64)
            if RegExMatch(t, "m)^part=[^\r\n]+") {
                txt := t
                if (gDump) {
                    BLog("DUMP-BEGIN")
                    BLog(B64Decode(CDP_Eval(DumpAllJS())))
                    BLog("DUMP-END")
                }
                break
            }
        } else if (st = "none") {
            txt := "NOTFOUND"
            break
        } else if (st = "term") {
            ; DC210 kills its own program instance when the item number does
            ; not exist. We only reach this AFTER the number was typed into the
            ; form, read back to confirm it landed, and OK was clicked - so the
            ; item is the cause; a session or transport fault would have failed
            ; earlier. Clear the dialog so the screen is clean for the next
            ; read, and call it what it is instead of "Isuzu did not answer".
            if (gBatch)
                BLog("DC210 'Program terminated' after a valid submit - treating as NOTFOUND")
            DismissTermination()
            return "NOTFOUND"
        }
    }
    ; timed out with nothing recognized - dump every visible text so the log
    ; shows exactly what screen we were stuck on
    if (txt = "" && gBatch) {
        BLog("PART-STUCK-DUMP-BEGIN")
        BLog(B64Decode(CDP_Eval(DumpLeafJS())))
        BLog("PART-STUCK-DUMP-END")
    }
    if (txt = "")
        return LkFail("DC210: 12s of polling and the record never rendered (last screen state """ st """)")
    return txt
}


;=========================== DC210 Item News ==================================
; The news is three screens deep: News F20 opens WAPR031 (the index of news
; types held against this item), a row there opens WAPR031A, and the text is
; on that. Nobody walks that far, so this walks it - AFTER the part record is
; already on screen, so it never delays the figures anyone is waiting for.
; Returns the news text (one line per news line) or "" when there is none.
NewsFetch() {
    global gBatch
    if !Coord(JsLeaf("News F20"), bx, by) {
        SLog("news: no News F20 button")
        return ""
    }
    Click(bx, by)
    ; the index screen: TECH when it is listed, else whatever the first row
    ; is. No index screen and no rows both mean the same thing - no news.
    if !WaitCoord(NewsRowJS(), ix, iy, 6000, 200) {
        SLog("news: no index row; leaf dump follows")
        SLog(B64Decode(CDP_Eval(DumpLeafJS())))
        NewsBack()
        return ""
    }
    ; the index row opens on a double-click, and ONLY on a double-click:
    ; selecting it and pressing OK leaves the index sitting there
    DblClick(ix, iy)
    txt := NewsRead(6000)
    if (txt = "") {
        ; ...but if a future screen ever does want the button, take it
        if Coord(JsLeaf("OK"), ox, oy) {
            Click(ox, oy)
            txt := NewsRead(4000)
        }
    }
    if (txt = "") {
        SLog("news: no Item News text; leaf dump follows")
        SLog(B64Decode(CDP_Eval(DumpLeafJS())))
    } else {
        SLog("news: " StrReplace(txt, "`n", " | "))
    }
    NewsBack()
    return txt
}

; poll for the WAPR031A text; "" if the screen never arrives
NewsRead(timeoutMs) {
    n := Round(timeoutMs / 250)
    Loop, %n% {
        Sleep, 250
        t := B64Decode(CDP_Eval(NewsReadJS()))
        if (t != "")
            return t
    }
    return ""
}

; back out to DC210 with the record still on it. CleanupForms() closes the lot
; a moment later anyway; this is so a failed walk cannot leave a news screen
; sitting in front of the next lookup.
NewsBack() {
    Loop, 4 {
        if (CDP_Eval(NewsOnPartJS()) = "1")
            return true
        if !Coord(JsLeaf("Exit F3"), ex, ey)
            return false
        Click(ex, ey)
        Sleep, 400
    }
    return (CDP_Eval(NewsOnPartJS()) = "1")
}

; RWT grids open a row on the second click of a real double-click, so the
; first click has to be a plain one and the pair has to carry clickCount 2.
DblClick(x, y) {
    Click(x, y)
    p := "{""type"":""mousePressed"",""x"":" x ",""y"":" y ",""button"":""left"",""clickCount"":2}"
    CDP_Cmd("Input.dispatchMouseEvent", p)
    p := "{""type"":""mouseReleased"",""x"":" x ",""y"":" y ",""button"":""left"",""clickCount"":2}"
    CDP_Cmd("Input.dispatchMouseEvent", p)
}

; centre of the first visible element whose whole text is exactly this label -
; the same trick the OK and Exit F3 clicks already use, given a name
JsLeaf(label) {
    return "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()===" JsQuote(label) ";});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
}

; WAPR031: the row to open, under the "Index Value" column header
NewsRowJS() {
    return "(function(){var vis=function(r){return r.width>0&&r.height>0;};var all=Array.from(document.querySelectorAll('div,span,td,label')).map(function(e){var r=e.getBoundingClientRect();return{t:(e.children.length===0?(e.innerText||''):'').trim(),r:r};}).filter(function(i){return vis(i.r)&&i.t!=='';});var hdr=all.find(function(i){return i.t==='Index Value';});if(!hdr)return'';var rows=all.filter(function(i){return i.r.top>hdr.r.bottom+2&&i.r.left>hdr.r.left-20&&i.r.left<hdr.r.left+60&&i.t.length<20;});rows.sort(function(a,b){return a.r.top-b.r.top;});var pick=null;for(var i=0;i<rows.length;i++){if(rows[i].t==='TECH'){pick=rows[i];break;}}if(!pick)pick=rows[0];if(!pick)return'';return Math.round(pick.r.left+pick.r.width/2)+','+Math.round(pick.r.top+pick.r.height/2);})()"
}

; WAPR031A: every line under the "Item News" column header, base64. The page
; number column sits to the LEFT of that header, which is what keeps row
; numbers out of the text.
NewsReadJS() {
    return "(function(){var vis=function(r){return r.width>0&&r.height>0;};var all=Array.from(document.querySelectorAll('div,span,td,label')).map(function(e){var r=e.getBoundingClientRect();return{t:(e.children.length===0?(e.innerText||''):'').trim(),r:r};}).filter(function(i){return vis(i.r)&&i.t!=='';});var hdr=all.find(function(i){return i.t==='Item News';});if(!hdr)return'';var cells=all.filter(function(i){return i.r.top>hdr.r.bottom+2&&i.r.left>=hdr.r.left-6&&!/^(OK|Exit F3|Previous F2|Select All F21)$/.test(i.t);});cells.sort(function(a,b){return a.r.top-b.r.top||a.r.left-b.r.left;});var lines=[];var cur=[];var lastY=-99;var flush=function(){if(cur.length)lines.push(cur.join(' '));cur=[];};cells.forEach(function(c){if(c.r.top-lastY>5)flush();cur.push(c.t);lastY=c.r.top;});flush();lines=lines.slice(0,12);if(!lines.length)return'';return btoa(unescape(encodeURIComponent(lines.join('\n'))));})()"
}

; '1' when DC210 with a record is what is on screen - no news screen over it
NewsOnPartJS() {
    return "(function(){var vis=function(r){return r.width>0&&r.height>0;};var txt=function(e){return (e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();};var all=Array.from(document.querySelectorAll('input,div,span,td,label')).filter(function(e){return vis(e.getBoundingClientRect());});var has=function(s){return all.some(function(e){return txt(e)===s;});};return (has('List Price')&&!has('Item News')&&!has('Index Value'))?'1':'0';})()"
}

; diagnostic: every visible leaf text element AND non-empty input as x,y=text
DumpLeafJS() {
    return "(function(){var items=[];Array.from(document.querySelectorAll('input,div,span,label,td,button')).forEach(function(e){var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)return;var t=(e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();if(t==='')return;items.push({v:t.substring(0,60),x:Math.round(r.left),y:Math.round(r.top)});});items.sort(function(a,b){return a.y-b.y||a.x-b.x;});return btoa(unescape(encodeURIComponent(items.map(function(i){return i.x+','+i.y+'='+i.v;}).join('\n'))));})()"
}

; read the DC210 record label-relative; stock grid rows come from leaf text
; elements below the "Stock Available" header, snapped to the nearest column
PartReadJS() {
    return "(function(){var vis=function(r){return r.width>0&&r.height>0;};var leaf=function(e){return (e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();};var all=Array.from(document.querySelectorAll('input,div,span,label,td')).map(function(e){var r=e.getBoundingClientRect();return{e:e,t:leaf(e),r:r};}).filter(function(i){return vis(i.r)&&i.t!=='';});var rowInput=function(label,skip){var lab=all.find(function(i){return i.t===label;});if(!lab)return'';var ins=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return vis(r)&&Math.abs((r.top+r.height/2)-(lab.r.top+lab.r.height/2))<12&&r.left>lab.r.left;});ins.sort(function(a,b){return a.getBoundingClientRect().left-b.getBoundingClientRect().left;});var e=ins[skip||0];return e?(e.value||'').trim():'';};var out=[];out.push('part='+rowInput('Item#',0));out.push('desc='+rowInput('Item#',1));out.push('active='+rowInput('Active',0));out.push('discount='+rowInput('Discount code',0));out.push('class='+rowInput('Class',0));out.push('list='+rowInput('List Price',0));out.push('trade='+rowInput('Trade Price',0));out.push('daily='+rowInput('Daily Order',0));out.push('stock_order='+rowInput('Stock Order',0));out.push('repl='+rowInput('Repl#',0));out.push('old='+rowInput('Old#',0));out.push('oldest='+rowInput('Oldest',0));var hdr=all.find(function(i){return i.t==='Stock Available';});if(hdr){var names=['Whs','Stock Available','PO Number','Qty on Order','Min. Sell','Estimated Arrival Date','P/O Status','Pack Size'];var cols=[];names.forEach(function(n){var h=all.find(function(i){return i.t===n&&Math.abs(i.r.top-hdr.r.top)<10;});if(h)cols.push({n:n,x:h.r.left});});var cells=all.filter(function(i){return i.r.top>hdr.r.bottom+2&&i.r.top<hdr.r.bottom+330&&i.t.length<40&&i.t!=='OK'&&!/F\d+$/.test(i.t)&&(cols.length?i.r.left>=cols[0].x-15:false);});cells.sort(function(a,b){return a.r.top-b.r.top||a.r.left-b.r.left;});var lines=[];var cur=[];var lastY=-99;var flush=function(){if(!cur.length)return;var m={};cur.forEach(function(c){var best=null,bd=1e9;cols.forEach(function(col){var d=Math.abs(c.r.left-col.x);if(d<bd){bd=d;best=col;}});if(best&&!(best.n in m))m[best.n]=c.t;});if(m['Whs']!==undefined)lines.push(m['Whs']+'|'+(m['Stock Available']||'')+'|'+(m['Qty on Order']||'')+'|'+(m['Min. Sell']||'')+'|'+(m['Pack Size']||''));cur=[];};cells.forEach(function(c){if(c.r.top-lastY>5)flush();cur.push(c);lastY=c.r.top;});flush();lines.slice(0,9).forEach(function(l,i){out.push('stock'+(i+1)+'='+l);});}return btoa(unescape(encodeURIComponent(out.join('\n'))));})()"
}

; When a server-side program instance dies (e.g. DC210 hit with a bad item),
; IDS replaces the whole tab's content with "Termination / Program terminated".
; The tab is dead - no buttons, keys do nothing. The only way out is closing
; the tab via the X on its tab header (a ~16px child at the label's right).
DismissTermination() {
    jsT := "(function(){return Array.from(document.querySelectorAll('div,span,td,input')).some(function(x){var r=x.getBoundingClientRect();if(r.width<=0||r.height<=0)return false;var v=(x.tagName==='INPUT'?(x.value||''):(x.children.length===0?(x.innerText||''):'')).trim();return /program terminated/i.test(v);})?'1':'0';})()"
    jsX := "(function(){var tabs=Array.from(document.querySelectorAll('div')).filter(function(e){var r=e.getBoundingClientRect();return r.height>18&&r.height<30&&r.top<80&&r.width>80&&r.width<420&&/^DC\d+/.test((e.innerText||'').trim())&&e.children.length>=2;});if(!tabs.length)return'';var t=tabs[0];var kids=Array.from(t.children).map(function(c){return c.getBoundingClientRect();}).filter(function(r){return r.width>=10&&r.width<=20;});if(!kids.length)return'';var r=kids[kids.length-1];return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    Loop, 3 {
        if (CDP_Eval(jsT) != "1")
            return true
        if Coord(jsX, tx, ty) {
            Click(tx, ty)
            Sleep, 600
            continue
        }
        ; no tab X found - last-ditch keys
        KeyPress("Enter", 13)
        Sleep, 400
        KeyPress("Escape", 27)
        Sleep, 400
    }
    return (CDP_Eval(jsT) != "1")
}

; close any open DC611 screens (Exit F3) until none remain (max 3 levels)
CleanupForms() {
    DismissTermination()
    ; closing a dead tab (or the death itself) can throw up the mid-session
    ; re-auth challenge - sign back in in place before touching anything else
    if (!IsLoggedIn())
        EnsureLogin()
    jsExit := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='Exit F3';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    Loop, 3 {
        if !Coord(jsExit, ex, ey)
            break
        Click(ex, ey)
        Sleep, 500
    }
}

; diagnostic: every non-empty input as "x,y=value" lines (base64)
DumpAllJS() {
    return "(function(){var items=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),x:Math.round(r.left),y:Math.round(r.top),w:Math.round(r.width)};}).filter(function(i){return i.w>0&&i.v!=='';});items.sort(function(a,b){return a.y-b.y||a.x-b.x;});return btoa(unescape(encodeURIComponent(items.map(function(i){return i.x+','+i.y+'='+i.v;}).join('\n'))));})()"
}

JsQuote(s) {
    return "'" StrReplace(s, "'", "\'") "'"
}

ReadResultJS() {
    return "(function(){var cells={vin:[419,140],year:[697,140],group:[847,140],model:[419,164],model_desc:[605,164],colour_code:[419,188],colour:[475,188],trim_code:[761,188],trim:[817,188],engine:[467,210],activity:[973,231],key_number:[500,276],status_code:[811,299],status:[835,299],rego:[500,322],selling_dealer:[811,345],build_date:[499,368],retail_sale:[810,368],purpose_code:[1008,368],warranty_start:[810,414],sold_to_dealer:[500,437],warranty_expiry:[810,437],kms:[965,437],date_to_dealer:[499,483],comments:[500,512]};var items=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),x:Math.round(r.left),y:Math.round(r.top),w:Math.round(r.width)};}).filter(function(i){return i.w>0&&i.v!=='';});var out=[];var tol=28;Object.keys(cells).forEach(function(k){var cx=cells[k][0],cy=cells[k][1],best='',bd=tol+1;items.forEach(function(i){var d=Math.abs(i.x-cx)+Math.abs(i.y-cy);if(d<bd){bd=d;best=i.v;}});out.push(k+'='+best);});return btoa(unescape(encodeURIComponent(out.join('\n'))));})()"
}

;==============================================================================
; WS - minimal WebSocket client over raw Winsock (ws2_32), merged from WS.ahk
;==============================================================================
; Minimal WebSocket client over raw Winsock (ws2_32) for AutoHotkey v1.
; No permessage-deflate; plain text/binary frames. Client frames are masked.
; Designed for Chrome DevTools Protocol on localhost.

WS_Startup() {
    static done := 0
    if (done)
        return
    VarSetCapacity(wsadata, 408, 0)
    DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", &wsadata)
    done := 1
}

; Connect a TCP socket to host:port and perform the WS upgrade for `path`.
; Returns socket handle (>0) or 0 on failure.
WS_Connect(host, port, path) {
    WS_Startup()
    AF_INET := 2, SOCK_STREAM := 1, IPPROTO_TCP := 6
    sock := DllCall("ws2_32\socket", "Int", AF_INET, "Int", SOCK_STREAM, "Int", IPPROTO_TCP, "Ptr")
    if (sock = -1 || sock = 0)
        return 0

    ; resolve host via inet_addr (localhost -> 127.0.0.1)
    if (host = "localhost")
        host := "127.0.0.1"
    addr := DllCall("ws2_32\inet_addr", "AStr", host, "UInt")

    VarSetCapacity(sa, 16, 0)
    NumPut(AF_INET, sa, 0, "UShort")
    ; port network byte order
    NumPut(((port & 0xFF) << 8) | ((port >> 8) & 0xFF), sa, 2, "UShort")
    NumPut(addr, sa, 4, "UInt")
    r := DllCall("ws2_32\connect", "Ptr", sock, "Ptr", &sa, "Int", 16, "Int")
    if (r != 0) {
        WS_CloseSocket(sock)
        return 0
    }
    ; receive timeout (ms) so a broken session can't freeze forever
    SOL_SOCKET := 0xFFFF, SO_RCVTIMEO := 0x1006
    tmo := 10000
    DllCall("ws2_32\setsockopt", "Ptr", sock, "Int", SOL_SOCKET, "Int", SO_RCVTIMEO, "UInt*", tmo, "Int", 4)

    ; websocket handshake (omit Sec-WebSocket-Extensions => no compression)
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    req := "GET " path " HTTP/1.1`r`n"
         . "Host: " host ":" port "`r`n"
         . "Upgrade: websocket`r`n"
         . "Connection: Upgrade`r`n"
         . "Sec-WebSocket-Key: " key "`r`n"
         . "Sec-WebSocket-Version: 13`r`n"
         . "`r`n"
    if !WS_SendRaw(sock, req) {
        WS_CloseSocket(sock)
        return 0
    }
    ; read handshake response headers up to \r\n\r\n
    resp := ""
    Loop {
        chunk := WS_RecvSome(sock, 1)
        if (chunk = "")
            break
        resp .= chunk
        if (InStr(resp, "`r`n`r`n"))
            break
        if (StrLen(resp) > 8192)
            break
    }
    if !InStr(resp, " 101 ") {
        WS_CloseSocket(sock)
        return 0
    }
    return sock
}

; send raw bytes from an AHK string (UTF-8)
WS_SendRaw(sock, str) {
    len := StrPut(str, "UTF-8") - 1
    VarSetCapacity(buf, len + 1)
    StrPut(str, &buf, "UTF-8")
    sent := 0
    while (sent < len) {
        n := DllCall("ws2_32\send", "Ptr", sock, "Ptr", &buf + sent, "Int", len - sent, "Int", 0, "Int")
        if (n <= 0)
            return false
        sent += n
    }
    return true
}

; send raw bytes from a buffer pointer
WS_SendBuf(sock, ptr, len) {
    sent := 0
    while (sent < len) {
        n := DllCall("ws2_32\send", "Ptr", sock, "Ptr", ptr + sent, "Int", len - sent, "Int", 0, "Int")
        if (n <= 0)
            return false
        sent += n
    }
    return true
}

; receive up to `max` bytes, return as latin1 string (1 byte per char) for header parsing
WS_RecvSome(sock, max) {
    VarSetCapacity(b, max, 0)
    n := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", &b, "Int", max, "Int", 0, "Int")
    if (n <= 0)
        return ""
    return StrGet(&b, n, "CP0")   ; treat bytes as chars 0..255
}

; receive EXACTLY n bytes into buffer `outbuf` (ByRef). Returns true/false.
WS_RecvN(sock, n, ByRef outbuf) {
    VarSetCapacity(outbuf, n, 0)
    got := 0
    while (got < n) {
        r := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", &outbuf + got, "Int", n - got, "Int", 0, "Int")
        if (r <= 0)
            return false
        got += r
    }
    return true
}

; send a text frame (opcode 0x1), masked
WS_SendText(sock, text) {
    plen := StrPut(text, "UTF-8") - 1
    VarSetCapacity(payload, plen + 1, 0)
    StrPut(text, &payload, "UTF-8")

    ; header size
    if (plen < 126)
        hdr := 2
    else if (plen < 65536)
        hdr := 4
    else
        hdr := 10
    total := hdr + 4 + plen        ; +4 mask key
    VarSetCapacity(frame, total, 0)
    NumPut(0x81, frame, 0, "UChar")   ; FIN + text
    if (plen < 126) {
        NumPut(0x80 | plen, frame, 1, "UChar")
        off := 2
    } else if (plen < 65536) {
        NumPut(0x80 | 126, frame, 1, "UChar")
        NumPut((plen >> 8) & 0xFF, frame, 2, "UChar")
        NumPut(plen & 0xFF, frame, 3, "UChar")
        off := 4
    } else {
        NumPut(0x80 | 127, frame, 1, "UChar")
        ; 8-byte length, big-endian; only lower 32 bits realistic
        Loop 8 {
            shift := (8 - A_Index) * 8
            NumPut((plen >> shift) & 0xFF, frame, 1 + A_Index, "UChar")
        }
        off := 10
    }
    ; mask key
    m0 := 0x12, m1 := 0x34, m2 := 0x56, m3 := 0x78
    NumPut(m0, frame, off, "UChar"), NumPut(m1, frame, off+1, "UChar")
    NumPut(m2, frame, off+2, "UChar"), NumPut(m3, frame, off+3, "UChar")
    mask := [m0, m1, m2, m3]
    dataoff := off + 4
    Loop %plen% {
        i := A_Index - 1
        b := NumGet(payload, i, "UChar")
        NumPut(b ^ mask[Mod(i,4)+1], frame, dataoff + i, "UChar")
    }
    return WS_SendBuf(sock, &frame, total)
}

; receive one full application message (handles fragmentation + ping/close).
; Returns the text (UTF-8 decoded), or "" on error/close.
WS_RecvMessage(sock) {
    latin1 := ""          ; accumulated raw bytes as code points 0..255 (only if fragmented)
    firstText := ""       ; fast path: single-frame payload decoded directly
    frames := 0
    Loop {
        if !WS_RecvN(sock, 2, h)
            return ""
        b0 := NumGet(h, 0, "UChar")
        b1 := NumGet(h, 1, "UChar")
        fin := (b0 & 0x80) != 0
        opcode := b0 & 0x0F
        masked := (b1 & 0x80) != 0
        len := b1 & 0x7F
        if (len = 126) {
            if !WS_RecvN(sock, 2, e)
                return ""
            len := (NumGet(e,0,"UChar")<<8) | NumGet(e,1,"UChar")
        } else if (len = 127) {
            if !WS_RecvN(sock, 8, e)
                return ""
            len := 0
            Loop 8
                len := (len * 256) + NumGet(e, A_Index-1, "UChar")
        }
        if (masked) {
            if !WS_RecvN(sock, 4, mk)
                return ""
        }
        if (len > 0) {
            if !WS_RecvN(sock, len, pb)
                return ""
            if (masked) {
                mk0:=NumGet(mk,0,"UChar"),mk1:=NumGet(mk,1,"UChar"),mk2:=NumGet(mk,2,"UChar"),mk3:=NumGet(mk,3,"UChar")
                mkeys := [mk0,mk1,mk2,mk3]
                Loop %len% {
                    i := A_Index-1
                    NumPut(NumGet(pb,i,"UChar") ^ mkeys[Mod(i,4)+1], pb, i, "UChar")
                }
            }
        }
        if (opcode = 0x8)            ; close
            return ""
        if (opcode = 0x9) {          ; ping -> pong
            if (len > 0)
                WS_SendPong(sock, &pb, len)
            continue
        }
        if (opcode = 0xA)            ; pong
            continue
        ; data frame
        frames += 1
        if (frames = 1 && fin) {     ; fast path: whole message in one frame
            return (len > 0) ? StrGet(&pb, len, "UTF-8") : ""
        }
        ; fragmented: accumulate byte-accurately
        if (frames = 2 && firstText != "") {
            ; move the first frame's already-decoded text back into latin1 bytes
            ; (rare path) - re-encode firstText to utf-8 bytes
        }
        if (len > 0) {
            Loop %len%
                latin1 .= Chr(NumGet(pb, A_Index-1, "UChar"))
        }
        if (fin)
            break
    }
    n := StrLen(latin1)
    if (n = 0)
        return ""
    VarSetCapacity(raw, n+1, 0)
    Loop %n%
        NumPut(Asc(SubStr(latin1, A_Index, 1)), raw, A_Index-1, "UChar")
    return StrGet(&raw, n, "UTF-8")
}

WS_SendPong(sock, ptr, len) {
    ; minimal masked pong, echo payload
    total := 2 + 4 + len
    VarSetCapacity(f, total, 0)
    NumPut(0x8A, f, 0, "UChar")
    NumPut(0x80 | (len < 126 ? len : 0), f, 1, "UChar")
    NumPut(0,f,2,"UChar"),NumPut(0,f,3,"UChar"),NumPut(0,f,4,"UChar"),NumPut(0,f,5,"UChar")
    Loop %len%
        NumPut(NumGet(ptr,A_Index-1,"UChar") ^ 0, f, 6 + A_Index-1, "UChar")
    WS_SendBuf(sock, &f, total)
}

WS_CloseSocket(sock) {
    DllCall("ws2_32\closesocket", "Ptr", sock)
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