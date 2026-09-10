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
;   Kia and Hyundai are read out of AUDOS. Isuzu and BYD go to IsuzuStock.ahk
;   (beside this script) and BydStock.ahk instead, and for them the tick
;   means Melbourne, with B (Brisbane) or O (other warehouses) in place of P.
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
;   AutoHotkey v1 and DllCall only. No UIA, no COM, nothing installed.
;=============================================================================

#NoEnv
#SingleInstance Force
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

; Isuzu and BYD have no AUDOS. Their parts go to two tools that know how to
; ask: IsuzuStock.ahk beside this script (IDS DC210, through the Chrome the
; Isuzu Parts & VIN Lookup keeps signed in) and BydStock.ahk (the BYD DMS),
; both with a command-line mode that writes a result file. BydStock is looked
; for beside this folder first, then in the usual place on the desktop.
global SW_ISUZU_SCRIPT := FileExist(A_ScriptDir "\IsuzuStock.ahk") ? A_ScriptDir "\IsuzuStock.ahk" : ""
global SW_BYD_SCRIPT   := SW_FindTool("BYDStockLookup\BydStock.ahk")
global SW_ISUZU_REUSE  := "reuse"   ; IsuzuStock --batch stays on the DC210 form
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
global gSW_TBPid   := 0          ; the running BydStock --cdpbatch, if any
global gSW_TBList  := "", gSW_TBOut := "", gSW_TBDir := ""
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

; SuperWarehouseCheck.ahk run        one pass now, no hotkey needed
; SuperWarehouseCheck.ahk run debug  the same, written up in swc_log.txt
for i, a in A_Args {
    if (a = "debug")
        SW_DEBUG := true
    if (a = "run")
        SetTimer, SW_RunOnce, -50
}
return


;--- hotkeys ----------------------------------------------------------------

#If WinActive(SW_ERA_TITLE " ahk_exe " SW_ERA_EXE)
^End::SW_Run()
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
        local script := (brand = "ISUZU") ? SW_ISUZU_SCRIPT : SW_BYD_SCRIPT
        if (script = "") {
            SW_SetStatus("The " brand " tool is not beside this folder")
            SW_FinishAll("unk")
            SW_Finish()
            return
        }
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
SW_FindTool(rel) {
    p := A_ScriptDir "\..\" rel
    if FileExist(p)
        return p
    p := A_Desktop "\Audos\" rel
    if FileExist(p)
        return p
    return ""
}

;-----------------------------------------------------------------------------
;   One IsuzuStock result block: "part=", "desc=" and then "stockN=whs|avail|
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
;   THE TOOL BATCH  -  BydStock.ahk --cdpbatch <list> <out>
;                      IsuzuStock.ahk --batch <list> <out> reuse
;
;   One run of the tool per part cost about two seconds each: a fresh
;   AutoHotkey, a fresh WebSocket to the tool's Chrome and a sign-in check
;   every time, then the server's own second or so. A batch pays those once
;   and appends each answer to the out file the moment it lands:
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
;   A timer here reads that file every 150 ms and paints whatever is new,
;   so the ticks arrive as the server answers rather than at the end. The
;   parse per tool is the one the single lookups had. BYD keeps six fetches
;   in flight (ten parts in about 4 s); IDS is one screen and one session,
;   so Isuzu parts still go one after another, on a form that is kept open
;   between them (about 1.2 s each). The pad's BY / IA make code comes off
;   first, as AUDOS_Switch takes it off, so one part on the screen twice is
;   one code on the list.
;
;   BYD signed out: the blocks say so, the batch ends, --cdplogin brings the
;   picture-code window up once, and the codes still unanswered go again.
;   IDS signs itself back in inside the batch.
;=============================================================================
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
    local i, c, list, script
    script := (gSW_Kind = "byd") ? SW_BYD_SCRIPT : SW_ISUZU_SCRIPT
    SplitPath, script, , gSW_TBDir
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
    if (gSW_Kind = "byd")
        Run, "%A_AhkPath%" "%script%" --cdpbatch "%gSW_TBList%" "%gSW_TBOut%", %gSW_TBDir%, Hide, gSW_TBPid
    else
        Run, "%A_AhkPath%" "%script%" --batch "%gSW_TBList%" "%gSW_TBOut%" %SW_ISUZU_REUSE%, %gSW_TBDir%, Hide, gSW_TBPid
    SW_Log("  " gSW_Kind " batch of " codes.MaxIndex() " started, pid " gSW_TBPid)
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
            SW_Log("  " gSW_Kind " batch went away without DONE")
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
; exists and nobody holds it. (Counted, not read off the header: BydStock
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

; What BydStock says when the tab cannot answer for want of a login.
SW_BydNeedsLogin(txt) {
    return InStr(txt, "signed out") || InStr(txt, "No DMS browser") || InStr(txt, "no oadms.byd.com tab")
        || InStr(txt, "login") || InStr(txt, "Lost the DMS tab")
}

; BydStock.ahk --cdplogin: it launches the hidden Chrome if need be, fills the
; username and password, shows the window with the cursor in the picture box
; and waits up to four minutes for you to type the code. True once the DMS
; is on main.html. The pill says what to do meanwhile; ERA keeps the marks.
SW_BydLogin() {
    global SW_BYD_SCRIPT, gSW_Cancel
    SplitPath, SW_BYD_SCRIPT, , dir
    out := A_Temp "\swc_byd_login.txt"
    if FileExist(out)
        FileDelete, %out%
    SW_SetStatus("BYD - type the picture code in the DMS window, then Enter")
    SW_Log("  byd sign-in: waiting on the picture code")
    t0 := A_TickCount
    RunWait, "%A_AhkPath%" "%SW_BYD_SCRIPT%" --cdplogin "%out%", %dir%, Hide
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
