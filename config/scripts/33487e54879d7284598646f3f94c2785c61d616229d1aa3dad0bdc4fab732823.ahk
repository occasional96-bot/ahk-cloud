;=============================================================================
;   SuperWarehouseCheck.ahk - every part on the ERA screen, ticked in place.
;
;   Insert   (in ERA)   read the ERA screen, check every part in AUDOS, and
;                       paint the answer straight after each part number
;   Esc      (in ERA)   take the marks away (ERA still gets the Esc)
;
;   Both keys are only ours while ERA is the active window. Anywhere else
;   Insert is left alone - AUDOS_Switch uses it to bring up the KIA window,
;   and the two do not collide: this one is a keyboard-hook hotkey behind a
;   window condition, so when ERA is not in front the key falls through.
;
;   You are sitting on an invoice, a quote or a picking slip in ERA. Press
;   the hotkey. Within a moment each part number on the screen grows a small
;   mark just to its right:
;
;       [tick] 3     Sydney has 3
;       P 2          Sydney has none, Perth has 2
;       [cross] 0    neither warehouse has any
;       ?            AUDOS does not know the part
;       ...          still being looked up
;
;   Kia and Hyundai are read out of AUDOS. Isuzu and BYD have none, so this
;   file asks IDS and the BYD DMS itself - the two legs at the bottom, run as
;   a worker copy of this same script (see THE WORKERS) - and for them the
;   tick means Melbourne, with B (Brisbane) or O (other warehouses) in place
;   of P.
;
;   Every run starts with a small picker - Kia, Hyundai, Isuzu, BYD - with
;   the buttons in order of how likely each make is, read off the screen:
;   a VIN's first three letters, the Make code, the customer's name, and
;   the shape of every part number (the same tests AUDOS_Switch uses to
;   route a number to Isuzu or BYD). The best guess is the default button,
;   so Enter takes it; K, H, I and B pick by hand.
;
;   Nothing else on the screen is covered. ERA is never typed into, never
;   scrolled, never touched at all beyond the one F11 that reads it. AUDOS is
;   worked in the background: it stays where it is, behind ERA, and is never
;   brought to the front.
;
;-----------------------------------------------------------------------------
;   HOW IT WORKS
;
;   1. F11 in ERA puts the whole screen on the clipboard as plain text, the
;      same trick StockCheck and EraWord use. The clipboard is put back
;      afterwards.
;
;   2. The make is guessed off that text - see SW_MakeScores - and the
;      picker comes up with the guesses ranked. Enter takes the top one.
;
;   3. The part lines are picked out of the text. On an invoice they read
;
;        Ln# Part# / Description............. Qord Qshp List.... ...
;          1 86610H8EA0        COVER-RR BUMPE    1    1   457.17  ...
;
;      A line counts when it starts with a line number and then a part
;      number, and it comes after the "Part#" heading. Where the part number
;      ends on that line is remembered, because that is where the mark goes.
;
;   4. The screen is a grid, and EraWord's sums turn a row and column into
;      pixels: the terminal canvas is a child window of known size, the F11
;      text says how many rows and columns it holds, and the cell under any
;      character is one proportion. Nothing is measured off fonts.
;
;   5. A click-through, never-activated overlay window the exact size of the
;      terminal canvas is laid over it. Everything on it is transparent
;      except the marks. Your mouse and keyboard go through it to ERA as if
;      it were not there. Every part starts with a "..." mark.
;
;   6. The AUDOS window for that make is found the way AUDOS_Switch finds it
;      (the dealer code sits in one of its edit boxes), Part Master (DS007)
;      is opened if it is not already up, and each part is put into the part
;      field by WM_SETTEXT, entered by ControlSend, and the Sydney and Perth
;      boxes are read back by WM_GETTEXT. None of that needs the window in
;      front. As each answer lands the "..." becomes the real mark.
;
;   7. The overlay follows ERA if the window is moved, hides while ERA is not
;      the active window, and goes away on Esc, on the next run, or by itself
;      after a while.
;
;   One file: AutoHotkey v1, DllCall, and the WinHTTP object the two legs ask
;   DevTools for its tab list with. No UIA, nothing installed, nothing beside
;   it. Saved UTF-8 with BOM on purpose: the BYD leg's warehouse names are
;   Chinese, and AutoHotkey reads a BOM-less file as ANSI.
;=============================================================================

#NoEnv
; #SingleInstance Force is done by hand (SW_OneInstance), once the command
; line has been read: the Isuzu and BYD legs run as worker copies of this same
; file, and Force would have each of them replace the window it works for.
#SingleInstance Off
#Persistent
SendMode Input
SetBatchLines -1
SetTitleMatchMode 2
DetectHiddenWindows On
CoordMode, Mouse, Screen
CoordMode, ToolTip, Screen


;--- settings ---------------------------------------------------------------

global SW_ERA_EXE      := "wInteg.exe"        ; the ERA terminal
global SW_ERA_TITLE    := "ERA Port"          ; and the words in its title

global SW_AUDOS_EXE    := "MiPlatform320U.exe"
global SW_AUDOS_HINT   := "AUDOS"
global SW_HYUNDAI_RE   := "i)^\s*H3029\s*$"   ; dealer codes, as in AUDOS_Switch
global SW_KIA_RE       := "i)^\s*83340\s*$"

global SW_PART_SCREEN  := "DS007"
global SW_PART_TITLE   := "Part Master"
global SW_BOTTOM_BAR   := "bottom_frame"
global SW_STOCK_BUTTON := "Stock Locator"
global SW_HIST_BUTTON  := "History"

global SW_OPEN_WAIT_MS := 10000   ; how long to wait for Part Master to open
global SW_PART_WAIT_MS := 6000    ; how long to wait for one part to come back
global SW_SETTLE_MS    := 60      ; pause after Enter before we start looking
global SW_ENTER_RETRY_MS := 2500  ; the typed number still sitting in the field
                                  ; this long after Enter = AUDOS dropped the
                                  ; key (it does when busy); it is sent again

global SW_LINGER_MS    := 45000   ; marks stay this long after the last answer
global SW_FOLLOW_MS    := 250     ; how often the overlay checks ERA moved

; Marks. Colours are RGB hex. Text is on a pill of the background colour.
global SW_OK_BG    := "1E7A3C", SW_OK_FG    := "FFFFFF"   ; Sydney has it
global SW_PERTH_BG := "B8730F", SW_PERTH_FG := "FFFFFF"   ; Perth only
global SW_NIL_BG   := "B3261E", SW_NIL_FG   := "FFFFFF"   ; neither
global SW_UNK_BG   := "5F5E5A", SW_UNK_FG   := "FFFFFF"   ; not on file
global SW_WAIT_BG  := "3A3A3A", SW_WAIT_FG  := "DDDDDD"   ; still looking
global SW_INFO_BG  := "2F6FD0", SW_INFO_FG  := "FFFFFF"   ; the status line

global SW_KEY      := "010203"    ; the colour that is made see-through.
                                  ; Nothing we draw may use it.
global SW_FONT     := "Consolas"

global SW_DEBUG    := false        ; write what happened to swc_log.txt

; Isuzu and BYD have no AUDOS. Their parts go to the two legs at the bottom of
; this file - IDS DC210 through the Chrome the Isuzu Parts & VIN Lookup keeps
; signed in, and the BYD DMS through the Chrome the BYD Stock Lookup keeps
; signed in - each run as a worker copy of this same script that writes a
; result file (see THE WORKERS). The legs' own settings follow the state below.
global SW_ISUZU_REUSE  := "reuse"   ; the Isuzu worker stays on the DC210 form
                                    ; between parts; "" opens the menu each time


;--- state ------------------------------------------------------------------

global gSW_Kids     := []
global gSW_WantText := true
global gSW_Busy     := false
global gSW_Cancel   := false
global gSW_Shown    := false      ; overlay exists
global gSW_Rows     := []         ; one per part line: row, col, part, state
global gSW_Grid     := ""         ; { cols, rows }
global gSW_Era      := 0          ; the ERA window the marks belong to
global gSW_Term     := 0          ; its terminal canvas
global gSW_TX := 0, gSW_TY := 0, gSW_TW := 0, gSW_TH := 0
global gSW_Status   := ""         ; text of the status pill, "" for none
global gSW_StatusRow := -1
global gSW_Next     := 0          ; index of the next row to look up
global gSW_Chain    := []         ; the AUDOS window to ask
global gSW_Brand    := ""         ; the make being asked, for the status line
global gSW_Kind     := ""         ; "audos", "isuzu" or "byd"
global gSW_Alt      := "P"        ; letter on the second-warehouse mark:
                                  ; P Perth (AUDOS), B Brisbane (Isuzu), O other (BYD)
global gSW_Ctx      := ""         ; the read screen, parked while you pick a make
global gSW_PickedBrand := ""
global gSW_BydLogin := false      ; the DMS sign-in was tried this run
global gSW_TBPid   := 0          ; the running worker (see THE WORKERS), if any
global gSW_TBList  := "", gSW_TBOut := ""
global gSW_TBCodes := []         ; the codes sent, in screen order
global gSW_TBMap   := {}         ; code key -> the row indexes that carry it
global gSW_TBSeen  := {}         ; code keys already read off the out file
global gSW_BydWantLogin := false  ; a block came back signed out
global gSW_TBT0    := 0
global gSW_TBShown := -1         ; rows marked at the last status update
global gSW_Scores   := ""        ; the picker's ranking, for the log
global gSW_Done     := {}         ; part -> result, so a repeat is one lookup
global gSW_AudosCache := {}       ; brand -> {hwnd, boxes}: the last run's AUDOS,
                                  ; so the next run does not hunt for it again
global gSW_Hidden   := false
global gSW_ExpireAt := 0
global gSW_Pt       := 9


;--- the Isuzu leg's settings (IsuzuVIN.ahk's names, IZ_ in front) ----------
global IZ_VER   := "1.1"                      ; the Isuzu leg; bump by hand on every change
global IZ_CFG_USER := "D7334KT"                  ; the IDS sign-in, as IsuzuVIN.ahk has it
global IZ_CFG_PW   := "aB7xK2qLlp"
global IZ_CFG_PORT := 9412                       ; IsuzuVIN.ahk's private CDP port - the one Chrome, the one session
global IZ_CFG_HOST := "idserp.iua.net.au"
global IZ_CFG_KEEPALIVE := 240000                ; the in-page poke interval, as IsuzuVIN.ahk installs it
global IZ_CFG_STALE_MS := 3000                   ; IDS quiet this long = ask the session whether it is alive
global IZ_CFG_ROWWAIT_MS := 2000                 ; how long the stock grid gets to show the answer's rows
; The Chrome profile and pid file live with IsuzuVIN.ahk when it is beside
; this folder, so a Chrome started here is the same signed-in Chrome that
; tool attaches to, and the other way round.
global IZ_CFG_HOME := FileExist(A_ScriptDir "\..\IsuzuVIN") ? A_ScriptDir "\..\IsuzuVIN" : A_ScriptDir
global IZ_CFG_PROFILE := IZ_CFG_HOME "\chrome-profile"
global IZ_CFG_PIDFILE := IZ_CFG_HOME "\chrome.pid"
global IZ_gSock := 0          ; page-target websocket
global IZ_gId   := 0          ; CDP message id counter
global IZ_gBatch := true      ; every run here is headless: BLog writes, nothing is drawn
global IZ_gReuse := false     ; --isuzubatch reuse: stay on the DC210 form between parts
global IZ_gAttached := false  ; true when we reused an already-running session
global IZ_gLog := A_ScriptDir "\swc_isuzu.log"
global IZ_gChromePID := 0
global IZ_gPokeMode := ""     ; "rap:..." (native RAP request) or "menu" fallback
global IZ_gMx := 0            ; cross-process mutex handle
global IZ_gTargetId := ""
global IZ_gFailWhy := ""      ; WHY the last lookup came back empty, in plain words
global IZ_gCdpDead := false   ; ...and true when the socket died during it
global IZ_gLastOk := 0        ; A_TickCount of the last CONFIRMED-live server contact
global IZ_gStale := false     ; the last lookup timed out waiting on IDS to answer

;--- the BYD leg's settings (BydStock.ahk's names, BY_ in front) ------------
global BY_BASE     := "https://oadms.byd.com/"
global BY_ENDPOINT := "part/masterdata/StockSearchAction/stockSearchQuery.json"
; BydStock.ahk's own debug port: 9222 is the rego lookup's and 9412 the Isuzu
; one, and sharing a port would mean hunting for a DMS tab in a browser that
; has none. The profile is that tool's too - the same hidden, signed-in Chrome
; under LOCALAPPDATA (beside this script if there is no LOCALAPPDATA).
global BY_CPORT    := 9413
global BY_CSOCK    := 0        ; live CDP WebSocket, 0 when not attached
global BY_CDPID    := 0        ; CDP message counter
global BY_LUSER    := "APAU3029S_PM"   ; the DMS login, filled into the DMS form - BydStock.ahk's two lines
global BY_LPASS    := "12345678@BYD"
global BY_CHWND    := 0        ; the hidden Chrome's window, once known
EnvGet, BY_LOCALAPPDATA, LOCALAPPDATA
global BY_CPROFILE := (BY_LOCALAPPDATA != "" ? BY_LOCALAPPDATA : A_ScriptDir) . "\byd-dms-chrome"
global BY_LOG      := A_ScriptDir "\swc_byd.log"

; SuperWarehouseCheck.ahk run        one pass now, no hotkey needed
; SuperWarehouseCheck.ahk run debug  the same, written up in swc_log.txt
;
; and, started by the run itself and never by hand except to try a number,
; the workers (see THE WORKERS):
;   SuperWarehouseCheck.ahk --isuzubatch <list> <out> [reuse]
;   SuperWarehouseCheck.ahk --bydbatch <list> <out>
;   SuperWarehouseCheck.ahk --bydlogin <out>
;   SuperWarehouseCheck.ahk --isuzu <part>     one number, to swc_isuzu_result.txt
;   SuperWarehouseCheck.ahk --byd <part>       one number, to swc_byd_result.txt
if (A_Args.Length() >= 1 && SubStr(A_Args[1], 1, 2) = "--") {
    SW_Worker(A_Args)
    ExitApp
}

SW_OneInstance()

for i, a in A_Args {
    if (a = "debug")
        SW_DEBUG := true
    if (a = "run")
        SetTimer, SW_RunOnce, -50
}
return


;--- hotkeys ----------------------------------------------------------------

#If WinActive(SW_ERA_TITLE " ahk_exe " SW_ERA_EXE)
Insert::SW_Run()
#If

#If (gSW_Shown && WinActive(SW_ERA_TITLE " ahk_exe " SW_ERA_EXE))
~Esc::SW_Stop()
#If

SW_RunOnce:
    SW_Run()
return


;=============================================================================
;   THE RUN
;=============================================================================
SW_Run() {
    global

    if (gSW_Busy) {
        SW_Tip("Still checking the last screen.")
        return
    }
    gSW_Busy := true
    gSW_Cancel := false
    SW_Log("== run ==")

    ;--- 1. ERA and its canvas ---------------------------------------------
    local tx, ty, tw, th
    local era := SW_EraWindow()
    if (!era) {
        SW_Tip("No ERA window is open.")
        gSW_Busy := false
        return
    }
    local term := SW_Terminal(era)
    if (!term || !SW_ClientRect(term, tx, ty, tw, th)) {
        SW_Tip("Could not find the terminal inside ERA.")
        gSW_Busy := false
        return
    }

    ;--- 2. the screen ------------------------------------------------------
    local screen := SW_Screen(era)
    if (!SW_LooksLikeScreen(screen)) {
        SW_Tip("ERA did not hand over its screen. Click in it and try again.")
        gSW_Busy := false
        return
    }
    local lines := SW_Lines(screen)
    local grid  := SW_Grid(tw, th, lines)
    if (!IsObject(grid)) {
        SW_Tip("Could not work out the size of the ERA screen.")
        gSW_Busy := false
        return
    }
    SW_Log("canvas " tw "x" th " at " tx "," ty " grid " grid.cols "x" grid.rows)

    ;--- 3. what is on it ---------------------------------------------------
    local rows := SW_PartRows(lines)
    if (rows.MaxIndex() < 1) {
        SW_Tip("No part lines on this screen.")
        gSW_Busy := false
        return
    }
    local ranked := SW_MakeScores(lines, rows)
    SW_Log("guess " ranked.why ", " rows.MaxIndex() " part lines")

    ; Everything the rest needs, parked: the picker is shown with the
    ; guesses ranked, and the run carries on from SW_Continue once you
    ; have chosen.
    gSW_Ctx := { era: era, term: term, tx: tx, ty: ty, tw: tw, th: th
               , grid: grid, lines: lines, rows: rows }
    SW_Pick(ranked)
}

;-----------------------------------------------------------------------------
;   From a known make onward: the marks go up, then the lookups start.
;-----------------------------------------------------------------------------
SW_Continue(brand) {
    global
    local c := gSW_Ctx
    local rows := c.rows

    ;--- 4. the marks, all waiting ----------------------------------------
    SW_Clear()
    gSW_Era := c.era, gSW_Term := c.term
    gSW_TX := c.tx, gSW_TY := c.ty, gSW_TW := c.tw, gSW_TH := c.th
    gSW_Grid := c.grid
    gSW_Rows := rows
    gSW_Done := {}
    gSW_BydLogin := false
    gSW_Brand := brand
    gSW_StatusRow := SW_BlankRowAfter(c.lines, rows)
    SW_Build()

    ;--- 5. who answers -----------------------------------------------------
    if (brand = "ISUZU" || brand = "BYD") {
        gSW_Kind := (brand = "ISUZU") ? "isuzu" : "byd"
        gSW_Alt  := (brand = "ISUZU") ? "B" : "O"
        gSW_Next := 1
        SW_SetStatus(brand " (Melbourne) - checking 1 of " rows.MaxIndex())
        SW_BatchRun()              ; see THE TOOL BATCH
        return
    }

    ; Kia or Hyundai: AUDOS, in the background. Finding the window, opening
    ; Part Master and placing its boxes costs one to two seconds - walking
    ; hundreds of child windows with WM_GETTEXT each - so the last run's
    ; answer is kept and used again while its windows still exist. If the
    ; first lookup on a remembered window comes back empty, SW_StepDo drops
    ; the memory and finds AUDOS afresh once.
    gSW_Kind := "audos"
    gSW_Alt  := "P"
    local hwnd := 0, boxes := "", cached := gSW_AudosCache[brand], fresh := false
    if (IsObject(cached) && SW_AudosCacheGood(cached)) {
        hwnd := cached.hwnd, boxes := cached.boxes
        SW_Log(brand " AUDOS remembered: " hwnd)
    } else {
        fresh := true
        SW_SetStatus(brand " - finding AUDOS")
        if (!SW_AudosFind(brand, hwnd, boxes)) {
            SW_FinishAll("unk")
            SW_Finish()
            return
        }
        gSW_AudosCache[brand] := { hwnd: hwnd, boxes: boxes }
    }
    gSW_Chain := [{ brand: brand, hwnd: hwnd, boxes: boxes, fresh: fresh }]
    gSW_Next := 1
    SW_SetStatus(brand " - checking 1 of " rows.MaxIndex())

    ; One part per timer tick, so the overlay keeps following ERA and Esc
    ; keeps working while a lookup runs.
    SetTimer, SW_Step, -10
}


;=============================================================================
;   THE PICKER  -  every run, with the makes in order of likelihood
;
;   Four buttons in a small window at the top right of the terminal, best
;   guess first and already the default, so Enter takes it. Under the
;   buttons, one line says why. Click one, or press K, H, I or B. Esc or
;   closing it drops the run. This window is a normal one - it has to take
;   a click - so ERA loses the focus for a moment and gets it back the
;   instant you choose.
;=============================================================================
SW_Pick(ranked) {
    global
    Gui, SWP:Destroy
    Gui, SWP:-MinimizeBox -MaximizeBox +ToolWindow +AlwaysOnTop -DPIScale +LastFound
    Gui, SWP:Color, F3F1EA
    Gui, SWP:Font, s9, Segoe UI
    Gui, SWP:Add, Text, x12 y10 w300, % "Which make?  " (ranked.sure ? "Looks like " SW_Nice(ranked.list[1].brand) "." : "The screen does not say.")
    Gui, SWP:Font, s10 bold, Segoe UI
    local i, e, w, opt
    for i, e in ranked.list {
        w := (e.brand = "HYUNDAI") ? 80 : (e.brand = "BYD") ? 56 : 64
        opt := (i = 1 ? "x12 y34" : "x+4") " w" w " h34 g" SW_PickLabel(e.brand) (i = 1 ? " Default" : "")
        Gui, SWP:Add, Button, %opt%, % SW_Amp(e.brand) (e.pct ? "  " e.pct "%" : "")
    }
    Gui, SWP:Font, s8 norm, Segoe UI
    Gui, SWP:Add, Text, x12 y74 w300 c6B6A66, % ranked.why
    local x := gSW_Ctx.tx + gSW_Ctx.tw - 336
    local y := gSW_Ctx.ty + 6
    Gui, SWP:Show, x%x% y%y% w324 h96, Super Warehouse Check
}

SW_PickLabel(brand) {
    return (brand = "KIA") ? "SW_PickKia" : (brand = "HYUNDAI") ? "SW_PickHyundai" : (brand = "ISUZU") ? "SW_PickIsuzu" : "SW_PickByd"
}
SW_Amp(brand) {
    return (brand = "KIA") ? "&Kia" : (brand = "HYUNDAI") ? "&Hyundai" : (brand = "ISUZU") ? "&Isuzu" : "&BYD"
}
SW_Nice(brand) {
    return (brand = "KIA") ? "Kia" : (brand = "HYUNDAI") ? "Hyundai" : (brand = "ISUZU") ? "Isuzu" : "BYD"
}

; The button thread only notes the choice and leaves; a timer does the work,
; so a button is never still busy when the next key arrives.
SW_PickKia:
    SW_Picked("KIA")
return
SW_PickHyundai:
    SW_Picked("HYUNDAI")
return
SW_PickIsuzu:
    SW_Picked("ISUZU")
return
SW_PickByd:
    SW_Picked("BYD")
return
SWPGuiEscape:
SWPGuiClose:
    Gui, SWP:Destroy
    gSW_Busy := false
    SW_Log("picker dropped")
return

SW_Picked(brand) {
    global
    Gui, SWP:Destroy
    gSW_PickedBrand := brand
    ; ERA had the focus before the picker; give it straight back.
    WinActivate, % "ahk_id " gSW_Ctx.era
    SetTimer, SW_PickGo, -10
}
SW_PickGo:
    SW_Continue(gSW_PickedBrand)
return

;-----------------------------------------------------------------------------
;   One part, then hand the thread back.
;-----------------------------------------------------------------------------
SW_Step:
    SW_StepDo()
return

SW_StepDo() {
    global
    if (gSW_Cancel || !gSW_Shown) {
        SW_Finish()
        return
    }
    local n := gSW_Rows.MaxIndex()
    if (gSW_Next > n) {
        SW_SetStatus(gSW_Brand " - " n " checked")
        SW_Finish()
        return
    }

    local i := gSW_Next
    local item := gSW_Rows[i]
    local key := SW_Key(item.part)
    local got

    if (gSW_Done.HasKey(key)) {
        got := gSW_Done[key]
    } else {
        got := SW_LookupOne(gSW_Chain[1].hwnd, gSW_Chain[1].boxes, item.part)
        ; A remembered window that gives nothing on its first part may be
        ; the wrong dialog by now: forget it, find AUDOS again, ask once more.
        if (!got.ok && !gSW_Chain[1].fresh) {
            local hwnd2 := 0, boxes2 := ""
            SW_Log("remembered AUDOS gave nothing - finding it again")
            gSW_AudosCache.Delete(gSW_Brand)
            if (SW_AudosFind(gSW_Brand, hwnd2, boxes2)) {
                gSW_AudosCache[gSW_Brand] := { hwnd: hwnd2, boxes: boxes2 }
                gSW_Chain := [{ brand: gSW_Brand, hwnd: hwnd2, boxes: boxes2, fresh: true }]
                got := SW_LookupOne(hwnd2, boxes2, item.part)
            } else {
                gSW_Chain[1].fresh := true
            }
        }
        gSW_Done[key] := got
        SW_Log(item.part " in " gSW_Brand " -> ok=" got.ok " here=" got.syd " other=" got.perth)
    }
    SW_Mark(i, got)

    gSW_Next := i + 1
    if (gSW_Next <= n)
        SW_SetStatus(gSW_Brand " - checking " gSW_Next " of " n)
    SetTimer, SW_Step, -10
}

SW_Finish() {
    global
    gSW_Busy := false
    gSW_ExpireAt := A_TickCount + SW_LINGER_MS
    SW_Log("finished")
}

; Every row that is still waiting gets the one state, for when AUDOS could
; not be reached at all.
SW_FinishAll(state) {
    global
    for i, item in gSW_Rows
        if (item.state = "wait")
            SW_Paint(i, state, "?")
}


;=============================================================================
;   ERA  -  the window, the canvas, and F11
;=============================================================================
SW_EraWindow() {
    global SW_ERA_EXE, SW_ERA_TITLE
    ; The one you are in, if you are in one; otherwise the first there is.
    era := WinActive(SW_ERA_TITLE " ahk_exe " SW_ERA_EXE)
    if (era)
        return era
    WinGet, list, List, % SW_ERA_TITLE " ahk_exe " SW_ERA_EXE
    return (list >= 1) ? list1 : 0
}

;-----------------------------------------------------------------------------
;   The terminal canvas: the child that fills the middle of the window,
;   found by shape, as EraWord does. Innermost of the nested windows that
;   all fill that space - the one the characters are drawn on.
;-----------------------------------------------------------------------------
SW_Terminal(era) {
    WinGetPos, wx, wy, ww, wh, ahk_id %era%
    best := 0, bestArea := 0
    for i, kid in SW_Kids(era, false) {
        if (!kid.vis)
            continue
        w := kid.r - kid.l, h := kid.b - kid.t
        if (w < ww * 0.8 || h < wh * 0.5)
            continue
        area := w * h
        if (!best || area <= bestArea) {
            best := kid.hwnd
            bestArea := area
        }
    }
    return best
}

SW_ClientRect(hwnd, ByRef x, ByRef y, ByRef w, ByRef h) {
    VarSetCapacity(rc, 16, 0)
    if (!DllCall("GetClientRect", "Ptr", hwnd, "Ptr", &rc))
        return false
    w := NumGet(rc, 8, "Int")
    h := NumGet(rc, 12, "Int")
    VarSetCapacity(pt, 8, 0)
    if (!DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", &pt))
        return false
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")
    return (w > 0 && h > 0)
}

;-----------------------------------------------------------------------------
;   F11 puts the whole screen on the clipboard. ERA has to be the active
;   window for the key to reach it. The clipboard goes back afterwards.
;-----------------------------------------------------------------------------
SW_Screen(era) {
    saved := ClipboardAll
    Clipboard := ""
    if (!WinActive("ahk_id " . era)) {
        WinActivate, ahk_id %era%
        WinWaitActive, ahk_id %era%, , 2
        if (ErrorLevel) {
            Clipboard := saved
            return ""
        }
        Sleep, 120
    }
    SendInput, {F11}
    ClipWait, 3, 1
    if (ErrorLevel) {
        Clipboard := saved
        return ""
    }
    screen := Clipboard
    Clipboard := saved
    saved := ""
    return screen
}

; A whole screen, not a few words somebody had highlighted.
SW_LooksLikeScreen(screen) {
    if (screen = "")
        return false
    lines := SW_Lines(screen)
    if (lines.MaxIndex() < 10)
        return false
    longest := 0
    for i, line in lines
        if (StrLen(line) > longest)
            longest := StrLen(line)
    return (longest >= 40)
}

SW_Lines(screen) {
    out := []
    Loop, Parse, screen, `n, `r
        out.Insert(A_LoopField)
    while (out.MaxIndex() > 0 && Trim(out[out.MaxIndex()]) = "")
        out.Remove(out.MaxIndex())
    return out
}

;-----------------------------------------------------------------------------
;   How many columns and rows the terminal is showing - EraWord's measure.
;   Only the counts; pixels are worked out proportionally at the point of
;   use, one sum each, so DPI scaling cannot compound a rounding error
;   across the screen.
;-----------------------------------------------------------------------------
SW_Grid(cw, chh, lines) {
    if (cw < 100 || chh < 100)
        return ""
    longest := 0
    for i, line in lines
        if (StrLen(line) > longest)
            longest := StrLen(line)
    cols := SW_BestFit(cw, (longest > 80) ? [132, 80] : [80, 132], longest)
    rows := SW_BestFit(chh, [24, 25, 43, 50], lines.MaxIndex())
    if (!cols || !rows)
        return ""
    return { cols: cols, rows: rows }
}

SW_BestFit(pixels, candidates, atLeast) {
    fallback := 0
    for i, n in candidates {
        if (n < atLeast)
            continue
        if (!fallback)
            fallback := n
        if (Mod(pixels, n) = 0)
            return n
    }
    return fallback
}


;=============================================================================
;   READING THE SCREEN
;=============================================================================

;-----------------------------------------------------------------------------
;   SW_MakeScores(lines, rows)  ->  { list: [{brand, score, pct}...], why, sure }
;
;   How likely each make is, from four things the screen can say, in order
;   of how much each is trusted:
;
;     Make code     "Make KI" / "Make HY" / "Make IA" / "Make BY" on the
;                   header block - what ERA itself has the parts filed under.
;     VIN           the first three letters of any 17-character VIN on the
;                   screen: KNA.. Kia, KMH.. Hyundai (Genesis is filed as
;                   Hyundai, see the RegoCheck notes), MPA/JAA.. Isuzu,
;                   LGX/LC0.. BYD.
;     Name          the customer's name - "Kia Motors Australia", "Isuzu
;                   Ute", a BYD dealer.
;     Part numbers  one point per part with a tell-tale shape, the same
;                   tests AUDOS_Switch routes by: 8 digits dash 2 is BYD,
;                   digit 8-digits digit is Isuzu, 5 digits then 5 letters
;                   or digits is a Kia or Hyundai number - which of the two
;                   no shape can say, so those parts score both.
;
;   Weights: Make 6, VIN 5, name 3, each part 1. The list comes back sorted,
;   ties broken Kia, Hyundai, Isuzu, BYD (the order the counter sees them).
;   sure is true when the top make has a Make code, a VIN or a name behind
;   it, or is clear of the runner-up by three parts or more.
;-----------------------------------------------------------------------------
SW_MakeScores(lines, rows) {
    sc := { KIA: 0, HYUNDAI: 0, ISUZU: 0, BYD: 0 }
    why := ""
    hard := { KIA: 0, HYUNDAI: 0, ISUZU: 0, BYD: 0 }   ; make/VIN/name hits

    text := ""
    for i, line in lines
        text .= line "`n"

    ;--- the Make code
    for i, line in lines {
        if (RegExMatch(line, "i)\bMake\s+([A-Z]{2})\b", m)) {
            StringUpper, m1, m1
            b := (m1 = "KI") ? "KIA" : (m1 = "HY") ? "HYUNDAI" : (m1 = "IA") ? "ISUZU" : (m1 = "BY") ? "BYD" : ""
            if (b != "") {
                sc[b] += 6, hard[b] += 1
                why .= "Make " m1 " = " SW_Nice(b) ". "
                break
            }
        }
    }

    ;--- a VIN
    if (RegExMatch(text, "\b([A-HJ-NPR-Z0-9]{17})\b", m) && RegExMatch(m1, "\d")) {
        b := SW_MakeFromVin(m1)
        if (b != "") {
            sc[b] += 5, hard[b] += 1
            why .= "VIN " SubStr(m1, 1, 3) "... = " SW_Nice(b) ". "
        }
    }

    ;--- the customer's name, or any word to that effect
    for i, b in ["KIA", "HYUNDAI", "ISUZU", "BYD"] {
        if (RegExMatch(text, "i)\b" b "\b")) {
            sc[b] += 3, hard[b] += 1
            why .= "Says " SW_Nice(b) ". "
        }
    }

    ;--- the parts
    kh := 0, ib := 0, ii := 0
    for i, e in rows {
        n := SW_PartShape(e.part)
        if (n = "BYD")
            sc.BYD += 1, ib += 1
        else if (n = "ISUZU")
            sc.ISUZU += 1, ii += 1
        else if (n = "KH")
            sc.KIA += 1, sc.HYUNDAI += 1, kh += 1
    }
    if (kh)
        why .= kh " Kia/Hyundai-shaped part" (kh = 1 ? "" : "s") ". "
    if (ii)
        why .= ii " Isuzu-shaped. "
    if (ib)
        why .= ib " BYD-shaped. "
    if (why = "")
        why := "Nothing on the screen gives the make away."

    ;--- rank
    list := []
    for i, b in ["KIA", "HYUNDAI", "ISUZU", "BYD"]
        list.Push({ brand: b, score: sc[b], pct: 0 })
    Loop % list.MaxIndex() - 1 {
        j := A_Index
        Loop % list.MaxIndex() - j {
            k := A_Index
            if (list[k + 1].score > list[k].score)
                t := list[k], list[k] := list[k + 1], list[k + 1] := t
        }
    }
    total := sc.KIA + sc.HYUNDAI + sc.ISUZU + sc.BYD
    if (total > 0)
        for i, e in list
            e.pct := Round(100 * e.score / total)
    sure := (list[1].score > 0) && (hard[list[1].brand] > 0 || list[1].score - list[2].score >= 3)
    return { list: list, why: Trim(why), sure: sure }
}

; The world manufacturer identifier - the first three of a VIN - for the
; four makes this tool knows. Kia: KNA/KNC/KND/KNE/KNM (Korea), U5Y/U6Y
; (Slovakia), 3KP (Mexico), 5XY/5XX (USA). Hyundai: KMH/KMF/KMJ/KMC/KMY
; (Korea), KM8 (Korea SUVs), KMT/KMU (Genesis), TMA (Czechia), 5NP/5NM
; (USA), MAL (India). Isuzu: MPA/MP1 (Thailand), JAA/JAB/JAC/JAL/JAE/JAN
; (Japan). BYD: LGX/LC0/LGL/LM8 (China), and LPE, which is not in the
; published lists but sits beside LGX and LC0 rows on this dealer's ERA
; invoice list and is none of the other three makes.
SW_MakeFromVin(vin) {
    StringUpper, vin, vin
    w := SubStr(vin, 1, 3)
    if w in KNA,KNC,KND,KNE,KNM,U5Y,U6Y,3KP,5XY,5XX
        return "KIA"
    if w in KMH,KMF,KMJ,KMC,KMY,KM8,KMT,KMU,TMA,5NP,5NM,MAL
        return "HYUNDAI"
    if w in MPA,MP1,JAA,JAB,JAC,JAL,JAE,JAN
        return "ISUZU"
    if w in LGX,LC0,LGL,LM8,LPE
        return "BYD"
    return ""
}

; "BYD", "ISUZU", "KH" (Kia or Hyundai) or "" for a part number's shape.
; The BYD and Isuzu tests are AUDOS_Switch's, with the pad's BY / IA make
; prefix accepted on the front. A Kia/Hyundai number is five digits and
; then five letters or digits (86610H8EA0, 273002E000, 3921003BD0).
SW_PartShape(part) {
    p := RegExReplace(Trim(part), "\s+")
    StringUpper, p, p
    if (RegExMatch(p, "^BY(?=[A-Z0-9])"))
        return "BYD"
    if (RegExMatch(p, "^IA(?=.{5,}$)(?=.*\d)"))
        return "ISUZU"
    if (RegExMatch(p, "^\d{8}-\d{2}$"))
        return "BYD"
    if (RegExMatch(p, "^\d-?\d{8}-?\d$"))
        return "ISUZU"
    if (RegExMatch(p, "^[A-Z]\d{4}[A-Z]\d{4}(-\d{3})?$"))
        return "ISUZU"
    if (RegExMatch(p, "^\d{5}[A-Z0-9]{5}$"))
        return "KH"
    return ""
}

;-----------------------------------------------------------------------------
;   The part lines. Each comes back as { row, col, part, state } where row
;   is the 0-based screen row and col the 0-based column just past the end
;   of the part number - where the mark goes.
;
;   A part line starts with a line number, then the part number, then at
;   least two spaces before whatever comes next. It has to sit below the
;   heading that says "Part#" so that a stray number on the header block
;   is never taken for one. The same part on two lines is two marks but
;   one lookup.
;-----------------------------------------------------------------------------
SW_PartRows(lines) {
    out := []
    below := false
    for i, line in lines {
        if (!below) {
            if (InStr(line, "Part#") || InStr(line, "Part #"))
                below := true
            continue
        }
        ; The totals block ends the list.
        if (RegExMatch(line, "^\s*\|?\s*(AVAI|Qpr|CMTD|New#|Remarks|Status\s*:)"))
            break
        ; Two shapes so far. The invoice screen numbers its lines:
        ;     1 86610H8EA0        COVER-RR BUMPE    1    1 ...
        ; the sales inquiry boxes them in bars and does not:
        ;   |273002E000        COIL ASSY-IGNIT    4     4 ...
        ; Either way: a part number, two or more spaces, then words.
        if (!RegExMatch(line, "^\s*\|?\s*(?:\d{1,3}\s+)?([A-Z0-9][A-Z0-9\-\./]{3,})\s{2,}\S", m))
            continue
        if (!RegExMatch(m1, "\d"))
            continue
        pos := RegExMatch(line, "\Q" m1 "\E")
        out.Insert({ row: i - 1, col: pos - 1 + StrLen(m1) + 1, part: m1, state: "wait" })
    }
    return out
}

;-----------------------------------------------------------------------------
;   Somewhere to put the status line: the first empty row after the last
;   part line, and before the totals block. -1 if there is none, in which
;   case the status goes to a tooltip instead.
;-----------------------------------------------------------------------------
SW_BlankRowAfter(lines, rows) {
    last := rows[rows.MaxIndex()].row
    Loop, % lines.MaxIndex() - last - 1
    {
        r := last + A_Index                   ; 0-based row
        if (RegExMatch(lines[r + 1], "^[\s|]*$"))         ; bars count as blank
            return r
        if (RegExMatch(lines[r + 1], "^\s*\|?\s*(AVAI|Qpr|CMTD|New#|Remarks|Status\s*:)"))
            return -1
    }
    return -1
}


;=============================================================================
;   THE OVERLAY
;
;   One window over the terminal canvas, exactly its size. Its background is
;   a colour nothing else uses, and that colour is made see-through, so only
;   the marks show. It is click-through (E0x20) and never activated
;   (E0x08000000), so ERA keeps both the mouse and the keyboard.
;=============================================================================
SW_Build() {
    global

    Gui, SWO:Destroy
    Gui, SWO:-Caption +ToolWindow +AlwaysOnTop +E0x20 +E0x08000000 -DPIScale +LastFound
    Gui, SWO:Color, %SW_KEY%
    Gui, SWO:Margin, 0, 0

    local cellW := gSW_TW / gSW_Grid.cols
    local cellH := gSW_TH / gSW_Grid.rows
    ; Points from pixels: the glyph sits a little under the cell height.
    local pt := Floor(cellH * 0.8 * 72 / A_ScreenDPI)
    if (pt < 7)
        pt := 7
    gSW_Pt := pt

    for i, item in gSW_Rows {
        SW_AddPill(i, item.row, item.col, "...", SW_WAIT_BG, SW_WAIT_FG)
    }
    ; The status pill is made last, blank, and filled in by SW_SetStatus.
    if (gSW_StatusRow >= 0)
        SW_AddPill(0, gSW_StatusRow, 2, " ", SW_INFO_BG, SW_INFO_FG)

    Gui, SWO:Show, % "x" gSW_TX " y" gSW_TY " w" gSW_TW " h" gSW_TH " NA"
    WinSet, TransColor, %SW_KEY%
    gSW_Shown := true
    gSW_Hidden := false
    gSW_ExpireAt := 0
    SetTimer, SW_Follow, %SW_FOLLOW_MS%
}

; A pill is a coloured Progress bar for the background with a Text on top.
; Both are named by the row index so they can be changed later.
SW_AddPill(i, row, col, text, bg, fg) {
    global
    local x := (col * gSW_TW) // gSW_Grid.cols
    local y := (row * gSW_TH) // gSW_Grid.rows
    local h := ((row + 1) * gSW_TH) // gSW_Grid.rows - y
    local w := ((col + StrLen(text)) * gSW_TW) // gSW_Grid.cols - x
    Gui, SWO:Add, Progress, % "x" x " y" y " w" w " h" h " Background" bg " vsw_p" i " -Smooth", 0
    Gui, SWO:Font, % "s" gSW_Pt " c" fg " bold", %SW_FONT%
    Gui, SWO:Add, Text, % "x" x " y" y " w" w " h" h " Center BackgroundTrans vsw_t" i " 0x200", %text%
}

; Change a pill's words and colours. The width follows the words.
SW_Paint(i, state, text) {
    global
    if (!gSW_Shown)
        return
    local bg, fg
    if (state = "ok")
        bg := SW_OK_BG, fg := SW_OK_FG
    else if (state = "perth")
        bg := SW_PERTH_BG, fg := SW_PERTH_FG
    else if (state = "nil")
        bg := SW_NIL_BG, fg := SW_NIL_FG
    else if (state = "info")
        bg := SW_INFO_BG, fg := SW_INFO_FG
    else if (state = "wait")
        bg := SW_WAIT_BG, fg := SW_WAIT_FG
    else
        bg := SW_UNK_BG, fg := SW_UNK_FG

    local row := (i = 0) ? gSW_StatusRow : gSW_Rows[i].row
    local col := (i = 0) ? 2 : gSW_Rows[i].col
    if (i > 0)
        gSW_Rows[i].state := state

    local x := (col * gSW_TW) // gSW_Grid.cols
    local w := ((col + StrLen(text)) * gSW_TW) // gSW_Grid.cols - x
    ; Keep the mark on the screen.
    if (x + w > gSW_TW)
        w := gSW_TW - x

    GuiControl, SWO:Move, sw_p%i%, w%w%
    GuiControl, SWO:+Background%bg%, sw_p%i%
    Gui, SWO:Font, % "s" gSW_Pt " c" fg " bold", %SW_FONT%
    GuiControl, SWO:Font, sw_t%i%
    GuiControl, SWO:Move, sw_t%i%, w%w%
    GuiControl, SWO:, sw_t%i%, %text%
}

; The mark for one answer.
SW_Mark(i, got) {
    global gSW_Alt
    if (!got.ok)
        SW_Paint(i, "unk", "?")
    else if (got.syd > 0)
        SW_Paint(i, "ok", Chr(0x2713) " " got.syd)
    else if (got.perth > 0)
        SW_Paint(i, "perth", gSW_Alt " " got.perth)
    else
        SW_Paint(i, "nil", Chr(0x2717) " 0")
}

SW_SetStatus(text) {
    global
    gSW_Status := text
    SW_Log("status: " text)
    if (gSW_Shown && gSW_StatusRow >= 0)
        SW_Paint(0, "info", " " text " ")
    else
        SW_Tip(text)
}

; Esc: stop asking AUDOS and take the marks away.
SW_Stop() {
    global
    gSW_Cancel := true
    SW_Log("stopped by Esc")
    SW_Clear()
}

; Take the marks away. Does not touch the cancel flag - a new run clears the
; old marks first, and must not cancel itself doing it.
SW_Clear() {
    global
    SetTimer, SW_Follow, Off
    if (gSW_Shown) {
        Gui, SWO:Destroy
        gSW_Shown := false
    }
    ToolTip
}

;-----------------------------------------------------------------------------
;   Every quarter second: follow ERA if it moved, hide while ERA is not in
;   front (an always-on-top overlay would otherwise sit over whatever you
;   switched to), and go away once the marks have had their time.
;-----------------------------------------------------------------------------
SW_Follow:
    SW_FollowDo()
return

SW_FollowDo() {
    global
    if (!gSW_Shown)
        return
    if (!DllCall("IsWindow", "Ptr", gSW_Era)) {
        SW_Clear()
        return
    }
    if (gSW_ExpireAt && A_TickCount > gSW_ExpireAt) {
        SW_Clear()
        return
    }
    local active := WinActive("ahk_id " gSW_Era)
    if (!active && !gSW_Hidden) {
        Gui, SWO:Hide
        gSW_Hidden := true
        return
    }
    if (!active)
        return

    local x, y, w, h
    if (!SW_ClientRect(gSW_Term, x, y, w, h)) {
        SW_Clear()
        return
    }
    ; Resized: the cells are a different size and every mark is in the wrong
    ; place. Rather than re-lay them, the marks are taken away; the next
    ; hotkey press draws them fresh.
    if (w != gSW_TW || h != gSW_TH) {
        SW_Clear()
        return
    }
    if (gSW_Hidden || x != gSW_TX || y != gSW_TY) {
        gSW_TX := x, gSW_TY := y
        Gui, SWO:Show, % "x" x " y" y " w" w " h" h " NA"
        gSW_Hidden := false
    }
}


;=============================================================================
;   AUDOS  -  all of it without bringing the window to the front
;=============================================================================

;-----------------------------------------------------------------------------
;   The AUDOS window for a brand: the dealer code sits in one of its edit
;   boxes and never appears in the other brand's window. Out of AUDOS_Switch.
;-----------------------------------------------------------------------------
SW_AudosWindow(brand) {
    global SW_AUDOS_EXE, SW_AUDOS_HINT, SW_KIA_RE, SW_HYUNDAI_RE
    want := (brand = "KIA") ? SW_KIA_RE : SW_HYUNDAI_RE
    WinGet, list, List, % SW_AUDOS_HINT " ahk_exe " SW_AUDOS_EXE
    Loop, %list%
    {
        hwnd := list%A_Index%
        for i, kid in SW_Kids(hwnd) {
            if (kid.cls = "EditTobe" && RegExMatch(kid.text, want))
                return hwnd
        }
    }
    return 0
}

;-----------------------------------------------------------------------------
;   Part Master (DS007), opened from the screen box on the bottom bar. The
;   code goes in by WM_SETTEXT and is read straight back before Enter, the
;   way AUDOS_Switch proved it has to be: typed keystrokes get dropped when
;   AUDOS is busy and the wrong screen opens. No WinActivate anywhere.
;-----------------------------------------------------------------------------
SW_OpenPartMaster(hwnd) {
    global SW_PART_SCREEN, SW_PART_TITLE, SW_OPEN_WAIT_MS

    if (SW_Dialog(hwnd, SW_PART_TITLE))
        return true

    box := SW_BottomBox(hwnd)
    if (!box) {
        SW_Log("no screen box")
        return false
    }
    ControlFocus, , ahk_id %box%
    Sleep, 60

    landed := SW_SetBoxText(box, SW_PART_SCREEN, 3)
    if (!landed) {
        box2 := SW_BottomBox(hwnd)
        if (box2 && box2 != box) {
            box := box2
            landed := SW_SetBoxText(box, SW_PART_SCREEN, 3)
        }
    }
    if (!landed) {
        SW_Log(SW_PART_SCREEN " would not set")
        return false
    }

    ControlSend, , {Enter}, ahk_id %box%
    if (SW_WaitDialog(hwnd, SW_PART_TITLE, SW_OPEN_WAIT_MS * 0.3))
        return true
    ; A second Enter if the first did not take - the box still holds DS007.
    ControlSend, , {Enter}, ahk_id %box%
    if (SW_WaitDialog(hwnd, SW_PART_TITLE, SW_OPEN_WAIT_MS * 0.7))
        return true
    SW_Log(SW_PART_TITLE " did not open")
    return false
}

SW_SetBoxText(box, text, tries := 3) {
    Loop, %tries%
    {
        ControlSetText, , %text%, ahk_id %box%
        ControlGetText, got, , ahk_id %box%
        if (got = text)
            return A_Index
        Sleep, 50
    }
    return 0
}

SW_WaitDialog(hwnd, title, timeoutMs) {
    stop := A_TickCount + timeoutMs
    Loop
    {
        if (SW_Dialog(hwnd, title))
            return true
        if (A_TickCount > stop)
            return false
        Sleep, 100
    }
}

;-----------------------------------------------------------------------------
;   The boxes on Part Master - StockCheck's bearings. Returns
;   { part, display, syd, perth } or "" if the screen is not as expected.
;
;   Stock Locator is a real button with that word on it. The two stock
;   boxes are the narrow ones directly under it, lined up with its left
;   edge; top one Sydney, next Perth. The part field is the one visible,
;   enabled box highest on the screen. The mirror box - the read-only Part
;   No that AUDOS refills when a part comes back - sits just above History.
;-----------------------------------------------------------------------------
SW_StockBoxes(hwnd) {
    global SW_PART_TITLE, SW_STOCK_BUTTON, SW_HIST_BUTTON

    dlg := SW_Dialog(hwnd, SW_PART_TITLE)
    if (!IsObject(dlg))
        return ""
    kids := SW_Kids(hwnd)

    stockBtn := "", histBtn := ""
    for i, kid in kids {
        if (kid.cls != "Button" || !kid.vis || !SW_IsUnder(kid.hwnd, dlg.hwnd))
            continue
        if (kid.text = SW_STOCK_BUTTON)
            stockBtn := kid
        else if (kid.text = SW_HIST_BUTTON)
            histBtn := kid
    }
    if (!IsObject(stockBtn) || !IsObject(histBtn))
        return ""

    fld := ""
    for i, kid in kids {
        if (kid.cls != "EditTobe" || !kid.vis || !kid.en || !SW_IsUnder(kid.hwnd, dlg.hwnd))
            continue
        if (!IsObject(fld) || kid.t < fld.t || (kid.t = fld.t && kid.l < fld.l))
            fld := kid
    }
    if (!IsObject(fld))
        return ""

    stock := []
    for i, kid in kids {
        if (kid.cls != "EditTobe" || !kid.vis || !SW_IsUnder(kid.hwnd, dlg.hwnd))
            continue
        if ((kid.r - kid.l) > 70 || Abs(kid.l - stockBtn.l) > 30 || kid.t <= stockBtn.t)
            continue
        stock.Insert(kid)
    }
    if (stock.MaxIndex() < 2)
        return ""
    SW_SortByTop(stock)

    disp := ""
    for i, kid in kids {
        if (kid.cls != "EditTobe" || !kid.vis || !SW_IsUnder(kid.hwnd, dlg.hwnd))
            continue
        if (kid.t >= histBtn.t || Abs(kid.l - histBtn.l) > 40)
            continue
        if (!IsObject(disp) || kid.t > disp.t)
            disp := kid
    }
    if (!IsObject(disp))
        return ""

    return { part: fld.hwnd, display: disp.hwnd, syd: stock[1].hwnd, perth: stock[2].hwnd }
}

;-----------------------------------------------------------------------------
;   One part. Blank the mirror, set the part, Enter, wait for the mirror to
;   come back holding the part we asked for, and only then read the stock.
;   A mirror that stays empty means AUDOS does not have the part.
;-----------------------------------------------------------------------------
;-----------------------------------------------------------------------------
;   The window for a make, Part Master open in it, and its four boxes.
;   False, with the status pill already saying why, when any of that is
;   missing.
;-----------------------------------------------------------------------------
SW_AudosFind(brand, ByRef hwnd, ByRef boxes) {
    global SW_PART_TITLE
    hwnd := SW_AudosWindow(brand)
    if (!hwnd) {
        SW_SetStatus("No " brand " AUDOS window is open")
        return false
    }
    if (!SW_OpenPartMaster(hwnd)) {
        SW_SetStatus(SW_PART_TITLE " would not open in " brand " AUDOS")
        return false
    }
    boxes := SW_StockBoxes(hwnd)
    if (!IsObject(boxes)) {
        SW_SetStatus("Sydney and Perth boxes not where they should be")
        return false
    }
    return true
}

; Every window a remembered AUDOS rests on still exists. Cheap: five
; IsWindow calls, no text read, no child walk.
SW_AudosCacheGood(c) {
    if (!DllCall("IsWindow", "Ptr", c.hwnd))
        return false
    for k, h in c.boxes
        if (!DllCall("IsWindow", "Ptr", h))
            return false
    return true
}

SW_LookupOne(hwnd, boxes, part) {
    global SW_PART_WAIT_MS, SW_SETTLE_MS, SW_ENTER_RETRY_MS, SW_DEBUG

    fld := boxes.part, disp := boxes.display
    ; AUDOS wants the bare number: 26300-35505 on a screen is 2630035505 to
    ; it, and a dashed number comes back as not on file.
    code := RegExReplace(Trim(part), "[^A-Za-z0-9]")
    if (code = "")
        return { ok: false, syd: 0, perth: 0 }

    ControlSetText, , , ahk_id %disp%
    if (!SW_SetBoxText(fld, code, 3))
        return { ok: false, syd: 0, perth: 0 }
    ControlSend, , {Enter}, ahk_id %fld%
    tEnter := A_TickCount
    Sleep, %SW_SETTLE_MS%

    ; What AUDOS does with the Enter, timed on the Kia and the Hyundai windows
    ; over thirty parts: about a second later it empties the field the number
    ; was typed in (the request has gone to the Mobis server), and 0.75 to
    ; 0.95 s after THAT the mirror and the stock fill - or, for a number it
    ; does not have, nothing ever does. So the mirror holding the number is
    ; the only answer there is, and the wait runs to SW_PART_WAIT_MS before a
    ; part is called unknown. (An earlier build read the emptied field as
    ; "the answer is in" and gave the record 700 ms to paint - less than the
    ; server takes - so parts Sydney holds were being marked ?.)
    ; The emptied field is good for one thing: an Enter that AUDOS dropped -
    ; it does that while it is busy - leaves the number sitting there, so a
    ; field still full at SW_ENTER_RETRY_MS gets the Enter once more, and the
    ; clock starts again.
    want := SW_Key(code)
    stop := A_TickCount + SW_PART_WAIT_MS
    resent := false
    ok := false
    Loop
    {
        ControlGetText, shown, , ahk_id %disp%
        if (SW_Key(shown) = want) {
            ok := true
            break
        }
        if (!resent && A_TickCount - tEnter > SW_ENTER_RETRY_MS) {
            resent := true
            ControlGetText, inFld, , ahk_id %fld%
            if (SW_Key(inFld) = want) {
                if (SW_DEBUG)
                    SW_Log("  " code " still in the field after " (A_TickCount - tEnter) " ms - Enter again")
                ControlSend, , {Enter}, ahk_id %fld%
                stop := A_TickCount + SW_PART_WAIT_MS
            }
        }
        if (A_TickCount > stop)
            break
        Sleep, 60
    }
    if (!ok) {
        if (SW_DEBUG)
            SW_Log("  " code ": no answer in " (A_TickCount - tEnter) " ms, mirror [" Trim(shown) "]")
        return { ok: false, syd: 0, perth: 0 }
    }

    ControlGetText, sSyd, , % "ahk_id " boxes.syd
    ControlGetText, sPer, , % "ahk_id " boxes.perth
    return { ok: true, syd: SW_Num(sSyd), perth: SW_Num(sPer) }
}

SW_Key(s) {
    s := RegExReplace(s, "[^A-Za-z0-9]", "")
    StringUpper, s, s
    return s
}

SW_Num(s) {
    s := RegExReplace(Trim(s), "[^\d\-]", "")
    return (s = "") ? 0 : s + 0
}


;=============================================================================
;   ISUZU and BYD  -  the other two tools, run once per part
;
;   Both answers come back in the same shape as an AUDOS one: ok, then the
;   count at the warehouse that matters here (Melbourne, in the "syd" slot)
;   and the count elsewhere (Brisbane for Isuzu, every other warehouse for
;   BYD, in the "perth" slot), so the marks need no second code path.
;=============================================================================

; Where a sibling tool lives: beside this folder in the same Audos tree, or
; failing that the usual place on this user's desktop. "" if neither.
;-----------------------------------------------------------------------------
;   One Isuzu worker block: "part=", "desc=" and then "stockN=whs|avail|
;   order|min|pack" per warehouse, 03 Melbourne and 04 Brisbane. NOTFOUND or
;   FAIL is a miss.
;-----------------------------------------------------------------------------
SW_IsuzuParse(res) {
    if (InStr(res, "NOTFOUND") || !InStr(res, "part="))
        return { ok: false, syd: 0, perth: 0 }
    melb := 0, bris := 0
    Loop, Parse, res, `n, `r
    {
        if (!RegExMatch(A_LoopField, "stock\d+=([^|]*)\|([^|]*)", m))
            continue
        whs := RegExReplace(Trim(m1), "^0+")
        n := SW_Num(m2)
        if (whs = "3")
            melb += n
        else if (whs = "4")
            bris += n
    }
    return { ok: true, syd: melb, perth: bris }
}

; The pad's IA make code off the front, as AUDOS_Switch takes it off: only
; when what follows is long enough to be a number and has a digit in it.
; Upper case and no spaces, as it does. A number of the genuine shape (one
; digit, eight, one) loses its dashes: IDS answers 8-98392204-0 with no such
; item and 8983922040 with the part. Any other shape keeps them - an
; accessory's -527 colour code is part of its number.
SW_IsuzuCode(part) {
    p := RegExReplace(Trim(part), "\s+")
    StringUpper, p, p
    if RegExMatch(p, "^IA(?=.{5,}$)(?=.*\d)")
        p := SubStr(p, 3)
    if RegExMatch(p, "^\d-\d{8}-\d$")
        p := StrReplace(p, "-")
    return p
}

;=============================================================================
;   THE WORKERS  -  this file again, headless, one leg at a time
;
;       SuperWarehouseCheck.ahk --isuzubatch <list> <out> [reuse]
;       SuperWarehouseCheck.ahk --bydbatch   <list> <out>
;       SuperWarehouseCheck.ahk --bydlogin   <out>
;       SuperWarehouseCheck.ahk --isuzu <part>     one number by hand, the block
;       SuperWarehouseCheck.ahk --byd   <part>     to swc_isuzu/byd_result.txt
;
;   Isuzu and BYD are asked by the two legs at the bottom of this file - the
;   Isuzu Parts & VIN Lookup's IDS plumbing and the BYD Stock Lookup's DMS
;   route, copied line for line with IZ_ and BY_ in front of every name, so
;   nothing has to sit beside this script. Either leg is a WebSocket
;   conversation with a hidden Chrome whose reads block for up to ten seconds
;   when the far end goes quiet, so it is not run on this window's own thread,
;   where it would hold the overlay still and Esc with it. The run starts this
;   same script again with one of the switches above - hidden, no hotkeys, no
;   tray icon (SW_Worker) - and that copy writes each answer to the out file
;   the moment it lands:
;
;       BEGIN 13885898-00
;       ROUTE=browser  RESULT=OK  rows=2  total=108
;       13885898-00  LAMP ASSY
;         Melbourne warehouse  qty=28  normal=...
;         Perth warehouse  qty=80  normal=...
;       END 13885898-00
;       ...
;       DONE
;
;   A timer here reads that file every 150 ms and paints whatever is new, so
;   the ticks arrive as the server answers rather than at the end. The parse
;   per leg is the one the single lookups had. BYD keeps six fetches in
;   flight (ten parts in about 4 s); IDS is one screen and one session, so
;   Isuzu parts go one after another, on a form kept open between them (about
;   0.4 s each). The pad's BY / IA make code comes off first, as AUDOS_Switch
;   takes it off, so one part on the screen twice is one code on the list.
;
;   One worker per run, not per part: a run per part cost about two seconds
;   each - a fresh AutoHotkey, a fresh WebSocket to the leg's Chrome and a
;   sign-in check every time, then the server's own second or so. The batch
;   pays those once.
;
;   BYD signed out: the blocks say so, the batch ends, --bydlogin brings the
;   picture-code window up once, and the codes still unanswered go again.
;   IDS signs itself back in inside the batch.
;
;   The workers are why #SingleInstance is done by hand (SW_OneInstance): the
;   directive's Force would have each worker, being this same file, replace
;   the window it works for.
;=============================================================================
SW_Worker(args) {
    global
    local mode := args[1], err, ok, lst, res
    ; Not the window: no hotkeys (the Insert in ERA would run in here too),
    ; no tray icon, and a title SW_OneInstance does not take for a window.
    Suspend, On
    Menu, Tray, NoIcon
    WinSetTitle, % "ahk_id " A_ScriptHwnd, , % "SuperWarehouseCheck worker " mode
    SetWorkingDir, %A_ScriptDir%
    if (mode = "--isuzubatch" && args.Length() >= 3) {
        IZ_gReuse := (args.Length() >= 4 && args[4] = "reuse")
        try {
            IZ_RunBatchList(args[2], args[3])
        } catch e {
            IZ_BLog("EXCEPTION: " e.Message " (line " e.Line ")")
            FileAppend, % "RESULT=FAIL  " e.Message "`nDONE`n", % args[3]
        }
        return
    }
    if (mode = "--bydbatch" && args.Length() >= 3) {
        BY_Log("== BYD leg: " args[2] " ==")
        try {
            BY_CdpBatch(args[2], args[3])
        } catch e {
            BY_Log("EXCEPTION: " e.Message " (line " e.Line ")")
            FileAppend, % "RESULT=FAIL  " e.Message "`nDONE`n", % args[3]
        }
        BY_Log("== done ==")
        return
    }
    if (mode = "--bydlogin" && args.Length() >= 2) {
        ; BydStock.ahk --cdplogin, as it was: put the tab back on the login
        ; form, fill what a script can, show the window with the cursor in
        ; the picture box, and wait for main.html.
        BY_Log("== BYD leg: sign-in ==")
        err := "", ok := false
        if (BY_CdpAttach(err)) {
            BY_CdpEval("location.href='/'")     ; a tab on main.html with a dead session
            Sleep, 500
        }
        ok := BY_CdpEnsureLogin(err)
        BY_Log("sign-in " (ok ? "done" : "failed: " err))
        FileAppend, % "ROUTE=browser  RESULT=" (ok ? "OK" : "FAIL  " err) "`n", % args[2]
        return
    }
    if ((mode = "--isuzu" || mode = "--byd") && args.Length() >= 2) {
        ; one number by hand: a one-line list, the block to a file beside this script
        lst := A_Temp "\swc_one.txt"
        res := A_ScriptDir "\swc_" SubStr(mode, 3) "_result.txt"
        if FileExist(lst)
            FileDelete, %lst%
        if FileExist(res)
            FileDelete, %res%
        FileAppend, % args[2] "`n", %lst%
        if (mode = "--isuzu") {
            IZ_gReuse := false
            IZ_RunBatchList(lst, res)
        } else
            BY_CdpBatch(lst, res)
        return
    }
    MsgBox, 64, Super Warehouse Check, % "Not a switch this script knows: " mode "`n`nThe workers:`n  --isuzubatch <list> <out> [reuse]`n  --bydbatch <list> <out>`n  --bydlogin <out>`n  --isuzu <part>`n  --byd <part>"
}

; #SingleInstance Force, by hand. The directive knows an instance by the
; script's path in its main window's title, and a worker is this same path;
; so the workers retitle their window (SW_Worker) and this closes only the
; copies that did not - the windows - waiting for each to go, as Force did.
SW_OneInstance() {
    WinGet, list, List, ahk_class AutoHotkey
    Loop, %list% {
        hw := list%A_Index%
        if (hw = A_ScriptHwnd)
            continue
        WinGetTitle, t, ahk_id %hw%
        if (SubStr(t, 1, StrLen(A_ScriptFullPath) + 3) != A_ScriptFullPath " - ")
            continue
        WinClose, ahk_id %hw%
        WinWaitClose, ahk_id %hw%, , 2
        if (ErrorLevel) {
            WinGet, pid, PID, ahk_id %hw%
            Process, Close, %pid%
        }
    }
}

SW_BatchRun() {
    global
    local i, item, code, k
    gSW_TBMap := {}
    gSW_TBCodes := []
    for i, item in gSW_Rows {
        code := (gSW_Kind = "byd") ? SW_BydCode(item.part) : SW_IsuzuCode(item.part)
        k := SW_Key(code)
        if (!gSW_TBMap.HasKey(k)) {
            gSW_TBMap[k] := []
            gSW_TBCodes.Push(code)
        }
        gSW_TBMap[k].Push(i)
    }
    gSW_BydWantLogin := false
    gSW_TBShown := -1
    SW_BatchStart(gSW_TBCodes)
}

; The pad's BY prefix off, as AUDOS_Switch takes it off (it sits in front of
; letters too: BYD005, BYAEG24SK18MB), upper case, no spaces. A bare ten
; digits is a -00 number keyed without its dash (1667736900 on the pad) and
; the DMS only knows it with the dash, so it goes back in.
SW_BydCode(part) {
    p := RegExReplace(Trim(part), "\s+")
    StringUpper, p, p
    p := RegExReplace(p, "^BY(?=[A-Z0-9])")
    if RegExMatch(p, "^\d{10}$")
        p := SubStr(p, 1, 8) "-" SubStr(p, 9)
    return p
}

SW_BatchStart(codes) {
    global
    local i, c, list
    gSW_TBList := A_Temp "\swc_" gSW_Kind "_list.txt"
    gSW_TBOut  := A_Temp "\swc_" gSW_Kind "_out.txt"
    if FileExist(gSW_TBList)
        FileDelete, % gSW_TBList
    if FileExist(gSW_TBOut)
        FileDelete, % gSW_TBOut
    list := ""
    for i, c in codes
        list .= c "`n"
    FileAppend, %list%, % gSW_TBList
    gSW_TBSeen := {}
    gSW_TBT0 := A_TickCount
    gSW_TBPid := 0
    ; this same script again, as a worker (see THE WORKERS)
    if (gSW_Kind = "byd")
        Run, "%A_AhkPath%" "%A_ScriptFullPath%" --bydbatch "%gSW_TBList%" "%gSW_TBOut%", %A_ScriptDir%, Hide, gSW_TBPid
    else
        Run, "%A_AhkPath%" "%A_ScriptFullPath%" --isuzubatch "%gSW_TBList%" "%gSW_TBOut%" %SW_ISUZU_REUSE%, %A_ScriptDir%, Hide, gSW_TBPid
    SW_Log("  " gSW_Kind " worker for " codes.MaxIndex() " codes started, pid " gSW_TBPid)
    SetTimer, SW_BatchPoll, 150
}

SW_BatchPoll:
    SW_BatchPollDo()
return

SW_BatchPollDo() {
    global
    local txt, pos, m, m1, m2, code, k, got, i, idx, item, marked, n, finished, alive, head, again, quiet

    if (gSW_Cancel || !gSW_Shown) {
        SW_BatchKill()
        SW_Finish()
        return
    }

    ;--- whatever is new in the file
    txt := ""
    if FileExist(gSW_TBOut)
        FileRead, txt, % gSW_TBOut
    pos := 1
    while (pos := RegExMatch(txt, "s)BEGIN (\S+)\r?\n(.*?)\r?\nEND \1\r?\n", m, pos)) {
        pos += StrLen(m)
        code := m1
        k := SW_Key(code)
        if (gSW_TBSeen.HasKey(k))
            continue
        gSW_TBSeen[k] := true
        got := (gSW_Kind = "byd") ? SW_BydParse(m2) : SW_IsuzuParse(m2)
        if (gSW_Kind = "byd" && !got.ok && SW_BydNeedsLogin(m2))
            gSW_BydWantLogin := true
        else
            gSW_Done[k] := got
        SW_Log(code " in " gSW_Brand " -> ok=" got.ok " here=" got.syd " other=" got.perth (got.ok ? "" : "  [" RegExReplace(Trim(m2, " `r`n"), "s)\R.*") "]"))
        for i, idx in gSW_TBMap[k]
            SW_Mark(idx, got)
    }

    ;--- the pill
    marked := 0
    for i, item in gSW_Rows
        if (item.state != "wait")
            marked++
    n := gSW_Rows.MaxIndex()
    if (marked != gSW_TBShown && marked < n) {
        gSW_TBShown := marked
        SW_SetStatus(gSW_Brand " (Melbourne) - checking " (marked + 1) " of " n)
    }

    ;--- over?
    finished := RegExMatch(txt, "m)^DONE\s*$")
    if (!finished && gSW_TBPid) {
        Process, Exist, % gSW_TBPid
        alive := ErrorLevel
        if (!alive) {
            SW_Log("  " gSW_Kind " worker went away without DONE")
            finished := true
        }
    }
    if (!finished && A_TickCount - gSW_TBT0 > 20000 * gSW_TBCodes.MaxIndex() + 30000) {
        SW_Log("  " gSW_Kind " batch took too long")
        finished := true
    }
    if (!finished)
        return
    SetTimer, SW_BatchPoll, Off
    SW_BatchKill()

    ; A batch that failed before any code (no browser, signed out at the
    ; door) says so on its first line.
    head := RegExReplace(txt, "s)\R.*")
    if (InStr(head, "RESULT=FAIL"))
        SW_Log("  " gSW_Kind " batch failed at the door: " head)
    if (gSW_Kind = "byd" && InStr(head, "RESULT=FAIL") && SW_BydNeedsLogin(head))
        gSW_BydWantLogin := true

    ;--- signed out: sign in once, then the codes still owed go again
    quiet := false
    if (gSW_BydWantLogin && !gSW_BydLogin) {
        gSW_BydLogin := true
        gSW_BydWantLogin := false
        again := []
        for i, code in gSW_TBCodes
            if (!gSW_Done.HasKey(SW_Key(code)))
                again.Push(code)
        if (again.MaxIndex() && SW_BydLogin()) {
            WinActivate, % "ahk_id " gSW_Era
            gSW_TBShown := -1
            SW_BatchStart(again)
            return
        }
        WinActivate, % "ahk_id " gSW_Era
        quiet := true                    ; SW_BydLogin left its own status
    } else if (gSW_BydWantLogin) {
        SW_SetStatus("BYD - the DMS is signed out again")
        quiet := true
    }

    SW_FinishAll("unk")
    if (!quiet)
        SW_SetStatus(gSW_Brand " - " n " checked")
    SW_Finish()
}

SW_BatchKill() {
    global
    SetTimer, SW_BatchPoll, Off
    if (gSW_TBPid) {
        Process, Exist, % gSW_TBPid
        if (ErrorLevel)
            Process, Close, % gSW_TBPid
    }
    gSW_TBPid := 0
}

; One block's summary: "RESULT=OK" and then one line per warehouse,
; "  Melbourne warehouse  qty=28  normal=...". Melbourne is here, the rest
; other. Anything else is a miss - and so is RESULT=OK with no warehouse
; line at all, which is what the DMS returns for a number it does not have:
; the BYD window calls that NO RECORD, and a red 0 here would say the part
; exists and nobody holds it. (Counted, not read off the header: the leg
; writes "rows=" with nothing after it for an empty answer.)
SW_BydParse(txt) {
    if !InStr(txt, "RESULT=OK")
        return { ok: false, syd: 0, perth: 0 }
    melb := 0, other := 0, rows := 0
    Loop, Parse, txt, `n, `r
    {
        if (!RegExMatch(A_LoopField, "^\s+(.+?)\s{2,}qty=(\S+)", m))
            continue
        rows += 1
        n := SW_Num(m2)
        if InStr(m1, "Melbourne")
            melb += n
        else
            other += n
    }
    if (!rows)
        return { ok: false, syd: 0, perth: 0 }
    return { ok: true, syd: melb, perth: other }
}

; What the BYD leg says when the tab cannot answer for want of a login.
SW_BydNeedsLogin(txt) {
    return InStr(txt, "signed out") || InStr(txt, "No DMS browser") || InStr(txt, "no oadms.byd.com tab")
        || InStr(txt, "login") || InStr(txt, "Lost the DMS tab")
}

; --bydlogin, a worker copy of this script running BydStock.ahk's own sign-in
; flow: it launches the hidden Chrome if need be, fills the username and
; password, shows the window with the cursor in the picture box and waits up
; to four minutes for you to type the code. True once the DMS is on
; main.html. The pill says what to do meanwhile; ERA keeps the marks.
SW_BydLogin() {
    global gSW_Cancel
    out := A_Temp "\swc_byd_login.txt"
    if FileExist(out)
        FileDelete, %out%
    SW_SetStatus("BYD - type the picture code in the DMS window, then Enter")
    SW_Log("  byd sign-in: waiting on the picture code")
    t0 := A_TickCount
    RunWait, "%A_AhkPath%" "%A_ScriptFullPath%" --bydlogin "%out%", %A_ScriptDir%, Hide
    txt := ""
    if FileExist(out)
        FileRead, txt, %out%
    ok := InStr(txt, "RESULT=OK") ? true : false
    SW_Log("  byd sign-in " (ok ? "done" : "failed: " Trim(txt, " `r`n")) " after " (A_TickCount - t0) " ms")
    if (!ok)
        SW_SetStatus("BYD - not signed in: " RegExReplace(Trim(txt, " `r`n"), "^.*RESULT=FAIL\s*"))
    return ok
}


;=============================================================================
;   WINDOWS PLUMBING  -  WM_GETTEXT through SendMessageTimeoutW, as in the
;   other tools: GetWindowText comes back empty across a process boundary,
;   and a plain SendMessage hangs forever on MiPlatform's owner-drawn tree.
;=============================================================================
SW_Kids(hwnd, wantText := true) {
    global gSW_Kids, gSW_WantText
    gSW_Kids := []
    gSW_WantText := wantText
    cb := RegisterCallback("SW_KidProc", "Fast")
    DllCall("EnumChildWindows", "Ptr", hwnd, "Ptr", cb, "Ptr", 0)
    DllCall("GlobalFree", "Ptr", cb)
    return gSW_Kids
}

SW_KidProc(hChild, lParam) {
    global gSW_Kids, gSW_WantText

    cls := ""
    VarSetCapacity(buf, 256 * 2, 0)
    if (DllCall("GetClassName", "Ptr", hChild, "Str", buf, "Int", 256))
        cls := buf

    ok := false
    VarSetCapacity(buf2, 1024 * 2, 0)
    if (gSW_WantText) {
        junk := 0
        ok := DllCall("SendMessageTimeoutW", "Ptr", hChild, "UInt", 0x000D
            , "Ptr", 1024, "Str", buf2, "UInt", 0x0002, "UInt", 200, "PtrP", junk)
        VarSetCapacity(buf2, -1)
    }

    VarSetCapacity(rect, 16, 0)
    DllCall("GetWindowRect", "Ptr", hChild, "Ptr", &rect)

    gSW_Kids.Insert({ hwnd: hChild
                    , cls:  cls
                    , text: ok ? buf2 : ""
                    , vis:  DllCall("IsWindowVisible", "Ptr", hChild)
                    , en:   DllCall("IsWindowEnabled", "Ptr", hChild)
                    , l:    NumGet(rect,  0, "Int")
                    , t:    NumGet(rect,  4, "Int")
                    , r:    NumGet(rect,  8, "Int")
                    , b:    NumGet(rect, 12, "Int") })
    return true
}

; A dialog on the window, by the name it gives itself.
SW_Dialog(hwnd, title) {
    for i, kid in SW_Kids(hwnd)
        if (kid.cls = "#32770" && kid.text = title)
            return kid
    return ""
}

; The screen box on the bottom bar: the widest box inside the container
; that names itself bottom_frame, or failing that the widest box in the
; bottom 40 pixels of the window.
SW_BottomBox(hwnd) {
    global SW_BOTTOM_BAR
    kids := SW_Kids(hwnd)

    frame := ""
    for i, kid in kids
        if (kid.text = SW_BOTTOM_BAR) {
            frame := kid
            break
        }
    if (IsObject(frame)) {
        best := ""
        for i, kid in kids {
            if (kid.cls != "EditTobe" || !kid.vis || !SW_IsUnder(kid.hwnd, frame.hwnd))
                continue
            if (!IsObject(best) || (kid.r - kid.l) > (best.r - best.l))
                best := kid
        }
        if (IsObject(best))
            return best.hwnd
    }

    WinGetPos, wx, wy, ww, wh, ahk_id %hwnd%
    floorY := wy + wh - 40
    best := ""
    for i, kid in kids {
        if (kid.cls != "EditTobe" || !kid.vis || kid.b < floorY)
            continue
        if (!IsObject(best) || (kid.r - kid.l) > (best.r - best.l))
            best := kid
    }
    return IsObject(best) ? best.hwnd : 0
}

; Is one control genuinely inside another? AUDOS stacks every screen in the
; same rectangle, so position proves nothing; the parent chain does.
SW_IsUnder(child, ancestor) {
    p := child
    Loop, 20
    {
        p := DllCall("GetParent", "Ptr", p, "Ptr")
        if (!p)
            return false
        if (p = ancestor)
            return true
    }
    return false
}

SW_SortByTop(ByRef list) {
    n := list.MaxIndex()
    Loop, % n - 1
    {
        i := A_Index
        Loop, % n - i
        {
            j := A_Index
            if (list[j].t > list[j + 1].t) {
                tmp := list[j]
                list[j] := list[j + 1]
                list[j + 1] := tmp
            }
        }
    }
}


;=============================================================================
;   SMALL THINGS
;=============================================================================
SW_Tip(text) {
    MouseGetPos, mx, my
    ToolTip, %text%, % mx + 12, % my + 19
    SetTimer, SW_TipOff, -2500
}

SW_TipOff:
    ToolTip
return

SW_Log(s) {
    global SW_DEBUG
    if (!SW_DEBUG)
        return
    FileAppend, % A_Hour ":" A_Min ":" A_Sec " " s "`n", %A_ScriptDir%\swc_log.txt
}


;=============================================================================
;   THE ISUZU LEG  -  IDS DC210, through the Isuzu Parts & VIN Lookup's Chrome
;
;   From here to THE BYD LEG is the Isuzu leg: IsuzuVIN.ahk's plumbing (the
;   WebSocket over raw Winsock, the Chrome DevTools calls, the sign-in, the
;   keepalive poke, the screen readers) copied out of that tool line for line
;   with IZ_ in front of every name, and on top of it the one lookup and the
;   batch driver. It drives the same hidden Chrome that tool keeps signed in
;   to IDS - the same debugging port, the same profile, the same mutex, so
;   the two never fight over the one IDS session - and IsuzuVIN.ahk itself is
;   never touched. Runs only in a worker copy of this script (SW_Worker):
;
;       SuperWarehouseCheck.ahk --isuzubatch <listfile> <outfile> [reuse]
;           every part number in the list file (one per line) through DC210,
;           each answer appended to the out file the moment it lands:
;               BEGIN <part>
;               part=... desc=... list=... stockN=whs|available|on order|min|pack
;               END <part>          (or NOTFOUND, or FAIL and why, in between)
;               DONE
;           "reuse" keeps the DC210 form open between parts - about 0.4 s a
;           part instead of 1.5 s - see THE ANSWER OFF THE WIRE below.
;       SuperWarehouseCheck.ahk --isuzu <part>
;           one part, the same block written to swc_isuzu_result.txt beside
;           this script, for trying a number by hand. The leg's own log is
;           swc_isuzu.log, beside this script too.
;
; THE ANSWER OFF THE WIRE. IDS is an Eclipse RAP client: every reply from the
; server is one message of operations that the page applies in one go
; (rwt.remote.MessageProcessor.processMessage). A hook on that one function
; counts the messages and what each carried - how many widgets had their text
; set to something, how many stock rows (GridItems) were made, how many form
; canvases were redrawn. OK on the DC210 form is answered by exactly one such
; message, about 200 ms after the click, so the record is read the moment the
; counter moves and never before, when a reused form still shows the last
; part. What the message carried decides what the screen means:
;
;   - a message that set text somewhere is a record (the answer put the
;     description or the prices up);
;   - a message that set no text, on a screen whose price / class / code
;     fields are all blank, is NO SUCH ITEM: IDS answers an unknown number by
;     blanking those fields (the description it leaves standing);
;   - a message that set no text on a screen that still holds a record is a
;     record too - the case that was being called NOT FOUND until this build:
;     a part whose description and prices are identical to the last part's
;     (7-55233852-0 after 7-55233851-0, both KNUCKLE; FRT AXLE at 960.38)
;     gets an answer with no text in it, because RAP only sends what changed,
;     and only the stock rows are new. The rows are what is read;
;   - the stock rows are rebuilt on every OK, so when the answer made rows the
;     read waits (up to IZ_CFG_ROWWAIT_MS) for the grid on screen to differ from
;     what it showed before the click; when it made none, rows still on screen
;     belong to the last part and are dropped.
;
; No hook (a page without RAP) or no answer inside IZ_CFG_STALE_MS, and a fresh
; form is read the old way, by polling the screen; a reused form is not
; trusted and the part is retried through the menu.
;=============================================================================

; The two lines IsuzuVIN.ahk's copied functions write to its window and its
; session log go to the leg's log (swc_isuzu.log) here.
IZ_SetStatus(s) {
    IZ_BLog(s)
}
IZ_SLog(s) {
    IZ_BLog(s)
}

; ---- THE LIST. One process, one attach, one sign-in check, then every part
; on the list through DC210 in turn, each answer appended to the out file
; the moment it is read, as a BEGIN part / result / END part block with DONE
; on the end - the same shape the BYD leg writes, so the overlay
; reads both the same way. The result inside a block is key=value lines
; (part=, desc=, stockN=...), or NOTFOUND, or FAIL and why.
;
; Where the time goes, and what this saves: one part per process cost about
; 2.5 s, of which 0.7 s was the process start, the mutex, the Chrome check
; and the sign-in check, paid again for every part. Here they are paid once.
; IDS itself is one screen and one session, so the lookups still run one
; after another - there is no six-in-flight here as there is for BYD.
;
; "reuse" on the command line stays on the DC210 form between parts: the
; next number goes straight into Item# without the menu being opened again.
; It needs the answer counter (a page without RAP has none), and a reused
; form that will not answer falls back to the menu route for that part, so
; the worst case is the old speed.
IZ_RunBatchList(listFile, outFile) {
    global
    IZ_SafeDelete(IZ_gLog)
    local t0 := A_TickCount
    local codes := [], seen := {}, txt := "", c, i, res, tries, hook
    if FileExist(listFile)
        FileRead, txt, %listFile%
    Loop, Parse, txt, `n, `r
    {
        c := Trim(A_LoopField)
        if (c = "" || seen.HasKey(c))
            continue
        seen[c] := true
        codes.Push(c)
    }
    IZ_BLog("== Isuzu leg " IZ_VER ": " codes.MaxIndex() " parts" (IZ_gReuse ? ", form reused" : "") " ==")
    if (!codes.MaxIndex()) {
        IZ_ListFail(outFile, "Nothing to look up.")
        return
    }
    if !IZ_MxAcquire(60000) {
        IZ_ListFail(outFile, "another Isuzu lookup is busy (mutex timeout)")
        return
    }
    if !IZ_EnsureChrome() {
        IZ_ListFail(outFile, "chrome start failed")
        IZ_MxRelease()
        return
    }
    if !IZ_OpenPage() {
        IZ_ListFail(outFile, "openpage failed")
        IZ_MxRelease()
        return
    }
    IZ_BLog("openpage OK (" (IZ_gAttached ? "attached to running session" : "new target") ") +" (A_TickCount-t0) "ms")
    local li
    try {
        li := IZ_RecoverSession()
    } catch e {
        IZ_ListFail(outFile, "EXCEPTION in login: " e.Message " (line " e.Line ")")
        IZ_MxRelease()
        return
    }
    if !li {
        IZ_ListFail(outFile, "login failed")
        IZ_MxRelease()
        return
    }
    IZ_BLog("logged in OK +" (A_TickCount-t0) "ms")
    IZ_DetectPoke()
    IZ_BLog("poke mode=" IZ_gPokeMode)
    ; the answer counter is what makes a reused form safe to read; without
    ; it every part goes through the menu, where the screen poll is enough
    hook := IZ_CDP_Eval(IZ_JsMsgHook())
    if (IZ_gReuse && !RegExMatch(hook, "^\d")) {
        IZ_BLog("no RAP answer counter on this page (" hook ") - menu route for every part")
        IZ_gReuse := false
    }
    IZ_CleanupForms()
    local wantReuse := IZ_gReuse
    local q
    for i, c in codes {
        IZ_BLog("--- " c " ---")
        ; IDS wants the genuine shape without its dashes: 8-98392204-0 typed
        ; as it is comes back as no such item, 8983922040 is the part. The
        ; block is still written under the number as it was given.
        q := IZ_IsuzuTyped(c)
        if (q != c)
            IZ_BLog("typed as " q)
        res := ""
        Loop, 2 {
            tries := A_Index
            try {
                res := IZ_Lookup("part", q)
            } catch e {
                IZ_BLog("EXCEPTION in lookup: " e.Message " (line " e.Line ")")
                res := ""
            }
            if (res != "")
                break
            ; A dead session is signed in again; a reused form that would
            ; not answer is left, and the menu route is taken. One more go.
            if (tries = 2)
                break
            if (IZ_gStale) {
                IZ_BLog("session stale - signing in again")
                try
                    IZ_RecoverSession()
                catch e
                    IZ_BLog("EXCEPTION in re-login: " e.Message)
            }
            IZ_CleanupForms()
            if (IZ_gReuse) {
                ; The reused form did not answer once; it is not trusted again
                ; this run. The menu route is the old speed, never worse.
                IZ_BLog("reused form gave nothing - menu route from here on")
                wantReuse := false
            }
            IZ_gReuse := false
        }
        IZ_gReuse := wantReuse
        FileAppend, % "BEGIN " c "`n" (res = "" ? "FAIL " IZ_gFailWhy : res) "`nEND " c "`n", %outFile%
        IZ_BLog("RESULT " c " " (res = "" ? "FAIL" : res = "NOTFOUND" ? "NOTFOUND" : "ok") " +" (A_TickCount-t0) "ms")
        if (!IZ_gReuse || res = "")
            IZ_CleanupForms()
    }
    IZ_CleanupForms()
    IZ_MxRelease()
    FileAppend, DONE`n, %outFile%
    IZ_BLog("== done +" (A_TickCount-t0) "ms ==")
}

; What goes into Item#: upper case, no spaces, and the dashes off a number of
; the genuine shape (one digit, eight, one). Every other shape - accessory
; numbers like A0562R0100-527 - is typed exactly as given.
IZ_IsuzuTyped(c) {
    c := RegExReplace(Trim(c), "\s+")
    StringUpper, c, c
    if RegExMatch(c, "^\d-\d{8}-\d$")
        c := StrReplace(c, "-")
    return c
}

; returns key=value lines, "NOTFOUND" for a genuine no-record, "" on error
; (IZ_gFailWhy says why, IZ_gStale says the session went quiet)
IZ_Lookup(field, value) {
    global IZ_gFailWhy, IZ_gCdpDead, IZ_gStale
    IZ_gFailWhy := "", IZ_gCdpDead := false, IZ_gStale := false
    return IZ_PartLookup(value)
}

;============================ answer counter ==================================
; Every message the server sends is applied by rwt.remote.MessageProcessor.
; processMessage. Wrapped once per page, it counts the messages that carried
; operations and keeps, for the latest one: how many operations it had, how
; many of them set a widget's text to something, how many GridItem rows it
; made, how many form canvases it redrew (a "call <id>.gc init"), and how
; many rows it destroyed that this hook had seen made. Returns
; "seq,ops,texts,rows,canvases,gone", or NA on a page without RAP.
; PartLookup reads it before pressing OK and again until it moves: the move
; IS the server's answer.
IZ_JsMsgHook() {
    return "(function(){try{var MP=rwt.remote.MessageProcessor;if(!MP||!MP.processMessage)return 'NA';if(!window.__isMsg){var S=window.__isMsg={seq:0,ops:0,txt:0,grid:0,gc:0,gone:0,rows:{}};var orig=MP.processMessage;MP.processMessage=function(m){var r=orig.apply(this,arguments);try{var ops=(m&&m.operations)||[];if(ops.length>0){var t=0,g=0,c=0,d=0;for(var i=0;i<ops.length;i++){var o=ops[i];if(o[0]==='set'&&o[2]&&typeof o[2].text==='string'&&o[2].text!=='')t++;else if(o[0]==='create'&&o[2]==='rwt.widgets.GridItem'){g++;S.rows[o[1]]=1;}else if(o[0]==='call'&&o[2]==='init'&&/\.gc$/.test(''+o[1]))c++;else if(o[0]==='destroy'&&S.rows[o[1]]){d++;delete S.rows[o[1]];}}S.seq++;S.ops=ops.length;S.txt=t;S.grid=g;S.gc=c;S.gone=d;}}catch(e){}return r;};}var s=window.__isMsg;return s.seq+','+s.ops+','+s.txt+','+s.grid+','+s.gc+','+s.gone;}catch(e){return 'NA';}})()"
}

; Every record field blank: what IDS leaves on the form for a number it does
; not have. The description is left out on purpose - on a reused form IDS
; leaves the previous item's description standing - and so are the stock
; rows, which can still be the last part's until the grid repaints. Read
; line by line, never with a ^ anchor: AutoHotkey's regex only knows `r`n as
; a line break, and these lines are joined with `n.
IZ_PartRecordEmpty(t) {
    Loop, Parse, t, `n, `r
    {
        eq := InStr(A_LoopField, "=")
        if (!eq)
            continue
        k := SubStr(A_LoopField, 1, eq - 1)
        if k not in active,discount,class,list,trade,daily,stock_order,repl,old,oldest
            continue
        if (Trim(SubStr(A_LoopField, eq + 1)) != "")
            return false
    }
    return true
}

; the stockN= lines of a record, as one string - what the grid is showing
IZ_StockBlock(t) {
    s := ""
    Loop, Parse, t, `n, `r
        if (SubStr(A_LoopField, 1, 5) = "stock")
            s .= A_LoopField "`n"
    return s
}

; the record without its stockN= lines
IZ_StripStock(t) {
    s := ""
    Loop, Parse, t, `n, `r
        if (A_LoopField != "" && SubStr(A_LoopField, 1, 5) != "stock")
            s .= (s != "" ? "`n" : "") A_LoopField
    return s
}

;--------------------- DC210 Item/Order Enquiry (parts) -----------------------
; Same session as the VIN tool, this one screen: opens DC210 from the menu box
; (or stays on it, --isuzubatch reuse), types the part number, clicks OK, then
; reads description/prices/stock LABEL-RELATIVE (find the label element, take
; the input(s) to its right on the same row) - never by absolute pixel
; coordinates, because this form's layout differs per window.
; Returns key=value lines, "NOTFOUND", or "" on error.
IZ_PartLookup(value) {
    global IZ_gBatch, IZ_gLog, IZ_CFG_STALE_MS, IZ_CFG_ROWWAIT_MS, IZ_gReuse
    jsMenu := "(function(){var e=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&r.width>0&&r.top<140&&r.left<400;})[0];if(!e)return'';var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    ; wait for the Item# entry field: label can be an input (like DC611) or a
    ; plain text element, so check both; entry field = first EDITABLE input to
    ; the label's right on the same row
    jsItem := "(function(){var vis=function(r){return r.width>0&&r.height>0;};var lab=null;var els=document.querySelectorAll('input,div,span,label,td');for(var i=0;i<els.length;i++){var e=els[i];var r=e.getBoundingClientRect();if(!vis(r))continue;var t=(e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();if(t==='Item#'){lab=r;break;}}if(!lab)return'';var ins=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&!x.disabled&&vis(r)&&Math.abs((r.top+r.height/2)-(lab.top+lab.height/2))<12&&r.left>lab.left;});ins.sort(function(a,b){return a.getBoundingClientRect().left-b.getBoundingClientRect().left;});if(!ins.length)return'';var r=ins[0].getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    ; Still on the form from the last part of a --isuzubatch reuse run? Then
    ; Item# is already on screen and the menu is left alone.
    onForm := (IZ_gReuse && IZ_Coord(jsItem, fx, fy))
    if (onForm)
        IZ_BLog("part: DC210 form still up, reusing it")
    if (!onForm) {
        if !IZ_Coord(jsMenu, mx, my)
            return IZ_LkFail("DC210: the menu search box was not on screen")
        IZ_Click(mx, my)
        IZ_SelAllDel()
        IZ_InsertText("DC210")
        Sleep, 250
        IZ_KeyPress("Enter", 13)
    }
    ; The first answer the server has to give. IZ_CFG_STALE_MS without it and
    ; the session is asked, with a real RAP send, whether it is still there:
    ; a dead one comes back as stale, and the batch signs in again and resends
    ; the number. A live one that was only slow gets the old fallback below.
    if !IZ_WaitCoord(jsItem, fx, fy, IZ_CFG_STALE_MS, 80) {
        if (!IZ_SessionAlive())
            return IZ_LkStale("DC210: no answer in " IZ_CFG_STALE_MS "ms and the session is dead")
        ; fallback: retry the menu open with slow per-key typing
        if !IZ_Coord(jsMenu, mx, my)
            return IZ_LkFail("DC210: the menu search box vanished on the retry")
        IZ_Click(mx, my)
        IZ_SelAllDel()
        IZ_TypeText("DC210")
        Sleep, 300
        IZ_KeyPress("Enter", 13)
        if !IZ_WaitCoord(jsItem, fx, fy, 8000, 250) {
            IZ_BLog("PART-NOFORM-DUMP-BEGIN")
            IZ_BLog(IZ_B64Decode(IZ_CDP_Eval(IZ_DumpLeafJS())))
            IZ_BLog("PART-NOFORM-DUMP-END")
            return IZ_LkFail("DC210: the Item# form never rendered (14s)")
        }
    }
    ; type the part number and verify it landed (retry up to 3x)
    entered := false
    Loop, 3 {
        IZ_Click(fx, fy)
        IZ_SelAllDel()
        Sleep, 20
        if (A_Index < 3)
            IZ_InsertText(value)
        else
            IZ_TypeText(value)
        Sleep, 40
        jsRead := "(function(){var ins=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),cy:r.top+r.height/2,cx:r.left+r.width/2,w:r.width};}).filter(function(i){return i.w>0;});var m=ins.find(function(i){return Math.abs(i.cx-" fx ")<3&&Math.abs(i.cy-" fy ")<3;});return m?m.v:'';})()"
        got := IZ_CDP_Eval(jsRead)
        StringUpper, gU, got
        StringUpper, vU, value
        if (gU = vU) {
            entered := true
            break
        }
        IZ_BLog("part entry attempt " A_Index ": got=""" got """")
    }
    if (!entered)
        return IZ_LkFail("DC210: the part number would not stay in the Item# field (read back """ got """)")
    ; click OK
    jsOK := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='OK';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !IZ_Coord(jsOK, ox, oy)
        return IZ_LkFail("DC210: no OK button on the Item# form")
    ; the answer counter before the press: the mark the answer must move past
    seq0 := RegExReplace(IZ_CDP_Eval(IZ_JsMsgHook()), ",.*$")
    ; and the stock rows on screen before it, so a grid that has not repainted
    ; yet can be told from the answer's rows (a fresh form shows none)
    before := onForm ? IZ_StockBlock(IZ_B64Decode(IZ_CDP_Eval(IZ_PartReadJS()))) : ""
    IZ_Click(ox, oy)
    ; poll for the result: a non-empty input right of the "List Price" label
    ; means the record rendered; a not-found style message means no record
    jsReady := "(function(){var vis=function(r){return r.width>0&&r.height>0;};var term=Array.from(document.querySelectorAll('div,span,td')).some(function(x){var r=x.getBoundingClientRect();return vis(r)&&x.children.length===0&&/program terminated/i.test((x.innerText||''));});if(term)return 'term';var lab=null;var els=document.querySelectorAll('input,div,span,label,td');for(var i=0;i<els.length;i++){var e=els[i];var r=e.getBoundingClientRect();if(!vis(r))continue;var t=(e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();if(t==='List Price'){lab=r;break;}}if(lab){var ins=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return vis(r)&&Math.abs((r.top+r.height/2)-(lab.top+lab.height/2))<12&&r.left>lab.left&&(x.value||'').trim()!=='';});if(ins.length)return 'ok';}var msg=Array.from(document.querySelectorAll('*')).some(function(x){return x.children.length<=1&&/not found|no record|does not exist|invalid item/i.test((x.innerText||''));});if(msg)return 'none';var il=null;var e2=document.querySelectorAll('input,div,span,label,td');for(var j=0;j<e2.length;j++){var q=e2[j];var qr=q.getBoundingClientRect();if(!vis(qr))continue;var qt=(q.tagName==='INPUT'?(q.value||''):(q.children.length===0?(q.innerText||''):'')).trim();if(qt==='Item#'){il=qr;break;}}if(il){var ii=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return vis(r)&&Math.abs((r.top+r.height/2)-(il.top+il.height/2))<12&&r.left>il.left;});ii.sort(function(a,b){return a.getBoundingClientRect().left-b.getBoundingClientRect().left;});if(ii.length&&(ii[0].value||'').trim()!==''&&(!ii[1]||(ii[1].value||'').trim()===''))return 'empty';}return 'wait';})()"
    txt := ""
    ; --- the answer, off the wire (see the top of this file) ---------------
    if (RegExMatch(seq0, "^\d+$")) {
        rt0 := A_TickCount
        ans := ""
        Loop {
            Sleep, 30
            r := IZ_CDP_Eval(IZ_JsMsgHook())
            ; a message with operations, past the mark, that redrew a form
            ; canvas or carried a handful of operations: the program answered
            if (RegExMatch(r, "^(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)$", rm) && rm1 != seq0 && (rm5 >= 1 || rm2 >= 5)) {
                ans := r
                break
            }
            if (A_TickCount - rt0 > IZ_CFG_STALE_MS)
                break
        }
        if (ans != "") {
            IZ_BLog("answer on the wire in " (A_TickCount - rt0) "ms: " rm2 " ops, " rm3 " texts, " rm4 " rows made, " rm6 " gone, " rm5 " canvases")
            if (IZ_CDP_Eval(jsReady) = "term") {
                IZ_BLog("DC210 'Program terminated' after a valid submit - treating as NOTFOUND")
                IZ_DismissTermination()
                return "NOTFOUND"
            }
            t := IZ_B64Decode(IZ_CDP_Eval(IZ_PartReadJS()))
            ; No text set and the record fields blank: no such item. The rows
            ; on screen do not count - the answer just destroyed them and
            ; the grid may not have caught up. Never seen split across two
            ; messages, but a second one arriving within 200 ms is allowed for.
            if (rm3 = 0 && IZ_PartRecordEmpty(t)) {
                Sleep, 200
                r2 := IZ_CDP_Eval(IZ_JsMsgHook())
                if (RegExMatch(r2, "^(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)$", rm) && rm1 != RegExReplace(ans, ",.*$")) {
                    IZ_BLog("a second message: " rm2 " ops, " rm3 " texts, " rm4 " rows made")
                    t := IZ_B64Decode(IZ_CDP_Eval(IZ_PartReadJS()))
                }
                if (rm3 = 0 && IZ_PartRecordEmpty(t)) {
                    IZ_BLog("the answer set no text and the record is blank - no such item")
                    return "NOTFOUND"
                }
            }
            if (rm4 > 0) {
                ; the answer made rows: wait for the grid to show rows that are
                ; not the ones it showed before the click. Identical rows for
                ; two parts in a row cost the whole wait and lose nothing.
                w0 := A_TickCount
                Loop {
                    blk := IZ_StockBlock(t)
                    if (blk != "" && blk != before)
                        break
                    if (A_TickCount - w0 > IZ_CFG_ROWWAIT_MS) {
                        IZ_BLog("the grid did not change in " IZ_CFG_ROWWAIT_MS "ms - taking the rows on screen")
                        break
                    }
                    Sleep, 60
                    t := IZ_B64Decode(IZ_CDP_Eval(IZ_PartReadJS()))
                }
                IZ_BLog("rows on screen after " (A_TickCount - w0) "ms")
            } else if (IZ_StockBlock(t) != "") {
                ; no row made for this record; rows on screen are the last part's
                IZ_BLog("the answer made no stock row - the rows on screen are dropped")
                t := IZ_StripStock(t)
            }
            return t
        }
        IZ_BLog("no answer on the wire in " IZ_CFG_STALE_MS "ms - " (onForm ? "the reused form is not trusted" : "watching the screen"))
        if (onForm)
            return IZ_LkFail("DC210: no answer on the wire on the reused form")
    } else if (onForm) {
        return IZ_LkFail("DC210: no answer counter on a reused form")
    }
    ; "empty" = the DC210 form is up, our number is in Item#, and the record
    ; fields are still blank. That is also what the first moment after clicking
    ; OK looks like, so it only means NOT FOUND once it has held still. A real
    ; record fills in within the first few polls; 45 polls is 4.5s of margin.
    empties := 0
    ; The second answer the server has to give. "empty" is the form waiting
    ; on it and gets its own 4.5s rule above; anything else past IZ_CFG_STALE_MS
    ; means the screen is not even holding the form, so the session is asked
    ; whether it is alive, once, and a dead one is handed back as stale.
    pt0 := A_TickCount
    asked := false
    Loop, 120 {
        Sleep, 100
        st := IZ_CDP_Eval(jsReady)
        if (st = "empty") {
            if (++empties >= 45) {
                if (IZ_gBatch)
                    IZ_BLog("DC210 form stayed empty - no such item")
                txt := "NOTFOUND"
                break
            }
        } else {
            empties := 0
            if (!asked && st = "wait" && A_TickCount - pt0 > IZ_CFG_STALE_MS) {
                asked := true
                if (!IZ_SessionAlive())
                    return IZ_LkStale("DC210: no record in " IZ_CFG_STALE_MS "ms and the session is dead")
            }
        }
        if (IZ_gBatch)
            IZ_BLog("part poll " A_Index ": st=" st)
        if (st = "ok") {
            Sleep, 300   ; let the stock grid paint
            b64 := IZ_CDP_Eval(IZ_PartReadJS())
            t := IZ_B64Decode(b64)
            if RegExMatch(t, "^part=[^\r\n]+") {
                txt := t
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
            if (IZ_gBatch)
                IZ_BLog("DC210 'Program terminated' after a valid submit - treating as NOTFOUND")
            IZ_DismissTermination()
            return "NOTFOUND"
        }
    }
    ; timed out with nothing recognized - dump every visible text so the log
    ; shows exactly what screen we were stuck on
    if (txt = "" && IZ_gBatch) {
        IZ_BLog("PART-STUCK-DUMP-BEGIN")
        IZ_BLog(IZ_B64Decode(IZ_CDP_Eval(IZ_DumpLeafJS())))
        IZ_BLog("PART-STUCK-DUMP-END")
    }
    if (txt = "")
        return IZ_LkFail("DC210: 12s of polling and the record never rendered (last screen state """ st """)")
    return txt
}


;=========================== the rest, verbatim from IsuzuVIN.ahk 4.5 ==========

IZ_BLog(s) {
    global IZ_gLog
    FileAppend, % s "`n", %IZ_gLog%
}

IZ_ListFail(outFile, why) {
    IZ_BLog("ERROR: " why)
    FileAppend, % "RESULT=FAIL  " why "`nDONE`n", %outFile%
}

; AHK v1 trap: inside an active `try`, commands that set ErrorLevel THROW -
; FileDelete on a file that isn't there raises exception "1". Every delete
; goes through here so a missing/locked file can never abort a lookup.
IZ_SafeDelete(f) {
    try {
        if FileExist(f)
            FileDelete, %f%
    } catch e {
    }
}

;======================= cross-process serialization ==========================
; GUI + batch runs share one Chrome/tab; a named mutex serializes drivers.
IZ_MxAcquire(timeoutMs) {
    global IZ_gMx
    if (!IZ_gMx)
        IZ_gMx := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", "Local\IsuzuVIN_CDP", "Ptr")
    r := DllCall("WaitForSingleObject", "Ptr", IZ_gMx, "UInt", timeoutMs, "UInt")
    return (r = 0 || r = 0x80)     ; WAIT_OBJECT_0 or WAIT_ABANDONED
}

IZ_MxRelease() {
    global IZ_gMx
    if (IZ_gMx)
        DllCall("ReleaseMutex", "Ptr", IZ_gMx)
}

;=========================== Chrome management ================================
IZ_ChromePath() {
    for i, p in ["C:\Program Files\Google\Chrome\Application\chrome.exe"
                , "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
                , A_AppData "\..\Local\Google\Chrome\Application\chrome.exe"] {
        if FileExist(p)
            return p
    }
    return ""
}

IZ_HttpGet(path) {
    global IZ_CFG_PORT
    try {
        whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://127.0.0.1:" IZ_CFG_PORT path, true)
        whr.Send()
        whr.WaitForResponse(5)
        return whr.ResponseText
    } catch e {
        return ""
    }
}

IZ_ReadPid() {
    local p := ""
    if !FileExist(IZ_CFG_PIDFILE)   ; missing pid file threw out of FileRead
        return 0
    FileRead, p, %IZ_CFG_PIDFILE%
    p := Trim(p, " `r`n")
    if p is not integer
        return 0
    Process, Exist, %p%
    return (ErrorLevel = p) ? p : 0
}

IZ_EnsureChrome() {
    global
    ; already up? (persistent Chrome from a previous run)
    if (InStr(IZ_HttpGet("/json/version"), "webSocketDebuggerUrl")) {
        IZ_gChromePID := IZ_ReadPid()
        return true
    }
    local exe := IZ_ChromePath()
    if (exe = "")
        return false
    local args := " --headless=new --disable-gpu"
          . " --remote-debugging-port=" IZ_CFG_PORT
          . " --user-data-dir=""" IZ_CFG_PROFILE """"
          . " --remote-allow-origins=*"
          . " --window-size=1280,1024"
          . " --no-first-run --no-default-browser-check"
          . " --disable-features=Translate,MediaRouter"
          . " --disable-background-timer-throttling"
          . " --disable-renderer-backgrounding"
          . " --disable-backgrounding-occluded-windows"
    local pid
    Run, %exe%%args%, , Hide, pid
    IZ_gChromePID := pid
    IZ_SafeDelete(IZ_CFG_PIDFILE)
    FileAppend, %pid%, %IZ_CFG_PIDFILE%
    ; wait until CDP responds
    Loop, 60 {
        Sleep, 300
        if (InStr(IZ_HttpGet("/json/version"), "webSocketDebuggerUrl"))
            return true
    }
    return false
}

; attach to an existing IDS tab (warm start) or create a fresh xtapp target
IZ_OpenPage() {
    global
    IZ_gAttached := false
    ; ---- warm path: reuse a live IDS tab from a previous run ----
    local list := IZ_HttpGet("/json/list")
    local pos := 1, blk, wm, wm1, im, im1, s
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (!InStr(blk, IZ_CFG_HOST))
            continue
        if (!InStr(blk, """page"""))
            continue
        if !RegExMatch(blk, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/page/[^""]+)""", wm)
            continue
        s := IZ_WS_Connect("127.0.0.1", IZ_CFG_PORT, wm1)
        if (!s)
            continue
        IZ_gSock := s
        if (IZ_CDP_Eval("'pong'") = "pong") {
            IZ_gAttached := true
            if RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im)
                IZ_gTargetId := im1
            IZ_CDP_Cmd("Emulation.setDeviceMetricsOverride", "{""width"":1280,""height"":1024,""deviceScaleFactor"":1,""mobile"":false}")
            return true
        }
        ; tab answers no evals = renderer wedged (dead RAP session). Close it
        ; via HTTP or it lingers forever eating memory.
        if (IZ_gSock) {
            IZ_WS_CloseSocket(IZ_gSock)
            IZ_gSock := 0
        }
        if RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im)
            IZ_HttpGet("/json/close/" im1)
    }
    ; ---- cold path: create a fresh target ----
    local ver := IZ_HttpGet("/json/version")
    local bm, bm1
    if !RegExMatch(ver, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/[^""]+)""", bm)
        return false
    local bsock := IZ_WS_Connect("127.0.0.1", IZ_CFG_PORT, bm1)
    if (!bsock)
        return false
    local id := ++IZ_gId
    IZ_WS_SendText(bsock, "{""id"":" id ",""method"":""Target.createTarget"",""params"":{""url"":""https://" IZ_CFG_HOST "/app?open=xtapp"",""newWindow"":true,""width"":1280,""height"":1024}}")
    local tid := "", r, tm, tm1
    Loop, 30 {
        r := IZ_WS_RecvMessage(bsock)
        if (r = "")
            break
        if (InStr(r, """id"":" id) && RegExMatch(r, """targetId""\s*:\s*""([0-9A-Fa-f]+)""", tm)) {
            tid := tm1
            break
        }
    }
    IZ_WS_CloseSocket(bsock)
    if (tid = "")
        return false
    IZ_gTargetId := tid
    IZ_gSock := IZ_WS_Connect("127.0.0.1", IZ_CFG_PORT, "/devtools/page/" tid)
    if (!IZ_gSock)
        return false
    ; deterministic viewport (no Runtime/Page.enable -> no event spam)
    IZ_CDP_Cmd("Emulation.setDeviceMetricsOverride", "{""width"":1280,""height"":1024,""deviceScaleFactor"":1,""mobile"":false}")
    return true
}

; full transport recovery: socket -> chrome -> page -> login
IZ_Reconnect() {
    global
    if (IZ_gSock) {
        IZ_WS_CloseSocket(IZ_gSock)
        IZ_gSock := 0
    }
    if !IZ_EnsureChrome()
        return false
    if !IZ_OpenPage()
        return false
    return IZ_RecoverSession()
}

;=============================== CDP layer ====================================
IZ_JsonEsc(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, """", "\""")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

IZ_CDP_Cmd(method, paramsJson) {
    global IZ_gSock, IZ_gId, IZ_gCdpDead
    ; A dead socket and a JS expression that returned "" are the SAME empty
    ; string to every caller, so a lost connection used to be indistinguishable
    ; from a button that was not on screen. This flag separates them.
    if (!IZ_gSock) {
        IZ_gCdpDead := true
        return ""
    }
    id := ++IZ_gId
    msg := "{""id"":" id ",""method"":""" method """,""params"":" paramsJson "}"
    if !IZ_WS_SendText(IZ_gSock, msg)
        return ""
    Loop, 500 {
        r := IZ_WS_RecvMessage(IZ_gSock)
        if (r = "") {
            ; transport dead or page main thread wedged - kill the socket so
            ; every later CDP call fails INSTANTLY instead of burning a full
            ; recv timeout each (a wedged page turned loops into 25min hangs)
            IZ_WS_CloseSocket(IZ_gSock)
            IZ_gSock := 0
            IZ_gCdpDead := true
            return ""
        }
        if (RegExMatch(r, """id""\s*:\s*" id "\b"))
            return r
        ; else it's an event or another id -> keep reading
    }
    return ""
}

; Runtime.evaluate returning a string value; returns the raw value text
IZ_CDP_Eval(js) {
    p := "{""expression"":""" IZ_JsonEsc(js) """,""returnByValue"":true}"
    r := IZ_CDP_Cmd("Runtime.evaluate", p)
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

IZ_B64Decode(b64) {
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
IZ_Click(x, y) {
    p := "{""type"":""mousePressed"",""x"":" x ",""y"":" y ",""button"":""left"",""clickCount"":1}"
    IZ_CDP_Cmd("Input.dispatchMouseEvent", p)
    p := "{""type"":""mouseReleased"",""x"":" x ",""y"":" y ",""button"":""left"",""clickCount"":1}"
    IZ_CDP_Cmd("Input.dispatchMouseEvent", p)
}

; fast: whole string in ONE CDP call (fires proper input events)
IZ_InsertText(s) {
    IZ_CDP_Cmd("Input.insertText", "{""text"":""" IZ_JsonEsc(s) """}")
}

; slow fallback: per-character key events
IZ_TypeText(s) {
    Loop, Parse, s
    {
        ch := IZ_JsonEsc(A_LoopField)
        IZ_CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""text"":""" ch """}")
        IZ_CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""text"":""" ch """}")
    }
}

IZ_KeyPress(key, vk) {
    IZ_CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""key"":""" key """,""code"":""" key """,""windowsVirtualKeyCode"":" vk "}")
    IZ_CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""key"":""" key """,""code"":""" key """,""windowsVirtualKeyCode"":" vk "}")
}

IZ_SelAllDel() {
    IZ_CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""modifiers"":2,""key"":""a"",""code"":""KeyA"",""windowsVirtualKeyCode"":65}")
    IZ_CDP_Cmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""modifiers"":2,""key"":""a"",""code"":""KeyA"",""windowsVirtualKeyCode"":65}")
    IZ_KeyPress("Delete", 46)
}

IZ_Coord(js, ByRef x, ByRef y) {
    v := IZ_CDP_Eval(js)
    if RegExMatch(v, "^(-?[0-9]+),(-?[0-9]+)$", m) {
        x := m1, y := m2
        return true
    }
    return false
}

; poll a coordinate-returning JS until it resolves (replaces fixed sleeps)
IZ_WaitCoord(js, ByRef x, ByRef y, timeoutMs = 6000, stepMs = 200) {
    start := A_TickCount
    Loop {
        if IZ_Coord(js, x, y)
            return true
        if (A_TickCount - start > timeoutMs)
            return false
        Sleep, %stepMs%
    }
}

;=============================== login ========================================
; Title alone LIES: it keeps saying "Active user" even after the server throws
; a re-auth panel back up (session challenged, not dead). RAP still answers so
; IZ_SessionAlive() also passes - the ONLY honest tell is a VISIBLE password field
; on screen. If one exists we are NOT usable-logged-in, whatever the title says.
; (width>0 filter: RAP leaves hidden stale password inputs in the DOM.)
IZ_IsLoggedIn() {
    t := IZ_CDP_Eval("document.title")
    if !InStr(t, "Active user")
        return false
    pw := IZ_CDP_Eval("''+Array.from(document.querySelectorAll('input[type=password]')).filter(function(x){return x.getBoundingClientRect().width>0;}).length")
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
IZ_JsLoginField(which, what) {
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
IZ_SetLoginField(which, text) {
    global IZ_gBatch
    jsCoord := IZ_JsLoginField(which, "xy")
    jsVal   := IZ_JsLoginField(which, "val")
    Loop, 3 {
        if !IZ_Coord(jsCoord, cx, cy)
            return false
        IZ_Click(cx, cy)
        Sleep, 100
        IZ_SelAllDel()
        Sleep, 60
        if (A_Index < 3)
            IZ_InsertText(text)
        else
            IZ_TypeText(text)
        Sleep, 120
        got := IZ_CDP_Eval(jsVal)
        if (got == text)
            return true
        if (IZ_gBatch)
            IZ_BLog("login field " which " attempt " A_Index ": got=""" got """ want=""" text """")
    }
    return false
}

IZ_EnsureLogin() {
    global
    local t0 := IZ_CDP_Eval("document.title")
    if (IZ_gBatch)
        IZ_BLog("login: title=" t0)
    if IZ_IsLoggedIn()
        return true
    ; wait for login form (VISIBLE password field - RAP keeps hidden stale ones)
    local n := 0
    Loop, 60 {
        n := IZ_CDP_Eval("''+Array.from(document.querySelectorAll('input[type=password]')).filter(function(x){return x.getBoundingClientRect().width>0;}).length")
        if (n >= 1)
            break
        Sleep, 250
    }
    if (IZ_gBatch)
        IZ_BLog("login: pwcount=" n)
    if (n < 1)
        return IZ_IsLoggedIn()
    Sleep, 700   ; let the RAP login form settle before typing
    ; fill + verify - fields found relative to the password box, never by index
    if !IZ_SetLoginField("u", IZ_CFG_USER) {
        if (IZ_gBatch)
            IZ_BLog("login: FAILED setting username field")
        return false
    }
    if !IZ_SetLoginField("p", IZ_CFG_PW) {
        if (IZ_gBatch)
            IZ_BLog("login: FAILED setting password field")
        return false
    }
    local jsS := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){return x.children.length<=1&&(x.innerText||'').trim()==='Sign in'&&x.getBoundingClientRect().width>0;});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    local sx, sy
    if !IZ_Coord(jsS, sx, sy) {
        if (IZ_gBatch)
            IZ_BLog("login: FAILED finding Sign in button")
        return false
    }
    IZ_Click(sx, sy)
    if (IZ_gBatch)
        IZ_BLog("login: clicked Sign in at " sx "," sy)
    local err
    Loop, 50 {
        Sleep, 300
        if IZ_IsLoggedIn()
            return true
        ; surface the server's own refusal text (e.g. "Authenticated, but no
        ; company found for user. (412)") instead of timing out blind
        err := IZ_CDP_Eval("(function(){var e=Array.from(document.querySelectorAll('div,span')).find(function(x){var r=x.getBoundingClientRect();return r.width>0&&x.children.length===0&&/incorrect|invalid|locked|no company|denied/i.test(x.innerText||'');});return e?(e.innerText||'').trim().substring(0,80):'';})()")
        if (err != "") {
            if (IZ_gBatch)
                IZ_BLog("login: server refused: " err)
            IZ_SetStatus("Sign-in refused: " err)
            return false
        }
    }
    if (IZ_gBatch)
        IZ_BLog("login: 15s timeout after Sign in click, title=" IZ_CDP_Eval("document.title"))
    return IZ_IsLoggedIn()
}

; alive check -> normal login -> fresh tab + login.
; TRAP 1: the page title keeps saying "Active user" long after the server has
; killed the session (zombie page) - IZ_IsLoggedIn() alone is NOT enough here.
; TRAP 2: NEVER Page.navigate a zombie RAP page - its unload handler fires a
; sync XHR into the dead session and blocks the renderer main thread FOREVER
; (every eval then hangs). Close the tab and open a fresh one instead.
IZ_RecoverSession() {
    global
    if (IZ_gSock && IZ_IsLoggedIn() && IZ_SessionAlive()) {
        IZ_DetectPoke()   ; (re)install the in-page keepalive on this page
        return true
    }
    ; a real login form on a live page? sign in in place
    if (IZ_gSock && !IZ_IsLoggedIn() && IZ_EnsureLogin()) {
        IZ_DetectPoke()
        return true
    }
    ; zombie session or wedged/dead page - fresh tab, fresh sign-in
    if !IZ_NewTab()
        return false
    if !IZ_EnsureLogin()
        return false
    IZ_DetectPoke()   ; fresh page = fresh window = interval must be reinstalled
    return true
}

; drop ALL IDS tabs (even wedged ones - HTTP close works when evals don't)
; and open a brand-new xtapp target
IZ_NewTab() {
    global
    if (IZ_gSock) {
        IZ_WS_CloseSocket(IZ_gSock)
        IZ_gSock := 0
    }
    local list := IZ_HttpGet("/json/list")
    local pos := 1, blk, im, im1
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (InStr(blk, IZ_CFG_HOST) && InStr(blk, """page""") && RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im))
            IZ_HttpGet("/json/close/" im1)
    }
    IZ_gTargetId := ""
    Sleep, 500
    return IZ_OpenPage()   ; no IDS tab left -> cold path creates a fresh one
}

; TRUE server liveness. A zombie page still answers JS and shows a logged-in
; title, but the RAP _requestCounter only advances when the SERVER answers a
; send(). Frozen counter after a real send = dead session.
IZ_SessionAlive() {
    global IZ_gBatch
    jsCnt := "(function(){try{return ''+rwt.remote.Connection.getInstance()._requestCounter;}catch(e){return 'NA';}})()"
    c0 := IZ_CDP_Eval(jsCnt)
    if (c0 = "NA" || c0 = "")
        return IZ_IsLoggedIn()   ; counter not exposed - fall back to title check
    IZ_CDP_Eval(IZ_JsRapSend())
    Loop, 12 {
        Sleep, 250
        c1 := IZ_CDP_Eval(jsCnt)
        if (c1 != "" && c1 != "NA" && c1 != c0)
            return true
    }
    if (IZ_gBatch)
        IZ_BLog("sessionalive: counter frozen at " c0 " - server session dead")
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
IZ_JsRapSend() {
    global IZ_CFG_KEEPALIVE
    return "(function(){if(!window.__ivSend){window.__ivSend=function(){try{if(window.rwt&&rwt.remote&&rwt.remote.Connection&&rwt.remote.Connection.getInstance){rwt.remote.Connection.getInstance().send();return 'sent-conn';}}catch(e){}try{if(window.rwt&&rwt.remote&&rwt.remote.Server&&rwt.remote.Server.getInstance){rwt.remote.Server.getInstance().send();return 'sent-server';}}catch(e){}try{if(window.org&&org.eclipse&&org.eclipse.swt&&org.eclipse.swt.Request&&org.eclipse.swt.Request.getInstance){org.eclipse.swt.Request.getInstance().send();return 'sent-legacy';}}catch(e){}return 'no';};}if(!window.__ivKA){window.__ivKA=setInterval(function(){try{window.__ivSend();}catch(e){}}," IZ_CFG_KEEPALIVE ");}return window.__ivSend();})()"
}

IZ_DetectPoke() {
    global IZ_gPokeMode
    r := IZ_CDP_Eval(IZ_JsRapSend())
    IZ_gPokeMode := InStr(r, "sent") ? ("rap:" r) : "menu"
}

IZ_Poke() {
    global IZ_gPokeMode
    if (IZ_gPokeMode = "")
        IZ_DetectPoke()
    if InStr(IZ_gPokeMode, "rap") {
        r := IZ_CDP_Eval(IZ_JsRapSend())
        if InStr(r, "sent")
            return true
        IZ_gPokeMode := "menu"
    }
    return IZ_MenuPoke()
}

IZ_MenuPoke() {
    jsMenu := "(function(){var e=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&r.width>0&&r.top<140&&r.left<400;})[0];if(!e)return'';var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !IZ_Coord(jsMenu, mx, my)
        return false
    IZ_Click(mx, my)
    IZ_InsertText("D")
    Sleep, 350
    IZ_SelAllDel()
    IZ_KeyPress("Escape", 27)
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
IZ_LkFail(why) {
    global IZ_gFailWhy, IZ_gCdpDead
    IZ_gFailWhy := why (IZ_gCdpDead ? "  [the connection died during this]" : "")
    return ""
}

; The same, for the one failure DoLookup treats differently: IDS took longer
; than IZ_CFG_STALE_MS to answer and the session did not prove alive after it.
IZ_LkStale(why) {
    global IZ_gStale
    IZ_gStale := true
    return IZ_LkFail(why)
}

; When a server-side program instance dies (e.g. DC210 hit with a bad item),
; IDS replaces the whole tab's content with "Termination / Program terminated".
; The tab is dead - no buttons, keys do nothing. The only way out is closing
; the tab via the X on its tab header (a ~16px child at the label's right).
IZ_DismissTermination() {
    jsT := "(function(){return Array.from(document.querySelectorAll('div,span,td,input')).some(function(x){var r=x.getBoundingClientRect();if(r.width<=0||r.height<=0)return false;var v=(x.tagName==='INPUT'?(x.value||''):(x.children.length===0?(x.innerText||''):'')).trim();return /program terminated/i.test(v);})?'1':'0';})()"
    jsX := "(function(){var tabs=Array.from(document.querySelectorAll('div')).filter(function(e){var r=e.getBoundingClientRect();return r.height>18&&r.height<30&&r.top<80&&r.width>80&&r.width<420&&/^DC\d+/.test((e.innerText||'').trim())&&e.children.length>=2;});if(!tabs.length)return'';var t=tabs[0];var kids=Array.from(t.children).map(function(c){return c.getBoundingClientRect();}).filter(function(r){return r.width>=10&&r.width<=20;});if(!kids.length)return'';var r=kids[kids.length-1];return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    Loop, 3 {
        if (IZ_CDP_Eval(jsT) != "1")
            return true
        if IZ_Coord(jsX, tx, ty) {
            IZ_Click(tx, ty)
            Sleep, 600
            continue
        }
        ; no tab X found - last-ditch keys
        IZ_KeyPress("Enter", 13)
        Sleep, 400
        IZ_KeyPress("Escape", 27)
        Sleep, 400
    }
    return (IZ_CDP_Eval(jsT) != "1")
}

; close any open DC611 screens (Exit F3) until none remain (max 3 levels)
IZ_CleanupForms() {
    IZ_DismissTermination()
    ; closing a dead tab (or the death itself) can throw up the mid-session
    ; re-auth challenge - sign back in in place before touching anything else
    if (!IZ_IsLoggedIn())
        IZ_EnsureLogin()
    jsExit := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='Exit F3';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    Loop, 3 {
        if !IZ_Coord(jsExit, ex, ey)
            break
        IZ_Click(ex, ey)
        Sleep, 500
    }
}

; diagnostic: every visible leaf text element AND non-empty input as x,y=text
IZ_DumpLeafJS() {
    return "(function(){var items=[];Array.from(document.querySelectorAll('input,div,span,label,td,button')).forEach(function(e){var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)return;var t=(e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();if(t==='')return;items.push({v:t.substring(0,60),x:Math.round(r.left),y:Math.round(r.top)});});items.sort(function(a,b){return a.y-b.y||a.x-b.x;});return btoa(unescape(encodeURIComponent(items.map(function(i){return i.x+','+i.y+'='+i.v;}).join('\n'))));})()"
}

; diagnostic: every non-empty input as "x,y=value" lines (base64)
IZ_DumpAllJS() {
    return "(function(){var items=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),x:Math.round(r.left),y:Math.round(r.top),w:Math.round(r.width)};}).filter(function(i){return i.w>0&&i.v!=='';});items.sort(function(a,b){return a.y-b.y||a.x-b.x;});return btoa(unescape(encodeURIComponent(items.map(function(i){return i.x+','+i.y+'='+i.v;}).join('\n'))));})()"
}

; read the DC210 record label-relative; stock grid rows come from leaf text
; elements below the "Stock Available" header, snapped to the nearest column
IZ_PartReadJS() {
    return "(function(){var vis=function(r){return r.width>0&&r.height>0;};var leaf=function(e){return (e.tagName==='INPUT'?(e.value||''):(e.children.length===0?(e.innerText||''):'')).trim();};var all=Array.from(document.querySelectorAll('input,div,span,label,td')).map(function(e){var r=e.getBoundingClientRect();return{e:e,t:leaf(e),r:r};}).filter(function(i){return vis(i.r)&&i.t!=='';});var rowInput=function(label,skip){var lab=all.find(function(i){return i.t===label;});if(!lab)return'';var ins=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return vis(r)&&Math.abs((r.top+r.height/2)-(lab.r.top+lab.r.height/2))<12&&r.left>lab.r.left;});ins.sort(function(a,b){return a.getBoundingClientRect().left-b.getBoundingClientRect().left;});var e=ins[skip||0];return e?(e.value||'').trim():'';};var out=[];out.push('part='+rowInput('Item#',0));out.push('desc='+rowInput('Item#',1));out.push('active='+rowInput('Active',0));out.push('discount='+rowInput('Discount code',0));out.push('class='+rowInput('Class',0));out.push('list='+rowInput('List Price',0));out.push('trade='+rowInput('Trade Price',0));out.push('daily='+rowInput('Daily Order',0));out.push('stock_order='+rowInput('Stock Order',0));out.push('repl='+rowInput('Repl#',0));out.push('old='+rowInput('Old#',0));out.push('oldest='+rowInput('Oldest',0));var hdr=all.find(function(i){return i.t==='Stock Available';});if(hdr){var names=['Whs','Stock Available','PO Number','Qty on Order','Min. Sell','Estimated Arrival Date','P/O Status','Pack Size'];var cols=[];names.forEach(function(n){var h=all.find(function(i){return i.t===n&&Math.abs(i.r.top-hdr.r.top)<10;});if(h)cols.push({n:n,x:h.r.left});});var cells=all.filter(function(i){return i.r.top>hdr.r.bottom+2&&i.r.top<hdr.r.bottom+330&&i.t.length<40&&i.t!=='OK'&&!/F\d+$/.test(i.t)&&(cols.length?i.r.left>=cols[0].x-15:false);});cells.sort(function(a,b){return a.r.top-b.r.top||a.r.left-b.r.left;});var lines=[];var cur=[];var lastY=-99;var flush=function(){if(!cur.length)return;var m={};cur.forEach(function(c){var best=null,bd=1e9;cols.forEach(function(col){var d=Math.abs(c.r.left-col.x);if(d<bd){bd=d;best=col;}});if(best&&!(best.n in m))m[best.n]=c.t;});if(m['Whs']!==undefined)lines.push(m['Whs']+'|'+(m['Stock Available']||'')+'|'+(m['Qty on Order']||'')+'|'+(m['Min. Sell']||'')+'|'+(m['Pack Size']||''));cur=[];};cells.forEach(function(c){if(c.r.top-lastY>5)flush();cur.push(c);lastY=c.r.top;});flush();lines.slice(0,9).forEach(function(l,i){out.push('stock'+(i+1)+'='+l);});}return btoa(unescape(encodeURIComponent(out.join('\n'))));})()"
}

IZ_JsQuote(s) {
    return "'" StrReplace(s, "'", "\'") "'"
}

;==============================================================================
; WS - minimal WebSocket client over raw Winsock (ws2_32), as in IsuzuVIN.ahk
;==============================================================================
IZ_WS_CloseSocket(sock) {
    DllCall("ws2_32\closesocket", "Ptr", sock)
}

; Connect a TCP socket to host:port and perform the WS upgrade for `path`.
; Returns socket handle (>0) or 0 on failure.
IZ_WS_Connect(host, port, path) {
    IZ_WS_Startup()
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
        IZ_WS_CloseSocket(sock)
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
    if !IZ_WS_SendRaw(sock, req) {
        IZ_WS_CloseSocket(sock)
        return 0
    }
    ; read handshake response headers up to \r\n\r\n
    resp := ""
    Loop {
        chunk := IZ_WS_RecvSome(sock, 1)
        if (chunk = "")
            break
        resp .= chunk
        if (InStr(resp, "`r`n`r`n"))
            break
        if (StrLen(resp) > 8192)
            break
    }
    if !InStr(resp, " 101 ") {
        IZ_WS_CloseSocket(sock)
        return 0
    }
    return sock
}

; receive one full application message (handles fragmentation + ping/close).
; Returns the text (UTF-8 decoded), or "" on error/close.
IZ_WS_RecvMessage(sock) {
    latin1 := ""          ; accumulated raw bytes as code points 0..255 (only if fragmented)
    firstText := ""       ; fast path: single-frame payload decoded directly
    frames := 0
    Loop {
        if !IZ_WS_RecvN(sock, 2, h)
            return ""
        b0 := NumGet(h, 0, "UChar")
        b1 := NumGet(h, 1, "UChar")
        fin := (b0 & 0x80) != 0
        opcode := b0 & 0x0F
        masked := (b1 & 0x80) != 0
        len := b1 & 0x7F
        if (len = 126) {
            if !IZ_WS_RecvN(sock, 2, e)
                return ""
            len := (NumGet(e,0,"UChar")<<8) | NumGet(e,1,"UChar")
        } else if (len = 127) {
            if !IZ_WS_RecvN(sock, 8, e)
                return ""
            len := 0
            Loop 8
                len := (len * 256) + NumGet(e, A_Index-1, "UChar")
        }
        if (masked) {
            if !IZ_WS_RecvN(sock, 4, mk)
                return ""
        }
        if (len > 0) {
            if !IZ_WS_RecvN(sock, len, pb)
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
                IZ_WS_SendPong(sock, &pb, len)
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

; receive EXACTLY n bytes into buffer `outbuf` (ByRef). Returns true/false.
IZ_WS_RecvN(sock, n, ByRef outbuf) {
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

; receive up to `max` bytes, return as latin1 string (1 byte per char) for header parsing
IZ_WS_RecvSome(sock, max) {
    VarSetCapacity(b, max, 0)
    n := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", &b, "Int", max, "Int", 0, "Int")
    if (n <= 0)
        return ""
    return StrGet(&b, n, "CP0")   ; treat bytes as chars 0..255
}

; send raw bytes from a buffer pointer
IZ_WS_SendBuf(sock, ptr, len) {
    sent := 0
    while (sent < len) {
        n := DllCall("ws2_32\send", "Ptr", sock, "Ptr", ptr + sent, "Int", len - sent, "Int", 0, "Int")
        if (n <= 0)
            return false
        sent += n
    }
    return true
}

IZ_WS_SendPong(sock, ptr, len) {
    ; minimal masked pong, echo payload
    total := 2 + 4 + len
    VarSetCapacity(f, total, 0)
    NumPut(0x8A, f, 0, "UChar")
    NumPut(0x80 | (len < 126 ? len : 0), f, 1, "UChar")
    NumPut(0,f,2,"UChar"),NumPut(0,f,3,"UChar"),NumPut(0,f,4,"UChar"),NumPut(0,f,5,"UChar")
    Loop %len%
        NumPut(NumGet(ptr,A_Index-1,"UChar") ^ 0, f, 6 + A_Index-1, "UChar")
    IZ_WS_SendBuf(sock, &f, total)
}

; send raw bytes from an AHK string (UTF-8)
IZ_WS_SendRaw(sock, str) {
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

; send a text frame (opcode 0x1), masked
IZ_WS_SendText(sock, text) {
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
    return IZ_WS_SendBuf(sock, &frame, total)
}

IZ_WS_Startup() {
    static done := 0
    if (done)
        return
    VarSetCapacity(wsadata, 408, 0)
    DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", &wsadata)
    done := 1
}


;=============================================================================
;   THE BYD LEG  -  the BYD DMS, through the BYD Stock Lookup's Chrome
;
;   From here to the end is the BYD leg: BydStock.ahk's browser route - the
;   hidden Chrome on its own debug port, the sign-in flow, the fetch() run
;   inside the signed-in tab, the batch with six in flight, and the same
;   WebSocket transport - copied out of that tool line for line with BY_ in
;   front of every name. Same port, same profile, so it is that tool's
;   signed-in session this rides, and BydStock.ahk itself is never touched.
;   Its status line was a window; here it is swc_byd.log beside this script.
;   Runs only in a worker copy of this script (SW_Worker):
;
;       SuperWarehouseCheck.ahk --bydbatch <listfile> <outfile>
;           every code in the list through the tab, six fetches in flight,
;           each answer appended to the out file as it lands:
;               BEGIN <code>
;               ROUTE=browser  RESULT=OK  rows=2  total=108
;               <code>  <name>
;                 Melbourne warehouse  qty=28  normal=...
;               END <code>          (or RESULT=FAIL and why, in between)
;               DONE
;       SuperWarehouseCheck.ahk --bydlogin <outfile>
;           sign the DMS tab in: the picture-code window comes up for you to
;           type; RESULT=OK or RESULT=FAIL <why> to the file
;       SuperWarehouseCheck.ahk --byd <code>
;           one code by hand, the block to swc_byd_result.txt beside this script
;
; ---------------------------------------------------------------------------
; ---- WHY THIS EXISTS. The other way in (BydStock.ahk's fallback, a pasted
; cookie) needs a JSESSIONID pasted out of DevTools, and that value is the
; login. It also dies on its own schedule, so the paste is not a one-off.
; Every way of reading the cookie back out of Chrome is closed on this
; machine, and each for its own reason:
;
;   * JSESSIONID is HttpOnly, so no bookmarklet and no in-page script can see
;     it. document.cookie returns nothing for it.
;   * The on-disk cookie store is held open by Chrome - a copy attempt gets
;     "device or resource busy" while the browser runs.
;   * Even closed, the values are unreadable: this Chrome writes
;     app_bound_encrypted_key into Local State, so cookie values are sealed to
;     the Chrome binary itself and plain DPAPI from another process cannot
;     unwrap them. And JSESSIONID is a session cookie, so it is very likely
;     never written to disk at all.
;   * Logging in again to mint our own cookie is the one forbidden move: the
;     DMS answers "sessionstatus: aready" and signs the dealer's tab out.
;
; So the cookie is not fetched. It is not touched. The query runs as a fetch()
; INSIDE a DMS tab that is already signed in, and Chrome attaches the session
; the way it does for every other click in that page. Same origin, so no CORS
; and no preflight. Nothing is stored by this script and nothing expires.
;
; ---- THE ONE REQUIREMENT. Talking to a tab needs a debug port, and a debug
; port can only be set when Chrome starts. Since Chrome 136 it is also refused
; outright on the default profile, so the everyday browser cannot be given one
; even if that were wise - and it would not be, because an open debug port
; lets any local process drive that browser and read every session in it.
; Hence a SEPARATE profile that holds the DMS and nothing else, launched by
; the script with its window hidden, and signed in by the flow below.
;
; ---- THE LOGIN, AND WHY A HUMAN IS STILL IN IT. The form (read out of the
; page's validation.js) is userName + passWord + checkCode, where checkCode
; is a picture captcha from CheckPwdCodeServlet. login() MD5s the password
; for a length check, asks checkLogin.json for an RSA key, encrypts the raw
; password with it, and POSTs doLogin.json with {userName, num, pwdToken};
; success navigates to main.html (or poseSel.html when the account has a
; position to choose). There is a DingXiang behavioural captcha in the page's
; source too, but its script tag is commented out and login() never reads its
; token - the picture is the only gate. So: the script fills the two fields it
; can, shows the window with the cursor already in the captcha box, and waits
; for the URL to change. Nothing here reads, solves, or bypasses the captcha.
;
; Signing in here WILL sign the everyday DMS tab out - one session per login
; is the server's rule, the same rule the Isuzu IDS tool works around by
; keeping one signed-in Chrome and sharing it. This tool takes port 9413 for
; the same reason that one took 9412: so the two never hunt through each
; other's tabs.
;=============================================================================

; BydStock.ahk's status line is a window; the worker has a log.
BY_SetStatus(msg) {
    BY_Log(msg)
}

BY_Log(s) {
    global BY_LOG
    FileAppend, % A_Hour ":" A_Min ":" A_Sec " " s "`n", %BY_LOG%
}

; Both routes hand their body here, so there is one reader and the two cannot
; drift apart. EN_LOCATION is only ever present on the browser route: the page
; resolved the warehouse name with the DMS's own dictionary, which beats
; BY_WarehouseName()'s guesswork - see the note above it.
BY_ParseStock(body) {
    if (!RegExMatch(body, """success""\s*:\s*true")) {
        msg := BY_JVal(body, "message")
        return {ok: false, err: "DMS said: " . (msg != "" ? msg : SubStr(body, 1, 200))}
    }
    rows := []
    for i, obj in BY_JsonDataObjects(body) {
        en := BY_JVal(obj, "EN_LOCATION")
        raw := BY_JVal(obj, "SUB_LOCATION")
        where := (en != "" ? en : BY_WarehouseName(raw))
        ; unmapped: neither the page's dictionary nor BY_WarehouseName() turned
        ; the whole name into English - some CJK is left in it.
        rows.Push({ code: BY_JVal(obj, "PART_CODE")
                  , name: BY_JVal(obj, "PART_NAME")
                  , series: BY_JVal(obj, "USED_CAR_SERIES")
                  , where: where
                  , whereRaw: raw
                  , unmapped: (raw != "" && RegExMatch(where, "[\x{4E00}-\x{9FFF}]") > 0)
                  , qty: BY_JVal(obj, "STOCK_COUNT")
                  , normal: BY_JVal(obj, "NORMAL_ORDER_PRICE")
                  , vor: BY_JVal(obj, "URGENT_ORDER_PRICE")
                  , sale: BY_JVal(obj, "SALE_PRICE")
                  , currency: BY_JVal(obj, "CURRENCY_CODE") })
    }
    return {ok: true, rows: rows}
}

; Exact map first. "?????" is literally "Australia branch office"; it is
; Melbourne by elimination - the web grid names Melbourne, Perth, Brisbane and
; Sydney, and the other three sites carry their city in the name.
BY_WarehouseName(cn) {
    static init := false, map, toks
    if (!init) {
        init := true
        map := {}
        map["?????"]       := "Melbourne warehouse"
        map["??????"]     := "Sydney warehouse"
        map["??????"]     := "Perth warehouse"
        map["????????"] := "Brisbane warehouse"
        ; fallback vocabulary, longest tokens first so ??? wins over ??
        toks := "????=Brisbane |????=Adelaide |???=Melbourne |??=Sydney |??=Perth |??=Australia |???=branch |???=central store |??=warehouse |?=store "
    }
    cn := Trim(cn)
    if (cn = "")
        return ""
    if map.HasKey(cn)
        return map[cn]
    out := cn
    Loop, Parse, toks, |
    {
        p := InStr(A_LoopField, "=")
        if (p)
            out := StrReplace(out, SubStr(A_LoopField, 1, p - 1), SubStr(A_LoopField, p + 1))
    }
    return Trim(out)
}

BY_JsonDataObjects(body) {
    rows := []
    p := InStr(body, """data""")
    if (!p)
        return rows
    p := InStr(body, "[", false, p)
    if (!p)
        return rows
    depth := 0, inQ := false, esc := false, start := 0
    n := StrLen(body)
    Loop, % (n - p + 1)
    {
        i := p + A_Index - 1
        c := SubStr(body, i, 1)
        if (inQ) {
            if (esc)
                esc := false
            else if (c = "\")
                esc := true
            else if (c = """")
                inQ := false
            continue
        }
        if (c = """") {
            inQ := true
            continue
        }
        if (c = "{" || c = "[") {
            if (depth = 1 && c = "{")
                start := i
            depth++
        } else if (c = "}" || c = "]") {
            depth--
            if (depth = 1 && c = "}" && start) {
                rows.Push(SubStr(body, start, i - start + 1))
                start := 0
            } else if (depth = 0)
                break
        }
    }
    return rows
}

BY_JVal(obj, key) {
    if !RegExMatch(obj, """" . key . """\s*:\s*(?:""((?:[^""\\]|\\.)*)""|([^,}\]]*))", m)
        return ""
    if (m2 != "") {
        v := Trim(m2)
        return (v = "null") ? "" : v
    }
    v := m1
    while RegExMatch(v, "\\u([0-9A-Fa-f]{4})", u)
        v := StrReplace(v, u, Chr("0x" . u1))
    v := StrReplace(v, "\""", """")
    v := StrReplace(v, "\/", "/")
    v := StrReplace(v, "\n", "`n")
    v := StrReplace(v, "\t", "`t")
    v := StrReplace(v, "\\", "\")
    return v
}

; Chrome first, Edge after it. Edge is Chromium with the same DevTools
; protocol and the same Chrome_WidgetWin_1 window class, and it is on every
; Windows 11 box, so a machine with no Chrome still gets the browser route.
BY_ChromeExe() {
    for i, p in ["C:\Program Files\Google\Chrome\Application\chrome.exe"
                , "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
                , A_AppData "\..\Local\Google\Chrome\Application\chrome.exe"
                , "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
                , "C:\Program Files\Microsoft\Edge\Application\msedge.exe"] {
        if FileExist(p)
            return p
    }
    return ""
}

; The DevTools HTTP side - target listing only. Short timeout: a local port
; either answers at once or is not there.
BY_CdpHttp(path) {
    global BY_CPORT
    try {
        whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://127.0.0.1:" . BY_CPORT . path, true)
        whr.Send()
        whr.WaitForResponse(3)
        return whr.ResponseText
    } catch e {
        return ""
    }
}

; ---- NEVER KILLS AN EXISTING ONE. The signed-in session is the expensive
; thing in this arrangement; a second launch on a live port would do nothing
; useful and a restart would throw the login away. Starts Chrome hidden and
; keeps it that way: the window is only ever shown by BY_ShowDms().
BY_LaunchDmsChrome(ByRef err) {
    global BY_CPORT, BY_CPROFILE, BY_BASE, BY_CHWND
    if (InStr(BY_CdpHttp("/json/version"), "webSocketDebuggerUrl"))
        return true
    exe := BY_ChromeExe()
    if (exe = "") {
        err := "Could not find chrome.exe or msedge.exe."
        return false
    }
    FileCreateDir, %BY_CPROFILE%
    args := " --remote-debugging-port=" . BY_CPORT
          . " --user-data-dir=""" . BY_CPROFILE . """"
          . " --remote-allow-origins=*"
          . " --no-first-run --no-default-browser-check"
          . " " . BY_BASE
    Run, %exe%%args%, , UseErrorLevel, pid
    if ErrorLevel {
        err := "Chrome would not start."
        return false
    }
    ; Chrome opens its window before the page is up; hide it the moment it
    ; exists. One flash at most, and only on the first launch. The process
    ; owns several Chrome_WidgetWin_1 windows, most of them titleless helpers,
    ; so only the titled one is the browser - and BY_CHWND is left for
    ; BY_DmsWindow() to settle by its own, surer method.
    Loop, 60 {
        WinGet, list, List, ahk_pid %pid% ahk_class Chrome_WidgetWin_1
        Loop, %list% {
            hw := list%A_Index%
            WinGetTitle, t, ahk_id %hw%
            if (t != "") {
                WinHide, ahk_id %hw%
                return true
            }
        }
        Sleep, 250
    }
    return true
}

; The DMS browser's top-level window, or 0. The launch remembers it; when the
; browser was already running the tab is stamped with a title nothing else
; carries, found by that, and given its title back. Chrome pushes a title
; change to the window a beat later, hence the short wait.
BY_DmsWindow() {
    global BY_CPORT, BY_CHWND
    if (BY_CHWND && WinExist("ahk_id " . BY_CHWND))
        return BY_CHWND
    BY_CHWND := 0
    mark := "BydStock " . BY_CPORT
    old := BY_CdpEval("(function(){var t=document.title;document.title='" . mark . "';return t;})()")
    Loop, 20 {
        WinGet, hw, ID, %mark% ahk_class Chrome_WidgetWin_1
        if (hw)
            break
        Sleep, 100
    }
    BY_CdpEval("document.title='" . BY_JsStr(old) . "'")
    if (hw)
        BY_CHWND := hw
    return BY_CHWND
}

BY_ShowDms() {
    hw := BY_DmsWindow()
    if (!hw)
        return false
    WinShow, ahk_id %hw%
    WinActivate, ahk_id %hw%
    return true
}

BY_HideDms() {
    hw := BY_DmsWindow()
    if (hw)
        WinHide, ahk_id %hw%
}

; ---- THE LOGIN FLOW. True when a DMS tab is signed in, launching, filling
; and waiting as needed. The only thing it will not do is read the picture.
BY_CdpEnsureLogin(ByRef err) {
    global BY_CSOCK, BY_LUSER, BY_LPASS
    err := ""
    if (!BY_CdpAttach(err)) {
        if (!BY_LaunchDmsChrome(err))
            return false
        Loop, 60 {                        ; the tab takes a moment to list
            Sleep, 250
            if (BY_CdpAttach(err))
                break
        }
        if (!BY_CSOCK)
            return false
    }
    path := BY_CdpEval("location.pathname")
    if (InStr(path, "main.html"))
        return true
    if (InStr(path, "poseSel")) {
        BY_ShowDms()
        BY_SetStatus("The DMS wants a position picked - choose one in its window.")
        return BY_WaitForMain(err)
    }
    if (BY_LUSER = "" || BY_LPASS = "") {
        if (!BY_AskLogin()) {
            err := "No DMS login saved."
            return false
        }
    }
    ; Anywhere but the login form (a sign-out landing, an error page): go to
    ; the form and wait for its fields, because that is all the fill can use.
    if (BY_CdpEval(BY_JsHasLoginForm()) != "yes") {
        BY_CdpEval("location.href='/'")
        Loop, 40 {
            Sleep, 250
            if (BY_CdpEval(BY_JsHasLoginForm()) = "yes")
                break
        }
    }
    r := BY_CdpEval(BY_JsFillLogin(BY_LUSER, BY_LPASS))
    if (r != "FILLED") {
        err := "Could not reach the DMS login form" . (r != "" ? " (" . r . ")" : "") . "."
        return false
    }
    BY_ShowDms()
    BY_CdpEval("document.getElementById('checkCode').focus()")   ; again, now that the window can take focus
    BY_SetStatus("Type the picture code in the DMS window and press Enter.")
    return BY_WaitForMain(err)
}

; Polls the tab's URL until the DMS lands on main.html, then hides the window
; again. Four minutes is long enough to misread the picture twice. A wrong
; code just leaves the page where it is, so the wait simply continues.
BY_WaitForMain(ByRef err) {
    Loop, 480 {                           ; 500ms x 480 = 4 min
        Sleep, 500
        path := BY_CdpEval("location.pathname")
        if (path = "") {                  ; mid-navigation, or the socket dropped
            e2 := ""
            BY_CdpAttach(e2)
            continue
        }
        if (InStr(path, "main.html")) {
            BY_HideDms()
            return true
        }
        if (InStr(path, "poseSel"))
            BY_SetStatus("The DMS wants a position picked - choose one in its window.")
    }
    err := "The DMS login was not completed."
    return false
}

; Only reached if BY_LUSER or BY_LPASS at the top is blank. Held for this run only;
; the lasting fix is to fill the two lines in. The password box is masked.
BY_AskLogin() {
    global BY_LUSER, BY_LPASS
    InputBox, u, BYD stock - DMS login, % "DMS username (the same one used in Chrome).`n"
        . "Kept for this run only - fill LUSER and LPASS in the script to keep it.", , 460, 170, , , , , %BY_LUSER%
    if (ErrorLevel || Trim(u) = "")
        return false
    InputBox, p, BYD stock - DMS login, % "DMS password for " . Trim(u) . ".", HIDE, 460, 150
    if (ErrorLevel || p = "")
        return false
    BY_LUSER := Trim(u), BY_LPASS := p
    return true
}

BY_JsHasLoginForm() {
    return "(document.getElementById('userName')&&document.getElementById('passWord')&&document.getElementById('checkCode'))?'yes':'no'"
}

; Fills the two fields a script can, ticks the privacy box login() checks,
; clears the captcha field and puts the cursor in it. The values are JS string
; literals, so BY_JsStr() closes the injection door the same way CdpStock()'s
; character whitelist does for part codes.
BY_JsFillLogin(user, pass) {
    return ""
    . "(function(){"
    .   "var u=document.getElementById('userName'),p=document.getElementById('passWord'),c=document.getElementById('checkCode');"
    .   "if(!u||!p||!c)return 'NOFORM';"
    .   "u.value='" . BY_JsStr(user) . "';p.value='" . BY_JsStr(pass) . "';"
    .   "var d=document.getElementById('READ_AND_AGREE_CHECKBOX');if(d)d.checked=true;"
    .   "c.value='';c.focus();"
    .   "return 'FILLED';"
    . "})()"
}

; For a single-quoted JS literal. BY_CdpEsc() then wraps the whole expression for
; JSON, and it escapes backslashes first, so the two layers do not collide.
BY_JsStr(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, "'", "\'")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    return s
}

; Attach to a signed-in DMS tab. Reuses the socket when it still answers, so a
; run of queries costs one handshake, not one per part.
BY_CdpAttach(ByRef err) {
    global BY_CPORT, BY_CSOCK
    if (BY_CSOCK) {
        if (BY_CdpEval("'pong'") = "pong")
            return true
        BY_WS_Close(BY_CSOCK), BY_CSOCK := 0
    }
    list := BY_CdpHttp("/json/list")
    if (list = "") {
        err := "No DMS browser on port " . BY_CPORT . "."
        return false
    }
    pos := 1
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (!InStr(blk, "oadms.byd.com") || !InStr(blk, """page"""))
            continue
        if !RegExMatch(blk, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/page/[^""]+)""", wm)
            continue
        s := BY_WS_Connect("127.0.0.1", BY_CPORT, wm1)
        if (!s)
            continue
        BY_CSOCK := s
        if (BY_CdpEval("'pong'") = "pong")
            return true
        BY_WS_Close(BY_CSOCK), BY_CSOCK := 0
    }
    err := "DMS browser is open but has no oadms.byd.com tab."
    return false
}

; ---- WHY THE PAGE ALSO TRANSLATES. The action returns SUB_LOCATION in
; Chinese and the grid shows English only because it looks the id up with the
; app's own getLang(). In here that function is in scope, so the names come
; back the way the dealer reads them on the web page - which beats
; BY_WarehouseName()'s by-hand map, and settles the one entry that map had to
; guess. If getLang is missing the rows are passed through untouched and the
; map takes over.
BY_JsFetch(code, key := "") {
    global BY_ENDPOINT
    ; One slot, window.__bs, for the window's own query; a keyed slot under
    ; window.__bsb for the batch, where several are in flight at once. The
    ; key is the code after CdpStock's whitelist, so it is safe in quotes.
    store := (key = "") ? "window.__bs" : "(window.__bsb=window.__bsb||{})['" . key . "']"
    return ""
    . "(function(){"
    .   "var d={s:'WAIT'};" . store . "=d;"
    .   "try{"
    .     "fetch('/" . BY_ENDPOINT . "',{method:'POST',credentials:'same-origin',"
    .       "headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8','X-Requested-With':'XMLHttpRequest'},"
    .       "body:'PART_CODE=" . code . "&page=1&start=0&limit=100'})"
    .     ".then(function(r){d.http=r.status;d.sess=r.headers.get('sessionstatus')||'';return r.text();})"
    .     ".then(function(t){"
    .       "try{var j=JSON.parse(t);"
    .         "if(j&&j.data&&typeof getLang=='function'){"
    .           "for(var i=0;i<j.data.length;i++){"
    .             "var id=j.data[i].SUB_LOCATION_ID;"
    .             "if(id){var en=getLang(id+'WAREHOUSE_NAME');"
    .               "if(en&&en.indexOf('WAREHOUSE_NAME')<0)j.data[i].EN_LOCATION=en;}"
    .           "}"
    .           "t=JSON.stringify(j);"
    .         "}"
    .       "}catch(e){}"
    .       "d.body=t;d.s='OK';"
    .     "})"
    .     ".catch(function(e){d.err=String(e);d.s='ERR';});"
    .   "}catch(e){d.err=String(e);d.s='ERR';}"
    .   "return 'STARTED';"
    . "})()"
}

; The readable summary the batch writes: RESULT=OK with
; the row count and total on the first line, the code and name on the second,
; then one line per warehouse; or RESULT=FAIL and why.
BY_StockSummary(body) {
    res := BY_ParseStock(body)
    if (!res.ok)
        return "ROUTE=browser  RESULT=FAIL  " . res.err . "`n"
    total := 0, lines := ""
    for i, r in res.rows {
        total += (r.qty + 0)
        lines .= "  " . r.where . "  qty=" . r.qty . "  normal=" . r.normal . " " . r.currency . "  raw=" . r.whereRaw . "`n"
    }
    head := res.rows.MaxIndex() ? (res.rows[1].code . "  " . res.rows[1].name) : ""
    return "ROUTE=browser  RESULT=OK  rows=" . res.rows.MaxIndex() . "  total=" . total . "`n" . head . "`n" . lines
}

; ---- THE BATCH. Why it is quicker than one run per code: the AHK
; start, the /json/list call, the WebSocket handshake and the login check
; happen once instead of once per code, and six fetches sit on the wire
; together, so the DMS's own 1.8 s per answer overlaps. Measured on ten
; codes: one at a time 18.9 s, three 6.6 s, six about 4.5 s, ten 3.9 s, the
; same quantities every way, no rate limit seen. Six leaves room. The polls
; run every 60 ms. Nothing about the query or the parse is different: same
; BY_ENDPOINT, same page, same fetch, same StockSummary.
;
; Rate limit: the first "limit" answer drops the batch to one fetch at a time
; and that code goes again after a second; a second "limit" is a FAIL for
; that code. Signed out mid-batch: every remaining code fails with the
; signed-out line, and the caller runs --bydlogin and sends those again.
BY_CdpBatch(listFile, outFile, para := 6) {
    para := (para + 0 >= 1) ? para + 0 : 6
    codes := [], seen := {}
    txt := ""
    if FileExist(listFile)
        FileRead, txt, %listFile%
    Loop, Parse, txt, `n, `r
    {
        c := Trim(A_LoopField)
        if (c = "" || seen.HasKey(c))
            continue
        seen[c] := true
        codes.Push(c)
    }
    err := ""
    if (!codes.MaxIndex()) {
        FileAppend, % "RESULT=FAIL  Nothing to look up.`nDONE`n", %outFile%
        return
    }
    if (!BY_CdpEnsureLogin(err)) {
        FileAppend, % "RESULT=FAIL  " . err . "`nDONE`n", %outFile%
        return
    }
    next := 1
    inflight := {}
    Loop {
        while (next <= codes.MaxIndex() && BY_ObjCount(inflight) < para) {
            code := codes[next], next++
            safe := RegExReplace(code, "[^0-9A-Za-z\-]")
            if (safe = "" || inflight.HasKey(safe)) {
                BY_BatchEmit(outFile, code, "ROUTE=browser  RESULT=FAIL  Nothing usable in that code.`n")
                continue
            }
            if (BY_CdpEval(BY_JsFetch(safe, safe)) != "STARTED") {
                BY_BatchEmit(outFile, code, "ROUTE=browser  RESULT=FAIL  The DMS tab would not start the query.`n")
                continue
            }
            inflight[safe] := {code: code, t0: A_TickCount, tries: 1}
        }
        if (!BY_ObjCount(inflight))
            break
        Sleep, 60
        for key, f in inflight.Clone() {
            r := BY_CdpEval(BY_JsPoll(key))
            if (r = "") {                       ; socket dropped, or mid-navigation
                e2 := ""
                if (!BY_CdpAttach(e2)) {
                    BY_BatchEmit(outFile, f.code, "ROUTE=browser  RESULT=FAIL  Lost the DMS tab mid-query.`n")
                    inflight.Delete(key)
                }
                continue
            }
            if (r = "NONE") {                   ; the slot is gone: the page moved
                path := BY_CdpEval("location.pathname")
                if (path != "" && !InStr(path, "main.html")) {
                    BY_BatchEmit(outFile, f.code, "ROUTE=browser  RESULT=FAIL  The DMS browser is signed out - sign in again in that window.`n")
                    inflight.Delete(key)
                    continue
                }
            }
            if (r = "WAIT" || r = "NONE") {
                if (A_TickCount - f.t0 >= 10000) {
                    BY_BatchEmit(outFile, f.code, "ROUTE=browser  RESULT=FAIL  The DMS did not answer within 10 seconds.`n")
                    inflight.Delete(key)
                }
                continue
            }
            inflight.Delete(key)
            p := StrSplit(BY_B64Utf8(r), Chr(1))
            st := p[1], http := p[2], sess := p[3], payload := p[4]
            if (sess = "limit") {
                para := 1
                if (f.tries < 2) {
                    Sleep, 1000
                    if (BY_CdpEval(BY_JsFetch(key, key)) = "STARTED") {
                        f.tries += 1, f.t0 := A_TickCount
                        inflight[key] := f
                        continue
                    }
                }
                BY_BatchEmit(outFile, f.code, "ROUTE=browser  RESULT=FAIL  Server rate limit: wait a minute.`n")
                continue
            }
            if (st = "ERR")
                out := "ROUTE=browser  RESULT=FAIL  The page's own fetch failed: " . payload . "`n"
            else if (sess = "timeout" || http = 404)
                out := "ROUTE=browser  RESULT=FAIL  The DMS browser is signed out - sign in again in that window.`n"
            else if (sess = "aready")
                out := "ROUTE=browser  RESULT=FAIL  Another login took that session over.`n"
            else if (http != 200)
                out := "ROUTE=browser  RESULT=FAIL  HTTP " . http . " from the DMS.`n"
            else
                out := BY_StockSummary(payload)
            BY_BatchEmit(outFile, f.code, out)
        }
    }
    FileAppend, DONE`n, %outFile%
}

; One block per code, written in one go so a reader never sees half of one.
BY_BatchEmit(outFile, code, summary) {
    FileAppend, % "BEGIN " . code . "`n" . summary . "END " . code . "`n", %outFile%
}

BY_ObjCount(o) {
    n := 0
    for k in o
        n++
    return n
}

; ---- BASE64 ON THE WAY BACK, AND IT IS NOT DECORATION. BY_CdpEval() reads the
; result with a regex that stops at the first quote, and a JSON body is made of
; quotes. Base64 has none, so the body survives the trip whole. Chr(1)
; separates the fields: a control character, so nothing in a part name or a
; warehouse name can split a record by accident.
BY_JsPoll(key := "") {
    store := (key = "") ? "window.__bs" : "(window.__bsb||{})['" . key . "']"
    return ""
    . "(function(){"
    .   "var d=" . store . ";"
    .   "if(!d)return 'NONE';"
    .   "if(d.s=='WAIT')return 'WAIT';"
    .   "var p=d.s+'\u0001'+(d.http||'')+'\u0001'+(d.sess||'')+'\u0001'"
    .     "+(d.s=='ERR'?(d.err||''):(d.body||''));"
    .   "return btoa(unescape(encodeURIComponent(p)));"
    . "})()"
}

BY_B64Utf8(b64) {
    if (b64 = "")
        return ""
    sz := 0
    DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UIntP", sz, "Ptr", 0, "Ptr", 0)
    if (sz = 0)
        return ""
    VarSetCapacity(bin, sz, 0)
    DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1, "Ptr", &bin, "UIntP", sz, "Ptr", 0, "Ptr", 0)
    return StrGet(&bin, sz, "UTF-8")
}

BY_CdpEsc(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, """", "\""")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

; ---- A DEAD SOCKET IS DROPPED, NOT RETRIED. A wedged renderer answers
; nothing, and without this every later call would burn a full receive timeout
; instead of failing at once.
BY_CdpCmd(method, paramsJson) {
    global BY_CSOCK, BY_CDPID
    if (!BY_CSOCK)
        return ""
    id := ++BY_CDPID
    if !BY_WS_SendText(BY_CSOCK, "{""id"":" . id . ",""method"":""" . method . """,""params"":" . paramsJson . "}")
        return ""
    Loop, 500 {
        r := BY_WS_Recv(BY_CSOCK)
        if (r = "") {
            BY_WS_Close(BY_CSOCK)
            BY_CSOCK := 0
            return ""
        }
        if (RegExMatch(r, """id""\s*:\s*" . id . "\b"))
            return r
        ; an event, or somebody else's id - keep reading
    }
    return ""
}

BY_CdpEval(js) {
    r := BY_CdpCmd("Runtime.evaluate", "{""expression"":""" . BY_CdpEsc(js) . """,""returnByValue"":true}")
    if (r = "")
        return ""
    if RegExMatch(r, """value""\s*:\s*""([^""]*)""", m)
        return m1
    return ""
}

;==============================================================================
; WS_ - a minimal WebSocket client over raw Winsock, for the CDP conversation
; above. Lifted verbatim from the Isuzu tools' transport, which is where it was
; proven; no compression, no extensions, client frames masked because the
; protocol says they must be. Localhost only.
;==============================================================================
BY_WS_Startup() {
    static done := 0
    if (done)
        return
    VarSetCapacity(wsadata, 408, 0)
    DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", &wsadata)
    done := 1
}

; TCP connect plus the upgrade handshake for `path`. Socket handle, or 0.
BY_WS_Connect(host, port, path) {
    BY_WS_Startup()
    sock := DllCall("ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
    if (sock = -1 || sock = 0)
        return 0
    if (host = "localhost")
        host := "127.0.0.1"
    addr := DllCall("ws2_32\inet_addr", "AStr", host, "UInt")
    VarSetCapacity(sa, 16, 0)
    NumPut(2, sa, 0, "UShort")
    NumPut(((port & 0xFF) << 8) | ((port >> 8) & 0xFF), sa, 2, "UShort")   ; network byte order
    NumPut(addr, sa, 4, "UInt")
    if (DllCall("ws2_32\connect", "Ptr", sock, "Ptr", &sa, "Int", 16, "Int") != 0) {
        BY_WS_Close(sock)
        return 0
    }
    ; a receive timeout, so a broken session cannot freeze the window forever
    tmo := 10000
    DllCall("ws2_32\setsockopt", "Ptr", sock, "Int", 0xFFFF, "Int", 0x1006, "UInt*", tmo, "Int", 4)

    req := "GET " . path . " HTTP/1.1`r`n"
         . "Host: " . host . ":" . port . "`r`n"
         . "Upgrade: websocket`r`n"
         . "Connection: Upgrade`r`n"
         . "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==`r`n"
         . "Sec-WebSocket-Version: 13`r`n"
         . "`r`n"
    if !BY_WS_SendRaw(sock, req) {
        BY_WS_Close(sock)
        return 0
    }
    resp := ""
    Loop {
        chunk := BY_WS_RecvSome(sock, 1)
        if (chunk = "")
            break
        resp .= chunk
        if (InStr(resp, "`r`n`r`n") || StrLen(resp) > 8192)
            break
    }
    if !InStr(resp, " 101 ") {
        BY_WS_Close(sock)
        return 0
    }
    return sock
}

BY_WS_SendRaw(sock, str) {
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

BY_WS_SendBuf(sock, ptr, len) {
    sent := 0
    while (sent < len) {
        n := DllCall("ws2_32\send", "Ptr", sock, "Ptr", ptr + sent, "Int", len - sent, "Int", 0, "Int")
        if (n <= 0)
            return false
        sent += n
    }
    return true
}

; up to `max` bytes back as one char per byte, for reading the handshake
BY_WS_RecvSome(sock, max) {
    VarSetCapacity(b, max, 0)
    n := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", &b, "Int", max, "Int", 0, "Int")
    if (n <= 0)
        return ""
    return StrGet(&b, n, "CP0")
}

BY_WS_RecvN(sock, n, ByRef outbuf) {
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

BY_WS_SendText(sock, text) {
    plen := StrPut(text, "UTF-8") - 1
    VarSetCapacity(payload, plen + 1, 0)
    StrPut(text, &payload, "UTF-8")
    if (plen < 126)
        hdr := 2
    else if (plen < 65536)
        hdr := 4
    else
        hdr := 10
    total := hdr + 4 + plen        ; + the four mask bytes
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
        Loop 8 {
            shift := (8 - A_Index) * 8
            NumPut((plen >> shift) & 0xFF, frame, 1 + A_Index, "UChar")
        }
        off := 10
    }
    m0 := 0x12, m1 := 0x34, m2 := 0x56, m3 := 0x78
    NumPut(m0, frame, off, "UChar"), NumPut(m1, frame, off + 1, "UChar")
    NumPut(m2, frame, off + 2, "UChar"), NumPut(m3, frame, off + 3, "UChar")
    mask := [m0, m1, m2, m3]
    dataoff := off + 4
    Loop %plen% {
        i := A_Index - 1
        NumPut(NumGet(payload, i, "UChar") ^ mask[Mod(i, 4) + 1], frame, dataoff + i, "UChar")
    }
    return BY_WS_SendBuf(sock, &frame, total)
}

; one whole application message, handling fragments, pings and close
BY_WS_Recv(sock) {
    latin1 := ""
    frames := 0
    Loop {
        if !BY_WS_RecvN(sock, 2, h)
            return ""
        b0 := NumGet(h, 0, "UChar")
        b1 := NumGet(h, 1, "UChar")
        fin := (b0 & 0x80) != 0
        opcode := b0 & 0x0F
        masked := (b1 & 0x80) != 0
        len := b1 & 0x7F
        if (len = 126) {
            if !BY_WS_RecvN(sock, 2, e)
                return ""
            len := (NumGet(e, 0, "UChar") << 8) | NumGet(e, 1, "UChar")
        } else if (len = 127) {
            if !BY_WS_RecvN(sock, 8, e)
                return ""
            len := 0
            Loop 8
                len := (len * 256) + NumGet(e, A_Index - 1, "UChar")
        }
        if (masked) {
            if !BY_WS_RecvN(sock, 4, mk)
                return ""
        }
        if (len > 0) {
            if !BY_WS_RecvN(sock, len, pb)
                return ""
            if (masked) {
                mkeys := [NumGet(mk,0,"UChar"), NumGet(mk,1,"UChar"), NumGet(mk,2,"UChar"), NumGet(mk,3,"UChar")]
                Loop %len% {
                    i := A_Index - 1
                    NumPut(NumGet(pb, i, "UChar") ^ mkeys[Mod(i, 4) + 1], pb, i, "UChar")
                }
            }
        }
        if (opcode = 0x8)            ; close
            return ""
        if (opcode = 0x9) {          ; ping -> pong
            if (len > 0)
                BY_WS_Pong(sock, &pb, len)
            continue
        }
        if (opcode = 0xA)            ; pong
            continue
        frames += 1
        if (frames = 1 && fin)       ; the whole message in one frame
            return (len > 0) ? StrGet(&pb, len, "UTF-8") : ""
        if (len > 0) {
            Loop %len%
                latin1 .= Chr(NumGet(pb, A_Index - 1, "UChar"))
        }
        if (fin)
            break
    }
    n := StrLen(latin1)
    if (n = 0)
        return ""
    VarSetCapacity(raw, n + 1, 0)
    Loop %n%
        NumPut(Asc(SubStr(latin1, A_Index, 1)), raw, A_Index - 1, "UChar")
    return StrGet(&raw, n, "UTF-8")
}

BY_WS_Pong(sock, ptr, len) {
    total := 2 + 4 + len
    VarSetCapacity(f, total, 0)
    NumPut(0x8A, f, 0, "UChar")
    NumPut(0x80 | (len < 126 ? len : 0), f, 1, "UChar")
    NumPut(0,f,2,"UChar"), NumPut(0,f,3,"UChar"), NumPut(0,f,4,"UChar"), NumPut(0,f,5,"UChar")
    Loop %len%
        NumPut(NumGet(ptr, A_Index - 1, "UChar") ^ 0, f, 6 + A_Index - 1, "UChar")
    BY_WS_SendBuf(sock, &f, total)
}

BY_WS_Close(sock) {
    DllCall("ws2_32\closesocket", "Ptr", sock)
}
