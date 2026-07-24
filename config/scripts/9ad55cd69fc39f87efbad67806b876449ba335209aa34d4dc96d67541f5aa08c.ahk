; ============================================================================
;  ERA DOCK  (AutoHotkey v1.1, Unicode)  -  merged build 2026-07-20
;
;  ONE process, three former scripts:
;    1. The dock: a 5-cell strip riding the ERA Port titlebar (this section).
;    2. The Invoice Sender  (BYD and ISUZU sender.ahk, v2.2.0)  - SndAutoExec.
;    3. The Receipting worklist (Receipting worklist.ahk, v2.14.0) - WlAutoExec.
;
;  Merge rules applied (so future-you knows what moved):
;    - Shared-by-copy plumbing deduped: one HttpPostJson / JsonStr / JsonBool /
;      DlgCenter* / ShowToast survives (the worklist's copies - they were the
;      supersets). ShowToast now restores A_DefaultGui, so sender threads get
;      Gui 1 back and worklist threads get Gui SB back.
;    - Log stays TWO functions on purpose: Log() writes [wl], SndLog() writes
;      [snd]. Same sender.log, same timeline, same tags as the 2-process days.
;    - VERSION collision: the sender's is SND_VERSION now.
;    - WorklistStart/WorklistHwnd return A_ScriptHwnd - the WL_MSG ping between
;      the two halves is now a PostMessage to our own hidden script window.
;    - ReadConfig: one copy (the worklist's; it reads every key the sender's did).
;
;  Everything the user touches is unchanged: Ctrl+Space worklist, Ctrl+Alt+I
;  sender, backtick rebuild, Ctrl+RButton over Outlook, tray menus, config.ini.
;
;  DOCK CELLS (left to right):
;    worklist | sender | PO upload | recon link | menu
;  Badges exist but start OFF (g_showBadges := false, Kaine 2026-07-20 -
;  "toggle the red notification off for now"). SetBadge(jobs, notifs) still
;  works the moment g_showBadges is flipped true.
; ============================================================================
#NoEnv
#SingleInstance Force
SetBatchLines, -1
SetWorkingDir, %A_ScriptDir%
SetTitleMatchMode, 2

; Parse-verify guard: `AutoHotkeyU64.exe /ErrorStdOut <copy> selfcheck` reads the ENTIRE
; merged file then exits before any GUI/tray/OLE starts. Run against a COPY.
if (A_Args.Length() >= 1 && A_Args[1] = "selfcheck") {
    FileAppend, SELFCHECK_OK`n, *
    ExitApp
}

; Prefer 64-bit AHK (OLE drag-drop needs it). Find64BitAhk lives in the sender section.
if (!A_IsCompiled && A_PtrSize != 8) {
    u64 := Find64BitAhk()
    if (u64 != "") {
        Run, "%u64%" "%A_ScriptFullPath%", , UseErrorLevel
        if (!ErrorLevel)
            ExitApp
    }
}

SetEmbeddedIcon()

; ---- dock globals ----------------------------------------------------------
global DOCK_VERSION := "1.27.0"  ; 1.27.0: worklist 2.26.0 - red dots draw only when Po/Inv has both sides (Settings toggle, default ON) | 1.26.0: stdparts search is newest-wins across all 3 folders (invoice date, then rows, then file time - a stale C:\Temp copy can no longer shadow a fresh OneDrive/PSdata one), every candidate logged, the winner re-seeds C:\Temp | 1.25.0: Receipted column deleted, receipted rows draw a GREEN tick, the seven columns stretch to fill | 1.24.1: worklist 535 -> 575 so no column ellipsizes | 1.24.0: counts footer deleted, Hide-warn on the brand strip, h18 bar, unthemed search box, Ex GST floor 86 | 1.23.1: -MaximizeBox (v1) not -MaxBox (v2) - the worklist would not open | 1.23.0: worklist window fixed at 535x456, search Edit + X (no combo, no Receipt button), h36 bar | 1.22.2: default columns = all but Receipted; toast dwell 1.2s | 1.22.1: Subtract-by defaults to 0+B (25 live runs - it is the proven one now) | 1.22.0: uncovered lines are subtracted in BOTH qty modes (the missing 0+B), Fast + Hide-warn are the defaults | 1.21.2: same-day re-exports upload when the local file grew (row-count tie-break) | 1.21.1: no more "? not checked yet" - check runs before the boot import and on first dot click | 1.21.0: Full refresh runs the invoice CSVs in a child process, two-lane progress panel | 1.20.0: Full refresh + grouped menu, no passwords in the one-click run | 1.19.1: HY defaults to recv-aLL under auto | 1.19.0: "Export + upload PO data" - ERA drives the export, then the normal PO upload + import
                                 ; 1.17.0: Ctrl+Esc reloads the script (blocked while a receipt run is typing)
                                 ; 1.16.0: stale-upload guard (old CSV refused if server's is newer) + Upload PO Data in the dot menu
                                 ; 1.15.0: dot menu renamed + reordered, mockup option 1 (upload / re-import / check)
                                 ; 1.14.0: recon import auto-fires at startup, quiet (dot only, green toast when done)
                                 ; 1.13.1: pop-out toast dwells 2s, not 5 (Kaine 2026-07-20)
                                 ; 1.13.0: REVERT the toast to the 1.10.x pop-out - glyph + two lines of text, acrylic panel (Kaine 2026-07-20)
                                 ; 1.12.0: toast is a BARE glyph - disc/Region/acrylic gone, black keyed out, parked above ERA's status bar (2026-07-20)
                                 ; 1.11.0: toast is a 32px glyph-only circle (WinSet Region) in the ERA corner - no text either state (2026-07-20)
                                 ; 1.10.1: bold no longer bleeds onto later cells (restore the DC font on a miss); cell font 800wt +15%
                                 ; 1.10.0: Ex GST of the invoice you last ran draws bold (NM_CUSTOMDRAW, double-click preserved)
                                 ; 1.9.0: tray duplicates removed (4 pairs left by the merge); toast dwell 5s -> 2s
                                 ; 1.8.1: DockPinZ was inverted - hWndInsertAfter puts you BELOW that window, so the strip sat behind ERA
                                 ; 1.8.0: no longer topmost - rides z-order above ERA and survives focus loss; Despatch cell opens the PDF window directly
                                 ; 1.7.0: Kia+HY CSV row moved to the status dot menu; dot menu flush to the strip's left edge
                                 ; 1.6.1: CoordMode,Menu,Screen - THE popup drift (v1 defaults it to window-relative)
                                 ; 1.6.0: popups anchor to their own cell rect, toast parks inside the ERA window with acrylic glass
                                 ; 1.5.0: 2-cell strip (Receipting / BYD & Isuzu Despatch), PO+Menu cells cut, strip fills the titlebar
global targetTitle  := "ERA Port"
global trackedHwnd  := 0
global g_showBadges := false    ; badges built but hidden until this is true
global pendingJobs  := 0
global notifCount   := 0
global DockHwnd     := 0
; 3-pull status dot state (engine lives after SetBadge; initializers MUST be here in
; auto-exec or they never run)
global g_stBusy := false, g_stCheckedAt := 0, g_stCheckedAtTs := ""
global g_stS1 := "unk", g_stS2 := "unk", g_stS3 := "unk"     ; ok | warn | bad | unk
; Plain-English status lines (1.15.0, mockup option 1): "Server files / Last import /
; Server" - the user-facing names for csv-server hosting, recon ingest freshness, and
; recon health. The LOG keeps richer detail; these render in the dot menu and toasts.
global g_stT1 := "Server files - not checked yet"
global g_stT2 := "Last import - not checked yet"
global g_stT3 := "Server - not checked yet"
global CsvBase := "https://csv-server-production-efc6.up.railway.app"
global g_logTag := "[wl]"       ; 1.21.0: the child job overwrites this with [job] so one
                                ; shared sender.log still tells the two processes apart
global g_jobState := ""         ; "", "running", "done", "fail" - the invoice lane
global g_jobLine := ""          ; last line the child reported
global g_progOn := 0            ; 1 while the Full refresh panel owns the corner
global g_headless := 0          ; 1 in the child job process - it must never build a GUI
; The child runs from a COPY in A_Temp, so its A_ScriptDir is the temp folder. Anything
; that writes shared state - the log, the inv-caches - must use this instead, which the
; child overwrites with the real folder passed on its command line.
global g_dataDir := A_ScriptDir

; cell layout: text labels on the teal titlebar strip (Kaine 2026-07-20: "I like the old
; gui, let's go back to that style" - this is the pre-Mock-C layout, kept verbatim)
; Receipting 78 | BYD & Isuzu Despatch 144 | status dot 20, 1px dividers between.
; (Recon cell removed 2026-07-20 "make the recon move inside the dot" - its state and
; rev now live on the status dot + StMenu.  PO + Menu cells removed 2026-07-20 - PO
; upload lives on the tray menu, and the whole Menu popup is now a RIGHT-CLICK anywhere
; on the strip, because Settings... has no other home.)
global w1 := 78, w2 := 144, w6 := 20
global guiH := 28                      ; start value only - DockSetHeight() fits it to the titlebar
global guiW := w1+w2+w6 + 2

; THE popup-drift bug (Kaine 2026-07-20: "it never pops up underneath"). AHK v1 defaults
; CoordMode,Menu to RELATIVE - every `Menu, Show, X, Y` treats X,Y as relative to the
; ACTIVE window, and all three dock popups hand it screen coords. The popups were landing
; shifted right by exactly ERA's left edge, which is why the drift looked arbitrary and
; changed whenever the window moved. Anchoring to the cell rect was necessary but not
; sufficient - the coords were being reinterpreted after we worked them out.
; Auto-exec, so every thread inherits it. The two coord-less `Menu, Show` calls (RowMenu,
; SenderMenu) use the mouse position and are unaffected.
CoordMode, Menu, Screen

; ---- child job mode (1.21.0) -----------------------------------------------
; Full refresh launches a SECOND copy of this script to do the invoice CSVs while the main
; copy is busy driving ERA. This branch is what that copy runs: no dock, no tray, no GUI,
; no timers - it uploads, reports back by WM_COPYDATA and exits.
;
; It has to sit HERE and not up beside the selfcheck branch: CsvBase and the other globals
; are assigned in the auto-exec above, so branching any earlier would run the job with an
; empty CsvBase - the same empty-scheme WinHttp failure as before.
;
; The copy runs from a DIFFERENT PATH (see JobLaunch) because #SingleInstance Force matches
; on the script path - launching this same file again would kill the parent mid-export.
if (A_Args.Length() >= 3 && A_Args[1] = "/job" && A_Args[2] = "invoices") {
    g_logTag := "[job]"
    g_headless := 1                 ; no toasts from the child - it has no screen presence
    if (A_Args.Length() >= 4)
        g_dataDir := A_Args[4]      ; the PARENT's folder - see g_dataDir above
    JobRunInvoices(A_Args[3] + 0)
    ExitApp
}

; NOT +AlwaysOnTop (2026-07-20). Topmost meant the strip floated over every other app, so
; TrackWindow had to hide it the moment ERA lost focus - which is why it vanished whenever
; you looked at anything else. It now rides in NORMAL z-order directly above ERA
; (DockPinZ), so it stays put when ERA is merely unfocused, and anything stacked on top of
; ERA covers it like an ordinary window.
Gui, Dock:New, +ToolWindow -Caption +LastFound +HwndDockHwnd
Gui, Dock:Color, 0F766E
x2 := w1+1, x6 := x2+w2+1
; 1px dividers
Gui, Dock:Add, Progress, x%w1% y0 w1 h%guiH% -Theme c0B5850 Background0B5850 vDiv1, 100
dx2 := x2+w2
Gui, Dock:Add, Progress, x%dx2% y0 w1 h%guiH% -Theme c0B5850 Background0B5850 vDiv2, 100
Gui, Dock:Font, s9 Bold cWhite, Segoe UI
Gui, Dock:Add, Text, x0 y0 w%w1% h%guiH% Center 0x200 BackgroundTrans gDockWorklist vCellWl, Receipting
; 0x80 = SS_NOPREFIX: without it the "&" is eaten and renders as an underline mnemonic.
Gui, Dock:Add, Text, x%x2% y0 w%w2% h%guiH% Center 0x200 0x80 BackgroundTrans gDockSender vCellSnd, BYD & Isuzu Despatch
; status dot: 3-pull health (csv-server files / recon ingest freshness / recon health).
; Gray until the first check lands. Click = StMenu popup (native menu: no new HWND, no
; new bleed-over surface - #32768 is already whitelisted in TrackWindow).
Gui, Dock:Add, Text, x%x6% y0 w%w6% h%guiH% Center 0x200 BackgroundTrans gDockStatus vDockStatus c9CA3AF, % Chr(0x25CF)

; badges (hidden; kept for the day g_showBadges flips on)
Gui, Dock:Font, s7, Segoe UI
bx1 := w1 - 16
Gui, Dock:Add, Progress, x%bx1% y1 w15 h14 -Theme cDC2626 BackgroundDC2626 vBadge1P Hidden HwndhB1, 100
Gui, Dock:Add, Text, x%bx1% y3 w15 h11 Center BackgroundTrans cFFFFFF gDockWorklist vBadge1T Hidden, 0
bx2 := x2 + w2 - 16
Gui, Dock:Add, Progress, x%bx2% y1 w15 h14 -Theme cDC2626 BackgroundDC2626 vBadge2P Hidden HwndhB2, 100
Gui, Dock:Add, Text, x%bx2% y3 w15 h11 Center BackgroundTrans cFFFFFF gDockSender vBadge2T Hidden, 0

Menu, DockMenu, Add, Receipting worklist`tCtrl+Space, DockMenuWorklist
Menu, DockMenu, Add, Invoice sender`tCtrl+Alt+I, DockMenuSender
Menu, DockMenu, Add
; One item since 2026-07-20 - the Kia + Hyundai CSV row moved to the status dot menu.
Menu, SndCellMenu, Add, BYD + Isuzu invoices (PDF window)`tCtrl+Alt+I, DockMenuSender

Menu, DockMenu, Add, Upload PO data..., DockMenuUploadPo
Menu, DockMenu, Add, Get latest Kia + HY invoices, DockGetLatest
Menu, DockMenu, Add, View receipting flags, DockMenuFlags
Menu, DockMenu, Add
Menu, DockMenu, Add, Settings..., DockMenuSettings
Menu, DockMenu, Add, Open log, DockMenuLog
Menu, DockMenu, Add
Menu, DockMenu, Add, Exit, DockMenuExit

; Gui,Dock:New made DOCK this thread's default GUI - the sender's BuildGui uses bare
; `Gui,` commands that assume default = 1 (it was written as its own process). Without
; this line every sender control lands INSIDE the dock window and "Invoice Sender"
; never exists (found on the 505 workstation, 2026-07-20).
Gui, 1:Default

; ---- boot the two embedded halves (order matters: sender first, like the old
; morning routine; its WorklistStart() is now a no-op that points at ourselves) ----
Gosub, SndAutoExec
Gosub, WlAutoExec

; recon cell colour: config is loaded now (ReadConfig ran inside SndAutoExec)
; (Recon cell recolor removed - recon state is the status dot now)

Menu, Tray, Tip, ERA Dock v%DOCK_VERSION% (sender v%SND_VERSION% + worklist v%VERSION%)
UpdateBadges()
SetTimer, TrackWindow, 250
; status checks: first pass 1.5s after boot (so boot never waits on the network), then
; every 15 min. Both funnel into StatusRunCheck(); g_stBusy stops overlap.
; 1.14.0: the first pass also runs the recon import, quietly - dot only, green toast when
; done, no "Importing..." pop-out (Kaine 2026-07-20: "make that do that from the start").
; Cheap since recon-11 batched the Firestore writes: ~4s server-side, pumped so the dock
; stays live. The status check runs AFTER it so the dot reports the fresh ingest.
Menu, StMenu, Add, starting..., StNoop
SetTimer, DockStatusFirst, -1500
SetTimer, DockStatusTick, 900000
return

DockStatusFirst:
    ; 1.21.1: quick check FIRST. The import takes 10-30s, and any dot click in that window
    ; used to serve three "? not checked yet" rows (Kaine's screenshot, 2026-07-21). A
    ; pumped 3-pull check costs ~2s, so the menu has real state almost immediately; the
    ; second check after the import keeps the original point - the dot ends up reporting
    ; the FRESH ingest, not the pre-import world.
    StatusRunCheck(true)
    DockImportRun(false)
    StatusRunCheck(true)
return

DockStatusTick:
    StatusRunCheck(true)
return

; ---- dock plumbing ---------------------------------------------------------
TrackWindow:
    WinGet, activeHwnd, ID, A
    WinGetTitle, activeTitle, ahk_id %activeHwnd%
    if InStr(activeTitle, targetTitle)
        trackedHwnd := activeHwnd
    if (!trackedHwnd || !WinExist("ahk_id " trackedHwnd))
    {
        ; Nothing tracked yet (dock started before ERA, or ERA was restarted): adopt any
        ; ERA window that exists rather than waiting to be focused once.
        trackedHwnd := WinExist(targetTitle)
        if (!trackedHwnd)
        {
            Gui, Dock:Hide
            return
        }
    }
    ; Hide only when ERA genuinely is not on screen. Losing FOCUS is no longer a reason -
    ; that was the old topmost workaround (Kaine 2026-07-20: "stays there even when the
    ; window is not active"). Minimised, hidden, or cloaked (sitting on another virtual
    ; desktop) all still hide it, or the strip would strand itself over someone else's app.
    WinGet, mm, MinMax, ahk_id %trackedHwnd%
    if (mm = -1 || !DllCall("IsWindowVisible", "Ptr", trackedHwnd) || DockIsCloaked(trackedHwnd))
    {
        Gui, Dock:Hide
        return
    }
    WinGetPos, ex, ey, ew, eh, ahk_id %trackedHwnd%
    ; Fit the strip to the REAL titlebar instead of the old hard-coded 28px at y+1 (that
    ; left a 2px blue gap under the strip). TitleBarRect gives the caption band only.
    TitleBarRect(trackedHwnd, tbX, tbY, tbW, tbH)
    DockSetHeight(tbH)
    gx := tbX + tbW - guiW - 142
    gy := tbY
    Gui, Dock:Show, x%gx% y%gy% w%guiW% h%guiH% NA
    DockPinZ()
return

; Keep the strip immediately above ERA in normal z-order.
;
; The trap that cost a restart (2026-07-20): SetWindowPos's hWndInsertAfter puts the window
; BELOW that handle, not above it. Passing trackedHwnd - the obvious-looking thing - pins
; the strip behind ERA, which is exactly what it did (probe: ERA z=32, dock z=33). To land
; ABOVE ERA you insert after whatever is currently above ERA, or HWND_TOP (0) when ERA is
; already at the top of the non-topmost group.
;
; Guard first: GW_HWNDPREV is the window above ERA, so if that is already us there is
; nothing to do. Unguarded this fires 4x a second forever and the strip flickers.
; SWP_NOACTIVATE matters - ERA must never lose focus mid-keystroke because the dock moved.
DockPinZ() {
    global DockHwnd, trackedHwnd
    static GW_HWNDPREV := 3, HWND_TOP := 0
    static SWP_NOSIZE := 0x1, SWP_NOMOVE := 0x2, SWP_NOACTIVATE := 0x10
    above := DllCall("GetWindow", "Ptr", trackedHwnd, "UInt", GW_HWNDPREV, "Ptr")
    if (above = DockHwnd)
        return
    DllCall("SetWindowPos", "Ptr", DockHwnd, "Ptr", (above ? above : HWND_TOP)
          , "Int", 0, "Int", 0, "Int", 0, "Int", 0
          , "UInt", SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE)
}

; True when DWM has cloaked the window - the usual cause is it living on a virtual desktop
; you are not looking at. Such a window is still "visible" by the old IsWindowVisible test,
; so without this the strip would hang in mid-air on the wrong desktop.
DockIsCloaked(hwnd) {
    VarSetCapacity(ck, 4, 0)
    if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "Ptr", &ck, "UInt", 4) != 0)
        return false                                  ; pre-Win8 / no DWM: never cloaked
    return (NumGet(ck, 0, "UInt") != 0)
}

; Caption band of a window, in screen coords: the area between the top of the visible
; frame and the top of the client area, minus the side border.  Uses the DWM extended
; frame bounds because GetWindowRect on Win10/11 includes the invisible resize border.
TitleBarRect(hwnd, ByRef x, ByRef y, ByRef w, ByRef h) {
    VarSetCapacity(fr, 16, 0)
    if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 9, "Ptr", &fr, "UInt", 16) != 0) {
        WinGetPos, wx, wy, ww, wh, ahk_id %hwnd%
        NumPut(wx, fr, 0, "Int"), NumPut(wy, fr, 4, "Int"), NumPut(wx+ww, fr, 8, "Int")
    }
    fx := NumGet(fr, 0, "Int"), fy := NumGet(fr, 4, "Int"), fw := NumGet(fr, 8, "Int") - fx
    VarSetCapacity(pt, 8, 0)
    DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", &pt)      ; client (0,0) in screen coords
    cy := NumGet(pt, 4, "Int")
    VarSetCapacity(cr, 16, 0)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", &cr)
    bw := (fw - NumGet(cr, 8, "Int")) // 2
    if (bw < 0)
        bw := 0
    x := fx + bw, y := fy + bw, w := fw - (bw * 2), h := cy - y
    if (h < 20 || h > 60) {                                 ; nonsense measurement - old behaviour
        y := fy + 1, h := 28
        x := fx, w := fw
    }
}

; Re-fit every strip control when the titlebar height changes (theme/DPI/window swap).
; Cheap no-op on the common path: only the first pass and real changes do any work.
DockSetHeight(h) {
    global guiH
    static cur := 0
    if (h = cur)
        return
    cur := h, guiH := h
    for i, c in ["CellWl", "CellSnd", "DockStatus", "Div1", "Div2"]
        GuiControl, Dock:Move, %c%, h%h%
    by := (h - 14) // 2                                     ; badges stay vertically centred
    bt := by + 2
    GuiControl, Dock:Move, Badge1P, y%by%
    GuiControl, Dock:Move, Badge2P, y%by%
    GuiControl, Dock:Move, Badge1T, y%bt%
    GuiControl, Dock:Move, Badge2T, y%bt%
}

; Right-click anywhere on the strip = the old Menu cell's popup.  The cell itself is gone
; (Kaine 2026-07-20) but Settings... lives nowhere else, so the menu had to survive.
DockContextMenu:
    Gosub, DockMenu
return

UpdateBadges() {
    global
    local on1 := (g_showBadges && pendingJobs > 0)
    local on2 := (g_showBadges && notifCount > 0)
    GuiControl, Dock:, Badge1T, %pendingJobs%
    GuiControl, % "Dock:" (on1 ? "Show" : "Hide"), Badge1P
    GuiControl, % "Dock:" (on1 ? "Show" : "Hide"), Badge1T
    GuiControl, Dock:, Badge2T, %notifCount%
    GuiControl, % "Dock:" (on2 ? "Show" : "Hide"), Badge2P
    GuiControl, % "Dock:" (on2 ? "Show" : "Hide"), Badge2T
}

SetBadge(jobs, notifs) {
    global pendingJobs, notifCount
    pendingJobs := jobs, notifCount := notifs
    UpdateBadges()
}

; ---- 3-pull status (Kaine 2026-07-20: "conferming all 3 pulls are the lasted") --------
; Pull 1  csv-server /files      -> both stdparts CSVs hosted (presence only; the files
;                                   endpoint has no timestamps)
; Pull 2  recon /invoices        -> newest updatedAt lands on TODAY (local). This is the
;                                   check that would have caught the 16/07 freeze: server
;                                   reachable but ingest dead. Amber = stale, red = down.
; Pull 3  recon /health          -> ok:true (+ rev shown in the menu)
; Dot: worst state wins. green = all fresh, amber = something stale, red = something down,
; gray = not checked yet. All requests go through HttpGetPumped so the dock never blocks.
; NOTE: the g_st* / CsvBase initializers live UP TOP with the dock globals - `global x := v`
; down here is BELOW the auto-exec return, the assignment never runs (found 2026-07-20:
; CsvBase was "" so WinHttp got the URL "/files" -> 0x80072EE6 unrecognized scheme).

StatusRunCheck(quiet := true) {
    global g_stBusy, g_stCheckedAt, g_stCheckedAtTs, CsvBase, ReconUrl
    global g_stS1, g_stS2, g_stS3, g_stT1, g_stT2, g_stT3
    if (g_stBusy)
        return
    g_stBusy := true
    StatusDot("busy")

    ; pull 1: csv-server file list
    r := StatusGet(CsvBase "/files", 20)
    if (r.status = 200) {
        hasKi := InStr(r.text, "stdpartski.csv"), hasHy := InStr(r.text, "stdpartshy.csv")
        if (hasKi && hasHy)
            g_stS1 := "ok",  g_stT1 := "Server files - Kia + Hyundai hosted"
        else
            g_stS1 := "bad", g_stT1 := "Server files - missing " (hasKi ? "stdpartshy" : "stdpartski") ".csv"
    } else
        g_stS1 := "bad", g_stT1 := "Server files - " (r.status = 0 ? "unreachable: " StatusClean(r.text) : "HTTP " r.status)

    ; pull 2 + 3 need the recon service
    if (ReconUrl = "") {
        g_stS2 := "bad", g_stT2 := "Last import - no ReconApiUrl configured"
        g_stS3 := "bad", g_stT3 := "Server - no ReconApiUrl configured"
    } else {
        r := StatusGet(ReconUrl "/invoices?limit=25", 25)
        if (r.status = 200) {
            newest := ""   ; max updatedAt as UTC yyyyMMddHHmmss - the array is not
            pos := 1       ; guaranteed newest-first forever, so scan them all
            Loop {
                pos := RegExMatch(r.text, """updatedAt""\s*:\s*""(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)", m, pos)
                if (!pos)
                    break
                u := m1 . m2 . m3 . m4 . m5 . "00"
                if (u > newest)
                    newest := u
                pos += StrLen(m)
            }
            if (newest = "")
                g_stS2 := "warn", g_stT2 := "Last import - none stored"
            else {
                diff := A_NowUTC
                EnvSub, diff, %newest%, Seconds
                loc := A_Now
                EnvAdd, loc, % -diff, Seconds
                FormatTime, locDay, %loc%, yyyyMMdd
                FormatTime, locHm,  %loc%, HH:mm
                FormatTime, locDm,  %loc%, dd/MM
                FormatTime, today, , yyyyMMdd
                if (locDay = today)
                    g_stS2 := "ok",   g_stT2 := "Last import - " locHm " today"
                else
                    g_stS2 := "warn", g_stT2 := "Last import - " locDm " (stale)"
            }
        } else
            g_stS2 := "bad", g_stT2 := "Last import - can't read (HTTP " r.status ")"

        r := StatusGet(ReconUrl "/health", 20)
        if (r.status = 200 && InStr(r.text, """ok"":true")) {
            RegExMatch(r.text, """rev""\s*:\s*""([^""]+)", mRev)
            g_stS3 := "ok",  g_stT3 := "Server - healthy" (mRev1 != "" ? " - rev " mRev1 : "")
        } else
            g_stS3 := "bad", g_stT3 := "Server - HTTP " r.status
    }

    g_stCheckedAt := A_TickCount
    g_stCheckedAtTs := A_Now
    g_stBusy := false
    worst := StatusWorst()
    StatusDot(worst)
    Log("status: " worst " | " g_stT1 " | " g_stT2 " | " g_stT3)
    if (!quiet) {
        ; toast detail = the line that actually caused the state, not always ingest
        ; (2026-07-20: "a pull is down" showed the healthy ingest line - confusing)
        detail := g_stT2
        for i, pair in [[g_stS1, g_stT1], [g_stS2, g_stT2], [g_stS3, g_stT3]] {
            if (pair[1] = worst) {
                detail := pair[2]
                break
            }
        }
        ShowToast(worst = "ok" ? "ok" : "bad", "Status: " (worst = "ok" ? "all 3 pulls fresh" : (worst = "warn" ? "stale data" : "a pull is down")), detail)
    }
}

StatusWorst() {
    global g_stS1, g_stS2, g_stS3
    for i, s in [g_stS1, g_stS2, g_stS3] {
        if (s = "bad")
            return "bad"
    }
    for i, s in [g_stS1, g_stS2, g_stS3] {
        if (s = "warn" || s = "unk")
            return "warn"
    }
    return "ok"
}

StatusDot(state) {
    c := (state = "ok") ? "4ADE80" : (state = "warn") ? "FBBF24" : (state = "bad") ? "F87171" : "9CA3AF"
    GuiControl, Dock:+c%c%, DockStatus
    GuiControl, Dock:, DockStatus, % Chr(0x25CF)
}

StatusGlyph(state) {
    return (state = "ok") ? Chr(0x2713) : (state = "warn") ? Chr(0x26A0) : (state = "bad") ? Chr(0x2717) : "?"
}

; Error text goes into native menu items: a TAB there becomes the accelerator column
; (2026-07-20: "Source:<tab>WinHttp..." rendered as right-aligned "T"). Flatten all
; whitespace and cap the length so the menu stays one sane line.
StatusClean(s) {
    s := RegExReplace(s, "[\r\n\t]+", " ")
    s := Trim(RegExReplace(s, "\s{2,}", " "))
    return SubStr(s, 1, 80)
}

DockStatus:
    ; 1.21.1: belt-and-braces for the "?" rows - if the dot is clicked before the first
    ; check has ever finished (or the boot check failed to run), do one now, pumped, before
    ; building the menu. ~2s once, never again; g_stBusy makes a mid-check click fall
    ; through to the menu as-is rather than double-running.
    if (g_stCheckedAt = 0)
        StatusRunCheck(true)
    Gosub, StBuildMenu
    ; Flush to the LEFT END OF THE STRIP, not to the dot (Kaine 2026-07-20: "the drop-down
    ; on the left side to the end of the receipting green"). The menu sizes itself to its
    ; longest row - the C:\Temp one - so it ends up ~24px wider than the strip and hangs
    ; that far past the dot on the right. That overhang is the accepted trade for the left
    ; edges lining up; widening the strip to match a menu would be the tail wagging the dog.
    CellRect("CellWl", stX, cy, cw, ch)
    stY := cy + ch
    Menu, StMenu, Show, %stX%, %stY%
return

StBuildMenu:
    Menu, StMenu, DeleteAll
    Menu, StMenu, Add, % StatusGlyph(g_stS1) "  " g_stT1, StNoop
    Menu, StMenu, Add, % StatusGlyph(g_stS2) "  " g_stT2, StNoop
    Menu, StMenu, Add, % StatusGlyph(g_stS3) "  " g_stT3, StNoop
    Menu, StMenu, Add
    ; 1.20.0 (Kaine, 2026-07-21): grouped under disabled greyed headers, because "I always
    ; forget what these do". The header answers which direction the data moves, so the item
    ; itself does not have to carry that in its wording. Disabled items still render, they
    ; just cannot be picked - that is the whole trick.
    Menu, StMenu, Add, RUN IT ALL, StNoop
    Menu, StMenu, Disable, RUN IT ALL
    ; The 95%-of-mornings item: ERA export -> PO upload -> invoice CSVs -> one import.
    ; Sits above the individual steps; they stay for when half of it fails.
    Menu, StMenu, Add, Full refresh, DockFullRefresh
    Menu, StMenu, Add
    Menu, StMenu, Add, INVOICES -> WORKLIST, StNoop
    Menu, StMenu, Disable, INVOICES -> WORKLIST
    ; 1.18.0 (Kaine: "check the local one, check the server one, justify which one is the
    ; latest, go with their route"): ONE smart action replaces "Upload new CSVs + import"
    ; and "Re-import server copies" - DockGetLatest compares dates per file and does the
    ; right thing without the user having to know which copy is fresher.
    Menu, StMenu, Add, Get latest + import, DockGetLatest
    Menu, StMenu, Add
    Menu, StMenu, Add, PO DATA -> SERVER, StNoop
    Menu, StMenu, Disable, PO DATA -> SERVER
    ; 1.16.0 (Kaine): the PO upload joins the dot menu - it was tray-only, and the tray is
    ; the long way round. Same WlUploadPo the tray item calls.
    Menu, StMenu, Add, Upload from a file..., DockUploadPo
    ; 1.19.0 (Kaine): the same upload, but the CSV comes from ERA instead of a file
    ; picker - report 6913 / saved query KAINE. Password-gated like the manual one.
    Menu, StMenu, Add, Export from ERA + upload, DockPoExport
    Menu, StMenu, Add
    Menu, StMenu, Add, DIAGNOSTICS, StNoop
    Menu, StMenu, Disable, DIAGNOSTICS
    Menu, StMenu, Add, Check status only, StReCheck
    Menu, StMenu, Add
    if (g_stCheckedAt = 0)
        ago := "never checked"
    else {
        mins := (A_TickCount - g_stCheckedAt) // 60000
        rel := (mins < 1) ? "just now" : mins "m ago"
        FormatTime, stStamp, %g_stCheckedAtTs%, ddd dd/MM HH:mm
        ago := "checked " stStamp " (" rel ")"
    }
    Menu, StMenu, Add, %ago%, StNoop
    Menu, StMenu, Disable, %ago%
return

StNoop:
return

StReCheck:
    StatusRunCheck(false)
return

; (StRunImport lived here until 1.18.0 - "Re-import server copies" folded into
;  DockGetLatest, which imports either way after deciding whose files are newest.)

; The recon import, shared by DockGetLatest and the startup auto-run.
; showLoad=false is the quiet startup shape Kaine asked for: no "Importing..." pop-out,
; just the busy dot while it runs - but the RESULT toasts either way (green done / red
; failed), because a silent failure at boot would leave stale data looking imported.
; g_impBusy: the pumped POST spins the message loop, so the menu entry could re-enter
; this while the startup run is still in flight - second caller just leaves.
DockImportRun(showLoad := true) {
    global ReconUrl
    static g_impBusy := false
    if (ReconUrl = "" || g_impBusy)
        return
    g_impBusy := true
    StatusDot("busy")
    if (showLoad)
        ShowToast("load", "Importing into recon...", "Pulling both feeds server-side")
    impRes := HttpPostJsonPumped(ReconUrl "/import-dealer-invoices", "{}", "application/json", 120)
    if (impRes.status = 200 || impRes.status = 207) {
        RegExMatch(impRes.text, """imported""\s*:\s*(\d+)", mImp)
        Log("status: import ok, " mImp1 " invoice(s)" (showLoad ? "" : " (startup auto-run)"))
        ShowToast("ok", "Import done", mImp1 " invoice(s) reconciled")
        WorklistPing(2)
    } else {
        Log("status: import failed http=" impRes.status " | " SubStr(impRes.text, 1, 200))
        ShowToast("bad", "Import failed (HTTP " impRes.status ")", "Tray > Open log")
    }
    g_impBusy := false
}

; Async GET that pumps the message loop while waiting - the GET sibling of
; HttpPostJsonPumped, so the dot checks never freeze the dock or the toasts.
; 2 attempts: cold DNS/TLS on the first request after boot showed as "HTTP 0"
; on the 505 workstation (2026-07-20) while later requests to the SAME infra
; succeeded. A WaitForResponse error now fails fast instead of spinning to the
; timeout, so the retry actually happens quickly.
HttpGetPumped(url, timeoutS := 30) {
    out := {status: 0, text: ""}
    Loop, 2
    {
        attempt := A_Index
        err := ""
        try {
            whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
            whr.Open("GET", url, true)
            whr.SetTimeouts(8000, 8000, 30000, 60000)
            try whr.Option(9) := 0x0800 | 0x2000
            whr.Send()
        } catch e {
            err := e.message
        }
        if (err = "") {
            t0 := A_TickCount
            Loop {
                done := false
                try done := whr.WaitForResponse(0)
                catch e2 {
                    err := e2.message
                    break
                }
                if (done)
                    break
                if (A_TickCount - t0 > timeoutS * 1000) {
                    err := "timeout after " timeoutS "s"
                    break
                }
                Sleep, 60
            }
        }
        if (err = "") {
            try {
                out.status := whr.Status
                out.text   := whr.ResponseText
            }
            return out
        }
        out.status := 0
        out.text := err
        if (attempt = 1)
            Sleep, 400
    }
    return out
}

; curl fallback for when WinHttp says no but the box is clearly online - curl is the
; exact transport DockUploadStd already uses successfully against the csv-server, so
; if WinHttp GETs fail (proxy/TLS quirks) this asks curl the same question. Blocking
; RunWait, but only ever runs on the failure path and is capped at 15s.
HttpGetCurl(url) {
    out := {status: 0, text: ""}
    tmp := A_Temp "\dock_stget.txt"
    FileDelete, %tmp%
    ; -w marker appended on the SAME line as the body: a `n here becomes a real newline
    ; inside the cmd /c command line and cmd truncates the command at it (found
    ; 2026-07-20 - the fallback silently returned nothing, wiping the WinHttp error).
    RunWait, %ComSpec% /c curl -s -m 15 -w "CURLHTTP:`%{http_code}" "%url%" > "%tmp%" 2>&1, , Hide
    FileRead, resp, %tmp%
    if (resp = "")
        return out
    if RegExMatch(resp, "CURLHTTP:(\d+)\s*$", mC) {
        out.status := mC1 + 0
        out.text := RegExReplace(resp, "CURLHTTP:\d+\s*$", "")
    } else
        out.text := resp
    return out
}

; One front door for the status checks, a 3-rung ladder:
;   1. async pumped WinHttp  (never blocks the dock - the normal path)
;   2. sync WinHttp          (same engine, no async plumbing - covers async quirks;
;                             blocks briefly but only ever runs on the failure path)
;   3. curl                  (the transport the uploads already use)
; The first real error text survives - a later empty result must not erase it.
StatusGet(url, timeoutS := 20) {
    r := HttpGetPumped(url, timeoutS)
    if (r.status != 0)
        return r
    firstErr := r.text
    r := HttpGetJson(url, 8000, 1)
    if (r.status != 0) {
        Log("status: async failed, sync rescued " url " | async: " firstErr)
        return r
    }
    r := HttpGetCurl(url)
    if (r.status = 0) {
        Log("status: GET failed x3 " url " | async: " firstErr " | sync+curl also failed | curl: " (r.text = "" ? "(no output)" : SubStr(r.text, 1, 120)))
        if (r.text = "")
            r.text := firstErr
    } else
        Log("status: winhttp failed, curl rescued " url " | async: " firstErr)
    return r
}

DockWorklist:
    WlToggle()
return

DockSender:
    ; Straight to the PDF window - no dropdown (Kaine 2026-07-20: "I want it to open
    ; straight away"). Invoices still come in two shapes, but once the Kia + Hyundai CSV
    ; row moved to the status dot menu this was a one-item popup: a click that only bought
    ; you another click. SndCellMenu is left defined but unused - deleting it would strand
    ; the Ctrl+Alt+I accelerator text that documents the shortcut.
    Gosub, ShowMainWindow
return

DockUploadPo:
    Gosub, WlUploadPo
return

DockPoExport:
    PoExportRun()
return

; ---- Get latest + import (1.18.0) -----------------------------------------------------
; Kaine: "check the local one, check the server one, justify which one is the latest, go
; with their route." Per feed file: newest invoice date wins - a newer C:\Temp copy is
; uploaded (multipart /upload, same transport as before), an equal-or-newer server copy is
; kept untouched. Either way ONE import then runs server-side, so recon always ingests
; whichever copies won. This absorbs 1.16.0's stale-upload guard (keeping the server's
; newer file IS the refusal, just no longer worded as an error) and replaces both
; "Upload new CSVs + import" and "Re-import server copies".
DockGetLatest:
    ; 1.21.0: the per-file work moved into StdCsvSync() so the child job process runs the
    ; IDENTICAL compare-and-upload. Two copies of newest-copy-wins would have drifted.
    upN := 0, keptN := 0, failN := 0
    for i, f in StdCsvPaths()
        StdCsvSync(f, upN, keptN, failN)
    Log("latest: " upN " uploaded, " keptN " kept from server, " failN " failed - importing")
    if (failN)
        ShowToast("bad", "Get latest: " failN " file(s) failed", "Tray > Open log - importing the rest anyway")
    ; Import either way: recon never watches the csv-server, this is what makes it pull
    ; both feeds, reconcile against the PO snapshot and store.
    DockImportRun(true)
    StatusRunCheck(true)
return

; ============================================================
;  Full refresh  (1.21.0)
; ============================================================
; One item for the 95% morning. Two lanes run at once:
;
;   lane A (this process)  drive ERA 6913 -> wait for the CSV -> upload the PO snapshot
;   lane B (child process) compare + upload stdpartski.csv / stdpartshy.csv
;   lane C (join)          ONE import, only after BOTH lanes are in
;
; The parallel half buys about 10 seconds - the invoice lane is short and the import has to
; wait for both regardless. It is worth it because that 40s of ERA driving was dead time,
; not because the run gets dramatically faster.
;
; A LABEL, not a function: the Gosub-into-a-function scoping trap means CsvBase and friends
; would read as empty locals. Same reason as 1.20.0.
;
; No password anywhere in here (asked twice in one run before 1.20.0). The 409 cliff gate
; still stops a bad snapshot - see PoUploadRun.
DockFullRefresh:
    ProgShow()
    Log("full-refresh: started")
    ; Kick the child FIRST so its uploads overlap the ERA drive rather than following it.
    JobLaunch()
    if (g_jobState = "running")
        ProgSeg("B", 1, "now"), ProgLaneText("B", "uploading in the background...")
    else
        ProgLaneText("B", "queued - will run after the PO lane")
    ProgSeg("A", 1, "now"), ProgLaneText("A", "driving ERA...")

    ; doImport=false: lane C runs the single import once both lanes are in.
    frOk := PoExportRun(true, false)
    if (!frOk) {
        ProgSeg("A", 3, "err")
        ProgLaneText("A", "failed - see the log")
        ProgSub("Stopped. Invoice lane left to finish on its own.")
        Log("full-refresh: stopped - the ERA export or PO upload failed")
        Sleep, 2500
        ProgHide()
        ; PoExportRun/PoUploadRun already logged the specific reason; this says the REST of
        ; the run did not happen, which is the part that is not obvious from the log.
        ShowToast("bad", "Full refresh stopped", "PO step failed - no import run")
        StatusRunCheck(false)
        return
    }
    ProgSeg("A", 1, "on"), ProgSeg("A", 2, "on"), ProgSeg("A", 3, "on")
    ProgLaneText("A", "done - snapshot replaced")

    ; ---- lane B: join, fall back, or time out -------------------------------------
    if (g_jobState = "nolaunch") {
        ; No child (no AutoHotkey.exe found, or Run failed). Do it inline - a slower run is
        ; a far better outcome than skipping the invoice feeds entirely.
        ProgSeg("B", 1, "now"), ProgLaneText("B", "running here (no child process)...")
        frUp := 0, frKept := 0, frFail := 0
        for i, f in StdCsvPaths()
            StdCsvSync(f, frUp, frKept, frFail)
        g_jobState := frFail ? "fail" : "done"
        g_jobLine := frUp " uploaded, " frKept " kept" (frFail ? ", " frFail " FAILED" : "")
        ProgSeg("B", 2, "on"), ProgSeg("B", 3, frFail ? "err" : "on")
        ProgLaneText("B", g_jobLine)
    } else if (g_jobState = "running") {
        ProgSeg("B", 2, "now")
        ProgLaneText("C", "waiting for the invoice lane...")
        frT0 := A_TickCount
        ; Sleep is where AHK dispatches messages, so JobMsg lands during this loop.
        while (g_jobState = "running" && A_TickCount - frT0 < 60000)
            Sleep, 100
        if (g_jobState = "running") {
            ; The child died without reporting. Import anyway: whatever it DID upload is on
            ; the server already, and a hung child must not hold the morning hostage.
            Log("full-refresh: invoice child never reported in 60s - importing anyway")
            ProgSeg("B", 3, "err")
            ProgLaneText("B", "no reply in 60s - importing anyway")
        }
    }

    ; ---- lane C: the single import ------------------------------------------------
    ProgSeg("C", 1, "now"), ProgLaneText("C", "importing...")
    DockImportRun(true)
    ProgSeg("C", 1, "on"), ProgSeg("C", 2, "on")
    ProgLaneText("C", "imported")
    StatusRunCheck(true)
    Log("full-refresh: finished | invoices: " (g_jobLine = "" ? "n/a" : g_jobLine))
    ProgSub("Done - PO + invoices in, worklist reloaded")
    Sleep, 1300
    ProgHide()
    ShowToast("ok", "Full refresh done", g_jobLine = "" ? "PO snapshot replaced" : "PO in - " g_jobLine)
return

; ============================================================
;  Full refresh progress panel  (1.21.0)
; ============================================================
; Same dark styling and same corner as the toast, and it REPLACES the toasts for the length
; of a run (see the g_progOn branch in ShowToast) - a panel plus five toasts saying the same
; thing is noise.
;
; Segments, not a percentage bar: the ERA step takes 40s and nothing can honestly report
; progress inside it, so a creeping bar would be a lie. A segment that sits blue for 40s is
; at least true.
ProgShow() {
    global ProgHwnd, g_progOn, g_progT0
    prevDef := A_DefaultGui
    ; Reset every run - the panel is reused, so yesterday's green must not lead.
    for i, lane in ["A", "B", "C"] {
        Loop, % (lane = "C") ? 2 : 3
            ProgSeg(lane, A_Index, "off", true)
        ProgLaneText(lane, "waiting", true)
    }
    GuiControl, Prog:, PgSub, Starting...
    GuiControl, Prog:, PgTime, 0:00
    g_progT0 := A_TickCount
    g_progOn := 1
    Gui, Prog:Show, Hide AutoSize NoActivate
    DetectHiddenWindows, On
    WinGetPos, , , pw, ph, ahk_id %ProgHwnd%
    DetectHiddenWindows, Off
    if (pw = "")
        pw := 392
    if (ph = "")
        ph := 176
    ; Bottom-right INSIDE the tracked ERA window, exactly like the toast. The monitor corner
    ; is only the fallback for when no ERA window is being tracked.
    if (ToastAnchorRect(ax, ay, aw, ah)) {
        px := ax + aw - pw - 12
        py := ay + ah - ph - 12
    } else {
        SysGet, wa, MonitorWorkArea
        px := waRight - pw - 20
        py := waBottom - ph - 20
    }
    Gui, Prog:Show, NoActivate x%px% y%py%
    SetTimer, ProgTick, 1000
    Gui, %prevDef%:Default
}

ProgHide() {
    global g_progOn
    prevDef := A_DefaultGui
    g_progOn := 0
    SetTimer, ProgTick, Off
    Gui, Prog:Hide
    Gui, %prevDef%:Default
}

; state: "off" dark | "now" blue, running | "on" green, done | "err" red, stopped here
ProgSeg(lane, idx, state, force := false) {
    global g_progOn
    if (!g_progOn && !force)
        return
    prevDef := A_DefaultGui
    col := (state = "now") ? "4DA3FF" : (state = "err") ? "F25A5A" : "33C966"
    v := "Pg" lane idx
    GuiControl, Prog:+c%col%, %v%
    GuiControl, Prog:, %v%, % (state = "off") ? 0 : 100
    Gui, %prevDef%:Default
}

ProgLaneText(lane, txt, force := false) {
    global g_progOn
    if (!g_progOn && !force)
        return
    prevDef := A_DefaultGui
    v := "Pg" lane "T"
    GuiControl, Prog:, %v%, %txt%
    Gui, %prevDef%:Default
}

; Also nudges lane A along. The step names come from the toasts PoExportRun already emits
; (which land here instead of on screen while the panel is up), so this is COSMETIC ONLY:
; reword a toast and the bar just stops advancing mid-lane, nothing breaks.
ProgSub(txt) {
    global g_progOn
    if (!g_progOn)
        return
    prevDef := A_DefaultGui
    GuiControl, Prog:, PgSub, %txt%
    Gui, %prevDef%:Default
    if (InStr(txt, "Waiting for the CSV"))
        ProgSeg("A", 1, "on"), ProgSeg("A", 2, "now")
    else if (InStr(txt, "Uploading PO data"))
        ProgSeg("A", 2, "on"), ProgSeg("A", 3, "now")
}

ProgTick:
    if (!g_progOn) {
        SetTimer, ProgTick, Off
        return
    }
    pgSecs := (A_TickCount - g_progT0) // 1000
    GuiControl, Prog:, PgTime, % (pgSecs // 60) ":" SubStr("0" Mod(pgSecs, 60), -1)
return

; One feed file: compare the local copy against the server's, upload only if local is newer,
; refresh the inv-cache the worklist pairs against. Counters come back ByRef.
;
; Shared verbatim by DockGetLatest (main process) and JobRunInvoices (child process) - two
; copies of newest-copy-wins would have drifted apart within a month.
StdCsvSync(f, ByRef upN, ByRef keptN, ByRef failN) {
    global CsvBase, g_dataDir
    stdUrl := CsvBase "/upload"
    SplitPath, f, fn
    srvRes := HttpGetPumped(CsvBase "/file/" fn, 20)
    srvMax := (srvRes.status = 200) ? CsvMaxDate(srvRes.text) : ""
    locMax := ""
    if (FileExist(f)) {
        FileRead, glTxt, %f%
        locMax := CsvMaxDate(glTxt)
    }
    if (locMax = "" && srvMax = "") {
        failN++
        Log("latest: " fn " - no usable copy on disk or server")
        return false
    }
    ; 1.21.2: dates tie at DAY granularity, so "newest date wins" alone refused every
    ; same-day re-export - the afternoon HY file had 17 invoices the server's morning copy
    ; didn't, max date 21/07 on both, and the compare said "kept" (Kaine, 2026-07-21: "it's
    ; picking up the kia one but not the hyundai"). Kia only LOOKED fine because its two
    ; copies happened to be identical. Tie-break: same max date, more data rows local ->
    ; the feed grew today -> upload. Server having equal-or-more rows still keeps.
    if (locMax != "" && locMax = srvMax) {
        locRows := CsvRowCount(glTxt)
        srvRows := CsvRowCount(srvRes.text)
        if (locRows > srvRows) {
            Log("latest: " fn " - same day (" CsvDateHuman(locMax) ") but local has " locRows " rows vs server " srvRows " - uploading")
            srvMax := ""   ; fall through to the upload below
        }
    }
    if (locMax = "" || (srvMax != "" && locMax <= srvMax)) {
        ; Server route: its copy is as new or newer (or there is no local file at all).
        keptN++
        Log("latest: " fn " - server copy kept (server " (srvMax = "" ? "?" : CsvDateHuman(srvMax)) " vs local " (locMax = "" ? "none" : CsvDateHuman(locMax)) ")")
        return true
    }
    ; Local route: this machine's copy is newer - upload it.
    ShowToast("load", "Uploading " fn "...", "Local is newer: " CsvDateHuman(locMax) (srvMax != "" ? " vs server " CsvDateHuman(srvMax) : " (server has none)"))
    tmp := A_Temp "\dock_stdup_" A_TickCount ".txt"
    FileDelete, %tmp%
    RunWait, %ComSpec% /c curl -s -F "file=@%f%" %stdUrl% > "%tmp%" 2>&1, , Hide
    FileRead, resp, %tmp%
    FileDelete, %tmp%
    if InStr(resp, "Uploaded successfully") {
        upN++
        Log("latest: " fn " uploaded - local " CsvDateHuman(locMax) " beat server " (srvMax = "" ? "(none)" : CsvDateHuman(srvMax)))
        ; local copy feeds the client-side invoice pairing (WlLoadInvCaches)
        if InStr(fn, "ki")
            FileCopy, %f%, %g_dataDir%\inv-cache-KI.csv, 1
        else if InStr(fn, "hy")
            FileCopy, %f%, %g_dataDir%\inv-cache-HY.csv, 1
        ; 1.26.0: the winner also becomes the C:\Temp copy, so the master folder is always
        ; the freshest known file. Copy, never move - the OneDrive/PSdata original stays.
        if (f != "C:\Temp\" fn)
            FileCopy, %f%, C:\Temp\%fn%, 1
        return true
    }
    failN++
    Log("latest: " fn " upload FAILED | " SubStr(resp, 1, 200))
    return false
}

; ============================================================
;  Child job process  (1.21.0)
; ============================================================
; AHK v1 has one thread, so "at the same time" means a second PROCESS: while the main copy
; sits inside ERA's blocking waits, this copy does the invoice CSVs, posts one WM_COPYDATA
; line back and dies. It builds no GUI and no tray icon - the branch in the auto-exec fires
; before any of that runs.
JobRunInvoices(parentHwnd) {
    upN := 0, keptN := 0, failN := 0
    Log("invoice job: started (parent " parentHwnd ")")
    for i, f in StdCsvPaths()
        StdCsvSync(f, upN, keptN, failN)
    Log("invoice job: " upN " uploaded, " keptN " kept, " failN " failed")
    JobSend(parentHwnd, (failN ? "fail" : "done") "|" upN "|" keptN "|" failN)
}

; WM_COPYDATA - the same transport the sender already uses to reach the worklist, so this
; adds no new IPC concept to the script, only a new dwData tag (0xE2A).
JobSend(hwnd, str) {
    VarSetCapacity(cds, A_PtrSize * 3, 0)
    NumPut(0xE2A, cds, 0, "Ptr")
    NumPut((StrLen(str) + 1) * 2, cds, A_PtrSize, "UInt")
    NumPut(&str, cds, A_PtrSize * 2, "Ptr")
    DetectHiddenWindows, On
    SendMessage, 0x4A, 0, &cds, , ahk_id %hwnd%
}

; Parent side. Fires while the main thread is asleep inside the ERA waits - Sleep is exactly
; where AHK dispatches messages, which is what makes the two lanes possible at all.
JobMsg(wParam, lParam) {
    global g_jobState, g_jobLine
    if (NumGet(lParam + 0, 0, "Ptr") != 0xE2A)
        return 0
    str := StrGet(NumGet(lParam + 0, A_PtrSize * 2, "Ptr"), "UTF-16")
    f := StrSplit(str, "|")
    g_jobState := f[1]
    g_jobLine := f[2] " uploaded, " f[3] " kept" ((f[4] + 0) ? ", " f[4] " FAILED" : "")
    Log("invoice job: reported " str)
    ProgLaneText("B", (g_jobState = "fail") ? "failed - " g_jobLine : g_jobLine)
    ProgSeg("B", 2, "on")
    ProgSeg("B", 3, (g_jobState = "fail") ? "err" : "on")
    return 1
}

; Copies this script elsewhere and runs the copy with /job. The copy is REQUIRED: the script
; is `#SingleInstance Force`, which matches on script path, so re-running this same path
; would kill the parent in the middle of driving ERA.
JobLaunch() {
    global g_jobState
    g_jobState := "running"
    if (A_IsCompiled) {
        exe := A_Temp "\ERA_Dock_job.exe"
        FileCopy, %A_ScriptFullPath%, %exe%, 1
        Run, "%exe%" /job invoices %A_ScriptHwnd% "%A_ScriptDir%", , UseErrorLevel
    } else {
        ahk := A_AhkPath
        if (!FileExist(ahk))
            ahk := Find64BitAhk()
        if (ahk = "") {
            Log("invoice job: no AutoHotkey.exe found - running the invoice lane inline")
            g_jobState := "nolaunch"
            return false
        }
        job := A_Temp "\ERA_Dock_job.ahk"
        FileCopy, %A_ScriptFullPath%, %job%, 1
        Run, "%ahk%" "%job%" /job invoices %A_ScriptHwnd% "%A_ScriptDir%", , UseErrorLevel
    }
    if (ErrorLevel) {
        Log("invoice job: launch FAILED - running the invoice lane inline")
        g_jobState := "nolaunch"
        return false
    }
    Log("invoice job: launched")
    return true
}

; Where the KI + HY invoice feeds live on THIS machine (1.26.0: newest-wins).
;
; 1.20.0 took the FIRST path that existed, which let a stale C:\Temp copy shadow a fresh
; export in one of the other folders forever - Kaine (2026-07-23): "sometimes takes 2 or 3
; tries to find those files". The 2nd try only ever worked because a human moved the file.
; The export always lands in one of these three folders under its exact name (Kaine,
; 2026-07-23: never Downloads, never a "(1)" copy), so now ALL THREE are read and the best
; copy wins on the same keys StdCsvSync already trusts: newest invoice date, then row
; count, then file time. Only WHICH local file enters the server compare changed; the
; compare didn't.
;
; A_UserName, never a hard-coded profile: kainet on the work box, kaine on the dev box,
; joshuar on Josh's, and his is not a OneDrive setup at all, which is exactly why the
; plain C:\Temp entry has to stay rather than be replaced.
;
; Returns one path per feed - the winning candidate. If none exists anywhere the C:\Temp
; path is returned anyway so DockGetLatest can still take the server copy and log the miss
; against a real filename.
StdCsvPaths() {
    out := []
    for i, fn in ["stdpartski.csv", "stdpartshy.csv"] {
        cand := []
        cand.Push("C:\Temp\" fn)
        cand.Push("C:\Users\" A_UserName "\OneDrive - Hopper Motor Group\Temp\" fn)
        cand.Push("C:\Users\" A_UserName "\Documents\PSdata\" fn)
        best := "", bDate := "", bRows := 0, bTime := "", nSeen := 0
        for j, c in cand {
            if (!FileExist(c))
                continue
            nSeen++
            FileRead, scTxt, %c%
            cDate := CsvMaxDate(scTxt), cRows := CsvRowCount(scTxt)
            FileGetTime, cTime, %c%, M
            Log("search: " fn " candidate " c " (" (cDate = "" ? "no dates" : CsvDateHuman(cDate)) ", " cRows " rows)")
            if (best = "" || cDate > bDate
                || (cDate = bDate && cRows > bRows)
                || (cDate = bDate && cRows = bRows && cTime > bTime))
                best := c, bDate := cDate, bRows := cRows, bTime := cTime
        }
        if (best = "") {
            Log("search: " fn " - no local copy in any of the three folders (the server copy will decide)")
            best := "C:\Temp\" fn
        } else if (nSeen > 1)
            Log("search: " fn " - picked " best " of " nSeen " candidates (" (bDate = "" ? "no dates" : CsvDateHuman(bDate)) ", " bRows " rows)")
        out.Push(best)
    }
    return out
}

; Data rows in a feed CSV: non-empty lines minus the header. Good enough as a same-day
; tie-break because the feeds only ever GROW within a day - ERA re-exports are supersets.
CsvRowCount(txt) {
    n := 0
    Loop, Parse, txt, `n, `r
        if (A_LoopField != "")
            n++
    return n > 0 ? n - 1 : 0
}

; Newest DD/MM/YYYY anywhere in a feed CSV, as sortable yyyyMMdd ("" = none found).
; Deliberately scans ALL dates rather than locating the "Inv. Date" column: an old export
; cannot contain dates newer than a fresh one, any date column moves forward together, and
; a whole-text regex has no CSV-quoting edge cases to get wrong.
CsvMaxDate(txt) {
    max := "", pos := 1
    while (pos := RegExMatch(txt, "\b(\d{2})/(\d{2})/(\d{4})\b", m, pos)) {
        d := m3 . m2 . m1
        if (d > max)
            max := d
        pos += StrLen(m)
    }
    return max
}

CsvDateHuman(ymd) {
    return SubStr(ymd, 7, 2) "/" SubStr(ymd, 5, 2) "/" SubStr(ymd, 1, 4)
}

DockStatusOnce:
    StatusRunCheck(true)
return

DockMenu:
    ; Right-click menu: hang it off the left end of the strip, under the strip's bottom.
    CellRect("CellWl", dgx, dgy, cw, ch)
    menuY := dgy + ch
    Menu, DockMenu, Show, %dgx%, %menuY%
return

; Screen rect of one dock strip control. Everything that pops out of the strip anchors
; through here, so a layout change can never leave a popup pointing at dead space again.
CellRect(ctl, ByRef x, ByRef y, ByRef w, ByRef h) {
    global DockHwnd
    GuiControlGet, p, Dock:Pos, %ctl%
    WinGetPos, dx, dy,,, ahk_id %DockHwnd%
    x := dx + pX, y := dy + pY, w := pW, h := pH
}

DockMenuWorklist:
    WlToggle()
return
DockMenuSender:
    Gosub, ShowMainWindow
return
DockMenuUploadPo:
    Gosub, WlUploadPo
return
DockMenuFlags:
    Gosub, MenuViewFlags
return
DockMenuSettings:
    Gosub, SettingsShow
return
DockMenuLog:
    Gosub, WlOpenLog
return
DockMenuExit:
    ExitApp
return

; ============================================================================
;  SENDER SECTION  (was: BYD and ISUZU sender.ahk v2.2.0)
; ============================================================================
; Search every common place a 64-bit AutoHotkey 1.1 build might live.
; Returns the first existing path, or "" if none found.
Find64BitAhk() {
    SplitPath, A_AhkPath, , ahkDir
    cands := []
    ; same folder as the running exe (most installs put both side by side)
    cands.Push(ahkDir "\AutoHotkeyU64.exe")
    cands.Push(ahkDir "\AutoHotkey64.exe")          ; some repackaged 1.1 builds
    ; standard install roots
    for i, root in ["C:\Program Files\AutoHotkey", "C:\Program Files (x86)\AutoHotkey"] {
        cands.Push(root "\AutoHotkeyU64.exe")
        cands.Push(root "\AutoHotkey64.exe")
        cands.Push(root "\v1.1.37.02\AutoHotkeyU64.exe")
        cands.Push(root "\v1.1\AutoHotkeyU64.exe")
    }
    ; per-user install (newer AHK installer default)
    if (A_AppData != "") {
        cands.Push(A_AppData "\..\Local\Programs\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe")
        cands.Push(A_AppData "\..\Local\Programs\AutoHotkey\AutoHotkeyU64.exe")
    }
    for i, p in cands {
        if FileExist(p)
            return p
    }
    return ""
}


; ============================================================
;  Invoice Sender  (AutoHotkey v1.1, Unicode)  -  Isuzu + BYD
;  Drag PDF invoices onto the window -> each is auto-routed to
;  the matching Railway parser (/parse-invoice) by brand, then
;  base64-encoded and POSTed. Per-row: Queued -> Sending -> Sent.
;
;  Brand routing (BrandFor): filename pattern first (instant),
;  then a raw-text scan of the PDF bytes, then a per-file prompt.
;    BYD    -> filename starts "E-BYD" / contains "BYD"  | text "BYD"
;    Isuzu  -> filename matches I + 7 digits             | text "ISUZU"
;
;  No secrets live here. Keys stay server-side; we upload bytes.
;
;  NOTE: pure ASCII source. Glyphs built at runtime with Chr().
; ============================================================

SndAutoExec:
global SND_VERSION    := "2.2.0"
global IsuzuUrl   := ""
global BydUrl     := ""
global ReconUrl   := ""    ; invoice-recon service. EMPTY = feature off (sender behaves exactly as before)
global g_batchId  := ""    ; ties one send batch's recon results together
global g_reconCount := 0   ; how many recon posts were fired this batch
global g_reconReqs  := []  ; keeps async WinHttp objects ALIVE until batch end - releasing a
                           ; WinHttpRequest mid-flight ABORTS the send (measured: found 0/1
                           ; released vs 1/1 kept). Fire-and-forget must not be fire-and-cancel.
global g_reconFlags := ""  ; last batch's flag text, shown on demand from the tray menu
global g_reconFlagsAt := "" ; when that batch finished (so the on-demand view can say how old)
; ---- receipting lives in its own script now (2026-07-18 split) ----
; "Receipting worklist.ahk" owns the worklist window, Settings, and the whole Rcp*/Era*
; typing engine. The sender only RAISES it (WorklistPing) - it holds none of that state.
global WL_SCRIPT  := "Receipting worklist.ahk"
global WL_MSG     := 0x8001   ; wParam 1 = show + refresh, 2 = quiet refresh if already up
global DLG_ERA_TITLE := "ERA Port"  ; window our MsgBoxes centre on (DlgCenterMove)
global CfgFanOut  := 1     ; recon fan-out master switch (ReconApiUrl empty still wins);
                           ; owned by the worklist's Settings window, re-read per batch.
global DefaultBrand := ""        ; "isuzu"/"byd"/"" -> "" means prompt when unknown
global EnableEmailDrag := true
global Busy       := false
global Paths      := {}    ; ListView row number -> full file path
global Brands     := {}    ; ListView row number -> "isuzu"/"byd"/"unknown"
global Seen       := {}    ; full path -> true (dedupe drops)
global hwndMain   := 0
global g_lastId    := ""   ; last successful invoice id   (for the Ctrl+Right menu toast)
global g_lastLines := 0    ; last successful line count   (for the Ctrl+Right menu toast)
global gOutlookHwnd := 0   ; Outlook window captured when the Ctrl+Right menu opens
global ToastHwnd    := 0   ; custom on-screen toast window
global gDragX := 0         ; cursor X at Ctrl+Right (the attachment) - for new-Outlook auto-drag
global gDragY := 0         ; cursor Y at Ctrl+Right
global g_oleInit   := false ; OLE libraries initialized (needed for clipboard + drop)
global g_oleActive := false ; drag-drop target registered
global g_vtbl, g_obj       ; OLE IDropTarget memory (kept alive while running)
global __EMBED_ICON_PATH := ""

; Unicode glyphs, built from code points (encoding-independent)
global GLYPH_OK   := Chr(0x2713)   ; check mark
global GLYPH_BAD  := Chr(0x2717)   ; ballot X
global GLYPH_DOWN := Chr(0x2193)   ; down arrow
global GLYPH_WARN := Chr(0x26A0)   ; warning triangle (sidebar: order not in export / PO with no invoice)
global GLYPH_DOT  := Chr(0x25CF)   ; red dot (sidebar: invoice carries part(s) NOT on the PO - 2.25.0)
global HINT_IDLE  := ""
global HINT_MORE  := ""

HINT_IDLE := GLYPH_DOWN "   Drag Isuzu + BYD invoice PDFs here   " GLYPH_DOWN
HINT_MORE := GLYPH_DOWN "   Drop more, or click ""Send all""   " GLYPH_DOWN

ReadConfig()


; ---- GUI is built by the BuildGui label (called at startup + by the SC029 hotkey) ----

; ---- Tray menu ---------------------------------------------
; ---- Full refresh progress panel (1.21.0) ----------------------------------
; Built HERE, at the top level, and not inside ProgShow(). AHK v1 will not accept a Gui
; control variable that is a function local, and these names are dynamic (PgA1, PgB2...) so
; they cannot be declared static the way ShowToast declares TGlyph/TL1/TL2. Building it in a
; function hangs on an error dialog at the first `vPg...` control - verified under wine.
; Everything after this only ever touches it through GuiControl, which takes the control
; name as a string and does not care about scope.
Gui, Prog:New, +AlwaysOnTop -Caption +ToolWindow +HwndProgHwnd +E0x08000000
Gui, Prog:Color, 26262B
Gui, Prog:Font, s11 Bold cWhite, Segoe UI
Gui, Prog:Add, Text, x16 y14 w200 vPgTitle, Full refresh
Gui, Prog:Font, s9 Norm cBBBBBB, Segoe UI
Gui, Prog:Add, Text, x236 y17 w140 Right vPgTime, 0:00
Gui, Prog:Add, Text, x16 y38 w360 vPgSub, Starting...
pgY := 62
for pgI, pgLane in ["A", "B", "C"] {
    pgNm := (pgLane = "A") ? "PO data" : (pgLane = "B") ? "Invoices" : "Import"
    Gui, Prog:Font, s8 Bold cE6E6EA, Segoe UI
    Gui, Prog:Add, Text, x16 y%pgY% w90 vPgL%pgLane%, %pgNm%
    Gui, Prog:Font, s8 Norm c9B9AA2, Segoe UI
    Gui, Prog:Add, Text, x106 y%pgY% w270 Right vPg%pgLane%T, waiting
    pgSegs := (pgLane = "C") ? 2 : 3      ; import is one step, so two segments read as a bar
    pgW := (pgSegs = 2) ? 178 : 117
    pgSy := pgY + 16
    Loop, %pgSegs% {
        pgSx := 16 + (A_Index - 1) * (pgW + 4)
        Gui, Prog:Add, Progress, x%pgSx% y%pgSy% w%pgW% h6 -Theme Background3A3A42 c33C966 vPg%pgLane%%A_Index%, 0
    }
    pgY += 34
}
Gui, 1:Default          ; Gui,Prog:New stole the thread default - hand it straight back

Menu, Tray, NoStandard
Menu, Tray, Add, Open window, ShowMainWindow
Menu, Tray, Add
Menu, Tray, Add, Grab from Outlook, GrabFromOutlook
Menu, Tray, Add, Paste copied attachment, PasteFromClipboard
Menu, Tray, Add, Add files..., MenuAddFiles
Menu, Tray, Add
; Duplicates removed 2026-07-20. The merge left this block and the worklist's block both
; adding a PO upload, a show-worklist, an Open log and an Exit. Survivors were chosen on
; what the handlers actually do, not on which came first:
;   Upload PO Data    -> WlUploadPo   (calls PoUploadRun + re-checks the status dot;
;                                      MenuUploadPo is the older inline copy)
;   Receipting worklist -> WlTrayShow (calls SidebarShow directly; MenuWorklist still hops
;                                      through WorklistPing, a two-process leftover)
;   Open log / Exit   -> kept here, identical either side.
; MenuUploadPo / MenuWorklist / MenuExit stay defined - other callers still use them.
Menu, Tray, Add, View receipting flags, MenuViewFlags
Menu, Tray, Add, Open log, MenuOpenLog
Menu, Tray, Add                      ; divider before the worklist block appends below
Menu, Tray, Default, Open window
Menu, Tray, Tip, Invoice Sender (Isuzu + BYD) v%SND_VERSION%

; Centre our MsgBoxes on the ERA window rather than on an owner parked at a screen edge -
; a confirm box you cannot read is a confirm box you cannot supervise (both videos,
; 2026-07-16/17). The worklist script runs the same handler for its own dialogs.
OnMessage(0x44, "DlgCenter")         ; WM_COMMNOTIFY - AHK posts it as a dialog is created

; ---- Right-click menu on a ListView row: override brand -----
Menu, RowMenu, Add, Route to Isuzu, RowSetIsuzu
Menu, RowMenu, Add, Route to BYD, RowSetByd
Menu, RowMenu, Add
Menu, RowMenu, Add, Remove row, RowRemove

; ---- Ctrl+Right-click menu (shown over Outlook) -----------
Menu, SenderMenu, Add, Send invoice to server, MenuSendOne
Menu, SenderMenu, Add
Menu, SenderMenu, Add, Bulk send selected emails, MenuSendBulk
Menu, SenderMenu, Add
Menu, SenderMenu, Add, Open log, MenuOpenLog
Menu, SenderMenu, Add
Menu, SenderMenu, Add, Exit, MenuExit
Menu, SenderMenu, Default, Send invoice to server

SndLog("startup v" SND_VERSION " | isuzu=" IsuzuUrl " | byd=" BydUrl " | bits=" (A_PtrSize * 8))
; Ctrl+Space lives in the WORKLIST script, so that hotkey only answers while that script is
; running. Start it here (silently - it opens no window until asked) so starting the sender
; is still the one thing Kaine has to do in the morning.
WorklistStart()
OnExit("CleanupOle")
g_oleInit := (A_PtrSize = 8 && DllCall("ole32\OleInitialize", "Ptr", 0, "Int") >= 0)
Gosub, BuildGui          ; build the window once at startup (stays hidden until Ctrl+Alt+I)
return

; ============================================================
;  BuildGui:  destroy the current window (if any) and build a
;  fresh one. Safe to call anytime. Used at startup and by the
;  SC029 (`) hotkey for a clean rebuild.
; ============================================================
BuildGui:
    Gui, 1:Default           ; merged build: never trust the calling thread's default
    ; tear down the old window's drag-drop registration, then the window
    if (g_oleActive) {
        DllCall("ole32\RevokeDragDrop", "Ptr", hwndMain)
        g_oleActive := false
    }
    Gui, 1:Destroy
    Paths  := {}          ; reset row maps so the new window starts clean
    Brands := {}
    Seen   := {}

    Gui, +HwndhwndMain +AlwaysOnTop
    Gui, Margin, 12, 12
    Gui, Font, s11 Bold, Segoe UI
    Gui, Add, Text, w460 Center, Invoice Sender  -  Isuzu + BYD
    Gui, Font, s9 Norm cGray, Segoe UI
    Gui, Add, Text, w460 Center, Drop invoice PDFs below (auto-routed by brand), then click "Send all"

    Gui, Font, s11 Norm, Segoe UI
    Gui, Add, GroupBox, x12 w460 h64 vDropBox,
    Gui, Add, Text, xp+12 yp+24 w436 Center vDropHint, %HINT_IDLE%

    Gui, Font, s9, Segoe UI
    Gui, Add, ListView, x12 y+32 w460 r10 Grid -Multi vLV gLV, #|File|Brand|Status
    LV_ModifyCol(1, 28)
    LV_ModifyCol(2, 215)
    LV_ModifyCol(3, 60)
    LV_ModifyCol(4, 145)

    Gui, Add, Button, x12 y+12 w130 h32 gSendAll vBtnSend, Send all
    Gui, Add, Button, x+10 yp w90 h32 gClearList vBtnClear, Clear
    Gui, Font, s9 cGray, Segoe UI
    Gui, Add, Text, x+90 yp+8, % "v" . SND_VERSION

    Gui, Show, Hide w484 h470, Invoice Sender   ; built hidden; Ctrl+Alt+I shows it

    ; re-register drag-drop on the NEW window handle
    if (EnableEmailDrag && g_oleInit) {
        if InitOleDrop(hwndMain)
            SndLog("email-drag: OLE drop target active (real files + classic-Outlook drags)")
        else
            SndLog("email-drag: init failed; basic drop + Grab + Paste still work")
    } else if (EnableEmailDrag) {
        SndLog("email-drag: needs 64-bit AHK; using basic drop + Grab + Paste")
    }
    if (A_PtrSize != 8) {
        GuiControl, 1:, DropHint, % "32-bit AHK: drag disabled. Use Add files / Grab / Paste, then Send all."
        Menu, Tray, Tip, Invoice Sender (32-bit: no drag) v%SND_VERSION%
    }
return

; ============================================================
;  Drag & drop  (fires for files dropped anywhere on the GUI)
; ============================================================
GuiDropFiles:
    addedAny := false
    Loop, Parse, A_GuiEvent, `n
    {
        if (A_LoopField = "")
            continue
        if AddFile(A_LoopField)
            addedAny := true
    }
    if (addedAny)
        GuiControl, 1:, DropHint, %HINT_MORE%
return

; ============================================================
;  ListView events: right-click a row to override its brand
; ============================================================
LV:
    if (A_GuiEvent = "RightClick") {
        Menu, RowMenu, Show
    }
return

RowSetIsuzu:
    if (Busy)
        return
    SetRowBrand(LV_GetSelRow(), "isuzu")
return
RowSetByd:
    if (Busy)
        return
    SetRowBrand(LV_GetSelRow(), "byd")
return
RowRemove:
    if (Busy)
        return
    row := LV_GetSelRow()
    if (row) {
        Gui, 1:Default
        path := Paths[row]
        if (path != "")
            Seen.Delete(path)
        LV_Delete(row)
        RebuildRowMaps()
    }
return

; ============================================================
;  Buttons
; ============================================================
SendAll:
    if (Busy)
        return
    Gui, 1:Default
    total := LV_GetCount()
    if (!total) {
        ShowToast("bad", "Nothing to send", "Drop some invoice PDFs first")
        return
    }
    ; Resolve any "unknown" rows before sending (prompt or default).
    if (!ResolveUnknowns())
        return
    Busy := true
    GuiControl, 1:Disable, BtnSend
    GuiControl, 1:Disable, BtnClear
    ReconBatchBegin()
    okCount := 0, failCount := 0
    Loop % total {
        row := A_Index
        LV_GetText(prev, row, 4)
        if InStr(prev, GLYPH_OK)             ; don't re-send successes
            continue
        path  := Paths[row]
        brand := Brands[row]
        ShowToast("load", "Sending to server...", "Invoice " row " of " total " (" BrandLabel(brand) ")")
        LV_Modify(row, "Col4", "Sending...")
        Sleep, 30                            ; let the row repaint before the blocking send
        result := SendOne(path, brand)
        LV_Modify(row, "Col4", result)
        if InStr(result, GLYPH_OK)
            okCount++
        else
            failCount++
    }
    Busy := false
    GuiControl, 1:Enable, BtnSend
    GuiControl, 1:Enable, BtnClear
    SndLog("batch done: " okCount " ok, " failCount " failed")
    if (okCount = 0)
        ShowToast("bad", "Send failed", "Tray icon > Open log for details")
    else {
        msg := okCount " invoice" (okCount = 1 ? "" : "s") " sent"
        if (failCount)
            msg .= ", " failCount " failed"
        ShowToast((failCount ? "bad" : "ok"), "Send all complete", msg)
    }
    ReconBatchEnd()          ; one round trip for the whole batch; may pop the flags MsgBox
return

ClearList:
    if (Busy)
        return
    LV_Delete()
    Paths  := {}
    Brands := {}
    Seen   := {}
    GuiControl, 1:, DropHint, %HINT_IDLE%
return

; ============================================================
;  Tray menu handlers
; ============================================================
MenuAddFiles:
    FileSelectFile, sel, M3, , Select invoice PDFs, PDF Documents (*.pdf)
    if (sel = "")
        return
    lineCount := 0
    Loop, Parse, sel, `n
        lineCount++
    if (lineCount = 1) {
        AddFile(sel)
    } else {
        dir := ""
        Loop, Parse, sel, `n
        {
            if (A_Index = 1)
                dir := A_LoopField
            else
                AddFile(dir "\" A_LoopField)
        }
    }
    GuiControl, 1:, DropHint, %HINT_MORE%
return

MenuOpenLog:
    logf := A_ScriptDir "\sender.log"
    if (!FileExist(logf))
        FileAppend, , %logf%
    Run, notepad.exe "%logf%"
return

; Uploads the ERA outstanding-PO export to invoice-recon. SYNCHRONOUS on purpose - you want
; the row count back to confirm it landed.
;
; The export holds only OUTSTANDING lines, so receipted orders have already dropped off it.
; Run this immediately before receipting: a stale snapshot silently degrades to
; "everything flags".
MenuUploadPo:
    Gui, 1:Default              ; menu threads have no GUI context
    if (ReconUrl = "") {
        ShowToast("bad", "PO upload unavailable", "Set ReconApiUrl in config.ini")
        return
    }
    FileSelectFile, poCsv, 3, , Select the ERA PO export, CSV (*.csv)
    if (poCsv = "")
        return
    FileRead, poText, %poCsv%
    if (ErrorLevel || poText = "") {
        ShowToast("bad", "PO upload failed", "Could not read that file")
        return
    }
    ShowToast("load", "Uploading PO data...", "")
    ; Raw text/csv - avoids having to JSON-escape 30 KB of quoted CSV.
    poRes := HttpPostJson(ReconUrl "/po-data", poText, false, "text/csv")
    if (poRes.status != 200) {
        SndLog("po-data: upload failed http=" poRes.status " | " SubStr(poRes.text, 1, 200))
        ShowToast("bad", "PO upload failed", "HTTP " poRes.status " - see log")
        return
    }
    FileCopy, %poCsv%, %A_ScriptDir%\po-cache.csv, 1   ; local copy feeds the PO-only rows
    ; NO `U)`. It inverts greediness, so (\d+) matched a SINGLE digit: every upload from
    ; 2.0 to 2.1.0 logged and toasted "rows=4 byd=1" for a 497-row / 117-BY export (found
    ; 2026-07-19, visible in sender.log back to 2026-07-16). Nothing downstream read the
    ; numbers, so it only ever misreported - but it misreported the one number that tells
    ; you the upload landed. Same fix applied in the worklist's own copy.
    RegExMatch(poRes.text, """rowCount""\s*:\s*(\d+)", mRc)
    RegExMatch(poRes.text, """bydRowCount""\s*:\s*(\d+)", mBc)
    SndLog("po-data: uploaded rows=" mRc1 " byd=" mBc1)
    ShowToast("ok", "PO data uploaded", mRc1 " rows (" mBc1 " BYD)")
    ; The snapshot just changed - bring the worklist up reconciled against it.
    WorklistPing(1)
return

; ============================================================
;  Receipting worklist (a separate script since the 2026-07-18 split)
;
;  "Receipting worklist.ahk" owns the worklist window, Settings and the whole typing
;  engine, and answers Ctrl+Space itself. The sender's only jobs are to START it if it
;  isn't running and to NUDGE it when the data behind it changed. Everything here is
;  best-effort: the worklist being absent must never disturb a send.
; ============================================================
MenuWorklist:
    WorklistPing(1)
return

; mode 1 = show + refresh, 2 = quiet refresh (only if it's already on screen).
; A worklist that isn't running is STARTED first and then pinged - it comes up in the tray
; showing nothing, so without the ping "Receipting worklist" would look like it did nothing.
; Quiet refreshes never start it: a batch end must not conjure a window nobody asked for.
WorklistPing(mode) {
    global WL_MSG
    hwnd := (mode = 1) ? WorklistStart(true) : WorklistHwnd()
    if (!hwnd)
        return
    prevHid := A_DetectHiddenWindows
    DetectHiddenWindows, On
    PostMessage, WL_MSG, mode, 0, , ahk_id %hwnd%
    DetectHiddenWindows, %prevHid%
}

; Start the worklist script if it isn't already running. Returns its script-window hwnd, or
; 0 if it could not be started (or did not come up in time). wait=false is the startup call:
; the sender should not sit blocking on it, and nothing is pinged.

; The worklist script's own (hidden) main window. Script main windows are titled with the
; full script path, so a prefix match on the path finds ours and nobody else's.

; On-demand view of the last batch's receipting flags. The batch end only raises a quiet
; tray balloon; the text itself lives here (and, uncapped, in sender.log).
MenuViewFlags:
    Gui, 1:Default              ; menu threads have no GUI context
    if (g_reconFlags = "") {
        ShowToast("ok", "No receipting flags", "Nothing flagged since the sender started")
        return
    }
    Gui, 1:+OwnDialogs
    MsgBox, 0x40, Receipting flags (batch of %g_reconFlagsAt%), % g_reconFlags
return

ShowMainWindow:
    Gui, 1:Show
return

MenuExit:
    ExitApp
return

; Tray-driven: closing/Esc just hides the window. Exit from the tray menu.
GuiClose:
GuiEscape:
    Gui, 1:Hide
return

; ============================================================
;  Brand routing
; ============================================================
; Decide which parser a PDF belongs to. Returns "isuzu", "byd", or "unknown".
;  1) filename pattern  (instant, no I/O)
;  2) raw-byte text scan (catches uncompressed PDFs / odd names)
;  3) "unknown" -> caller prompts or applies DefaultBrand
BrandFor(path) {
    SplitPath, path, fname
    b := BrandFromName(fname)
    if (b != "unknown") {
        SndLog("route: '" fname "' -> " b " (filename)")
        return b
    }
    b := BrandFromBytes(path)
    SndLog("route: '" fname "' -> " b " (text scan)")
    return b
}

BrandFromName(fname) {
    StringUpper, up, fname
    if (InStr(up, "E-BYD") || InStr(up, "BYDAU") || InStr(up, "BYD"))
        return "byd"
    ; Isuzu dealer invoices: I followed by 6-8 digits, then .pdf  e.g. I0957393.pdf
    if RegExMatch(up, "^I\d{6,8}\.PDF$")
        return "isuzu"
    if (InStr(up, "ISUZU"))
        return "isuzu"
    return "unknown"
}

; Scan the raw PDF bytes for a brand marker. Most invoice text is FlateDecode-
; compressed so this only catches uncompressed streams, but it's a cheap, safe
; second pass before falling back to a prompt. Reads up to 256 KB.
BrandFromBytes(path) {
    f := FileOpen(path, "r")
    if (!IsObject(f))
        return "unknown"
    len := f.Length
    cap := (len < 262144 ? len : 262144)
    VarSetCapacity(buf, cap + 1, 0)
    f.RawRead(buf, cap)
    f.Close()
    ; Interpret bytes as Latin-1 text (PDF operators/literals are ASCII).
    txt := StrGet(&buf, cap, "CP1252")
    StringUpper, txt, txt
    hasByd   := InStr(txt, "BYD")
    hasIsuzu := InStr(txt, "ISUZU")
    if (hasByd && !hasIsuzu)
        return "byd"
    if (hasIsuzu && !hasByd)
        return "isuzu"
    return "unknown"
}

BrandLabel(b) {
    if (b = "isuzu")
        return "Isuzu"
    if (b = "byd")
        return "BYD"
    return "?"
}

UrlFor(brand) {
    global IsuzuUrl, BydUrl
    if (brand = "isuzu")
        return IsuzuUrl
    if (brand = "byd")
        return BydUrl
    return ""
}

; Update one row's brand in the map + the Brand column.
SetRowBrand(row, brand) {
    global Brands
    if (!row)
        return
    Gui, 1:Default
    Brands[row] := brand
    LV_Modify(row, "Col3", BrandLabel(brand))
}

; After a row delete, ListView renumbers rows; rebuild Paths/Brands to match.
RebuildRowMaps() {
    global Paths, Brands
    Gui, 1:Default
    newPaths  := {}
    newBrands := {}
    Loop % LV_GetCount() {
        r := A_Index
        LV_GetText(fn, r, 2)
        ; find the old path whose filename matches this row (paths are unique by Seen)
        for oldRow, p in Paths {
            SplitPath, p, pn
            if (pn = fn && !ObjHasValue(newPaths, p)) {
                newPaths[r]  := p
                newBrands[r] := Brands[oldRow]
                break
            }
        }
    }
    Paths  := newPaths
    Brands := newBrands
    ; renumber the # column
    Loop % LV_GetCount()
        LV_Modify(A_Index, "Col1", A_Index)
}

ObjHasValue(obj, val) {
    for k, v in obj
        if (v = val)
            return true
    return false
}

; Currently focused (else first selected) ListView row. 0 if none.
LV_GetSelRow() {
    Gui, 1:Default
    row := LV_GetNext(0, "F")
    if (!row)
        row := LV_GetNext(0)
    return row
}

; Resolve every "unknown" row before a batch send. Returns true to proceed,
; false if the user cancelled. Uses DefaultBrand if set, else asks per file.
ResolveUnknowns() {
    global Brands, Paths, DefaultBrand
    Gui, 1:Default
    Loop % LV_GetCount() {
        row := A_Index
        if (Brands[row] != "unknown")
            continue
        if (DefaultBrand = "isuzu" || DefaultBrand = "byd") {
            SetRowBrand(row, DefaultBrand)
            continue
        }
        p := Paths[row]
        SplitPath, p, fn
        Gui, 1:+OwnDialogs
        MsgBox, 0x33, Which parser?, % "Couldn't auto-detect the brand for:`n`n" fn "`n`nYes = Isuzu`nNo = BYD`nCancel = stop sending"
        IfMsgBox, Yes
            SetRowBrand(row, "isuzu")
        else IfMsgBox, No
            SetRowBrand(row, "byd")
        else
            return false
    }
    return true
}

; ============================================================
;  Helpers
; ============================================================
AddFile(path) {
    global Seen, Paths, Brands
    Gui, 1:Default            ; ensure LV_* target our window (callbacks/menus have no GUI context)
    SplitPath, path, fname, , ext
    StringLower, extLower, ext
    if (extLower != "pdf") {
        SndLog("skip non-pdf " path)
        return false
    }
    if Seen.HasKey(path) {
        return false
    }
    if (!FileExist(path)) {
        SndLog("skip missing " path)
        return false
    }
    Seen[path] := true
    brand := BrandFor(path)
    row := LV_Add("", LV_GetCount() + 1, fname, BrandLabel(brand), "Queued")
    Paths[row]  := path
    Brands[row] := brand
    SndLog("queued " path " (" brand ")")
    return true
}

SendOne(path, brand) {
    global GLYPH_OK, GLYPH_BAD, g_lastId, g_lastLines
    SplitPath, path, fname
    if (!FileExist(path)) {
        SndLog("send: missing " path)
        return GLYPH_BAD . " file missing"
    }
    url := UrlFor(brand)
    if (url = "") {
        SndLog("send: no endpoint for brand '" brand "' " fname)
        return GLYPH_BAD . " no route"
    }
    b64 := Base64FromFile(path)
    if (b64 = "") {
        SndLog("send: read failed " fname)
        return GLYPH_BAD . " read failed"
    }
    body := "{""dataBase64"":""" b64 """}"
    ; Mirror the same bytes to invoice-recon before the blocking primary send. Fire-and-forget,
    ; so this costs the existing send nothing; the batch collects the flags later via /flags.
    ReconFire(b64, brand)
    res := HttpPostJson(url "/parse-invoice", body)
    if (res.status = 0) {
        SndLog("send: network error " fname " | " res.text)
        return GLYPH_BAD . " network"
    }
    okMatch := ""
    RegExMatch(res.text, "i)""ok""\s*:\s*(true|false)", m)
    okMatch := m1
    if (res.status = 200 && okMatch = "true") {
        id := "", conf := "", lines := 0
        ; These next two were NOT broken: [^"]* is followed by a literal quote, and a
        ; class that cannot match " lands on the same text lazy or greedy. Dropping U)
        ; anyway - a pattern that is only harmless by accident is the one that gets
        ; copied into the next parser that DOES have a (\d+) in it.
        RegExMatch(res.text, """id""\s*:\s*""([^""]*)""", mId)
        id := mId1
        StrReplace(res.text, """partNumber""", "", lines)
        ; Same lazy-quantifier bug, and this one reads worse in the log: ([0-9.]+) under
        ; U) took ONE character, so an OpenAI-fallback parse at 0.85 logged "conf=0" -
        ; indistinguishable from genuine zero confidence. BYD's deterministic 1 came out
        ; right by luck (it is one character), which is why it never looked wrong.
        RegExMatch(res.text, """confidence""\s*:\s*([0-9.]+)", mConf)
        conf := mConf1
        g_lastId    := id        ; stash for the Ctrl+Right menu toast
        g_lastLines := lines
        SndLog("send: OK " fname " [" brand "] -> id=" id " lines=" lines " conf=" conf " http=" res.status)
        out := GLYPH_OK . " Sent"
        if (id != "")
            out .= " " id
        if (lines > 0)
            out .= " (" lines ")"
        return out
    }
    err := ""
    RegExMatch(res.text, """errors""\s*:\s*\[\s*""([^""]*)""", mErr)
    err := mErr1
    if (err = "")
        err := "HTTP " res.status
    SndLog("send: FAIL " fname " [" brand "] http=" res.status " err=" err " | " SubStr(res.text, 1, 200))
    return GLYPH_BAD . " " . err
}

; --- POST JSON via WinHTTP. Returns {status, text}.
;     Hardened: forces TLS 1.2/1.3, tolerates cert hiccups behind proxies,
;     longer receive window for big PDFs, retries transient failures.
;
;     async=true -> fire-and-forget: returns the instant the request is handed off, WITHOUT
;     waiting for a response. This is what keeps the recon fan-out from slowing the existing
;     send. Status/text are NOT read in that mode (they throw on an async handle) and no
;     retry is possible, so the result is {status:0} by design - callers must ignore it.
; connectMs/maxAttempts default to the original behaviour - the parse path (the send itself)
; must stay patient and keep retrying. Callers that merely decorate the send pass a short
; bound instead: a dead host costs 34s (DNS never resolves) to 51s (packets dropped) at the
; defaults, because the resolve/connect timeout is charged PER ATTEMPT on top of the sleeps.

; --- Read a file as raw bytes and return standard base64 (no line breaks).
Base64FromFile(path) {
    f := FileOpen(path, "r")
    if (!IsObject(f))
        return ""
    len := f.Length
    if (len <= 0) {
        f.Close()
        return ""
    }
    VarSetCapacity(data, len, 0)
    got := f.RawRead(data, len)
    f.Close()
    if (got <= 0)
        return ""
    return Base64Enc(data, got)
}

Base64Enc(ByRef data, len) {
    static fmt := 0x40000001   ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    if !DllCall("Crypt32.dll\CryptBinaryToStringW", "Ptr", &data, "UInt", len, "UInt", fmt, "Ptr", 0, "UInt*", chars)
        return ""
    VarSetCapacity(buf, chars * 2, 0)
    if !DllCall("Crypt32.dll\CryptBinaryToStringW", "Ptr", &data, "UInt", len, "UInt", fmt, "Ptr", &buf, "UInt*", chars)
        return ""
    return StrGet(&buf, "UTF-16")
}

; The sender's slice of config.ini. The receipting keys (SubtractBy, timing, hide-columns,
; alerts...) belong to "Receipting worklist.ahk" since the 2026-07-18 split - that script
; reads AND writes them; this one never touches them. FanOut is the one shared key, so it is
; re-read per batch (ReconBatchBegin) rather than only at startup.


; ============================================================
;  invoice-recon fan-out  (additive; ReconApiUrl empty = all of this is inert)
;
;  Shape: every invoice is POSTed to the recon service fire-and-forget DURING the send, so
;  the existing send is never slowed. Each post carries a batchId. At the END of the batch we
;  make ONE synchronous /flags call, which waits server-side for the batch to finish and
;  returns the rendered text. That is why there is no polling loop or timer here.
; ============================================================

; Extract a JSON string value, honouring backslash escapes. The flag text is multi-line, so a
; plain regex would stop at the first \n and a non-greedy match would trip over escaped quotes.


ReconBatchBegin() {
    global ReconUrl, g_batchId, g_reconCount, g_reconReqs
    ; Re-read config: the fan-out switch now lives in the WORKLIST's Settings window, in
    ; another process. Reading it per batch is how this process learns a toggle happened.
    ReadConfig()
    g_batchId := ""
    g_reconCount := 0
    g_reconReqs := []
    if (ReconUrl = "")
        return
    Random, rnd, 100000, 999999
    g_batchId := A_TickCount . "-" . rnd
}

; BYD + Isuzu (recon-6 parses both deterministically; the service detects the brand from
; the PDF's own text, so the body needs no brand field). Other/unknown brands still ride
; the existing path untouched.
ReconFire(b64, brand) {
    global ReconUrl, g_batchId, g_reconCount, g_reconReqs, CfgFanOut
    if (ReconUrl = "" || g_batchId = "" || !CfgFanOut || (brand != "byd" && brand != "isuzu"))
        return
    body := "{""dataBase64"":""" b64 """,""batchId"":""" g_batchId """}"
    ; The returned WinHttp object MUST be kept alive or the async send is aborted at release.
    g_reconReqs.Push(HttpPostJson(ReconUrl "/parse-invoice", body, true))
    g_reconCount += 1
}

ReconBatchEnd() {
    global ReconUrl, g_batchId, g_reconCount, g_reconReqs, g_reconFlags, g_reconFlagsAt
    if (ReconUrl = "" || g_batchId = "" || g_reconCount = 0)
        return
    body := "{""batchId"":""" g_batchId """,""expect"":" g_reconCount "}"
    ; Short bound + no retry: this is the ONLY recon call that blocks the send, and recon is a
    ; nice-to-have riding on top of a send that already worked. At the defaults a dead host costs
    ; 34-51s per batch (measured). One 3s attempt caps it at ~3s. The receive timeout is untouched:
    ; a host that ANSWERS is allowed to think - /flags legitimately waits server-side for the batch.
    res := HttpPostJson(ReconUrl "/flags", body, false, "application/json", 3000, 1)
    g_batchId := ""
    g_reconReqs := []   ; async posts are long since done (or lost) - safe to release now
    if (res.status != 200) {
        SndLog("recon: flags failed http=" res.status " | " SubStr(res.text, 1, 200))
        return                       ; recon being down must never disturb the send
    }
    ; The batch just changed the worklist - nudge the worklist script if it's running (it
    ; refreshes only when it is actually on screen). BEFORE the hasFlags check: a clean batch
    ; still turns invoices ready. A PostMessage costs nothing and never starts the worklist.
    WorklistPing(2)
    if (!JsonBool(res.text, "hasFlags")) {
        SndLog("recon: no flags to show")
        return                       ; nothing to say -> no popup at all
    }
    full := JsonStr(res.text, "full")
    txt  := JsonStr(res.text, "text")
    if (full != "")
        SndLog("recon flags:`n" full)   ; the log always gets the UNCAPPED copy
    if (!JsonBool(res.text, "complete"))
        txt .= "`n`n(Some invoices had not finished reconciling - see sender.log.)"
    if (txt = "")
        return
    ; No blocking popup (Kaine, 2026-07-16): stash the text for the tray menu's
    ; "View receipting flags" and raise a quiet balloon instead.
    g_reconFlags := txt
    FormatTime, g_reconFlagsAt, , HH:mm
    TrayTip, Receipting flags, Some lines need attention - tray menu > View receipting flags, 5, 1
}

; --- MsgBox positioning ---------------------------------------------------------
; A dialog can't be moved from inside the message handler (it isn't up yet), so this only
; arms a timer. See the OnMessage(0x44) note in the auto-exec section for the why.


; Centre the dialog on the ERA Port window, else on the primary screen. Scoped to OUR pid:
; ERA's own dialogs ("Receipt All Parts") are #32770 too and must not be touched - the
; sender clicks those by handle and moving one under itself would be its own bug.

; Both scripts append to the SAME sender.log, in the same format, on purpose: the whole
; debugging method is matching a complaint to log bytes, and splitting the file would split
; the timeline. The worklist's copy of this function also feeds its activity-log pane.
; [snd] = this line came from the SENDER script (the worklist writes [wl]) - the tag is what
; tells the two processes apart in the shared file (Kaine asked for the tags 2026-07-19).
SndLog(msg) {
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    FileAppend, % ts " | [snd] " msg "`n", % A_ScriptDir "\sender.log"
}

; --- Custom on-screen toast (bottom-right). States: "load" / "ok" / "bad".


; ============================================================
;  Grab attachments straight from Outlook (reliable COM route)
; ============================================================
GrabFromOutlook:
    n := GrabFromOutlookCore("button")
    if (n > 0) {
        GuiControl, 1:, DropHint, %HINT_MORE%
        TrayTip, Invoice Sender, % n " PDF" (n=1?"":"s") " grabbed from Outlook.", 3, 1
    } else {
        TrayTip, Invoice Sender, No PDF attachment on the open/selected email., 3, 3
    }
return

MenuSendOne:
    AutoGrabAndSend(false)
return

MenuSendBulk:
    Gui, 1:Default
    Busy := false
    WinSet, Transparent, Off, ahk_id %hwndMain%
    Gui, 1:+AlwaysOnTop
    GuiControl, 1:Enable, BtnSend
    GuiControl, 1:Enable, BtnClear
    LV_Delete()
    Paths  := {}
    Brands := {}
    Seen   := {}
    GuiControl, 1:, DropHint, %HINT_IDLE%
    Gui, 1:Show
return

PasteFromClipboard:
    pcN := ClipboardGrabCore()
    if (pcN > 0) {
        GuiControl, 1:, DropHint, %HINT_MORE%
        TrayTip, Invoice Sender, % pcN " PDF" (pcN=1?"":"s") " pasted from clipboard.", 3, 1
    } else {
        TrayTip, Invoice Sender, No PDF on the clipboard - copy the attachment first., 4, 3
    }
return

ClipboardGrabCore() {
    Gui, 1:Default
    pcData := 0
    pcHr := DllCall("ole32\OleGetClipboard", "Ptr*", pcData, "UInt")
    if (pcHr != 0 || !pcData) {
        SndLog("clip: OleGetClipboard hr=" pcHr)
        return 0
    }
    SndLog("clip: reading clipboard")
    DiagFormats(pcData)
    EnumFormats(pcData)
    pcAsync := StartAsync(pcData)
    pcN := ReadHdrop(pcData)
    if (pcN <= 0)
        pcN := ReadVirtualFiles(pcData)
    EndAsync(pcAsync, pcN > 0)
    pcVt := NumGet(pcData + 0, 0, "Ptr")
    DllCall(NumGet(pcVt + 2 * 8, 0, "Ptr"), "Ptr", pcData)   ; IUnknown::Release
    return pcN
}

GrabFromOutlookCore(src, bulk := true) {
    ol := ""
    try ol := ComObjActive("Outlook.Application")
    if (!IsObject(ol)) {
        SndLog("grab(" src "): no running classic Outlook COM (new Outlook? falling back to clipboard)")
        return 0
    }
    mails := []
    try {
        insp := ol.ActiveInspector
        if (IsObject(insp)) {
            ci := insp.CurrentItem
            if (IsObject(ci))
                mails.Push(ci)
        }
    }
    if (mails.Length() = 0) {
        try {
            sel := ol.ActiveExplorer.Selection
            if (bulk) {
                Loop % sel.Count
                    mails.Push(sel.Item(A_Index))
            } else if (sel.Count >= 1) {
                mails.Push(sel.Item(1))
            }
        }
    }
    if (mails.Length() = 0) {
        SndLog("grab(" src "): no open or selected email")
        return 0
    }
    grabbed := 0
    for i, m in mails {
        atts := ""
        try atts := m.Attachments
        if (!IsObject(atts))
            continue
        cnt := 0
        try cnt := atts.Count
        Loop % cnt {
            att := atts.Item(A_Index)
            fn := ""
            try fn := att.FileName
            if (fn = "")
                continue
            SplitPath, fn, , , ext
            StringLower, el, ext
            if (el != "pdf")
                continue
            dest := GrabDir() "\" SafeName(fn)
            try {
                att.SaveAsFile(dest)
                if AddFile(dest)
                    grabbed++
            } catch e {
                SndLog("grab(" src "): SaveAsFile failed " fn " | " e.message)
            }
        }
    }
    SndLog("grab(" src "): " grabbed " pdf(s) from " mails.Length() " mail(s)")
    return grabbed
}

SendQueuedFrom(startCount, bulk) {
    global Busy, GLYPH_OK, Paths, Brands, g_lastId, g_lastLines
    if (Busy)
        return
    Gui, 1:Default
    total := LV_GetCount()
    if (total <= startCount)
        return
    if (!ResolveUnknowns())
        return
    Busy := true
    GuiControl, 1:Disable, BtnSend
    GuiControl, 1:Disable, BtnClear
    ReconBatchBegin()
    okCount := 0, failCount := 0
    queued := total - startCount
    row := startCount
    Loop {
        row += 1
        if (row > total)
            break
        path  := Paths[row]
        brand := Brands[row]
        ShowToast("load", "Sending to server...", "Invoice " (row - startCount) " of " queued " (" BrandLabel(brand) ")")
        LV_Modify(row, "Col4", "Sending...")
        Sleep, 30
        result := SendOne(path, brand)
        LV_Modify(row, "Col4", result)
        if InStr(result, GLYPH_OK)
            okCount += 1
        else
            failCount += 1
    }
    Busy := false
    GuiControl, 1:Enable, BtnSend
    GuiControl, 1:Enable, BtnClear
    SndLog("auto-send: " okCount " ok, " failCount " failed (from row " startCount ")")
    if (okCount = 0) {
        ShowToast("bad", "Send failed", "Tray icon > Open log for details")
    } else if (!bulk && okCount = 1 && failCount = 0) {
        det := (g_lastId != "" ? g_lastId : "Invoice") " confirmed sent"
        if (g_lastLines > 0)
            det .= " (" g_lastLines " line" (g_lastLines = 1 ? "" : "s") ")"
        ShowToast("ok", "Sent to server", det)
    } else {
        msg := okCount " invoice" (okCount = 1 ? "" : "s") " sent"
        if (failCount)
            msg .= ", " failCount " failed"
        ShowToast((failCount ? "bad" : "ok"), "Bulk send complete", msg)
    }
    ReconBatchEnd()          ; one round trip for the whole batch; may pop the flags MsgBox
}

AutoGrabAndSend(bulk) {
    Gui, 1:Default
    startCount := LV_GetCount()
    n := GrabFromOutlookCore("menu-single", false)
    if (n > 0) {
        SendQueuedFrom(startCount, false)
        return
    }
    BackgroundAutoDrag(startCount)
}

BackgroundAutoDrag(startCount) {
    global gDragX, gDragY, gOutlookHwnd, hwndMain
    ShowToast("load", "Sending invoice...", "Grabbing attachment")
    SysGet, wa, MonitorWorkArea
    winW := 484, winH := 470
    winLeft := gDragX - winW // 2
    winTop  := gDragY + 55
    if (winTop + winH > waBottom)
        winTop := gDragY - 55 - winH
    if (winLeft < waLeft)
        winLeft := waLeft
    if (winLeft + winW > waRight)
        winLeft := waRight - winW
    dstX := gDragX
    if (dstX < winLeft + 20)
        dstX := winLeft + 20
    if (dstX > winLeft + winW - 20)
        dstX := winLeft + winW - 20
    dstY := winTop + 90
    WinSet, Transparent, 1, ahk_id %hwndMain%
    Gui, 1:+AlwaysOnTop
    Gui, 1:Show, NoActivate x%winLeft% y%winTop% w%winW% h%winH%
    if (gOutlookHwnd && WinExist("ahk_id " gOutlookHwnd))
        WinActivate, ahk_id %gOutlookHwnd%
    Sleep, 150
    DragMouse(gDragX, gDragY, dstX, dstY)
    waited := 0
    while (LV_GetCount() <= startCount && waited < 2500) {
        Sleep, 100
        waited += 100
    }
    Gui, 1:Hide
    Gui, 1:+AlwaysOnTop
    WinSet, Transparent, Off, ahk_id %hwndMain%
    if (LV_GetCount() > startCount)
        SendQueuedFrom(startCount, false)
    else {
        ShowToast("bad", "Couldn't grab it", "Hover the PDF, then Ctrl+Right > Send")
        SndLog("bg auto-drag: nothing captured from " gDragX "," gDragY)
    }
}

DragMouse(x1, y1, x2, y2) {
    CoordMode, Mouse, Screen
    SendMode, Event
    SetDefaultMouseSpeed, 2
    MouseMove, %x1%, %y1%, 0
    Sleep, 150
    MouseClick, Left, %x1%, %y1%, 1, 0, D
    Sleep, 180
    nx := x1 + 6,  ny := y1 + 8
    MouseMove, %nx%, %ny%, 2
    nx := x1 + 12, ny := y1 + 16
    MouseMove, %nx%, %ny%, 2
    Sleep, 150
    steps := 16
    Loop, %steps% {
        nx := Round(x1 + (x2 - x1) * A_Index / steps)
        ny := Round(y1 + (y2 - y1) * A_Index / steps)
        MouseMove, %nx%, %ny%, 3
        Sleep, 25
    }
    MouseMove, %x2%, %y2%, 3
    Sleep, 300
    MouseClick, Left, %x2%, %y2%, 1, 0, U
    Sleep, 120
}

GrabDir() {
    d := A_Temp "\InvoiceSender"
    if (!FileExist(d))
        FileCreateDir, %d%
    return d
}

SafeName(fn) {
    SplitPath, fn, name
    name := RegExReplace(name, "[\\/:*?""<>|]", "_")
    return (name = "" ? "invoice.pdf" : name)
}

; ============================================================
;  OLE drop target - drop straight from an email.
; ============================================================
InitOleDrop(hwnd) {
    global g_vtbl, g_obj, g_oleActive, g_oleInit
    static cbQI, cbAR, cbRel, cbDE, cbDOv, cbDL, cbDrop
    if (A_PtrSize != 8 || !g_oleInit)
        return false
    cbQI   := RegisterCallback("IDT_QueryInterface", "", 3)
    cbAR   := RegisterCallback("IDT_AddRef", "", 1)
    cbRel  := RegisterCallback("IDT_Release", "", 1)
    cbDE   := RegisterCallback("IDT_DragEnter", "", 5)
    cbDOv  := RegisterCallback("IDT_DragOver", "", 4)
    cbDL   := RegisterCallback("IDT_DragLeave", "", 1)
    cbDrop := RegisterCallback("IDT_Drop", "", 5)
    if (!cbQI || !cbDrop)
        return false
    VarSetCapacity(g_vtbl, 7 * 8, 0)
    NumPut(cbQI,   g_vtbl, 0 * 8, "Ptr")
    NumPut(cbAR,   g_vtbl, 1 * 8, "Ptr")
    NumPut(cbRel,  g_vtbl, 2 * 8, "Ptr")
    NumPut(cbDE,   g_vtbl, 3 * 8, "Ptr")
    NumPut(cbDOv,  g_vtbl, 4 * 8, "Ptr")
    NumPut(cbDL,   g_vtbl, 5 * 8, "Ptr")
    NumPut(cbDrop, g_vtbl, 6 * 8, "Ptr")
    VarSetCapacity(g_obj, 8, 0)
    NumPut(&g_vtbl, g_obj, 0, "Ptr")
    hr := DllCall("ole32\RegisterDragDrop", "Ptr", hwnd, "Ptr", &g_obj, "UInt")
    if (hr != 0) {
        SndLog("RegisterDragDrop failed hr=" hr)
        return false
    }
    g_oleActive := true
    return true
}

IsEqualGUID(pGuid, strGuid) {
    VarSetCapacity(sg, 80, 0)
    DllCall("ole32\StringFromGUID2", "Ptr", pGuid, "Ptr", &sg, "Int", 40)
    return (StrGet(&sg, "UTF-16") = strGuid)
}

IDT_QueryInterface(this, riid, ppv) {
    static IUNK := "{00000000-0000-0000-C000-000000000046}"
    static IDT  := "{00000122-0000-0000-C000-000000000046}"
    if (IsEqualGUID(riid, IUNK) || IsEqualGUID(riid, IDT)) {
        NumPut(this, ppv + 0, 0, "Ptr")
        return 0
    }
    NumPut(0, ppv + 0, 0, "Ptr")
    return 0x80004002   ; E_NOINTERFACE
}
IDT_AddRef(this) {
    return 1
}
IDT_Release(this) {
    return 1
}
IDT_DragEnter(this, pDataObj, grfKeyState, pt, pdwEffect) {
    NumPut(1, pdwEffect + 0, 0, "UInt")   ; DROPEFFECT_COPY
    return 0
}
IDT_DragOver(this, grfKeyState, pt, pdwEffect) {
    NumPut(1, pdwEffect + 0, 0, "UInt")
    return 0
}
IDT_DragLeave(this) {
    return 0
}
IDT_Drop(this, pDataObj, grfKeyState, pt, pdwEffect) {
    global HINT_MORE
    NumPut(1, pdwEffect + 0, 0, "UInt")   ; DROPEFFECT_COPY
    Gui, 1:Default
    pAsync := 0
    try {
        SndLog("drop fired")
        DiagFormats(pDataObj)
        EnumFormats(pDataObj)
        pAsync := StartAsync(pDataObj)
        n := ReadHdrop(pDataObj)
        if (n <= 0)
            n := ReadVirtualFiles(pDataObj)
        if (n <= 0)
            n := GrabFromOutlookCore("drag")
        EndAsync(pAsync, n > 0)
        pAsync := 0
        if (n > 0)
            GuiControl, 1:, DropHint, %HINT_MORE%
        else
            SndLog("drop: nothing read from that drag")
    } catch e {
        SndLog("drop handler error: " e.message)
        if (pAsync)
            EndAsync(pAsync, false)
    }
    return 0
}

ReadHdrop(pData) {
    static CF_HDROP := 15
    if (!HasFormat(pData, CF_HDROP)) {
        SndLog("hdrop: CF_HDROP not offered")
        return -1
    }
    VarSetCapacity(fmt, 32, 0)
    NumPut(CF_HDROP, fmt, 0,  "UShort")
    NumPut(0,        fmt, 8,  "Ptr")
    NumPut(1,        fmt, 16, "UInt")
    NumPut(-1,       fmt, 20, "Int")
    NumPut(1,        fmt, 24, "UInt")       ; TYMED_HGLOBAL
    VarSetCapacity(stg, 24, 0)
    vtbl := NumGet(pData + 0, 0, "Ptr")
    pGetData := NumGet(vtbl + 3 * 8, 0, "Ptr")
    hr := 0, tries := 0
    Loop {
        hr := DllCall(pGetData, "Ptr", pData, "Ptr", &fmt, "Ptr", &stg, "UInt")
        if (hr = 0)
            break
        if (++tries >= 15) {
            SndLog("hdrop: GetData failed hr=" hr " after " tries " tries")
            return -1
        }
        Sleep, 100
    }
    hDrop := NumGet(stg, 8, "Ptr")
    count := hDrop ? DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0, "UInt") : 0
    SndLog("hdrop: tymed=" NumGet(stg, 0, "UInt") " hDrop=" hDrop " count=" count " tries=" tries)
    added := 0
    Loop % count {
        idx := A_Index - 1
        len := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", idx, "Ptr", 0, "UInt", 0, "UInt")
        VarSetCapacity(buf, (len + 1) * 2, 0)
        DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", idx, "Ptr", &buf, "UInt", len + 1, "UInt")
        path := StrGet(&buf, "UTF-16")
        SndLog("hdrop: file " idx " = '" path "' exists=" (FileExist(path) ? 1 : 0))
        if (path != "" && AddDroppedFile(path))
            added++
    }
    DllCall("ole32\ReleaseStgMedium", "Ptr", &stg)
    SndLog("hdrop: added=" added)
    return added
}

AddDroppedFile(srcPath) {
    if (srcPath = "")
        return false
    if InStr(FileExist(srcPath), "D") {         ; a folder -> queue every PDF inside it
        added := 0
        Loop, Files, %srcPath%\*.pdf
        {
            if AddFile(A_LoopFileFullPath)
                added++
        }
        SndLog("hdrop: folder " srcPath " -> " added " pdf(s)")
        return (added > 0)
    }
    SplitPath, srcPath, fname, , ext
    StringLower, el, ext
    if (el != "pdf") {
        SndLog("hdrop: skip non-pdf " srcPath)
        return false
    }
    size := WaitForFile(srcPath, 4000)
    if (size <= 0) {
        SndLog("hdrop: missing/empty after wait " srcPath)
        return false
    }
    dest := GrabDir() "\" SafeName(fname)
    if (srcPath = dest)
        return AddFile(srcPath)
    FileCopy, %srcPath%, %dest%, 1
    if (ErrorLevel) {
        SndLog("hdrop: copy failed " srcPath " -> " dest)
        return AddFile(srcPath)
    }
    return AddFile(dest)
}

WaitForFile(path, ms) {
    waited := 0
    Loop {
        if FileExist(path) {
            FileGetSize, sz, %path%
            if (sz > 0)
                return sz
        }
        if (waited >= ms)
            return (FileExist(path) ? 0 : -1)
        Sleep, 100
        waited += 100
    }
}

CleanupOle(reason := "", code := "") {
    global g_oleActive, g_oleInit, hwndMain
    if (g_oleActive) {
        DllCall("ole32\RevokeDragDrop", "Ptr", hwndMain)
        g_oleActive := false
    }
    if (g_oleInit) {
        DllCall("ole32\OleUninitialize")
        g_oleInit := false
    }
    return 0
}

HasFormat(pData, cf) {
    VarSetCapacity(fmt, 32, 0)
    NumPut(cf, fmt, 0,  "UShort")
    NumPut(0,  fmt, 8,  "Ptr")
    NumPut(1,  fmt, 16, "UInt")
    NumPut(-1, fmt, 20, "Int")
    NumPut(0xFFFFFFFF, fmt, 24, "UInt")
    vt := NumGet(pData + 0, 0, "Ptr")
    pQuery := NumGet(vt + 5 * 8, 0, "Ptr")
    return (DllCall(pQuery, "Ptr", pData, "Ptr", &fmt, "UInt") = 0)
}

DiagFormats(pData) {
    SndLog("  std: CF_HDROP=" (HasFormat(pData,15)?1:0) " CF_UNICODETEXT=" (HasFormat(pData,13)?1:0) " CF_TEXT=" (HasFormat(pData,1)?1:0))
    for idx, nm in ["FileGroupDescriptorW","FileGroupDescriptor","FileContents","FileNameW","FileName","UniformResourceLocatorW","text/html"] {
        cf := DllCall("RegisterClipboardFormatW", "WStr", nm, "UInt")
        if HasFormat(pData, cf)
            SndLog("  reg: " nm "=1")
    }
}

EnumFormats(pData) {
    vt := NumGet(pData + 0, 0, "Ptr")
    pEnumFn := NumGet(vt + 8 * 8, 0, "Ptr")
    pEnum := 0
    hr := DllCall(pEnumFn, "Ptr", pData, "UInt", 1, "Ptr*", pEnum, "UInt")
    if (hr != 0 || !pEnum) {
        SndLog("  enum: EnumFormatEtc unavailable hr=" hr)
        return
    }
    evt   := NumGet(pEnum + 0, 0, "Ptr")
    pNext := NumGet(evt + 3 * 8, 0, "Ptr")
    pRel  := NumGet(evt + 2 * 8, 0, "Ptr")
    VarSetCapacity(fe, 32, 0)
    Loop 40 {
        fetched := 0
        hr := DllCall(pNext, "Ptr", pEnum, "UInt", 1, "Ptr", &fe, "UInt*", fetched, "UInt")
        if (hr != 0 || fetched < 1)
            break
        cf     := NumGet(fe, 0,  "UShort")
        ptd    := NumGet(fe, 8,  "Ptr")
        aspect := NumGet(fe, 16, "UInt")
        lindex := NumGet(fe, 20, "Int")
        tymed  := NumGet(fe, 24, "UInt")
        SndLog("  enum: cf=" cf " " CfName(cf) " aspect=" aspect " lindex=" lindex " tymed=" tymed)
        if (ptd)
            DllCall("ole32\CoTaskMemFree", "Ptr", ptd)
    }
    DllCall(pRel, "Ptr", pEnum)
}

CfName(cf) {
    if (cf = 1)
        return "CF_TEXT"
    if (cf = 13)
        return "CF_UNICODETEXT"
    if (cf = 15)
        return "CF_HDROP"
    if (cf < 0xC000)
        return "std#" cf
    VarSetCapacity(nb, 512, 0)
    got := DllCall("GetClipboardFormatNameW", "UInt", cf, "Ptr", &nb, "Int", 255)
    return got ? StrGet(&nb, "UTF-16") : ("reg#" cf)
}

QI(pUnk, iidStr) {
    VarSetCapacity(iid, 16, 0)
    if (DllCall("ole32\CLSIDFromString", "WStr", iidStr, "Ptr", &iid) != 0)
        return 0
    vt := NumGet(pUnk + 0, 0, "Ptr")
    pOut := 0
    hr := DllCall(NumGet(vt + 0, 0, "Ptr"), "Ptr", pUnk, "Ptr", &iid, "Ptr*", pOut, "UInt")
    return (hr = 0 ? pOut : 0)
}

StartAsync(pData) {
    static IID_ASYNC := "{3D8B0590-F691-11D2-8EA9-006097DF5BD4}"
    pAsync := QI(pData, IID_ASYNC)
    if (!pAsync) {
        SndLog("  async: not supported (synchronous source)")
        return 0
    }
    vt := NumGet(pAsync + 0, 0, "Ptr")
    isAsync := 0
    DllCall(NumGet(vt + 4 * 8, 0, "Ptr"), "Ptr", pAsync, "Int*", isAsync, "UInt")
    hr := DllCall(NumGet(vt + 5 * 8, 0, "Ptr"), "Ptr", pAsync, "Ptr", 0, "UInt")
    SndLog("  async: supported, mode=" isAsync " StartOperation hr=" hr)
    return pAsync
}

EndAsync(pAsync, ok) {
    if (!pAsync)
        return
    vt := NumGet(pAsync + 0, 0, "Ptr")
    DllCall(NumGet(vt + 7 * 8, 0, "Ptr"), "Ptr", pAsync, "UInt", (ok ? 0 : 0x80004005), "Ptr", 0, "UInt", 1, "UInt")
    DllCall(NumGet(vt + 2 * 8, 0, "Ptr"), "Ptr", pAsync)
}

; --- Read "virtual files" (email attachments). Hardened with a GetData retry.
ReadVirtualFiles(pData) {
    cfDesc := DllCall("RegisterClipboardFormatW", "WStr", "FileGroupDescriptorW", "UInt")
    cfCont := DllCall("RegisterClipboardFormatW", "WStr", "FileContents", "UInt")
    if (!HasFormat(pData, cfDesc)) {
        SndLog("virtual: FileGroupDescriptorW not offered")
        return 0
    }
    VarSetCapacity(fmt, 32, 0)
    NumPut(cfDesc, fmt, 0, "UShort")
    NumPut(0,  fmt, 8,  "Ptr")
    NumPut(1,  fmt, 16, "UInt")
    NumPut(-1, fmt, 20, "Int")
    NumPut(1,  fmt, 24, "UInt")            ; TYMED_HGLOBAL
    VarSetCapacity(stg, 24, 0)
    vt := NumGet(pData + 0, 0, "Ptr")
    pGetData := NumGet(vt + 3 * 8, 0, "Ptr")
    hr := 0, tries := 0
    Loop {
        hr := DllCall(pGetData, "Ptr", pData, "Ptr", &fmt, "Ptr", &stg, "UInt")
        if (hr = 0)
            break
        if (++tries >= 15) {
            SndLog("virtual: GetData descriptor failed hr=" hr " after " tries " tries")
            return 0
        }
        Sleep, 100
    }
    hG := NumGet(stg, 8, "Ptr")
    pDesc := DllCall("GlobalLock", "Ptr", hG, "Ptr")
    added := 0
    if (pDesc) {
        cItems := NumGet(pDesc + 0, 0, "UInt")
        SndLog("virtual: " cItems " item(s) in descriptor (tries=" tries ")")
        Loop % cItems {
            i := A_Index - 1
            fname := StrGet(pDesc + 4 + i * 592 + 72, 260, "UTF-16")   ; cFileName offset
            SplitPath, fname, , , ext
            StringLower, el, ext
            if (el != "pdf") {
                SndLog("virtual: skip non-pdf '" fname "'")
                continue
            }
            dest := GrabDir() "\" SafeName(fname)
            if ExtractContents(pData, cfCont, i, dest) {
                if AddFile(dest)
                    added++
            } else {
                SndLog("virtual: extract failed '" fname "'")
            }
        }
    }
    DllCall("GlobalUnlock", "Ptr", hG)
    DllCall("ole32\ReleaseStgMedium", "Ptr", &stg)
    return added
}

ExtractContents(pData, cfCont, index, dest) {
    VarSetCapacity(fmt, 32, 0)
    NumPut(cfCont, fmt, 0,  "UShort")
    NumPut(0,      fmt, 8,  "Ptr")
    NumPut(1,      fmt, 16, "UInt")
    NumPut(index,  fmt, 20, "Int")
    NumPut(4|1|2,  fmt, 24, "UInt")        ; TYMED_ISTREAM | HGLOBAL | FILE
    VarSetCapacity(stg, 24, 0)
    vt := NumGet(pData + 0, 0, "Ptr")
    pGetData := NumGet(vt + 3 * 8, 0, "Ptr")
    hr := 0, tries := 0
    Loop {
        hr := DllCall(pGetData, "Ptr", pData, "Ptr", &fmt, "Ptr", &stg, "UInt")
        if (hr = 0)
            break
        if (++tries >= 15) {
            SndLog("virtual: GetData FileContents idx " index " hr=" hr " after " tries " tries")
            return false
        }
        Sleep, 100
    }
    tym := NumGet(stg, 0, "UInt")
    ok := false
    if (tym = 4) {                          ; TYMED_ISTREAM
        ok := ReadStreamToFile(NumGet(stg, 8, "Ptr"), dest)
    } else if (tym = 1) {                   ; TYMED_HGLOBAL
        ok := WriteHGlobalToFile(NumGet(stg, 8, "Ptr"), dest)
    } else if (tym = 2) {                   ; TYMED_FILE
        src := StrGet(NumGet(stg, 8, "Ptr"), "UTF-16")
        if (src != "") {
            FileCopy, %src%, %dest%, 1
            ok := !ErrorLevel
        }
    } else {
        SndLog("virtual: unexpected tymed=" tym " idx " index)
    }
    DllCall("ole32\ReleaseStgMedium", "Ptr", &stg)
    return ok
}

ReadStreamToFile(pStream, dest) {
    if (!pStream)
        return false
    f := FileOpen(dest, "w")
    if (!IsObject(f))
        return false
    vt := NumGet(pStream + 0, 0, "Ptr")
    pRead := NumGet(vt + 3 * 8, 0, "Ptr")   ; IStream::Read
    chunkSize := 1048576
    VarSetCapacity(chunk, chunkSize, 0)
    total := 0
    Loop {
        got := 0
        hr := DllCall(pRead, "Ptr", pStream, "Ptr", &chunk, "UInt", chunkSize, "UInt*", got, "UInt")
        if (got > 0) {
            f.RawWrite(&chunk, got)
            total += got
        }
        if (got = 0)
            break
        if (hr != 0 && hr != 1)
            break
    }
    f.Close()
    return (total > 0)
}

WriteHGlobalToFile(hG, dest) {
    if (!hG)
        return false
    p  := DllCall("GlobalLock", "Ptr", hG, "Ptr")
    sz := DllCall("GlobalSize", "Ptr", hG, "UPtr")
    ok := false
    if (p && sz) {
        f := FileOpen(dest, "w")
        if (IsObject(f)) {
            f.RawWrite(p + 0, sz)
            f.Close()
            ok := true
        }
    }
    DllCall("GlobalUnlock", "Ptr", hG)
    return ok
}

; Ctrl+V pastes a copied attachment while the tool window is active.
#If WinActive("ahk_id " hwndMain)
^v::Gosub, PasteFromClipboard
#If

; Ctrl+Right-click over Outlook opens the Sender menu.
#If WinActive("ahk_exe OUTLOOK.EXE") or WinActive("ahk_exe olk.exe")
^RButton::
    CoordMode, Mouse, Screen
    MouseGetPos, gDragX, gDragY
    WinGet, gOutlookHwnd, ID, A
    Menu, SenderMenu, Show
return
#If

; Global hotkey: Ctrl+Alt+I shows the Invoice Sender window
^!i::Gosub, ShowMainWindow

; ` (backtick, SC029) destroys the current window and builds a fresh one.
; Scoped: only fires over the tool window or Outlook, so typing ` in
; Notepad/ERA/etc. doesn't wipe the queue.
; Global hotkey: ` (backtick, SC029) destroys the current window and builds a fresh one
SC029::
    if (Busy)            ; never rebuild mid-send
        return
    Gosub, BuildGui      ; tears down old window + builds new (hidden)
    Gui, 1:Show          ; show the fresh window
return



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
AAABAAYAEBAAAAEAIADDAQAAZgAAACAgAAABACAA0QIAACkCAAAwMAAAAQAgACIDAAD6BAAAQEAAAAEAIADJAwAAHAgAAICAAAABACAAVgcAAOULAAAAAAAA
AQAgAN0MAAA7EwAAiVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7D
AcdvqGQAAAFYSURBVDhPY2AgAoRqMbChixENCl0YvEo8GZrRxYkCGVYM6p1xDM+KPBny0eUIghhXBu7uOIZDG5oZvqdYMfijyxMEjWEMM2+vYfi5vJLhcYoN
gzG6PF5QE8KQsm8Cw+v/Zxj+T05nuJ1izZCdas0QhYxBLkTXBwapdgy6C0oZHoI0g/C1ZQz/T85E4EOTGf63RzPcTDZnEEfXy5BpwyDYn8Rw8ushiGZseFUN
w6NiLwY7dL3guG6LZFj6ZDOmJhi+uJDhZ3UAQx26XjCoDWWoWFLG8APZuciGvdvL8L8tmmE3zkSVasPgghxIKdYMNavrGJ6BNP8+wfB/WhbDtRR7Bhl0fThB
qjWD585uho8gAza1MLwEpUh0NXhBjiND6pm5DP8vL2H4WRPM0I4uTxDUBDF0gwxoi2I4hNPf+EBDGMPS/mSGR6D8gC5HFKjwY9hW5sMQhS6ODgChQ6x/dAmR
hgAAAABJRU5ErkJggolQTkcNChoKAAAADUlIRFIAAAAgAAAAIAgGAAAAc3p69AAAAAFzUkdCAK7OHOkAAAAEZ0FNQQAAsY8L/GEFAAAACXBIWXMAAA7DAAAO
wwHHb6hkAAACZklEQVRYR92WS2gTYRSFz8qNK1duXLkRBFcufGSIiBVsUYt2EqURHzXjIwZqLZZWmpoYSdEqFovVIIpifaDtRos0VBEiikGhi0IhhC6qVarU
R6GC1cXIWQTjHexMJjOz8IOzmf/OPf/M/R8X+B/Yp2Dpro1YKJ97Ao1PbEOmYQ38cswTkjtw89xeTB5ai2VyzHVitYi86MXXzhDynpdA82PFjeOY+PESekLF
iBx3lf2rsPjiAYzQfOox9HgAAzLGNQLLsSAVwgCN9TfQx+5Ab92CpIxzjVgAra+vYpbmVLYHP8MKVBnnCk1VqHl4Gh+L5tSDDnwI+7BaxjpOeB2W9EYw9uvV
H3PqyhGMaz5Uc1GayfZO4Ytn9mD4y9O/zalMF2a4G8zUreF98yZEZG5LJIJIF/oxJ82tihNPhTDMBSxzm9KyGfVPzmNaJrUqloylYwllblNYt74WFGTdy9HQ
WUwf3YBamduUwwoWXWhA7nvWmNSqWDaWT+a2RDyI25OPjEmtauYZ9K7dyNpa+fKwKVcs2fUm5G3dkM018KejmOLXzydpWirekLwpZW5LHKtGI3//fIptx/P8
PaMxxckxRuZ1lI46XBrvN5pzwXLhcgHLdxzlVBCDnzLGCfDE49aV8Y7DBoS9QKl5Lo3Ztq1olLGOw+M0uRP5UnP2BuwRbB215cIjtecgCkVz/gl2R+ySZKwr
hBWsvNuGd8UJ3G/HW25dGecamoKqwRQ+03y0D3PtdeiUMa6i+VCfS1d4xVYCG9DRWxVcsZUSV3HtchTf2B/KMU84qWIooaJbPveM6Hpotq7Yf/Ab4ml1zHFM
KT0AAAAASUVORK5CYIKJUE5HDQoaCgAAAA1JSERSAAAAMAAAADAIBgAAAFcC+YcAAAABc1JHQgCuzhzpAAAABGdBTUEAALGPC/xhBQAAAAlwSFlzAAAOwwAA
DsMBx2+oZAAAArdJREFUaEPtmE9IVFEUxr9Vm1at2rRqEwStWkQ1jIumjQVRzgwyRpA5ZVZWhJIx4mimgYRQMCRTEFQWkRRlQVQIQpEkuBCkyUX/XJRkEhQU
Ll58xcPHmTc19O5h7qN+8G1m7txzBu7c83sD/OcfILEaSxqr0CJfDw2ZGvR21GBcvh4KjsZQnW/GfDaBIfme9eyOYOX5Q3gxNQgnswN98n2r2bkZS/t2YfTz
CJyxATjpjUjJNVbTmcTA9E18d8bh3O7CbP16ROUaa2nditSjM/jI5pn8Ebxq3IBVcp2VpKNYc6kFb9zmmd46FHik5Frr2B/Bsv56jH0dXWz+21M4nXFMyLVW
kk3i6szdxeaZ9/fhhOIKbU/g+PM8vnibZwrXQ3CFHqtG9EYGb2XzjPVX6J51WH52LyZ41mXzjNVXKCXtVArDsw+KG3dj9RVKSZu88mtYlUruAOY64nj5tzmx
HYOyrhEoaXe68UE2bDIchhyKsnZgXElbeFZc1FSoIdQRWTswXkmTRU2Fe7OGyvT2SppW1H74UtI08iSH+fZtaJK1A+MnaaZDDaGOyNqB8ZM00+HerMFasn5g
/CTNdK614V1DBGtl7cCUkjST4f6sI2sH5neSZirU7Z46DFFLZP1A/EnSTIR7swZryfqBObgJ/dJLykm+GTOy0VKhilBJZO2KwWNwshYF2ahfKIGUQblHRWmo
wopz+zAtm5X59PjnuX9o/NwHpZxhRwHMNWGKX1Z+vuKkI4gN92BONu2NmiKbgM++fAaWTbtRU2RTtG5B2+Tl4sYZVUU2RTaOi69vFTfPqCmySbqS/g/4aops
Gv6FKCe3miKbxm+IqSqyafyGmJoiayCHmJoia+EdYmqKrIk7xFQVWRN3iFmnyOXCIXbvNBasU+Ry4RDrrsVIqM69l8MxXLBSkW3nB8IsUi8Wflp1AAAAAElF
TkSuQmCCiVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQA
AANeSURBVHhe7ZpNSFRRHMXPqk2rVm3aB0GrFoUjRmCLkUooZyANiZzpw4KyDzEYSzOSklASBBGrhVb0QVEgRJZgFEmCi0KYXFQWUhSFkKS0eHFGHkz/GX13
Bu+9dvUHZzPvof/jfPzPuSOwzDKLhsg6rJCPLRlqilFyMowm+fiS4GAB1l6sxMTxMI7Ka86zZytWtlRi8EETfscKUCqvO09jFJ1jdzFz8zQ+xQqxQV53mkQZ
Ys/a8M0bhtd+AGOxzVgj73GWeBHWXz+FjzRPnS3DO3mPsxwqxKrWfRiaGpw1/+MpvHMR9Mv7nIS7/sJu9H5+NGue+nAfXkMZuuW9TlIfQd3rLvzyzVMj1+At
iRV4ogRFtxMYTzdPDbRhyvkVWLURq6/sx8j0y3/NU86vwNT7vgJP+GEnzVPOr8DELjS/6cGMNO7L6RXIkvPwPL5K076cXoEsOVdrkPzzKtO4L2dXoF9yJgcy
TafL2RXolxxpWMrJFZhecoLk3AqUJSdIqRUYwuF4COULKb4F5WzakSVHRaM34A11LpwG2+E1VyDJ4CXn00q2kmNDjNqM3HI+7WQrOabFsMXQJWfTzlwlx6QY
qBi3jR+tz1dyTIlBq6Mao8b7RFDJMSVGbUZuOZ92gkqOCTFsMXTJ2bQTVHJMiDGbcdv4zlcpObrF380ZOIucTyuqJUe3+i/je+02lMv5tKNacnSKYashil45
m3ZyKTm6xJjNuM3YLefTSq4lR5c4A2eR82kln5KjQy868LO+FNVyPq0slpLzpS8Vde8Zj7osOT21mJa1Mx/l+0dkzGbcNl5xSbwQxfKwIR/FQkjcOYMJaU5F
1iruQhIPIfy4BZPSXJBYsfkqlD/vv+PIFsSHuzMNzidrFVcHddvRxOMvaXIuWau4umByy+VD0FrF1UVjFM9V+4O1oy2dNETwVqU9Wqu4OmGSvLQXSWlWylrF
1Q0NdR3De2lYylrF1U0shE1BIcja0ZYJ+OUnvwSVpn1Zq7imCApBViquSRI70ZK8lWmcslJxTTNXCLJ2tGWabCHIasU1Df8LTD77TlRcFbKFIGcqrgoyBFk7
2rJFeghyruKqkB6CnKu4KvghyMmKqwJDEE+EnTnayhUGndYqjDtXcVWp24E+JyuuKk6XHBf4C/gOYgqaVQPFAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhE
UgAAAIAAAACACAYAAADDPmHLAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAbrSURBVHhe7Z1RiBV1GMW/p156
6qmX3gOhpx6Ke69amIRRLJERmRtbO3fX1bDEkqQNE8mStqw1KqPyYaESrBBFsLBiiUpYKpCSoiKoKCRaRCwxY+Ls7e/d/nd3Z+7emZjv+86Bg7C7sjD/2fl/
5/xm5opQFEVRc2jwGrk8/hrlRElN+pKGXB1/nXKgdTW5stmQt3kFcKiRhlyW1OU1nADx9ygHShryxIM3yfGkJi/F36OMq1mXNZtXySc775JfkrqMxt+nDAsD
3/rr5b1n7pVz2++Q75OGNOOfoYwKw16zJvt33S2/vbBe0tFb5ctmXVbFP0cZ1O1L5JLBujy9bbV8e3inpAd3SDozAzAC+hAu9Vtulql9myU997Gk+HfjCvmQ
EdCBmg25YcMKObZnWM7/ekTSvz6VdHxIUkZAB0qWyxXDS+Xgrn6ZPjEhaTol6e/HJB0bkDOMgMaFfR+LvONO+fHdsdbiw98dkPTJtXKKEdC4sMBb++SLiYda
l/1wAny+T1JGQOMC5MGQ9+IGuYBLflh8+P3djICmBcgzcp0cGrtH/sDlfvbiw4yAhhUgD2reyT2diw8zAhoWIA8u7/tH/7vvBzMCGlaAPK88IOnZyc7FhxkB
jWo25PnpUOfCB2MmIAU0ptmQ5/jezkWfbUZAYwqQB4sKyBMveGxEwEf65AQjoBHFkCde8NiMgIYUQ554secyThT8H0ZA5QqQ56kBOR0gT5YRAZ9N5G9GQOWa
D/JkmRHQiOaDPFlmBDQgQJ5NN8pHc0GeLDMCKlcW5MkyI6Bi5YE8WWYEVCxAnkdvk5PzQZ48ZgRUqjyQJ8uMgEqVF/JkmRFQoXCpHm7IgTyQJ8uMgMrULeTJ
MiIgngpiBFSibiFPlhkBFWkxkCfLiIAYJBkBK64AeTCw5YU8eYwrCYZJRsAKa7GQJ8uMgEqECR37dLeQJ8uIgMDGjIAVVi+QJ8shAuK+QTSKKlyX7WtXyqXx
cTKpXiFPlhEBUSShT6i68dDquuVyFINwfJxMqgjIk+XTH0iKFrHK/uEdSVF14z6HwZpsio+TWeFyt221fNML5LFgnPwYfvHHgGE4Pk4mVQTksWBse9j+EH+x
HcbHyaSKgjzaje0Jgy8GYAzC8XEyqYuQp1+me4U82v3WY613FbiBVEVDHs3Gyf8voZzAMBwfK5MqGvJoNbY9bH/YBpvL5Kr4OJkUsi1ezFAk5NFoDLwYfDEA
YxCOj5NJlQV5NBpbH6IvInB8nEyqLMij0Wgl0fihlnZDJjHhYtItGvJoM7Y9bH+41yGpy7XxcTKpMiGPJuPEx+CLAdjNbWllQx5NxtaH6Nusy7iLqjdAHtCt
siCPFn/1eut+BAzBGIbjY2VShDwtY9t7fkQuIP66QbyEPC3jxMcfgCvEC8iDKdc75IHdIV5CnrbdIV5Cnrax7blDvIQ8bbtDvAHyYNr1DHlgd4iXkKdtd4g3
QJ7H18jP3iEPtj1/iJeQ56LdIV5CnrbdIV5CnrbdId4AeXDGe4c82Paw/blCvIQ8bbtDvIQ8bbtDvAHy7B6U894hjzvEOxvy7L2vVXVWyfEClWl3iDdAHjyz
jst/lfzwLfIZTsh4kcq0O8SLt1Sg1qya0UPcv1Im39jauUhleQbxDsgZN4i3ykLmRvzC69/ihSrDGHpf3ugM8VZZWAS8UAovgIwXqwxj1nCFeKuupCYDePXr
/3HnkTvEq0HNhmzBMIY8Hi9YkQ6Id+bFTR4QrxahkUQdXWYnAcSLO5yQONwgXi1CDAOMKpNEukO8mpTU5TBe/1oWj3CHeDUJgxhuuwKTiBeuCJ862kK8+B0u
EK82oYRBHi+jBHKJeLUplEBlPH/gDvFqFEoglDJFl0CIlABebhCvVoUSaOrVzkVcrPHCRleIV7NQAuFW9KJKIHeIV7uKLoHcIV7tCiUQLtvxYnZrvKadiFeZ
UAKND/V+UyoRr0IVWQIR8SpUUSUQEa9SFVEC4WkeIl6l6rUEIuJVrl5LICJe5Qol0Ndvdi5ulol4DWimBOqX6W5LINw4QsRrQIspgYh4DSmUQPEiL2QiXiNC
XscDqt2UQES8hhRKIJC7eKHncvhMPiJeI8LwhgdC85RARLwGFUqgPK+mIeI1KJRAGOaySiAiXqPKUwIR8RpWnhKIiNewskogIl7jWqgEAuJ9rilniXiNaqES
iIjXgRYqgYh4HWi+EgifUUDE60BzlUBAvOPD8icRrwOFEgg3dWDxiXidCSUQIl4ogYh4nSmUQIh7OAmIeJ0JJVD4NFIgXkRCIl5HCiUQEa9DhRIIJwARr0Oh
BELLR8TrVOFxMLwdnIjXobDoQ0vlCBGvU6EEIuJ1LJRARLyOxcWnqB71D4saEMI243cEAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYA
AABccqhmAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAxySURBVHhe7d1fqORlHcfx71U3XXXVjVfdBEFXXrTN
TC6hEhvKEq5UZrK6M2IalViLSyu6SVtuW8aGoVDrxYK6kEG0yG5hxZKVsFiwpCgVQYWxSCFRSBEnvjPz2PidZ/aZc+b353m+z/sFHxR3Xc96fs+c32++389Z
EQAAAAAAACDiwPvknePdcoX95wCcu/E98rYDQ/n6p0byDvtjAJwbj2QyGcn37T8H4Nx4KLvGQzkzGcoJ+2MAHNNnfv3Kry8A46Ectj8OwCl97h8P5NH54T8z
Hsh++3MAOHVgIHe/efhnjwB77M8B4NB4IHv10N/+AXnmzg/Kj6cvAFfJe+3PA+DMHQN5d3juP/oJefWO3XJO/54RIODczdfK28dDOakH/vBH5LcPH5B/T7/6
MwIE/BsP5Yge+Ls/JD//5lj++9An5e+MAIEKTIZykx52feY/fqv868TtsvXlm+QvjAAB5/QNvvBu/0O3yGt6+DX375NXGAECjk1LPkM5pQddD3w4/Jp7r5cX
GAECToWSjx7yz39Yng8H/9t3zv6q7wUwAgSc0pKPHvC7rpZn9R1/PfTPPyZbj3169gLACBBwKpR8dNlH3+3XA3/mqGz98/zs8DMCBJxaLPkc+aj8QQ/84/fI
1hu/kK2/PjN7AWAECDi0WPI5tFd+E5759eBvXZCtF5+YvQAwAgQcCiWfz1wtP9NlHz3sF0/NDr/muUcYAQIuLZZ8ju+Xf+hB/9Hx/x9+zdljjAABd2zJRw/5
qS/I1n9+9dYXgCcPMQIEXLElHz3gOur727NvPfwaRoCAM7bkowf8999bPvyMAAFnYiWf899aPvwaRoCAI7GSz+nDy8/9IYwAASdiJZ/vfG52m28PfggjQMCB
VSWfP/9w+dAvhhEg4MCqko898DaMAIHCrSr52MMeCyNAoGCXK/nYw27DCBAoWKrkkwojQKBgqZJPKowAgUKtU/JJRd8kZAQIFGbdkk8qjACBwmyn5JOKbggy
AgQKsm7JZ50wAgQKsp2STyo6JmQECBRiuyWfVBgBAoXYScknlZefYgQIZG+nJZ9UGAECBdhpyScVRoBA5jYp+aTCCBDI2CYln3XCCBDI1KYln1QYAQIZ27Tk
kwojQCBTTZR8UmEECGSoqZJPKowAgcw0WfJJhREgkJkmSz6pMAIEMtJkyWedMAIEMtF0yScVRoBAJtoo+aTCCBDIQFsln1QYAQIZaKvkkwojQKBnbZZ8UmEE
CPSo7ZJPKowAgZ60XfJZJ4wAgZ60XfJJhREg0JMuSj6pXDrHCBDoXFcln1QYAQId67Lkk8qF7zICBDrVZcknFX3kYAQIdKTrkk8qjACBjnRd8lkn2jNgBAi0
rI+STyqMAIEO9FXySYURINCBvko+qTACBFrWZ8knFUaAQIv6LvmkwggQaEkOJZ9UGAECLem75LNOGAECLcih5JMKI0CgBbmUfFJhBAg0LKeSTyqMAIGG5VTy
SYURINCg3Eo+qTACBBqSY8knFUaAQANyLPmsE0aAwIZyLfmkwggQaECuJZ9U7AiQtBd9b8heN3Ag55JPKpERIGkjI/mKvW7gQO4ln1TCCJA0H70e9LqYDOS0
vj9krx0UroSSTyphBEiajd4J6h3h/A5gl7124EAJJR/SXV58Ynb49VrQa2J+6z+x1w0cKKHkQ7qLrnjr3Z9eB3o3OL31H8oJvUu01w4KV0rJh3QT/bzr51+v
gwc/Ln+aHn69PnbLFfbaQeFKKvmQbvKTh2eHX+8Ew3P/ZCTX2GsHDpRU8iHtRz/34bk/rFLre0P2uoEDpZV8SLt5/aezuz+9DvRucP6O/0me+x0qseRD2ot+
3kOJSt8HCs/9+v6QvXZQuFJLPqS96Jq3XgffuE3eCCUqnQzZaweFK7XkQ9qLfu7DdXDPHvnl/M6Q76LkUaklH9JO9K4v1Kff/A5KQzml0yF77aBwJZd8SDt5
+oH5qu8t8lp4T4hvoOJQ6SUf0nx+/fjs8OudoE6Cpoefiq8/Hko+pNno5z6s+h68Ti5Mv/pT8fWJkg9ZjN716d2fXgeLFV++dZpDlHyIzdlj8+d+Kr6+UfIh
NlR8K0HJh9jEKr66E8Kqr0P6ho5+gin5EA0V34pQ8iE2VHwrQcmH2FDxrYSWfHSco59gSj5EE634DuRRnvudoeRDbKj4VoSSD7Gh4luJ294vV+knl5IPCaHi
WwlKPsSGim8lKPmQWKj4VmIykoP6yaXkQ0Ko+FaCkg+xoeJbCUo+xIaKbyUo+ZBYwp+KTMXXOUo+xGax4qt7IPNbfyq+3lDyITZUfCtByYfYUPGtBCUfEove
/em1QMXXMUo+JJbFiu9nr5Xz01t/Kr7+UPIhNlR8K0HJh8QSq/jeOpJ32esHBaPkQ2IJFV+dAlHxdYqSD4mFim8lKPkQmxUV35NUfJ2h5ENi+cGD81VfKr5+
UfIhsYSKr35rLyq+TlHyIbFQ8a0EJR9iE6v46rf2ouLrDCUfEgsV3wpQ8iGxUPGtACUfEgsV3wpQ8iGxrKr46hcLew2hYJR8SCxUfCtAyYfEQsW3ApR8SCxU
fCtAyYesChXfClDyIbFQ8a0AJR8SCxXfClDyIbFQ8a0AJR+yKlR8K0DJh8RCxbcClHxILFR8K0DJh8RCxbcClHzIqlDxdW5VyYeko8/F9sB4ChXfCsRKPmS9
vPzU8qHxEiq+FQglH7K9fG2/vK4Hw+tKdLTiO5DTVHwdWSz5kO1FR2F6OLQQYw+Ph1DxBYz5gtR0NTo8AtiD4yGLFV/tgOjvmYovqqd3THoY9L0SPSA6GrOH
p/RQ8QVWGI/kSj0QWoDRA6I7EvYAlZ5YxVdf+Oz/C6A6+gyshyJ8X4Szx5YPUMmh4gtcRliTvu8GeUkPiqcV6cWKr3ZA5m92UvEFAn0jTA/Glz4mf9SD4mUJ
iIovsIbxUI7o4QjfH8HLElCs4qvfD8L+/oGqhe+N6GkJiIovsKZQlvKyBLRY8dUOyPSrPxVfYJm3JSAqvsA2eFsCilZ8R3Kl/X0DcLYEFCq+2vyk4guswcsS
EBVfYAc8LAFR8QV2yMMSEBVfYIdKXwKi4gtsoOQlICq+wIZKXgKi4gtsoOQlICq+wIZKXQKi4gs0oMQlICq+QENKXAKi4gs0xC4BPffI8oHLKVR8gQaVtARE
xRdomF0C0qUae/ByCBVfoAWlLAHFKr76R77b3w+AbbBLQDn+kelUfIEWlLAERMUXaEnuS0BUfIEW2SWgpx9YPoR9Jlbx1T/y3f4+AOxAzktAVHyBloUlIF2n
1cOWyxLQYsX3i3vl4vRNPyq+QLNyXQLSRxH9eKj4Ai0KS0BfvVku6YHLYQkoVvGdDGWP/dgBbCi3JaBQ8dXnfiq+QMvCEpAu2OjB63MJiIov0KHcloDOHJ2v
+s4rvvrcT8UXaElYAtIRmx68PpeAqPgCHctlCWix4qsfy/TWn4ov0K4cloB01ZeKL9CDHJaAqPgCPel7CYiKL9CjPpeAFiu+914vL+jHQcUX6FBfS0D63P/k
ISq+QK/6WgKi4gv0rK8lICq+QAb6WAKi4gtkoo8lICq+QCa6XgKi4gtkpMslICq+QGa6WgKi4gtkqKslICq+QIa6WAKKVXzHI9lnPxYAHWt7CYiKL5CptpeA
qPgCGWt7CYiKL5CxNpeAohXfgey3HwOAnrS1BETFFyhAG0tAVHyBQrSxBBSr+I6Hssv+twH0rOklICq+QEGaXAKi4gsUpsklICq+QEGaXAKKVnxHco39bwLI
RFNLQFR8gQI1sQS0WPG97wZ5aX74qfgCuWtiCYiKL1CoTZeAqPgCBdtkCYiKL1C4nS4BLVZ8798nv5s/91PxBUpil4AunVs+7LFQ8QUc2MkSEBVfwAG7BKTP
8/aw2yxWfA9eJxf036fiCxRou0tAVHwBR7a7BETFF3DELgHpG3v20IfEKr7jodxlf00AhVh3CWix4qsvFvM3/aj4AiWzS0AXTy0ffg0VX8ChdZaAqPgCTqWW
gGIV38lIDtpfB0CBLrcERMUXcCy1BETFF3DscktA0YrvQPbaXwNAoVYtAVHxBSoQWwKi4gtUIrYERMUXqIRdAjp9eLniqy8S9t8D4IBdAgqh4gtUwC4Baaj4
ApWwS0BUfIFK2CUgKr5ARewSEBVfoCKLS0BUfIHKhCUgfQGg4gtUJiwBhVDxBSoSloDmoeIL1CQsAVHxBSoUloCo+AIVmi4BUfEF6jNfAqLiC9RIZ/1UfAEA
AAAAHfsfpnYYHI3/T/0AAAAASUVORK5CYII=
)"
    return s
}
; ============================================================================
;  END EMBEDDED ICON BLOCK
; ====================================================

; ---- merged build: worklist lives IN THIS PROCESS (dock merge 2026-07-20) ----
; The old two-process Start/Hwnd pair is reduced to "our own script window". WlPing
; still arrives via PostMessage(WL_MSG) so the wParam contract is unchanged.
WorklistStart(wait := false) {
    return A_ScriptHwnd
}
WorklistHwnd() {
    return A_ScriptHwnd
}

; ============================================================================
;  WORKLIST SECTION  (was: Receipting worklist.ahk v2.14.0)
; ============================================================================


; `... <copy> stalecheck` calls the REAL RcpExportAgeHours() and prints what the gate
; would decide, without a GUI and WITHOUT a receipt run. Added 2.13.1 because the honest
; way to test the stale gate is otherwise to start a real run with dry-run OFF - and if
; the gate failed to fire, that types into ERA. This asks the same question with nothing
; at stake. The gate itself is two comparisons on this number; get the number right and
; the gate is right. ReadConfig() first - CfgStaleHours/Mode come from config.ini.
WlAutoExec:
if (A_Args.Length() >= 1 && A_Args[1] = "stalecheck") {
    ReadConfig()
    age := RcpExportAgeHours()
    verdict := (age < 0) ? "UNKNOWABLE -> treated as fresh, gate stays quiet (this is what the 404 bug looked like)"
             : (age < CfgStaleHours) ? "fresh -> proceed"
             : (CfgStaleMode = "block") ? "STALE -> WOULD BLOCK the run (nothing typed)"
             : "STALE -> WOULD WARN (continue? dialog)"
    FileAppend, % "recon=" (ReconUrl = "" ? "(unset)" : ReconUrl)
               . "`nage=" age "h  limit=" CfgStaleHours "h  mode=" CfgStaleMode
               . "`nverdict: " verdict "`n", *
    ExitApp
}

global WL_MSG := 0x8001   ; sender -> worklist ping. wParam 1 = show + refresh, 2 = quiet refresh.

; ---- globals ---------------------------------------------------------------
; BUMP THE MINOR ON EVERY ITERATION PASS (Kaine, 2026-07-19): the number in the title bar /
; tray tip is how he tells at a glance which build is live. 2.10.0 = THE BRAND STRIP (Kaine,
; 2026-07-19, layout option 1 of five): a Make column between Invoice and Order, a radio
; strip above the list that filters to one of the four brands, and the Settings "Columns"
; tab that the CfgHide* keys have gone without since 2.1. VIEW ONLY - not one keystroke of
; the typing path moved, which is the whole reason this shipped before Kia/Hyundai ingest.
; Make is derived client-side by SbMakeOf (E-BYD/I/L/F), so the column works today on the
; two live brands; Kia and Hyundai sit at 0 until their feed lands. 2.9.0 = THE AUTO-RETRY (Kaine,
; off the 10:36-10:44 Stopped screenshots): a run that ends anything but green - Stopped,
; wrong-screen preflight abort, amber REVIEW - re-launches itself like a fresh sidebar
; double-click (new plan fetch, every gate re-run), capped at RCP_RETRY_MAX = 2 retries;
; a human No/Cancel (g_rcpUserAbort) never retries. 2.8.0 = THE STALE-FRAME CONFIRM
; (the 08:55 BY36466 run): after the qty, a line-prompt frame must hold still for TWO
; consecutive reads before it means "ERA closed the line" (a stale pre-entry frame let line
; 4's keystream become line 3's 0.04 cost), and an a=2 want now carries keepExc so the
; landed sweep convicts a kept cost that later changes. 2.7.0 = THE LANDED-PROOF PASS:
; RcpPageGate before the qty on page-jump lines, no keys into a no-Help screen, g_rcpWant +
; RcpLandedSweep + honest DONE (green only when proven). 2.6.0 = THE ACCURATE-PRICE SKIP
; (Kaine: "compare what the invoice price is to the PO, and if it's accurate, don't adjust
; the price") + the [wl]/[snd] log tags: a price-only fix line whose Exc Cost was already
; SEEN equal to the invoice price - on a capture the run had already paid for - is left
; alone entirely; no new captures, no walks, positive evidence only. 2.5.0 was THE
; DETERMINISTIC PASS ("rip it all out... speed is king"): no review walks, no finish check,
; no repair passes, no auto-recovery - one sequential pass, invoice values at the PO's line
; numbers, one in-place replay then a precise stop. 2.4.0 the sequential pass, 2.3.0 the
; clipboard pass, 2.2.0 the price deferral.
; 2.24.0: the Receipted column is DELETED - column, Settings switch and config key. The
;         stamp it printed now rides the status glyph: a run that finishes clean turns
;         that row's tick GREEN (SbCustomDraw's second job, alongside the bold total), and
;         receipted.ini remembers it across restarts. A run that ends in REVIEW stays
;         white. With the column gone the seven survivors STRETCH to fill the list exactly
;         - no dead strip on the right where it used to sit.
; 2.23.1: window 535 -> 575 so NO column ellipsizes. The Ex GST floor pushed the total
;         past what 535 could hold and the proportional squeeze truncated the rest; the
;         squeeze now logs when it fires instead of quietly shortening ERA's values.
; 2.23.0: the counts footer is DELETED and Hide-warn moved up to the far right of the
;         brand strip, flush with Setup (its width is read back from the auto-sized
;         control, never guessed). Bar back to h18, search box -Theme so the Win11 focus
;         accent stops underlining it, Ex GST floored at 86px so six figures never
;         squeeze, and the clean run line is order + clock + steps with the narration cut.
;         The list took every freed pixel: 286 -> 334.
; 2.22.1: -MaximizeBox, not v2's -MaxBox - the v2 spelling opened the worklist as an
;         "Invalid option" dialog. Runtime error, so the selfcheck parse ran green on it.
; 2.22.0: the window is a FIXED 535x456 and no longer resizes (the column-hide width snap
;         went with it). The lookup ComboBox is a plain Edit - no drop list, an X where its
;         arrow was - and the caret is parked in it permanently. The Receipt button is
;         DELETED: double-click is the run, the idle line says so, and the 40px the button
;         freed plus a doubled (h36) progress bar leave the list two rows taller.
; 2.21.2: defaults matched to what Kaine actually runs - every column drawn EXCEPT
;         Receipted, and the toast dwell down to 1.2s from 2.5s.
; 2.21.1: Subtract-by defaults to 0+B - 25 live runs make it the proven stream, and X
;         (line/x) is the one that has never touched real ERA. Settings tip corrected.
; 2.21.0: THE SUBTRACT IS MODE-INDEPENDENT. An uncovered line gets its 0+B (or X) under
;         per-line exactly as it does under recv-aLL - per-line used to leave those lines
;         untouched, and the cost model then chose per-line because it was pricing a job it
;         had no intention of doing. Six invoices shipped without their backorder that way.
;         Fast timing + hidden warn rows are the defaults now.
; 2.20.0: resize repaints (ghost buttons were stale paint, probe-proven); hiding a
;         column in Settings snaps the window width to the surviving columns.
; 2.19.0: columns content-sized (compact, no dead stretch); too-narrow windows scale
;         all columns to fit instead of growing a horizontal scrollbar.
; 2.18.0: toast dwell is a Settings > Service field (ToastSeconds; default 1.2 since 2.21.2).
; 2.17.0: sidebar built ONCE, hidden + pre-filled at startup; open = Gui Show, catch-up
;         fetch is silent (no marquee). The per-open Destroy+rebuild was the clunk.
; 2.16.0: worklist pre-loads at startup - WlPing(2) fetches while hidden, SidebarShow
;         paints instantly from the warm cache and refreshes behind the visible rows.
; 2.15.0: the bold Ex GST cell is underlined too (Kaine 2026-07-20).
; 2.25.0: "parts" (invoice carries part(s) NOT on the PO) is its own look - a RED DOT.
;         Dot rows always show (Hide-warn hides only triangles), sort between ready and
;         warn, and RUN on double-click: the plan types the PO-matched lines only, the
;         missing part is added to the PO by hand (Kaine 2026-07-23). Triangle = order
;         not in export / PO-only rows, still blocked and still hideable.
; 2.26.0: red dots draw only when Po/Inv has BOTH sides (e.g. 4/5, not 0/5) - Settings >
;         Columns checkbox "Show ? rows only when Po / Inv has both sides", default ON
;         (Kaine 2026-07-24). Config key DotBothOnly; default lives in the global AND the
;         IniRead fallback. Untick to see every dot again.
global VERSION    := "2.26.0"
; The worklist window's size, hard-coded (2.22.0, Kaine: "lock window size to current
; dimensions... no auto-sizing"). CLIENT pixels - the numbers measured off the window Kaine
; had sized by hand. Nothing recomputes these: not ERA's height, not a column hide. The
; window is -Resize -MaxBox, so they are also the only size it will ever have.
; 2.23.1: 535 -> 575. At Consolas 9 the seven drawn columns need ~508px of content
; (E-BYDAU26061585 alone is ~122) and 535 left only 494 after the vertical scrollbar and
; insets, so SbApplyCols scaled every column down and ERA's own values came out as
; "E-BYDAU2606...", "STK3...", "22/07/...". Kaine's call (2026-07-22): widen rather than
; scroll sideways or drop a column. Still fixed and non-resizable - just 40px wider.
; Turning the Receipted column back on in Settings re-crosses the line and the squeeze
; returns; that column costs ~78px and nothing here can conjure it.
global SB_W := 575
global SB_H := 456
; The idle status line. With the Receipt button gone this is the only place that says how
; a run gets started, so it is not just "Idle" any more.
global SB_IDLE_TXT := "Idle - double-click a row to receipt it"
; Settings password (2.12). Plain text on purpose - it is a speed bump against a curious
; picker, not a secret. Anyone who can read this file can already edit the script.
global SETTINGS_PW := "123"
global IsuzuUrl   := ""
global BydUrl     := ""
global ReconUrl   := ""    ; invoice-recon service. EMPTY = feature off (sender behaves exactly as before)
global g_batchId  := ""    ; ties one send batch's recon results together
global g_reconCount := 0   ; how many recon posts were fired this batch
global g_reconReqs  := []  ; keeps async WinHttp objects ALIVE until batch end - releasing a
                           ; WinHttpRequest mid-flight ABORTS the send (measured: found 0/1
                           ; released vs 1/1 kept). Fire-and-forget must not be fire-and-cancel.
global g_reconFlags := ""  ; last batch's flag text, shown on demand from the tray menu
global g_reconFlagsAt := "" ; when that batch finished (so the on-demand view can say how old)
global g_sbVisible  := false ; receipting sidebar (Gui SB) currently shown
global g_sbLvHwnd   := 0   ; sidebar ListView hwnd - the hover-tooltip hit test needs it
global g_sbFilter   := ""  ; last applied lookup text (the timer refills only on change)
global g_sbBrand    := ""  ; brand strip selection: "" = All, else a MAKE letter (BY/IA/KI/HY).
                           ; View-only - it never reaches the typing path. NOT persisted: a
                           ; filtered list must not be what greets you on the next start.
global g_wlIds      := []  ; worklist dataset, parallel arrays, full (unfiltered)
global g_wlOrders   := []
global g_wlMakes    := []  ; MAKE letters per row (BY/IA/KI/HY, "" = unknown) - see SbMakeOf
global g_wlGlyphs   := []
global g_wlTips     := []
global g_wlRowTip   := {}  ; current ListView row -> tooltip text (rebuilt on every fill)
global g_wlRowIdx   := {}  ; current ListView row -> worklist array index (double-click needs it)
; Worklist index of the invoice you last fired a run on - its Ex GST cell draws bold.
; Held as an INDEX, not a row number, so it follows the invoice through a refresh, a
; re-sort or a brand filter instead of bolding whatever lands in that row afterwards.
global g_sbBoldIdx  := 0
global g_sbTipRow   := 0   ; row the tooltip is currently up for
global g_rcpQtyMode := "auto" ; receipt qty mode PREFERENCE ("auto"/"perline"/"recvall").
                              ; NOT persisted: resets to auto every sender start (Kaine's
                              ; call - a one-off manual choice must not become the default).
                              ; RcpPickMode resolves the mode actually used, per invoice.
global g_rcpBusy    := false ; a click-to-receipt run is typing into ERA right now
global g_rcpHwnd    := 0   ; ERA Port window for the current receipt run
global g_rcpCtl     := 0   ; ERA input control (Afx child) - the PostMessage target. The
                           ; receipt drill points this at a mock Edit control instead.
; RCP_* MUST be assigned HERE, in the auto-execute section. They originally sat next to
; the Rcp* functions (line ~1145) where `global X := val` DECLARES but the assignment
; NEVER RUNS - every one was empty at runtime. recv-aLL typed literally nothing (the
; 2026-07-16 23:32/23:44 failures), and all pacing sleeps were 0.
; Pacing. These were DEAD (empty = 0 ms) until 2026-07-17, so every proven run before then
; actually paced on the typing primitives' own 150-200 ms sleeps alone. Switching them on at
; their original values put a visible 1.5 s stall between PO# and Supplier Inv# - Kaine flagged
; it on video ("it wasn't there before"). Cut to a middle ground: still real headroom for a
; slow ERA day, no stall you can watch. Tune here if a slow day ever misaligns a run.
global DLG_ERA_TITLE     := "ERA Port"  ; window our MsgBoxes centre on (drills override it)
global RCP_RECVALL_KEY   := "L"   ; the Field:-prompt key for recv-aLL (confirmed live)
global RCP_UNRECV_KEY    := "X"   ; Recv-field key that un-receives ONE line (Kaine, confirmed
                                  ; 2026-07-17). Clears the received qty, leaves QPR alone.
                                  ; Sent as a lowercase WM_CHAR - the delivery real ERA proved
                                  ; it listens to when recv-aLL's 'l' fired at 23:57. NOTE the
                                  ; action bar's eXit is also X; different prompt, don't conflate.
global RCP_AFTER_MENU    := 250   ; ms after "2062" before the PO# field accepts input
global RCP_AFTER_PO      := 400   ; ms for ERA to load the order + preload vendor/dates
global RCP_AFTER_INV     := 0     ; ms after the supplier inv# - the used-check's own wait follows
global RCP_BETWEEN_LINES := 120   ; ms between line entries
global RCP_TEXT_SETTLE   := 200   ; ms after a fixed keystream chunk (RcpText)
global RCP_VAR_SETTLE    := 150   ; ms after a variable value (RcpTextVar)
global RCP_PAGE_SETTLE   := 2500  ; v2.7.0: ms budget for a screen to settle - the page-jump
                                  ; gate, the after-qty settle and the sync no-Help wait all
                                  ; spend from it. Only ever spent when ERA is actually slow;
                                  ; a fast redraw exits on its first capture.
global RCP_RETRY_MAX     := 2     ; v2.9.0: auto-retry cap (Kaine: "keep retrying until it
                                  ; goes green, cap it at 2 tries") - a run that ends anything
                                  ; but green re-fires itself like a fresh double-click.
global RCP_RETRY_DELAY   := 2000  ; ms before a retry - let ERA finish whatever repaint,
                                  ; freeze or half-typed prompt killed the attempt.
global g_rcpUserAbort    := false ; per-run: the HUMAN stopped it (checkpoint No, focus-pause
                                  ; Cancel) - an auto-retry must never overrule a person.
; ---- 2026-07-18 GUI build: settings persisted in config.ini [settings] ----
; Defaults preserve the pre-2.1 behaviour exactly; every one is read in ReadConfig().
global CfgSubtractBy     := "zb"  ; "zb" = line/0/B/Enter - a zero receipt plus a booked
                                  ; backorder. THE DEFAULT (Kaine, 2026-07-22). No longer
                                  ; unproven: sender.log has 25 live "subtracted N uncovered
                                  ; line(s) by 0+backorder" runs, 20/07 onward.
                                  ; "x" = line/x/Enter (video-proven stream, never run live)
global CfgConfirmTyping  := 0     ; confirm dialog before any keystroke (Safety). Kaine's call
                                  ; 2026-07-18: OFF by default (no popup); re-enable in Settings.
global CfgDryRun         := 0     ; 1 = every receipt is a dry run (logs keystrokes, sends nothing
                                  ; to ERA, never stamps Receipted). The old sidebar Dry-run button
                                  ; moved here (Settings > Safety) 2026-07-18.
global CfgCkptStop       := 0     ; the checkpoint pause. 2026-07-18: OFF by default (Kaine -
                                  ; "remove that annoying message box"). Re-enable in Settings >
                                  ; Safety; note it is the X-out's ONLY verification when on.
global CfgScreenChk      := 1     ; 2026-07-18: READ THE ERA SCREEN. Kaine's WIS keyboard macro
                                  ; (Key_Kaine.wis) maps F11 -> ScrollEndPage + EditSelectWindow +
                                  ; EditCopy, i.e. the WHOLE ERA screen onto the clipboard. That
                                  ; overturns "ERA exposes no text" (WM_GETTEXT returns 0): the
                                  ; sender can now verify silently instead of stopping the human.
global ERA_SCR_KEY       := 0x7A  ; VK_F11 - the WIS binding that copies the screen
global ERA_SCR_WAIT      := 0.7   ; seconds to wait for the terminal's copy to land (seq-number poll)
global ERA_SCR_DUMP      := 1     ; also append every capture to era-screens.log (layout learning:
                                  ; nobody has ever seen a captured ERA screen - the first real
                                  ; runs are how we learn the column positions)
global g_rcpTyped        := {}    ; per-run: line no -> true once this run has typed that line.
global g_rcpNoCost       := {}    ; per-run: line no -> how many times ERA closed that line
                                  ; WITHOUT asking for a cost. Twice = ERA is keeping its own
                                  ; price on purpose; replaying a third time is the 23:09 run's
                                  ; corruption loop (line 61 ended up Exc 0.70). Report, don't loop.
global g_rcpAtLine       := false ; per-line: the PREVIOUS line's settle capture ended on a
                                  ; prompt we recognised, so the caret's position is already
                                  ; proven and the next pre-line EraSync capture can be
                                  ; skipped ("3 wins" pass 2026-07-18). Consumed every loop
                                  ; iteration; RcpLines caps the skips at 3 in a row so an
                                  ; unnoticed drift can never ride further than 3 lines, and
                                  ; the after-qty settle capture still checks every line.
global g_rcpSeen         := {}    ; per-run: line no -> the CLEAN grid row (no misaligned token)
                                  ; most recently seen on a capture the run already paid for
                                  ; (preflight after the order is proven, every sync/settle
                                  ; capture). v2.6.0: lets a price-only fix line whose Exc
                                  ; already equals the invoice price be LEFT ALONE (Kaine,
                                  ; 2026-07-19: "if it's accurate, don't adjust the price").
                                  ; An untyped line's Exc cannot change under us, so a clean
                                  ; sighting stays valid for the whole run; no extra captures.
global g_rcpPage         := {}    ; per-run: the grid rows of the page the LAST paid-for capture
                                  ; showed (v2.7.0). The page-jump gate reads it: a line number
                                  ; not on this page will make ERA repaint, so the qty must wait
                                  ; for the paint. Only a non-empty grid updates it.
global g_rcpWant         := {}    ; per-run: line no -> what that entry meant to leave on screen
                                  ; ({kind fix/sub/skip, qty, price, recvWant, proof, seen}).
                                  ; The landed sweep re-reads these rows off every later capture
                                  ; and the verify summary reports proven/wrong/not-re-shown
                                  ; (v2.7.0 - Kaine, 08:20 video: "make sure they actually got
                                  ; received and put in correctly").
global g_rcpFgOk         := 0     ; per-run: the one non-ERA, non-worklist foreground window the
                                  ; human has approved (run-start snapshot; updated on Continue
                                  ; at the focus pause) - one pause per focus thief, never two.
global g_rcpProgTxt      := ""    ; the progress line minus its clock - the 1s tick re-renders it
global g_rcpT0           := 0     ; per-run: A_TickCount when the run started. Kaine, 22:41:
                                  ; "a timer to time how long this takes and how many steps it
                                  ; took, start to finish" - so the bar carries mm:ss alongside
                                  ; the step counter, and the finish line + log record both.
global g_eraScrOk        := 0     ; captures that succeeded this session (0 = the macro isn't
                                  ; reaching ERA; the code degrades to today's blind behaviour)
global CfgStripIsuzuI    := 0     ; strip the leading I from Isuzu supplier inv# (UNCONFIRMED
                                  ; whether ERA wants it - OFF until a real Isuzu receipt says)
global CfgContinueInvUsed:= 0     ; 1 = continue past "invoice already used" without asking
global CfgStaleMode      := "warn"  ; stale PO export: warn | block
global CfgStaleHours     := 8     ; export older than this many hours counts as stale
global CfgAlertWhen      := "both"  ; both | checkpoint | finish
global CfgAlertHow       := "both"  ; both | beep | flash
global g_toastFast       := 0     ; 1.20.0: Full refresh drops every step toast to 1.3s
global CfgToastSecs      := 1.2   ; how long the corner toast stays up (2.18.0, Settings >
                                  ; Service). "load" toasts ignore it - they sit until the
                                  ; result replaces them. 1.2s is Kaine's call (2026-07-22);
                                  ; it was 2.5.
global CfgShowLogPane    := 0     ; activity log pane in the sidebar (off by default)
global CfgFanOut         := 1     ; recon fan-out master switch (ReconApiUrl empty still wins)
global CfgQtyModeDefault := "auto"  ; STARTUP default only - the sidebar radio stays session-only
global CfgBrand          := "byd" ; brand profile: routing default + prefix-strip label
global CfgReceiver       := "KAINE"
global CfgTimingPreset   := "fast"  ; Kaine, 2026-07-22: Fast is what he actually runs - it is
                                    ; the default now, not an opt-in (the six REAL waits below
                                    ; still carry the live-proven values as their own defaults)
global CfgHideOrder      := 0     ; hide-columns: Status + Invoice always show
global CfgHideMake       := 0
global CfgHideDate       := 0
global CfgHideExGst      := 0
global CfgHidePoInv      := 0
                                  ; (CfgHideReceipted is GONE with the column, 2.24.0 - the
                                  ; stamp is the tick's colour now, not a column of its own.
                                  ; St / Invoice / Make / Order / Date / Ex GST / Po-Inv is
                                  ; the whole set and every one of them draws.)
global CfgHideWarnRows   := 1     ; worklist footer toggle: hide the warn (check-parts) rows
global CfgDotBothOnly    := 1     ; 2.26.0: red-dot rows draw only when Po/Inv has BOTH sides
                                  ; (default ON - Kaine 2026-07-24; also the IniRead fallback)
                                  ; from the list. Counts still tally ALL rows, hidden or not.
                                  ; ON by default (Kaine, 2026-07-22) - the ready rows are the
                                  ; work; the warn rows are a separate look.
global g_rcpDone   := {}   ; invoice id -> HH:mm receipted stamp (receipted.ini; NOTE the sender
                           ; can only know it TYPED the receipt - never-finalize means the
                           ; human still commits. Kaine accepted that overclaim, card a4.)
global g_rcpDry    := false ; dry run: typing primitives log instead of posting to ERA
global g_rcpStepsTotal := 0 ; progress bar counts TYPED STEPS, not time
global g_rcpStepsDone  := 0
global g_sbWinHwnd := 0    ; sidebar window hwnd (taskbar flash target)
global g_sbBuilt   := 0    ; sidebar GUI exists (2.17.0: built ONCE, hidden at startup,
                           ; then opening is just Gui Show - the Destroy+rebuild per open
                           ; was the visible clunk). Only SidebarBuild sets it.
global g_wlDates   := []   ; worklist parallel arrays, extended wire fields (recon-6)
global g_wlExGst   := []
global g_wlPoLines := []
global g_wlInvLines := []
global g_wlFetchedAt := 0  ; tick of the last successful worklist fetch. Non-zero = the
                           ; g_wl* arrays are a renderable cache, so SidebarShow can paint
                           ; instantly and refresh behind the visible list (2.16.0). An
                           ; EMPTY fetched list still counts - empty is an answer.
global DefaultBrand := ""        ; "isuzu"/"byd"/"" -> "" means prompt when unknown
global EnableEmailDrag := true

; Unicode glyphs, built from code points (encoding-independent)
global GLYPH_OK   := Chr(0x2713)   ; check mark
global GLYPH_BAD  := Chr(0x2717)   ; ballot X
global GLYPH_DOWN := Chr(0x2193)   ; down arrow
global GLYPH_WARN := Chr(0x26A0)   ; warning triangle (sidebar: order not in export / PO with no invoice)
global GLYPH_DOT  := Chr(0x25CF)   ; red dot (sidebar: invoice carries part(s) NOT on the PO - 2.25.0)
global HINT_IDLE  := ""
global HINT_MORE  := ""

HINT_IDLE := GLYPH_DOWN "   Drag Isuzu + BYD invoice PDFs here   " GLYPH_DOWN
HINT_MORE := GLYPH_DOWN "   Drop more, or click ""Send all""   " GLYPH_DOWN

ReadConfig()
LoadReceipted()

Menu, Tray, NoStandard
Menu, Tray, Add, Show worklist`tCtrl+Space, WlTrayShow
Menu, Tray, Add, Settings..., SettingsShow
Menu, Tray, Add, Upload PO Data..., WlUploadPo
Menu, Tray, Add, Export + upload PO data, DockPoExport
Menu, Tray, Add, Full refresh, DockFullRefresh
Menu, Tray, Add
Menu, Tray, Add, Test ERA screen read (F11), MenuTestScreen
Menu, Tray, Add                      ; (Open log lives in the block above - was duplicated here)
Menu, Tray, Add, Exit, WlExit
Menu, Tray, Default, Show worklist`tCtrl+Space
Menu, Tray, Tip, Receipting worklist v%VERSION%

; Worklist hover tooltips: hit-test the row under the cursor on every mouse move.
OnMessage(0x200, "SB_OnMouseMove")   ; WM_MOUSEMOVE
; Centre our MsgBoxes on the ERA window - the worklist parks hard against the left screen
; edge, so an owner-centred dialog rendered mostly off-screen (both videos, 2026-07-16/17).
OnMessage(0x44, "DlgCenter")         ; WM_COMMNOTIFY - AHK posts it as a dialog is created
OnMessage(WL_MSG, "WlPing")          ; the sender's nudge
OnMessage(0x4A, "JobMsg")            ; WM_COPYDATA - the Full refresh invoice child
; Bold the Ex GST cell of the invoice you last double-clicked. An AHK v1 ListView has ONE
; font, so this is the only way - but WM_NOTIFY is also how AHK delivers DoubleClick to
; gSbLvEvent, and an earlier custom-draw attempt killed exactly that. See SbCustomDraw for
; the two rules that keep the double-click alive.
OnMessage(0x4E, "SbCustomDraw")      ; WM_NOTIFY

; Mop up wIntegrate's "Clip: Unable to open Clipboard" popups (Kaine, 2026-07-19) - the
; capture path retries its own, but this also catches ones his manual copies raise. 2s and
; a single WinExist when there is nothing to close: too cheap to interfere with a run.
SetTimer, ClipPopupSweep, 2000

Log("worklist startup v" VERSION " | recon=" (ReconUrl = "" ? "(unset)" : ReconUrl) " | bits=" (A_PtrSize * 8))
return

ClipPopupSweep:
    EraClipPopupClose()
return

; ---- Ctrl+Space: the one way in ------------------------------------------------
^Space::
    WlToggle()
return

WlTrayShow:
    if (!g_sbVisible)
        SidebarShow()
    else
        Gui, SB:Show
return

WlUploadPo:
    PoUploadRun(false)
    SetTimer, DockStatusOnce, -2000
return

WlOpenLog:
    logf := A_ScriptDir "\sender.log"
    if (!FileExist(logf))
        FileAppend, , %logf%
    Run, notepad.exe "%logf%"
return

WlExit:
    ExitApp
return

; Toggle: hidden/never-shown -> fetch + show; shown -> hide (and stop the filter poll).
WlToggle() {
    global g_sbVisible
    if (g_sbVisible) {
        Gui, SB:Hide
        g_sbVisible := false
        SetTimer, SbFilterTick, Off
    } else {
        SidebarShow()
    }
}

; The sender's ping. 1 = the worklist data just changed AND it should come up (PO upload);
; 2 = quiet refresh, only if already visible (end of a send batch).
WlPing(wParam) {
    global g_sbVisible, g_sbBuilt
    if (wParam = 1) {
        if (g_sbVisible) {
            SidebarRefresh(false)
            Gui, SB:Show
        } else {
            SidebarShow()
        }
    } else if (wParam = 2) {
        if (g_sbVisible) {
            SidebarRefresh(true)
        } else {
            ; 2.16.0/2.17.0: the hidden warm-up. Fetch the worklist, then build the whole
            ; window ONCE (hidden) and fill its rows, so the first click on Receipting is
            ; nothing but Gui Show. Startup's auto-import lands here via WorklistPing(2).
            if (SidebarFetch(false)) {
                if (!g_sbBuilt)
                    SidebarBuild(false)
                SidebarFill()
            }
        }
    }
}

; ============================================================
;  Receipting sidebar (Gui SB) - "what is ready to receipt NOW"
;
;  A thin window that parks itself to the LEFT of the ERA screen: every invoice the recon
;  service has seen in the last 14 days, re-reconciled against the CURRENT PO snapshot.
;  Check mark = order in the export and every part on it (price edits don't block readiness).
;  Warning   = parts missing from the order, or the order isn't in the export at all.
;  Hovering a row pops the detail: price changes old -> new, over-shipments, backorders,
;  not-on-PO parts. The combo box at the top filters by invoice or order number as you type.
;
;  Wire format from POST /worklist: response field "text" = one invoice per line,
;  "id|order|status|tooltip", tooltip newlines encoded as "~". Parsed with StrSplit -
;  no JSON array parsing in AHK.
; ============================================================

; (The old `MenuSidebar:` tray label lived here. It was a byte-for-byte duplicate of
;  WlToggle() and nothing referenced it after the split - deleted so there is ONE toggle.)

SBGuiClose:
SBGuiEscape:
    Gui, SB:Hide
    g_sbVisible := false
    SetTimer, SbFilterTick, Off
return

; Every control reflows to the new size (Kaine, 2026-07-18). A_EventInfo 1 = minimized:
; a 0-height relayout would clamp everything, so skip it and let restore fire the real one.
SBGuiSize:
    if (A_EventInfo = 1)
        return
    SbLayout(A_GuiWidth, A_GuiHeight)
return

; Footer toggle: hide/show the warn (check-parts) rows. Persists to config.ini; the counts
; in SidebarFill still tally every row, so the numbers never lie about what's hidden.
SbHideWarnToggle:
    GuiControlGet, sbHW, SB:, SbHideWarn
    CfgHideWarnRows := sbHW
    WriteConfig()
    SidebarFill()
return

; Brand strip: view filter only. It never touches CfgBrand (that one decides what gets
; TYPED into ERA) - picking "Kia" here narrows the list and nothing else. Not persisted,
; so a restart always comes up on All.
SbBrandPick:
    GuiControlGet, sbBrA, SB:, SbBrAll
    if (sbBrA) {
        g_sbBrand := ""
    } else {
        g_sbBrand := ""
        for sbBi, sbB in SbBrands() {
            GuiControlGet, sbBrOn, SB:, % "SbBr" sbBi
            if (sbBrOn) {
                g_sbBrand := sbB.m
                break
            }
        }
    }
    SidebarFill()
return

SbRefreshBtn:
    SidebarRefresh(false)
    SbFocusFilter()
return

; The X that replaced the combo's drop arrow (2.22.0): empty the box, put every row back,
; and hand the caret straight back so clearing costs one click and no re-aim.
SbClearBtn:
    GuiControl, SB:, SbFilter,
    g_sbFilter := ""
    SidebarFill()
    SbFocusFilter()
return

; Polls the search box while the sidebar is up. Was a ComboBox poll (a g-label only fired
; on SELECTION); an Edit's g-label would fire per keystroke, but the 250ms poll already
; works, coalesces a fast typist's bursts into one refill, and stays the cheaper path.
; Refills only when the text actually changed.
SbFilterTick:
    GuiControlGet, sbf, SB:, SbFilter
    if (sbf != g_sbFilter) {
        g_sbFilter := sbf
        SidebarFill()
    }
return

SidebarShow() {
    global ReconUrl, g_sbVisible, g_wlFetchedAt, g_sbBuilt
    if (ReconUrl = "") {
        ShowToast("bad", "Sidebar unavailable", "Set ReconApiUrl in config.ini")
        return
    }
    ; 2.17.0 (Kaine: "still very clunky... instant without the loading bar"): the window
    ; is built ONCE - normally hidden at startup by the warm-up in WlPing(2), already
    ; filled - so the usual open is Gui Show + a SILENT catch-up fetch behind the visible
    ; rows. No Destroy+rebuild (that was the clunk), no marquee unless there is genuinely
    ; nothing to show yet (first open before the warm-up landed, or recon down).
    if (g_sbBuilt) {
        SbReposition()
        g_sbVisible := true
        if (g_wlFetchedAt) {
            SetTimer, SbShowRefresh, -100      ; silent refresh AFTER the window has painted
        } else {
            SbLoading(true)
            ok := SidebarFetch(false)
            SbLoading(false)
            if (ok)
                SidebarFill()
        }
    } else {
        SidebarBuild()
        g_sbVisible := true
        if (g_wlFetchedAt) {
            SidebarFill()
            SetTimer, SbShowRefresh, -100
        } else {
            SbLoading(true)
            ok := SidebarFetch(false)
            SbLoading(false)
            if (ok)
                SidebarFill()
        }
    }
    SbFocusFilter()
    SetTimer, SbFilterTick, 250
}

; Re-show the already-built window, re-parked against ERA's current position - the same
; geometry SidebarBuild computes, minus the build. 2.22.0: w/h are the fixed SB_W/SB_H, so
; the controls SbLayout placed at build time are already where they belong.
SbReposition() {
    global VERSION, SB_W, SB_H
    W := SB_W, h := SB_H, x := "", y := ""   ; 2.22.0: the size never changes, only where it parks
    SetTitleMatchMode, 2
    if WinExist("ERA Port") {
        WinGetPos, ex, ey, ew, eh
        x := ex - (W + 8)
        if (x < 0)
            x := 0
        y := ey
    }
    if (x != "")
        Gui, SB:Show, % "x" x " y" y " w" W " h" h, Receipting worklist v%VERSION%
    else
        Gui, SB:Show, , Receipting worklist v%VERSION%
}

; One-shot: the open-from-cache catch-up. SILENT on purpose - no marquee, no "Loading
; worklist..." (Kaine 2026-07-20: "instant without having to see the loading bar"); the
; rows on screen are the last fetch, this swaps in the current one when it arrives.
; Closed-by-now is fine - the fetch just re-warms the cache for the next open.
SbShowRefresh:
    if (!SidebarFetch(false))
        return
    if (g_sbVisible)
        SidebarFill()
return

; Marquee on the existing SbProg bar while a worklist fetch is in flight. The receipt
; run's own percentage use of SbProg is untouched - this only runs between runs.
SbLoading(on) {
    global g_sbVisible, SB_IDLE_TXT
    if (!g_sbVisible)
        return
    GuiControlGet, hProg, SB:Hwnd, SbProg
    if (on) {
        GuiControl, SB:+0x8, SbProg                        ; PBS_MARQUEE
        SendMessage, 0x40A, 1, 40, , ahk_id %hProg%        ; PBM_SETMARQUEE on, 40ms step
        GuiControl, SB:, SbProgTxt, Loading worklist...
    } else {
        SendMessage, 0x40A, 0, 0, , ahk_id %hProg%
        GuiControl, SB:-0x8, SbProg
        GuiControl, SB:, SbProg, 0
        GuiControl, SB:, SbProgTxt, % SB_IDLE_TXT
    }
}

; quick=true rides the end of a send: one short attempt, and only when already visible.
SidebarRefresh(quick) {
    global g_sbVisible
    if (g_sbVisible && !quick)
        SbLoading(true)
    ok := SidebarFetch(quick)
    if (g_sbVisible && !quick)
        SbLoading(false)
    if (!ok)
        return
    if (g_sbVisible)
        SidebarFill()
}

SidebarFetch(quick) {
    global ReconUrl, g_wlIds, g_wlOrders, g_wlGlyphs, g_wlTips, GLYPH_OK, GLYPH_WARN, GLYPH_DOT
    global g_wlDates, g_wlExGst, g_wlPoLines, g_wlInvLines, g_wlMakes, g_wlFetchedAt
    if (ReconUrl = "")
        return false
    if (quick)
        res := HttpPostJson(ReconUrl "/worklist", "{""limit"":150}", false, "application/json", 3000, 1)
    else
        res := HttpPostJsonPumped(ReconUrl "/worklist", "{""limit"":150}")
    if (res.status != 200) {
        Log("worklist: fetch failed http=" res.status " | " SubStr(res.text, 1, 200))
        ShowToast("bad", "Worklist unavailable", "HTTP " res.status " - see log")
        return false
    }
    block := JsonStr(res.text, "text")   ; unescapes \n -> real newlines between invoices
    g_wlIds := [], g_wlOrders := [], g_wlGlyphs := [], g_wlTips := []
    g_wlDates := [], g_wlExGst := [], g_wlPoLines := [], g_wlInvLines := [], g_wlMakes := []
    Loop, Parse, block, `n
    {
        f := StrSplit(A_LoopField, "|")
        if (f.Length() < 4)
            continue
        g_wlIds.Push(f[1])
        g_wlOrders.Push(f[2])
        ; 2.25.0: "parts" (the invoice carries part(s) the PO doesn't have) is a RED DOT,
        ; its own look - the triangle now means only "order not in the export". A dot row
        ; still runs on double-click (Kaine: "we can manually add the part to the po").
        g_wlGlyphs.Push(f[3] = "ready" ? GLYPH_OK : (f[3] = "parts" ? GLYPH_DOT : GLYPH_WARN))
        ; Tooltip header carries the invoice + order so the tip stands alone.
        g_wlTips.Push(f[1] . "  -  " . f[2] . "`n" . StrReplace(f[4], "~", "`n"))
        ; Wire v2 (recon-6) appends date|exGst|poLines|invLines. A recon-5 service omits
        ; them -> blanks, and the sidebar degrades to the old three-column view of the data.
        g_wlDates.Push(f.Length() >= 5 ? f[5] : "")
        g_wlExGst.Push(f.Length() >= 6 ? f[6] : "")
        g_wlPoLines.Push(f.Length() >= 7 ? f[7] + 0 : 0)
        g_wlInvLines.Push(f.Length() >= 8 ? f[8] + 0 : 0)
        ; Field 9 (MAKE) is not sent by any service yet - derive it from the invoice id.
        ; Reading the field first means the day the wire grows one, it just wins.
        g_wlMakes.Push((f.Length() >= 9 && f[9] != "") ? f[9] : SbMakeOf(f[1]))
    }
    WlAppendPoOnly()
    g_wlFetchedAt := A_TickCount
    return true
}

; ---- PO-only rows (Kaine 2026-07-20: "I want outstanding POs to show as rows too") ----
; The service's worklist is invoice-keyed, and it has no endpoint to read the PO snapshot
; back. So the CLIENT keeps a copy: every successful "Upload PO data" also writes
; po-cache.csv beside the script, and this appends one warn row per order in that cache
; that no invoice row references yet. Id is "(PO) <order>" - unique, self-describing in
; the Invoice column and the lookup combo. The warn glyph makes RcpStart refuse it (the
; MsgBox shows this tip), and "Hide warn rows" hides them like any other warn.
WlAppendPoOnly() {
    global g_wlIds, g_wlOrders, g_wlGlyphs, g_wlTips, g_wlDates, g_wlExGst
    global g_wlPoLines, g_wlInvLines, g_wlMakes, GLYPH_WARN
    cache := A_ScriptDir "\po-cache.csv"
    if (!FileExist(cache))
        return
    seen := {}
    for i, o in g_wlOrders
        seen[o] := true
    agg := {}, order := []
    Loop, Read, %cache%
    {
        if (A_Index = 1)
            continue
        line := RTrim(A_LoopReadLine, "`r")   ; CRLF export: strip the CR or MAKE = "BY<CR>"
        Loop, Parse, line, CSV
        {
            if (A_Index = 1)
                po := A_LoopField
            else if (A_Index = 4)
                qty := A_LoopField + 0
            else if (A_Index = 6)
                cost := A_LoopField + 0
            else if (A_Index = 8)
                mk := A_LoopField
        }
        if (po = "" || seen.HasKey(po))
            continue
        if (mk != "BY" && mk != "IA" && mk != "KI" && mk != "HY")
            continue                       ; mirror the service: unsupported makes dropped
        if (!agg.HasKey(po)) {
            agg[po] := {n: 0, ex: 0, mk: mk}
            order.Push(po)
        }
        agg[po].n += 1
        agg[po].ex += qty * cost
    }
    inv := WlLoadInvCaches()
    for i, po in order {
        a := agg[po]
        if (inv.HasKey(po)) {
            ; The Kia/HY CSV HOLDS an invoice for this order - pair it client-side.
            ; Still a warn row: the recon service never ingested this invoice, so it has
            ; no receipt plan to type from. The tip says exactly that.
            v := inv[po]
            g_wlIds.Push(v.id)
            g_wlOrders.Push(po)
            g_wlGlyphs.Push(GLYPH_WARN)
            g_wlTips.Push(v.id "  -  " po "`nInvoice found in the " (v.mk = "KI" ? "Kia" : "Hyundai") " CSV (" v.n " line(s), " Round(v.ex, 2) " ex GST, dated " v.date ")`nThe recon server has NOT ingested it - it can pair but not receipt.`nServer-side CSV ingest is the fix (in progress).")
            g_wlDates.Push(v.date)
            g_wlExGst.Push(Round(v.ex, 2))
            g_wlPoLines.Push(a.n)
            g_wlInvLines.Push(v.n)
            g_wlMakes.Push(v.mk)
            continue
        }
        g_wlIds.Push("(PO) " po)
        g_wlOrders.Push(po)
        g_wlGlyphs.Push(GLYPH_WARN)
        g_wlTips.Push("(PO) " po "  -  no invoice yet`n" a.n " outstanding line(s) on the PO export`nEst " Round(a.ex, 2) " ex GST (PO cost x ord qty)`nDrop the invoice PDF into the Sender when it lands.")
        g_wlDates.Push("-")
        g_wlExGst.Push(Round(a.ex, 2))
        g_wlPoLines.Push(a.n)
        g_wlInvLines.Push(0)
        g_wlMakes.Push(a.mk)
    }
}

; Parse the cached stdparts CSVs (20 quoted columns) into: order -> {id, date, n, ex, mk}.
; IN lines only (credits skipped); ex = sum of "Invoice line value" (col 20); id carries
; the invoice number. Multiple invoices on one order: first invoice named, all lines kept.
WlLoadInvCaches() {
    inv := {}
    for j, mk in ["KI", "HY"]
    {
        f := A_ScriptDir "\inv-cache-" mk ".csv"
        if (!FileExist(f))
            continue
        Loop, Read, %f%
        {
            line := RTrim(A_LoopReadLine, "`r")
            if (InStr(line, "Franchise") = 2 || InStr(line, """Franchise""") = 1)
                continue
            invNo := "", dt := "", po := "", typ := "", val := 0
            Loop, Parse, line, CSV
            {
                if (A_Index = 3)
                    invNo := A_LoopField
                else if (A_Index = 4)
                    dt := A_LoopField
                else if (A_Index = 6)
                    po := A_LoopField
                else if (A_Index = 10)
                    typ := A_LoopField
                else if (A_Index = 20)
                    val := A_LoopField + 0
            }
            if (po = "" || invNo = "" || typ != "IN")
                continue
            if (!inv.HasKey(po))
                inv[po] := {id: "(CSV) " invNo, date: dt, n: 0, ex: 0, mk: mk}
            inv[po].n += 1
            inv[po].ex += val
        }
    }
    return inv
}

; (Re)creates the window, parked beside the ERA screen when one is up.
; 2.1 layout (the approved AHK-native mockup, v5-audit rules): EIGHT columns in ONE font
; (Consolas - the data is all tabular) and ONE text colour; first column is the status
; glyph; Ex GST is right-aligned (never column 1 - Win32 forbids it); NoSort NoSortHdr
; because the multi-key sort happens in AHK at fill time. Between the filter row and the
; list sits the 2.10 brand strip. Below the list: a step-counting progress bar, the action
; buttons, a footer, and (optional) the activity log pane. Settings hide-column toggles
; set a column's width to 0 - Make joined them in 2.10 and they finally have a UI.
; visible=false is the startup warm-up: create every control but keep the window hidden,
; so the first real open is Gui Show and nothing else.
SidebarBuild(visible := true) {
    global g_sbBuilt
    global g_sbLvHwnd, g_sbWinHwnd, g_wlIds, GLYPH_OK, GLYPH_WARN, g_rcpQtyMode, CfgShowLogPane, CfgHideWarnRows
    global SbFilter, SbLv             ; Gui control output vars in a FUNCTION must be global
    global SbProg, SbProgTxt, SbBtnSettings, SbLogPane
    global SbBtnRefresh, SbBtnSetup, SbBtnClear, SbHideWarn, SbTick
    global SB_W, SB_H, SB_IDLE_TXT
    global SbBrAll, SbBr1, SbBr2, SbBr3, SbBr4   ; brand strip radios
    Gui, SB:Destroy

    ; 2.22.0 (Kaine, 2026-07-22): the size is HARD-CODED and the window no longer resizes.
    ; SB_W/SB_H are the dimensions Kaine settled on by hand; everything below is laid out
    ; against them and nothing recomputes them - no ERA-derived height, no column-hide
    ; width snap. Only the PARK POSITION still follows ERA.
    W := SB_W
    h := SB_H, x := "", y := ""
    SetTitleMatchMode, 2
    if WinExist("ERA Port") {
        WinGetPos, ex, ey, ew, eh
        x := ex - (W + 8)
        if (x < 0)
            x := 0
        y := ey
    }
    logH := (CfgShowLogPane ? 110 : 0)
    lvH := h - 170 - logH       ; search row + brand strip + progress + % text + footer + margins
    if (lvH < 120)
        lvH := 120

    ; -MaximizeBox, NOT -MaxBox: MaxBox is the AHK v2 spelling and v1 rejects it at runtime
    ; with "Invalid option" - a selfcheck parse never sees it (2.22.1).
    Gui, SB:-Resize -MaximizeBox +LabelSBGui +Hwndg_sbWinHwnd
    Gui, SB:Font, s10, Segoe UI
    ; 2.22.0: a plain Edit, not a ComboBox. The drop list is gone and the X that replaced
    ; its arrow clears the box. The caret lives here permanently (SbFocusFilter).
    ; -Theme, and it costs the Win11 look on purpose (2.23.0, Kaine: kill "that blue line
    ; underneath the edit box"). The line is the themed Edit's focus accent - it is only
    ; ever visible because the caret is parked here permanently, and the theme is
    ; all-or-nothing on a v1 control, so losing the accent means a flat 1px border.
    Gui, SB:Add, Edit, % "x8 y7 w" (W - 154) " h26 -Theme vSbFilter",
    Gui, SB:Add, Button, % "x" (W - 142) " y7 w24 h26 vSbBtnClear gSbClearBtn", % Chr(0x00D7)
    Gui, SB:Add, Button, % "x" (W - 116) " y7 w56 h26 vSbBtnRefresh gSbRefreshBtn", &Refresh
    Gui, SB:Add, Button, % "x" (W - 56) " y7 w48 h26 vSbBtnSetup gSbSettingsBtn", Set&up
    ; ---- brand strip (2.10) ----
    ; RADIO buttons, not the mockup's push buttons, and deliberately so: a v1 push button
    ; has no pressed state without the ImageButton route, so a "which brand am I on?" strip
    ; built from buttons cannot answer its own question. A radio group is the native Win32
    ; control for one-of-N and shows its state for free. No colour options anywhere on them -
    ; cGray/cRed on a Radio silently strips the theme (v5 audit).
    ; Captions carry live counts and are rewritten by SidebarFill.
    Gui, SB:Font, s9, Segoe UI
    Gui, SB:Add, Radio, x8 y40 w62 h22 vSbBrAll Group Checked gSbBrandPick, All
    Gui, SB:Add, Radio, x+2 yp w66 h22 vSbBr1 gSbBrandPick, BYD
    Gui, SB:Add, Radio, x+2 yp w74 h22 vSbBr2 gSbBrandPick, Isuzu
    Gui, SB:Add, Radio, x+2 yp w66 h22 vSbBr3 gSbBrandPick, Kia
    Gui, SB:Add, Radio, x+2 yp w86 h22 vSbBr4 gSbBrandPick, Hyundai
    ; ONE font for the whole ListView - a per-column font swap clips (v5 audit, CDRF_NEWFONT).
    Gui, SB:Font, s9, Consolas
    Gui, SB:Add, ListView, % "x8 y66 w" (W - 16) " h" lvH " -Multi NoSortHdr NoSort Hwndg_sbLvHwnd vSbLv gSbLvEvent AltSubmit", % "St|Invoice|Make|Order|Date|Ex GST|Po/Inv"
    Gui, SB:Default
    SbApplyCols(W - 16)
    Gui, SB:Font, s9, Segoe UI
    ; Step-counting progress bar (typed steps, not time). Flat blue is the THEMED bar -
    ; colouring one strips its visual style permanently, so we leave it alone and put the
    ; percentage / status in a Text control below it (a Text has no theme to lose).
    ; 2.22.0 doubled it to h36; 2.23.0 puts it back to h18 - the list wanted the pixels more.
    Gui, SB:Add, Progress, % "x8 y+8 w" (W - 16) " h18 vSbProg Range0-100", 0
    Gui, SB:Font, s9 Bold, Segoe UI
    ; 2.22.0: the Receipt button is gone, so this line carries the only "how do I start a
    ; run?" hint the window has. Every run path overwrites it and SbLoading puts it back.
    ; 2.23.0: it is also the LAST row in the window - the counts footer under it is deleted.
    Gui, SB:Add, Text, % "x8 y+4 w" (W - 16) " vSbProgTxt", % SB_IDLE_TXT
    Gui, SB:Font, s9, Segoe UI
    if (CfgShowLogPane) {
        Gui, SB:Font, s8, Consolas
        Gui, SB:Add, Edit, % "x8 y+6 w" (W - 16) " h" logH " vSbLogPane ReadOnly -Wrap +HScroll", (activity log)
        Gui, SB:Font, s9, Segoe UI
    }
    ; Hide the warn (check-parts) rows. 2.23.0: it rides the BRAND STRIP now, right edge
    ; flush with Setup's - it is one more filter, so it belongs on the filter row. Added
    ; AFTER the flow controls (SbLayout sets its position, so where it lands here is moot).
    Gui, SB:Font, s9, Segoe UI
    ; No w: AHK sizes it to the caption, and SbLayout reads that width back to sit it flush.
    Gui, SB:Add, CheckBox, % "x8 y8 vSbHideWarn gSbHideWarnToggle Checked" CfgHideWarnRows, % "Hide " GLYPH_WARN " rows"
    ; The big "done" tick that caps the right end of the progress bar. Blank until a run
    ; completes; green (a Text has no theme to lose, so cColor is free). On top in z-order.
    Gui, SB:Font, s18 Bold, Segoe UI
    Gui, SB:Add, Text, % "x8 y8 w30 h34 +c14A04A Center vSbTick",
    Gui, SB:Font, s9, Segoe UI
    ; The version rides the TITLE BAR (Kaine, 2026-07-19). Safe: the sender pings the SCRIPT
    ; window by full path, never this GUI title - nothing matches on "Receipting worklist".
    if (x != "")
        Gui, SB:Show, % "x" x " y" y " w" W " h" h (visible ? "" : " Hide"), Receipting worklist v%VERSION%
    else
        Gui, SB:Show, % "w" W " h" h (visible ? "" : " Hide"), Receipting worklist v%VERSION%
    SbLayout(W, h)   ; normalise every control's geometry (the single source of layout truth)
    g_sbBuilt := 1
    SbFocusFilter()
}

; Column widths, honouring the hide-columns settings (hidden = width 0). Status + Invoice
; always show. 2.19.0 (Kaine: "compact and spaced perfectly... adaptable when I resize"):
; each visible column auto-sizes to its CONTENT (floored at its header width, so headers
; never clip), replacing the old fixed-widths-plus-flex that left a dead stretch on the
; right. When the window is too narrow for the full content, every column scales down
; proportionally to fit EXACTLY - no horizontal scrollbar, text ellipsizes instead.
; Content-dependent, so SidebarFill re-runs this after every refill.
SbApplyCols(lvClientW) {
    global CfgHideOrder, CfgHideMake, CfgHideDate, CfgHideExGst, CfgHidePoInv
    global g_sbLvHwnd
    Gui, SB:Default
    Gui, SB:ListView, SbLv
    hide := [0, 0, CfgHideMake, CfgHideOrder, CfgHideDate, CfgHideExGst, CfgHidePoInv]
    ; Header-width floors (Consolas 9 headers + sort arrow room). "Auto" is content-only,
    ; and LVSCW_AUTOSIZE_USEHEADER can't be used: on the LAST column it means
    ; "fill the remaining width", which is exactly the dead stretch being removed.
    ; Ex GST's floor is 86, not the header's 58 (2.23.0, Kaine: give it room so it never
    ; gets hidden "if it's like 30,000 in there"). Auto-size fits TODAY's biggest number;
    ; a six-figure total arriving later would be squeezed by the proportional scale-down
    ; below. 86 holds 129244.18 right-aligned, and the column may still grow past it.
    minW := [28, 64, 48, 56, 46, 86, 56]
    wArr := [], total := 0
    Loop, 7
    {
        if (hide[A_Index]) {
            wArr.Push(0)
            continue
        }
        LV_ModifyCol(A_Index, "Auto")
        SendMessage, 0x101D, % A_Index - 1, 0, , ahk_id %g_sbLvHwnd%   ; LVM_GETCOLUMNWIDTH
        cw := ErrorLevel
        if (cw = "FAIL" || cw < minW[A_Index])
            cw := minW[A_Index]
        wArr.Push(cw)
        total += cw
    }
    ; The grid must end EXACTLY where the list ends - too narrow and it ellipsizes, too wide
    ; and there is a dead strip on the right (which is what deleting Receipted would have
    ; left behind, 2.24.0). GetClientRect is the only honest width: it already excludes the
    ; vertical scrollbar, so it re-measures itself when a filter adds or drops the scrollbar.
    ; lvClientW - 25 is the pre-Show fallback (scrollbar 17 + insets), used only on the build
    ; call that runs before the control has a client rect worth reading.
    avail := lvClientW - 25
    VarSetCapacity(rc, 16, 0)
    if (g_sbLvHwnd && DllCall("GetClientRect", "Ptr", g_sbLvHwnd, "Ptr", &rc)) {
        cRect := NumGet(rc, 8, "Int")
        if (cRect > 120)
            avail := cRect
    }
    if (total < avail && avail > 120) {
        ; STRETCH. Column 1 is the status glyph and stays at its measured width - widening
        ; it only pushes the tick off-centre. The slack is shared out over the text columns
        ; in proportion to what they already hold, and the rounding remainder lands on the
        ; last visible column so the sum is the client width to the pixel.
        slack := avail - total
        base := total - wArr[1]
        if (base > 0) {
            lastVis := 0
            Loop, 7
            {
                if (A_Index > 1 && wArr[A_Index]) {
                    add := Floor(slack * wArr[A_Index] / base)
                    wArr[A_Index] += add
                    total += add
                    lastVis := A_Index
                }
            }
            if (lastVis && total < avail)
                wArr[lastVis] += avail - total
        }
    }
    if (total > avail && avail > 120) {
        ; 2.23.1: the squeeze is the thing that ellipsized ERA's values, so it no longer
        ; happens quietly - if the window is ever too narrow again (a longer invoice id
        ; than E-BYDAU26061585, a six-figure total), the log says so instead of the list
        ; just going "STK3...". SB_W is the knob.
        Log("worklist: columns squeezed - need " total "px, have " avail "px (values will ellipsize)")
        Loop, 7
        {
            if (wArr[A_Index])
                wArr[A_Index] := Floor(wArr[A_Index] * avail / total)
        }
    }
    LV_ModifyCol(1, wArr[1] " Center")
    LV_ModifyCol(2, wArr[2])
    LV_ModifyCol(3, wArr[3])
    LV_ModifyCol(4, wArr[4])
    LV_ModifyCol(5, wArr[5])
    LV_ModifyCol(6, wArr[6] ? wArr[6] " Right" : 0)   ; Ex GST right-aligned when shown
    LV_ModifyCol(7, wArr[7])
}

; The ONE place sidebar geometry lives, so every control grows with the window (Kaine,
; 2026-07-18 - "buttons and controls to all grow when I adjust the width"). Called after the
; initial Show and on every resize (SBGuiSize). w/h are CLIENT dimensions.
;   top row:  filter fills the width; Refresh + Setup pinned to the right edge
;   middle:   the ListView absorbs all vertical growth
;   bottom:   progress bar (+ big done-tick capping its right end) and the status text,
;             then the optional log pane. The counts footer is gone (2.23.0) and the
;             Hide-warn toggle moved up to the far right of the brand strip.
SbLayout(w, h) {
    global CfgShowLogPane, g_sbWinHwnd
    M := 8
    innerW := w - 2 * M
    if (innerW < 220)
        innerW := 220
    ; --- top: search box + X + Refresh + Setup (buttons hug the right edge) ---
    ; The X sits flush against the box's right edge, in the cell the combo's drop arrow
    ; used to occupy - 2px of gap, so the pair reads as one control.
    setX := w - M - 48
    refX := setX - 4 - 56
    clrX := refX - 4 - 24
    GuiControl, SB:Move, SbBtnSetup,   % "x" setX " y7 w48 h26"
    GuiControl, SB:Move, SbBtnRefresh, % "x" refX " y7 w56 h26"
    GuiControl, SB:Move, SbBtnClear,   % "x" clrX " y7 w24 h26"
    GuiControl, SB:Move, SbFilter,     % "x" M " y7 w" (clrX - M - 2) " h26"
    ; --- brand strip: fixed-width radios, left to right, wrapping is not a thing here ---
    ; They keep their widths on resize (a count only ever adds 3-4 chars); only the ListView
    ; below them absorbs growth. Widths match the SidebarBuild captions.
    brW := [62, 66, 74, 66, 86]
    brX := M
    for i, ctl in ["SbBrAll", "SbBr1", "SbBr2", "SbBr3", "SbBr4"] {
        GuiControl, SB:Move, %ctl%, % "x" brX " y40 w" brW[i] " h22"
        brX += brW[i] + 2
    }
    ; Hide-warn rides the far right of the SAME row (2.23.0) - it filters the list exactly
    ; like the radios do. Its width is whatever AHK auto-sized the caption to at build time
    ; (SidebarBuild adds it with no w), READ BACK here rather than guessed: a hard-coded
    ; width either clips the label or leaves it visibly short of flush, and the whole point
    ; is that its right edge lands on the same margin as Setup's.
    GuiControlGet, sbTog, SB:Pos, SbHideWarn
    togW := sbTogW ? sbTogW : 118
    GuiControl, SB:Move, SbHideWarn, % "x" (w - M - togW) " y40 w" togW " h22"
    ; --- vertical budget: the stack below the ListView is fixed height; the LV gets the rest ---
    ; 2.23.0: the counts footer is deleted and the bar is back to h18, so the status text is
    ; the last row in the window. Everything freed goes to the ListView:
    ;   below the LV = 8 + 18 (bar) + 4 + 18 (text) + 8 (margin) = 56
    logH := 110
    logExtra := CfgShowLogPane ? (6 + logH) : 0
    lvH := h - 66 - 56 - logExtra
    if (lvH < 100)
        lvH := 100
    GuiControl, SB:Move, SbLv, % "x" M " y66 w" innerW " h" lvH
    tickW := 34
    progY := 66 + lvH + 8
    GuiControl, SB:Move, SbProg, % "x" M " y" progY " w" (innerW - tickW) " h18"
    ; The tick is 26 tall against an 18 bar - centred on it, not hanging past the text below.
    GuiControl, SB:Move, SbTick, % "x" (M + innerW - tickW + 4) " y" (progY - 4) " w" (tickW - 4) " h26"
    txtY := progY + 18 + 4
    GuiControl, SB:Move, SbProgTxt, % "x" M " y" txtY " w" innerW " h18"
    if (CfgShowLogPane) {
        logY := txtY + 18 + 8
        GuiControl, SB:Move, SbLogPane, % "x" M " y" logY " w" innerW " h" logH
    }
    SbApplyCols(innerW)           ; re-flex the columns to the new ListView width
    GuiControl, SB:Move, SbFilter, % "x" M " y7 w" (clrX - M - 2) " h26"   ; redraw after the moves
    ; Force a repaint. GuiControl Move repositions without erasing, so a live drag left
    ; ghost button images at the old positions (probe 2026-07-20: geometry was correct,
    ; the "messed up" buttons were stale paint).
    if (g_sbWinHwnd)
        DllCall("InvalidateRect", "Ptr", g_sbWinHwnd, "Ptr", 0, "Int", 1)
}

; The caret lives in the search box (2.22.0, Kaine: "keep caret/focus permanently in that
; box"). Called after every show, refill, refresh, brand switch and clear. GuiControl Focus
; only moves focus WITHIN the SB Gui - it never activates the window - so calling it while
; a receipt run is typing into ERA cannot steal a keystroke from the run.
SbFocusFilter() {
    global g_sbBuilt
    if (!g_sbBuilt)
        return
    GuiControl, SB:Focus, SbFilter
}

; ---- brands -------------------------------------------------------------------
; The four brands, in strip order. MAKE letter -> label + ERA vendor number (Kaine,
; 2026-07-19, read off KAINE Data.csv's MAKE/VENDOR# columns and confirmed by hand).
; KAINE Data.csv also carries NG and RE - deliberately NOT listed: Kaine's call is that
; only these four ever get receipted, so an NG row lands in "other" and stays visible
; under All rather than being silently dropped.
SbBrands() {
    return [ {m: "BY", label: "BYD",     vendor: "12285"}
           , {m: "IA", label: "Isuzu",   vendor: "10520"}
           , {m: "KI", label: "Kia",     vendor: "10350"}
           , {m: "HY", label: "Hyundai", vendor: "9000"} ]
}

; Invoice id -> MAKE letter. Derived HERE, on the client, so the Make column works today
; without a wire change; SidebarFetch prefers an explicit field 9 when the service starts
; sending one. Prefixes are the confirmed ones:
;   E-BYDAU########  BYD      I#######  Isuzu     L######  Kia      F######  Hyundai
; The L/F split is the same rule the Warehouse PRO server applies in /log-scan.
; Unknown -> "" (shows as "-", still selectable, never hidden by a brand filter except
; when a specific brand is chosen).
SbMakeOf(id) {
    if (id = "")
        return ""
    if (SubStr(id, 1, 5) = "E-BYD")
        return "BY"
    if RegExMatch(id, "^I\d{6,8}$")
        return "IA"
    if RegExMatch(id, "^L\d{5,7}$")
        return "KI"
    if RegExMatch(id, "^F\d{5,7}$")
        return "HY"
    return ""
}

; MAKE letter -> the label shown in the Make column. Unknown/blank reads "-".
SbMakeLabel(m) {
    for i, b in SbBrands() {
        if (b.m = m)
            return b.label
    }
    return (m = "" ? "-" : m)
}

; "16/07/2026" -> 20260716 for sorting. Unparseable/blank -> 0 (sorts oldest).
SbDateNum(d) {
    if RegExMatch(d, "^(\d{2})/(\d{2})/(\d{4})$", m)
        return m3 . m2 . m1
    return 0
}

; Applies g_sbFilter (substring, invoice OR order) into the ListView and rebuilds row -> tip.
; Sort (the approved design): ready group first, then warn; inside each group newest printed
; date first; invoice number (desc) breaks same-day ties. Sorted HERE in AHK and inserted in
; order - the ListView is NoSort NoSortHdr so a header click can't destroy it.
SidebarFill() {
    global g_wlIds, g_wlOrders, g_wlGlyphs, g_wlTips, g_wlRowTip, g_wlRowIdx, g_sbFilter, g_sbTipRow
    global g_wlDates, g_wlExGst, g_wlPoLines, g_wlInvLines, GLYPH_OK, GLYPH_WARN, GLYPH_DOT
    global CfgHideWarnRows, CfgDotBothOnly
    global g_wlMakes, g_sbBrand
    Gui, SB:Default
    GuiControl, -Redraw, SbLv
    LV_Delete()
    g_wlRowTip := {}
    g_wlRowIdx := {}
    g_sbTipRow := 0
    ToolTip
    ; Collect the visible indices, then insertion-sort by the three keys.
    ; TWO filters now, ANDed: the lookup text, then the brand strip. Brand counts are
    ; tallied from the TEXT-filtered set only - so picking BYD must not zero the other
    ; three captions, which is what makes the strip usable as a dashboard.
    brCount := {"": 0, "BY": 0, "IA": 0, "KI": 0, "HY": 0}
    brAll := 0
    vis := []
    Loop % g_wlIds.Length() {
        if (g_sbFilter != "" && !InStr(g_wlIds[A_Index], g_sbFilter) && !InStr(g_wlOrders[A_Index], g_sbFilter))
            continue
        mk := g_wlMakes[A_Index]
        brCount[brCount.HasKey(mk) ? mk : ""] += 1
        brAll += 1
        if (g_sbBrand != "" && mk != g_sbBrand)
            continue
        vis.Push(A_Index)
    }
    GuiControl, SB:, SbBrAll, % "All " brAll
    for i, b in SbBrands()
        GuiControl, SB:, % "SbBr" i, % b.label " " brCount[b.m]
    n := vis.Length()
    Loop % n - 1 {
        i := A_Index + 1
        cur := vis[i]
        j := i - 1
        while (j >= 1 && SbOrderBefore(cur, vis[j])) {
            vis[j + 1] := vis[j]
            j -= 1
        }
        vis[j + 1] := cur
    }
    ; 2.23.0: the ready / check-parts / receipted tallies went with the counts footer that
    ; displayed them. The brand strip's own captions are the only counts left on screen.
    for k, idx in vis {
        ; 2.25.0: Hide-warn hides only the TRIANGLE rows. A red dot is a live invoice
        ; with a real mismatch - Kaine: always visible.
        if (CfgHideWarnRows && g_wlGlyphs[idx] = GLYPH_WARN)
            continue
        ; 2.26.0: a red dot must have BOTH sides of Po/Inv to draw (Settings toggle,
        ; default ON - Kaine 2026-07-24). A bare side (0/5, 3/0) means the PO or the
        ; invoice hasn't landed yet - noise until it does. Untick the box to see them all.
        if (CfgDotBothOnly && g_wlGlyphs[idx] = GLYPH_DOT && (g_wlPoLines[idx] <= 0 || g_wlInvLines[idx] <= 0))
            continue
        poInv := (g_wlPoLines[idx] || g_wlInvLines[idx]) ? g_wlPoLines[idx] "/" g_wlInvLines[idx] : "-"
        ; 2.24.0: no eighth field. The receipted stamp is not printed anywhere now - it is
        ; the colour SbCustomDraw paints this row's tick.
        row := LV_Add("", g_wlGlyphs[idx], g_wlIds[idx], SbMakeLabel(g_wlMakes[idx]), g_wlOrders[idx]
                    , g_wlDates[idx], g_wlExGst[idx], poInv)
        g_wlRowTip[row] := g_wlTips[idx]
        g_wlRowIdx[row] := idx
    }
    GuiControl, +Redraw, SbLv
    ; Columns are content-sized (2.19.0), so a refill means re-measuring them.
    GuiControlGet, sbLvP, SB:Pos, SbLv
    SbApplyCols(sbLvPW)
    SbFocusFilter()   ; the caret belongs in the search box, refill or no refill
}

; Does worklist index a sort strictly before index b?  ready > dot > warn; newer date
; first; invoice number desc breaks the tie.
SbOrderBefore(a, b) {
    global g_wlGlyphs, g_wlDates, g_wlIds, GLYPH_OK, GLYPH_DOT
    ra := (g_wlGlyphs[a] = GLYPH_OK ? 0 : (g_wlGlyphs[a] = GLYPH_DOT ? 1 : 2))
    rb := (g_wlGlyphs[b] = GLYPH_OK ? 0 : (g_wlGlyphs[b] = GLYPH_DOT ? 1 : 2))
    if (ra != rb)
        return ra < rb
    da := SbDateNum(g_wlDates[a]), db := SbDateNum(g_wlDates[b])
    if (da != db)
        return da > db
    return g_wlIds[a] > g_wlIds[b]
}

; Double-click a worklist row -> click-to-receipt. 2.22.0: the Receipt button is gone, so
; this is the ONLY way to fire a run and there is no caption left to keep in sync - the "I"
; (item changed) branch went with the button. The hint lives in the SbProgTxt idle line.
SbLvEvent:
    if (A_GuiEvent = "DoubleClick" && A_EventInfo > 0)
        RcpStart(A_EventInfo)
return

; ---- bold the total of the invoice you last ran, and green its tick once it is done ----
; TWO RULES, and breaking either is what killed the double-click last time:
;
;   1. RETURN NOTHING for every message that is not our ListView's NM_CUSTOMDRAW. An
;      OnMessage function that returns a value STOPS AHK processing that message - and
;      WM_NOTIFY is the same message that carries NM_DBLCLK to gSbLvEvent. Swallow it and
;      double-click silently dies. Every early exit below is a bare `return`, on purpose.
;   2. Filter on hwndFrom FIRST. WM_NOTIFY arrives from every control in the process,
;      including the sender's ListView.
;
; Offsets are 64-bit: the script relaunches itself under AutoHotkeyU64 (see Find64BitAhk),
; so a 32-bit layout never runs.
SbCustomDraw(wParam, lParam, msg, hwnd) {
    global g_sbLvHwnd, g_wlRowIdx, g_sbBoldIdx, g_wlGlyphs, GLYPH_DOT
    static NM_CUSTOMDRAW := -12
    static CDDS_PREPAINT := 0x1, CDDS_ITEMPREPAINT := 0x10001, CDDS_SUBITEMPREPAINT := 0x30001
    static CDRF_NEWFONT := 0x2, CDRF_NOTIFYITEMDRAW := 0x20
    static COL_ST := 0, COL_EXGST := 5    ; 0-based: St|Invoice|Make|Order|Date|Ex GST|Po/Inv
    static GREEN := 0x4AA014              ; COLORREF is BGR - this is RGB 14A04A, the same
                                          ; green as the big done-tick under the bar
    static RED := 0x3C3CD6                ; BGR again - RGB D63C3C, the not-on-PO dot (2.25.0)
    if (!g_sbLvHwnd)
        return                            ; rule 1
    if (NumGet(lParam + 0, 0, "Ptr") != g_sbLvHwnd)
        return                            ; rule 2 - someone else's control
    if (NumGet(lParam + 0, 16, "Int") != NM_CUSTOMDRAW)
        return                            ; rule 1 - this is the DoubleClick path
    stage := NumGet(lParam + 0, 24, "UInt")
    if (stage = CDDS_PREPAINT)
        return CDRF_NOTIFYITEMDRAW        ; "tell me about items"
    if (stage = CDDS_ITEMPREPAINT)
        return CDRF_NOTIFYITEMDRAW        ; same value doubles as CDRF_NOTIFYSUBITEMDRAW
    if (stage != CDDS_SUBITEMPREPAINT)
        return 0
    hdc := NumGet(lParam + 0, 32, "Ptr")
    row := NumGet(lParam + 0, 56, "UPtr") + 1        ; dwItemSpec is 0-based
    col := NumGet(lParam + 0, 88, "Int")
    idx := g_wlRowIdx.HasKey(row) ? g_wlRowIdx[row] : 0
    ; 2.24.0: the status glyph is GREEN once this invoice's run finished clean - it is what
    ; the deleted Receipted column used to say in text. 2.25.0: a not-on-PO dot paints RED
    ; (receipted green outranks it - a clean run is the newer fact). clrText lives at +80
    ; in NMLVCUSTOMDRAW (64-bit) and is written on EVERY subitem, hit or miss, for the
    ; same reason the font is: the struct is reused, so an unset colour is a stale colour.
    cdClr := SbLvTextColour()
    if (col = COL_ST && idx) {
        if (SbIdxReceipted(idx))
            cdClr := GREEN
        else if (g_wlGlyphs[idx] = GLYPH_DOT)
            cdClr := RED
    }
    NumPut(cdClr, lParam + 0, 80, "UInt")
    hit := (col = COL_EXGST) && g_sbBoldIdx && (idx = g_sbBoldIdx)
    ; THE BLEED (2026-07-20): a font selected into the DC stays selected for every cell
    ; painted afterwards, so one bold total turned every later total bold. Putting the
    ; normal font back on each miss is not optional tidying - it is the fix.
    hf := hit ? SbBoldFont() : SbNormalFont()
    if (hf)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", hf)
    return CDRF_NEWFONT                   ; also the "I changed clrText" return value
}

; Has the invoice at worklist index idx been receipted by a run that finished CLEAN?
; A REVIEW run stamped its time with an " R" suffix and does NOT go green (Kaine,
; 2026-07-22: "completed run only") - the row stays white until the re-run comes back clean.
SbIdxReceipted(idx) {
    global g_wlIds, g_rcpDone
    id := g_wlIds[idx]
    if (id = "" || !g_rcpDone.HasKey(id))
        return false
    return !InStr(g_rcpDone[id], "R")
}

; The ListView's own text colour, asked of the control rather than assumed - the same value
; goes back into clrText on every cell that is not a green tick, whatever theme is running.
SbLvTextColour() {
    global g_sbLvHwnd
    static c := ""
    if (c = "") {
        SendMessage, 0x1023, 0, 0, , ahk_id %g_sbLvHwnd%   ; LVM_GETTEXTCOLOR
        c := (ErrorLevel = "FAIL") ? 0x000000 : ErrorLevel
    }
    return c
}

; The ListView's own font, exactly as the control reports it. Handed back to the DC on
; every cell that is NOT the bold one.
SbNormalFont() {
    global g_sbLvHwnd
    static hFont := 0
    if (!hFont)
        hFont := DllCall("SendMessage", "Ptr", g_sbLvHwnd, "UInt", 0x31, "Ptr", 0, "Ptr", 0, "Ptr")
    return hFont
}

; The ListView's own font, cloned heavier and 15% larger. Built once and kept - creating a
; font per paint would leak a GDI handle on every repaint of every row.
;
; 15% is a ceiling, not a preference: ListView row height comes from the CONTROL's font,
; not this one, so a taller cell font gets clipped at the row boundary rather than growing
; the row. Going bigger means raising row height for every row in the list.
SbBoldFont() {
    global g_sbLvHwnd
    static hFont := 0
    if (hFont)
        return hFont
    hCur := SbNormalFont()
    if (!hCur)
        return 0
    VarSetCapacity(lf, 92, 0)                        ; LOGFONTW
    if (!DllCall("GetObject", "Ptr", hCur, "Int", 92, "Ptr", &lf))
        return 0
    h := NumGet(lf, 0, "Int")                        ; lfHeight - negative = character height
    NumPut((h < 0) ? -Round(Abs(h) * 1.15) : Round(h * 1.15), lf, 0, "Int")
    NumPut(800, lf, 16, "Int")                       ; lfWeight - 800 = extra bold
    NumPut(1, lf, 21, "UChar")                       ; lfUnderline
    hFont := DllCall("CreateFontIndirectW", "Ptr", &lf, "Ptr")
    return hFont
}

SbSettingsBtn:
    Gosub, SettingsShow
return

; WM_MOUSEMOVE over the sidebar ListView -> tooltip, but ONLY over the status-glyph column
; (the approved design: hovering the invoice text does nothing). LVM_SUBITEMHITTEST fills
; iSubItem so the column is knowable; subitem 0 is the glyph.
SB_OnMouseMove(wParam, lParam, msg, hwnd) {
    global g_sbLvHwnd, g_wlRowTip, g_sbTipRow
    if (!g_sbLvHwnd)
        return
    if (hwnd != g_sbLvHwnd) {
        if (g_sbTipRow) {
            ToolTip
            g_sbTipRow := 0
        }
        return
    }
    VarSetCapacity(ht, 24, 0)
    NumPut(lParam & 0xFFFF, ht, 0, "Int")
    NumPut((lParam >> 16) & 0xFFFF, ht, 4, "Int")
    SendMessage, 0x1039, 0, &ht, , ahk_id %g_sbLvHwnd%   ; LVM_SUBITEMHITTEST
    row := NumGet(ht, 12, "Int") + 1
    sub := NumGet(ht, 16, "Int")
    if (sub != 0)
        row := 0                      ; not the glyph column -> same as not on a row
    if (row = g_sbTipRow)
        return
    g_sbTipRow := row
    if (row && g_wlRowTip.HasKey(row)) {
        ToolTip, % g_wlRowTip[row]
        SetTimer, SbTipWatch, 300
    } else {
        ToolTip
    }
}

; Clears the tooltip once the mouse leaves the ListView - WM_MOUSEMOVE stops arriving the
; moment the cursor is off our windows, so the handler alone can't see the exit.
SbTipWatch:
    MouseGetPos, , , , sbHover, 2
    if (sbHover != g_sbLvHwnd) {
        ToolTip
        g_sbTipRow := 0
        SetTimer, SbTipWatch, Off
    }
return

; ============================================================
;  Settings window (Gui Set) - the approved 4-tab layout (Safety | What's typed |
;  Timing | Service). Built fresh on every open so the controls always start from the
;  live Cfg values. v5-audit rules kept: uncoloured (themed) CheckBoxes with separate
;  cGray Text descriptions; a Tab3 control because a Gui cannot scroll; manual modality
;  (+Owner alone does NOT disable the owner).
;  Toggles that reflect a LOCKED behaviour are shown checked+disabled and say so -
;  a checkbox that silently does nothing would be a lie.
; ============================================================
SettingsShow:
    ; Password gate (2.12, Kaine): both ways in - the Setup button and the tray item -
    ; land here, so ONE check covers both. Same 123 as the dashboard's invoice delete.
    ; This is a speed bump to stop a picker wandering into the timing values mid-shift,
    ; NOT security: the constant is in plain sight two lines up in this same file.
    if (!SettingsPwOk())
        return
    Gui, Set:Destroy
    Gui, Set:+AlwaysOnTop +LabelSetGui
    Gui, Set:Margin, 10, 10
    Gui, Set:Font, s9, Segoe UI
    Gui, Set:Add, Tab3, w470 h420 vSetTab, Safety|What's typed|Timing|Service|Columns

    ; ---- Tab 1: Safety ----
    Gui, Set:Tab, 1
    Gui, Set:Add, Text, x24 y44 w430 Section, Never finalize is LOCKED on - not a toggle. The sender always stops before Receipt-options.
    Gui, Set:Add, CheckBox, vSetCbConfirm Checked%CfgConfirmTyping%, Confirm before typing
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, Show the plan in a dialog before any keystroke. OFF by default now - the Receipt button fires straight away.
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xp-20 vSetCbDryRun Checked%CfgDryRun%, Dry run (log every keystroke, send NOTHING to ERA)
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, Walk the whole plan without touching ERA - the old sidebar Dry-run button moved here. Never stamps Receipted.
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xp-20 vSetCbScreen Checked%CfgScreenChk%, Read the ERA screen to verify (F11 screen-copy) - no popup, no pause
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, Uses your WIS F11 binding to copy the ERA screen and check it silently: the right order is loaded BEFORE typing, and the subtracted lines really changed AFTER the X-out. A failed check ABORTS the run. Costs well under a second; replaces the checkpoint pause.
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xp-20 vSetCbCkpt Checked%CfgCkptStop%, Stop at the checkpoint (after the X-out / after line 1)
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, The old human verification. Leave it OFF while the screen check above is on - it only stops you for something the sender now checks itself. Turn it back on if the screen check ever reports "could not read".
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xp-20 vSetCbHome Checked1 Disabled, Start every run from ERA's main menu
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, (always on - the run home-pages ERA first; an alternative start point is not built)
    Gui, Set:Font, s9 cDefault

    ; ---- Tab 2: What's typed ----
    Gui, Set:Tab, 2
    Gui, Set:Add, Text, x24 y44 w80 Section, Brand:
    Gui, Set:Add, DropDownList, x+4 w140 vSetDdlBrand gSetBrandChanged, BYD|Isuzu
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430 vSetBrandNote, (brand)
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, Text, xs w80, Receiver:
    Gui, Set:Add, Edit, x+4 w110 vSetEdRecvr, %CfgReceiver%
    Gui, Set:Add, Text, xs w110, Quantity mode:
    Gui, Set:Add, DropDownList, x+4 w170 vSetDdlQty, Auto (cost model)|Qty per line|recv-aLL + prices
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, The quantity mode for every receipt. Auto uses the cost model to pick per-line vs recv-aLL. (This is the only place it is set now.)
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, Text, xs w110, Subtract by:
    Gui, Set:Add, DropDownList, x+4 w250 vSetDdlSub, X out the line  (line / x / Enter)|Receive 0 + backorder  (line / 0 / B)
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, How a line the invoice doesn't ship is un-received - in BOTH qty modes, not just recv-aLL. 0+B is the DEFAULT and the one proven live (a 0 receipt plus a booked backorder). X (line/x) is the video-proven stream but has never run on real ERA - the checkpoint text follows this choice.
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xs vSetCbStripI Checked%CfgStripIsuzuI%, Strip the leading I from Isuzu supplier inv#
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, UNCONFIRMED whether ERA wants I0957035 or 0957035 - leave OFF until a real Isuzu receipt answers it. (BYD's E-BYD strip is server-side and always on.)
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xp-20 vSetCbOver Checked1 Disabled, Full shipped qty on over-shipments
    Gui, Set:Add, CheckBox, vSetCbShort Checked1 Disabled, Answer B on short shipments
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, (standing rules baked into the plan - alternatives are not built)
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xp-20 vSetCbInvUsed Checked%CfgContinueInvUsed%, Continue past "invoice already used" without asking

    ; ---- Tab 3: Timing ----
    Gui, Set:Tab, 3
    Gui, Set:Add, Text, x24 y44 w100 Section, Preset:
    Gui, Set:Add, DropDownList, x+4 w120 vSetDdlPreset gSetPresetChanged, Fast|Normal|Careful|Custom
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, The six REAL waits (ms) the run uses. Presets fill them; any hand edit means Custom. Defaults are the live-proven values.
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, Text, xs w170, After the 2062 menu:
    Gui, Set:Add, Edit, x+4 w60 vSetEdT1, %RCP_AFTER_MENU%
    Gui, Set:Add, Text, xs w170, After the PO# (order load):
    Gui, Set:Add, Edit, x+4 w60 vSetEdT2, %RCP_AFTER_PO%
    Gui, Set:Add, Text, xs w170, After the supplier inv#:
    Gui, Set:Add, Edit, x+4 w60 vSetEdT3, %RCP_AFTER_INV%
    Gui, Set:Add, Text, xs w170, Between line entries:
    Gui, Set:Add, Edit, x+4 w60 vSetEdT4, %RCP_BETWEEN_LINES%
    Gui, Set:Add, Text, xs w170, After a keystream chunk:
    Gui, Set:Add, Edit, x+4 w60 vSetEdT5, %RCP_TEXT_SETTLE%
    Gui, Set:Add, Text, xs w170, After a typed value:
    Gui, Set:Add, Edit, x+4 w60 vSetEdT6, %RCP_VAR_SETTLE%

    ; ---- Tab 4: Service ----
    Gui, Set:Tab, 4
    Gui, Set:Add, CheckBox, x24 y44 vSetCbFan Checked%CfgFanOut% Section, Recon fan-out on (mirror sends to invoice-recon)
    Gui, Set:Add, Text, xs w110, Stale export:
    Gui, Set:Add, DropDownList, x+4 w200 vSetDdlStale, Warn and continue|Block until re-exported
    Gui, Set:Add, Text, xs w110, Stale after (hours):
    Gui, Set:Add, Edit, x+4 w50 vSetEdStaleH, %CfgStaleHours%
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, Checked at receipt time against the service's uploadedAt. Export the CSV immediately before receipting - a stale snapshot degrades to "everything flags".
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, Button, xs w150 gSetUploadPo, Upload PO data now...
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, Sends an ERA PO export CSV to the service and re-reads the worklist against it. Also on this script's tray icon. Uploading does NOT save the settings above - Save or Cancel still decides those.
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, Text, xs w110, Alert when:
    Gui, Set:Add, DropDownList, x+4 w200 vSetDdlAlertWhen, Finish and checkpoint|Checkpoint only|Finish only
    Gui, Set:Add, Text, xs w110, Alert how:
    Gui, Set:Add, DropDownList, x+4 w200 vSetDdlAlertHow, Beep and flash|Beep only|Flash only
    Gui, Set:Add, Text, xs w110, Toast stays (secs):
    Gui, Set:Add, Edit, x+4 w50 vSetEdToastS, %CfgToastSecs%
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, How long the corner pop-up stays before fading. Decimals fine (default 1.2). "Working..." toasts ignore this - they sit until their result replaces them.
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xs vSetCbLog Checked%CfgShowLogPane%, Show the activity log pane in the sidebar

    ; ---- Tab 5: Columns (2.10) ----
    ; The config keys (CfgHide*) have existed since 2.1 and were already honoured by
    ; SbApplyCols - this tab is the switches they never had. Phrased as SHOW, not hide:
    ; a ticked box meaning "hidden" is the sort of double negative that gets misread.
    ; St and Invoice are checked+disabled, per the house rule that a checkbox which does
    ; nothing must say so rather than silently ignore you.
    setShMake := !CfgHideMake, setShOrder := !CfgHideOrder, setShDate := !CfgHideDate
    setShExGst := !CfgHideExGst, setShPoInv := !CfgHidePoInv
    Gui, Set:Tab, 5
    Gui, Set:Add, Text, x24 y44 w430 Section, Which columns the worklist draws. Hidden columns still load and still sort - they are only not shown, so nothing about a run changes.
    Gui, Set:Add, CheckBox, xs vSetCbColSt Checked1 Disabled, St  (status glyph)
    Gui, Set:Add, CheckBox, xs vSetCbColInv Checked1 Disabled, Invoice
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xp+20 w410, (always shown - a row has to stay identifiable, and the Receipt button names the order off it)
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xs vSetCbColMake Checked%setShMake%, Make
    Gui, Set:Add, CheckBox, xs vSetCbColOrder Checked%setShOrder%, Order
    Gui, Set:Add, CheckBox, xs vSetCbColDate Checked%setShDate%, Date
    Gui, Set:Add, CheckBox, xs vSetCbColExGst Checked%setShExGst%, Ex GST
    Gui, Set:Add, CheckBox, xs vSetCbColPoInv Checked%setShPoInv%, Po / Inv
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, The columns still showing stretch to fill the list, so hiding one never leaves a gap on the right. Turning Make off does NOT turn the brand strip off - the strip is a filter, the column is a label. (Receipted is gone as of 2.24.0 - a receipted row draws a green tick instead.)
    Gui, Set:Font, s9 cDefault
    Gui, Set:Add, CheckBox, xs vSetCbDotBoth Checked%CfgDotBothOnly%, % "Show " Chr(0x25CF) " rows only when Po / Inv has both sides"
    Gui, Set:Font, s8 cGray
    Gui, Set:Add, Text, xs w430, % "A " Chr(0x25CF) " row (invoice part not on the PO) draws only when the order has outstanding PO lines AND the invoice has lines - e.g. 4/5. A bare side like 0/5 hides until the PO catches up. All brands. Untick to see every " Chr(0x25CF) " row."
    Gui, Set:Font, s9 cDefault

    Gui, Set:Tab
    Gui, Set:Add, Button, x330 y444 w70 gSetSave Default, Save
    Gui, Set:Add, Button, x406 y444 w64 gSetCancel, Cancel

    ; Push the multi-state values into the dropdowns.
    GuiControl, Set:ChooseString, SetDdlBrand, % (CfgBrand = "isuzu" ? "Isuzu" : "BYD")
    GuiControl, Set:Choose, SetDdlQty, % (CfgQtyModeDefault = "perline" ? 2 : CfgQtyModeDefault = "recvall" ? 3 : 1)
    GuiControl, Set:Choose, SetDdlSub, % (CfgSubtractBy = "zb" ? 2 : 1)
    GuiControl, Set:Choose, SetDdlPreset, % (CfgTimingPreset = "fast" ? 1 : CfgTimingPreset = "careful" ? 3 : CfgTimingPreset = "custom" ? 4 : 2)
    GuiControl, Set:Choose, SetDdlStale, % (CfgStaleMode = "block" ? 2 : 1)
    GuiControl, Set:Choose, SetDdlAlertWhen, % (CfgAlertWhen = "checkpoint" ? 2 : CfgAlertWhen = "finish" ? 3 : 1)
    GuiControl, Set:Choose, SetDdlAlertHow, % (CfgAlertHow = "beep" ? 2 : CfgAlertHow = "flash" ? 3 : 1)
    Gosub, SetBrandNoteRefresh

    if (g_sbVisible)
        Gui, SB:+Disabled          ; manual modality - +Owner alone would NOT disable it
    Gui, Set:Show, , Sender settings
return

; Upload straight from Settings. Deliberately does NOT save or close the window: the
; snapshot lives on the service, not in config.ini, so it has nothing to do with Save.
SetUploadPo:
    PoUploadRun(true)
return

SetBrandChanged:
SetBrandNoteRefresh:
    GuiControlGet, sbBrandSel, Set:, SetDdlBrand
    if (sbBrandSel = "Isuzu")
        GuiControl, Set:, SetBrandNote, Isuzu: vendor 10520 / MAKE IA / invoice I####### (no E- prefix). Confirmed from the export 2026-07-18.
    else
        GuiControl, Set:, SetBrandNote, BYD: vendor 12285 / MAKE BY / invoice E-BYDAU########. Confirmed live.
return

; A preset fills the six waits: Fast = half, Normal = proven defaults, Careful = double.
SetPresetChanged:
    GuiControlGet, spSel, Set:, SetDdlPreset
    if (spSel = "Custom")
        return
    f := (spSel = "Fast" ? 0.5 : spSel = "Careful" ? 2 : 1)
    GuiControl, Set:, SetEdT1, % Round(250 * f)
    GuiControl, Set:, SetEdT2, % Round(400 * f)
    GuiControl, Set:, SetEdT3, % Round(0 * f)
    GuiControl, Set:, SetEdT4, % Round(120 * f)
    GuiControl, Set:, SetEdT5, % Round(200 * f)
    GuiControl, Set:, SetEdT6, % Round(150 * f)
return

SetSave:
    Gui, Set:Submit, NoHide
    CfgConfirmTyping   := SetCbConfirm
    CfgDryRun          := SetCbDryRun
    CfgCkptStop        := SetCbCkpt
    CfgScreenChk       := SetCbScreen
    CfgStripIsuzuI     := SetCbStripI
    CfgContinueInvUsed := SetCbInvUsed
    CfgFanOut          := SetCbFan
    CfgShowLogPane     := SetCbLog
    ; Columns tab: the boxes read SHOW, the config stores HIDE - invert on the way in.
    CfgHideMake        := !SetCbColMake
    CfgHideOrder       := !SetCbColOrder
    CfgHideDate        := !SetCbColDate
    CfgHideExGst       := !SetCbColExGst
    CfgHidePoInv       := !SetCbColPoInv
    CfgDotBothOnly     := SetCbDotBoth
    CfgReceiver        := SetEdRecvr
    CfgBrand           := (SetDdlBrand = "Isuzu" ? "isuzu" : "byd")
    CfgQtyModeDefault  := (SetDdlQty = "Qty per line" ? "perline" : InStr(SetDdlQty, "recv-aLL") ? "recvall" : "auto")
    g_rcpQtyMode       := CfgQtyModeDefault   ; mode lives only in Settings now - apply it live
    CfgSubtractBy      := (InStr(SetDdlSub, "backorder") ? "zb" : "x")
    CfgStaleMode       := (InStr(SetDdlStale, "Block") ? "block" : "warn")
    if SetEdStaleH is integer
        CfgStaleHours := SetEdStaleH
    CfgAlertWhen       := (SetDdlAlertWhen = "Checkpoint only" ? "checkpoint" : SetDdlAlertWhen = "Finish only" ? "finish" : "both")
    CfgAlertHow        := (SetDdlAlertHow = "Beep only" ? "beep" : SetDdlAlertHow = "Flash only" ? "flash" : "both")
    if SetEdToastS is number
    {
        if (SetEdToastS >= 0.5 && SetEdToastS <= 60)
            CfgToastSecs := SetEdToastS
    }
    CfgTimingPreset    := (SetDdlPreset = "Fast" ? "fast" : SetDdlPreset = "Careful" ? "careful" : SetDdlPreset = "Custom" ? "custom" : "normal")
    if SetEdT1 is integer
        RCP_AFTER_MENU := SetEdT1
    if SetEdT2 is integer
        RCP_AFTER_PO := SetEdT2
    if SetEdT3 is integer
        RCP_AFTER_INV := SetEdT3
    if SetEdT4 is integer
        RCP_BETWEEN_LINES := SetEdT4
    if SetEdT5 is integer
        RCP_TEXT_SETTLE := SetEdT5
    if SetEdT6 is integer
        RCP_VAR_SETTLE := SetEdT6
    WriteConfig()
    Log("settings: saved (brand=" CfgBrand " subtract=" CfgSubtractBy " ckpt=" CfgCkptStop " confirm=" CfgConfirmTyping ")")
    Gui, Set:Destroy
    if (g_sbVisible) {
        Gui, SB:-Disabled
        SidebarBuild()            ; column hides / log pane may have changed - rebuild at the fixed size
        SidebarFill()
    }
return

SetCancel:
SetGuiEscape:
SetGuiClose:
    Gui, Set:Destroy
    if (g_sbVisible)
        Gui, SB:-Disabled
return

; ============================================================
;  Settings password gate (2.12)
; ============================================================
; Returns true to open Settings. Cancel/Escape is silent - a wrong-password scold on
; someone who just changed their mind is noise. A WRONG entry says so and is logged,
; because that one is worth seeing in sender.log after the fact.
SettingsPwOk() {
    global SETTINGS_PW, g_sbVisible
    if (g_sbVisible)
        Gui, SB:+OwnDialogs
    InputBox, pwTry, Settings locked, Enter the settings password:, HIDE, 260, 130
    if (ErrorLevel)                       ; Cancel or Escape
        return false
    ; "x" prefix forces a STRING compare. Bare `pwTry = SETTINGS_PW` compares two
    ; numeric-looking strings as numbers, so 0123 and " 123" would both let you in.
    if ("x" pwTry == "x" SETTINGS_PW)
        return true
    Log("settings: wrong password entered - not opened")
    ShowToast("bad", "Wrong password", "Settings not opened")
    return false
}

; ============================================================
;  PO snapshot upload (2.11)
; ============================================================
; The sender has owned this since 2.0, but the stale-export block fires HERE, in the
; worklist, and told you to use "the tray menu" without saying whose - two tray icons,
; and the item only existed on the sender's (Kaine, 2026-07-19). Same endpoint, same
; raw text/csv POST as the sender's MenuUploadPo; neither process owns the snapshot.
;
; fromSet=true means we were called from the Settings window, which is +AlwaysOnTop:
; a toast would render behind it, so that path reports in an owned MsgBox instead.
PoUploadRun(fromSet, presetCsv := "", silent := false) {
    global ReconUrl
    if (ReconUrl = "") {
        if (fromSet) {
            Gui, Set:+OwnDialogs
            MsgBox, 0x30, PO upload unavailable, Set ReconApiUrl in config.ini first.
        } else {
            ShowToast("bad", "PO upload unavailable", "Set ReconApiUrl in config.ini")
        }
        return false
    }

    ; Same gate as Settings (2.13). Uploading REPLACES the snapshot every receipt is
    ; reconciled against, so it is at least as consequential as changing a timing value.
    ; 1.20.0: silent (Full refresh) skips it. Kaine, 2026-07-21: the one-click run asked
    ; for the password TWICE - once here, once in PoExportRun - which is not a gate, it is
    ; a nuisance you learn to type through. The cliff gate below is the real protection and
    ; it still stops a bad snapshot dead.
    if (!silent && !SettingsPwOk())
        return false

    ; 1.19.0: presetCsv is the ERA-driven path (PoExportRun) - identical from here down,
    ; so the preflight, the 409 cliff gate and the po-cache write are shared, not copied.
    if (presetCsv != "")
        poCsv := presetCsv
    else {
        if (fromSet)
            Gui, Set:+OwnDialogs
        FileSelectFile, poCsv, 3, , Select the ERA PO export, CSV (*.csv)
    }
    if (poCsv = "")
        return false
    FileRead, poText, %poCsv%
    if (ErrorLevel || poText = "") {
        if (fromSet)
            MsgBox, 0x30, PO upload failed, Could not read that file.
        else
            ShowToast("bad", "PO upload failed", "Could not read that file")
        return false
    }

    ; ---- Preflight: say what is about to be replaced, BEFORE replacing it (2.13) ----
    ; The snapshot is the thing every receipt is measured against and it had no
    ; confirmation step at all - pick the wrong file and the good rows were simply gone.
    ; A failed status read is NOT fatal: the server-side cliff gate is the real backstop,
    ; this dialog is only here to make the swap visible while it is still free to cancel.
    liveTxt := "(could not read the current snapshot - the service will still refuse a bad export)"
    stRes := HttpGetJson(ReconUrl "/po-data/status", 5000, 1)
    if (stRes.status = 200) {
        RegExMatch(stRes.text, """rowCount""\s*:\s*(\d+)", sRc)
        RegExMatch(stRes.text, """bydRowCount""\s*:\s*(\d+)", sBy)
        RegExMatch(stRes.text, """iaRowCount""\s*:\s*(\d+)", sIa)
        RegExMatch(stRes.text, """kiRowCount""\s*:\s*(\d+)", sKi)
        RegExMatch(stRes.text, """hyRowCount""\s*:\s*(\d+)", sHy)
        ageH := RcpExportAgeHours()
        liveTxt := "Currently live:  " sRc1 " rows  ->  kept " (sBy1 + sIa1 + sKi1 + sHy1)
                 . "  (" sBy1 " BY / " sIa1 " IA / " sKi1 " KI / " sHy1 " HY)"
                 . (ageH >= 0 ? "`nUploaded " ageH " hour(s) ago." : "")
    }
    SplitPath, poCsv, poName
    ; 1.20.0: Full refresh accepts the preflight silently - the CSV came from ERA seconds
    ; ago in the same run, so there is no "wrong file picked" mistake left for the dialog to
    ; catch. It is logged instead, and the 409 cliff gate below is untouched.
    if (silent) {
        Log("po-data: preflight auto-accepted by Full refresh (" poName ") | " StrReplace(liveTxt, "`n", " "))
    } else {
        if (fromSet)
            Gui, Set:+OwnDialogs
        else if (g_sbVisible)
            Gui, SB:+OwnDialogs
        MsgBox, 0x24, Replace the PO snapshot?, % liveTxt "`n`nAbout to upload:  " poName "`n`nThis REPLACES the snapshot every receipt is checked against. The old one is kept and can be rolled back.`n`nUpload it?"
        IfMsgBox, No
        {
            Log("po-data: upload cancelled at the preflight (" poName ")")
            return false
        }
    }

    if (!fromSet)
        ShowToast("load", "Uploading PO data...", "")
    ; Raw text/csv - avoids having to JSON-escape 30 KB of quoted CSV. Defaults are right:
    ; connectMs only gates resolve+connect, and the receive timeout is already 180s.
    poRes := HttpPostJson(ReconUrl "/po-data", poText, false, "text/csv")

    ; ---- 409 = the service refused a cliff (recon-8) ----------------------------------
    ; The snapshot is UNTOUCHED at this point. This is the one that matters: a wrong
    ; export and a stale export produce the identical symptom downstream (everything
    ; flags), so without this the mistake hides inside a state Kaine already tolerates.
    ; Show what the service objected to and let him overrule it - he is the one who
    ; knows whether the export really did just collapse.
    if (poRes.status = 409) {
        ; ["a","b"] -> "a`n  - b". Lazy .*? stops at the FIRST ], which is the end of the
        ; cliff array - the reason strings never contain one.
        cliffTxt := ""
        if (RegExMatch(poRes.text, """cliff""\s*:\s*\[(.*?)\]", cArr))
            cliffTxt := StrReplace(StrReplace(cArr1, """"), ",", "`n  - ")
        Log("po-data: BLOCKED by the cliff gate | " SubStr(poRes.text, 1, 300))
        ; 1.20.0: silent NEVER auto-overrides this. Removing the password was about typing;
        ; this is the one decision that actually needs a human, so Full refresh stops here
        ; and leaves the snapshot alone rather than forcing a suspect export through.
        if (silent) {
            ShowToast("bad", "Full refresh stopped - export looks wrong", StrReplace(cliffTxt, "`n  - ", " / "))
            return false
        }
        if (fromSet)
            Gui, Set:+OwnDialogs
        else if (g_sbVisible)
            Gui, SB:+OwnDialogs
        MsgBox, 0x34, PO upload REFUSED - this looks wrong, % "The service refused this export because it would gut the snapshot:`n`n  - " cliffTxt "`n`nThat is what a wrong ERA filter looks like. The snapshot has NOT been changed.`n`nIf the export really is correct, upload it anyway?"
        IfMsgBox, No
        {
            Log("po-data: cliff refusal accepted - snapshot left alone")
            if (!fromSet)
                ShowToast("ok", "Upload refused - snapshot safe", "Re-export and try again")
            return false
        }
        Log("po-data: cliff gate OVERRIDDEN by Kaine - forcing the upload")
        poRes := HttpPostJson(ReconUrl "/po-data?force=1", poText, false, "text/csv")
    }

    if (poRes.status != 200) {
        Log("po-data: upload failed http=" poRes.status " | " SubStr(poRes.text, 1, 200))
        if (fromSet)
            MsgBox, 0x30, PO upload failed, % "HTTP " poRes.status " - see sender.log."
        else
            ShowToast("bad", "PO upload failed", "HTTP " poRes.status " - see log")
        return false
    }
    FileCopy, %poCsv%, %A_ScriptDir%\po-cache.csv, 1   ; local copy feeds the PO-only rows

    ; recon-7 answers per-make counts; recon-6 only rowCount+bydRowCount, so a missing
    ; make reads as blank rather than 0 and the summary just gets shorter.
    ;
    ; NO `U)` HERE. The sender's copy of this has carried U) since 2.0, which inverts
    ; greediness and makes (\d+) match ONE digit: every upload since has logged
    ; "rows=4 byd=1" for a 497-row/117-BY export, and toasted the same at Kaine. Nothing
    ; downstream read those numbers so nothing broke - it was just quietly lying. The
    ; sender still has it (different file, not touched in this pass).
    RegExMatch(poRes.text, """rowCount""\s*:\s*(\d+)", mRc)
    RegExMatch(poRes.text, """bydRowCount""\s*:\s*(\d+)", mBy)
    RegExMatch(poRes.text, """iaRowCount""\s*:\s*(\d+)", mIa)
    RegExMatch(poRes.text, """kiRowCount""\s*:\s*(\d+)", mKi)
    RegExMatch(poRes.text, """hyRowCount""\s*:\s*(\d+)", mHy)
    parts := ""
    if (mBy1 != "")
        parts .= (parts = "" ? "" : " ") mBy1 " BY"
    if (mIa1 != "")
        parts .= (parts = "" ? "" : " ") mIa1 " IA"
    if (mKi1 != "")
        parts .= (parts = "" ? "" : " ") mKi1 " KI"
    if (mHy1 != "")
        parts .= (parts = "" ? "" : " ") mHy1 " HY"
    ; recon-8 reports what it threw away and what it replaced. Both are new and optional:
    ; a blank match just shortens the summary rather than breaking it.
    RegExMatch(poRes.text, """previous""\s*:\s*\{""rowCount""\s*:\s*(\d+)", mPrev)
    dropTxt := ""
    if (RegExMatch(poRes.text, """dropped""\s*:\s*\{(.*?)\}\s*,\s*""archivedId", mDrop)) {
        ; Just the counts, unwrapped from their two sub-objects - the point is the total
        ; and which buckets, not a JSON dump in a MsgBox.
        dropN := 0
        Loop, Parse, % mDrop1, ","
        {
            if (RegExMatch(A_LoopField, ":\s*(\d+)", dN))
                dropN += dN1
        }
        if (dropN > 0)
            dropTxt := dropN " row(s) dropped (unsupported make or wrong vendor) - normal for NG/RE."
    }
    Log("po-data: uploaded rows=" mRc1 " (" parts ")" (mPrev1 != "" ? " prev=" mPrev1 : "") (dropTxt != "" ? " | " dropTxt : ""))

    if (fromSet)
        MsgBox, 0x40, PO data uploaded, % mRc1 " rows read from the CSV." (parts = "" ? "" : "`n`nKept: " parts ".") (mPrev1 != "" ? "`n`nPrevious snapshot: " mPrev1 " rows (archived - can be rolled back)." : "") (dropTxt = "" ? "" : "`n`n" dropTxt)
    else
        ShowToast("ok", "PO data uploaded", mRc1 " rows" (parts = "" ? "" : " (" parts ")"))

    ; The snapshot just changed - everything on the board reconciles against the old one.
    SidebarRefresh(false)
    return true
}

; ============================================================
;  Stale-export check + alerts (2.1)
; ============================================================
; Age of the service's PO snapshot in hours, from /po-data/status uploadedAt (ISO 8601 UTC).
; Returns -1 when unknowable (no service / no upload / parse failure) - the caller treats
; unknown as NOT stale: the block must never fire on a network hiccup.
RcpExportAgeHours() {
    global ReconUrl
    if (ReconUrl = "")
        return -1
    ; GET, not POST (2.13). This POSTed to a GET-only route for its whole life: the 404
    ; came back as "age unknowable", unknowable is deliberately treated as NOT stale, so
    ; CfgStaleMode=block has never once blocked and the warn path has never once warned.
    ; recon-9 also answers POST here, so an old worklist is fixed too - but this is the
    ; honest call. If it ever 404s again the gate goes quiet again, silently.
    res := HttpGetJson(ReconUrl "/po-data/status", 3000, 1)
    if (res.status != 200)
        return -1
    up := JsonStr(res.text, "uploadedAt")          ; e.g. 2026-07-17T09:05:33.000Z
    if (!RegExMatch(up, "^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", m))
        return -1
    ts := m1 . m2 . m3 . m4 . m5 . m6
    diff := A_NowUTC
    EnvSub, diff, %ts%, Hours
    return diff
}

; warn|block gate before a receipt run. Returns true to proceed.
RcpStaleGate(plan) {
    global CfgStaleMode, CfgStaleHours
    age := RcpExportAgeHours()
    if (age < 0 || age < CfgStaleHours)
        return true
    if (CfgStaleMode = "block") {
        Gui, SB:+OwnDialogs
        MsgBox, 0x30, Export is stale - receipting blocked, % "The PO snapshot on the service is " age " hour(s) old (limit " CfgStaleHours ").`n`nExport a fresh CSV from ERA and upload it - this script's tray icon > Upload PO Data, or Settings > Service > Upload PO data now - then receipt again.`n`nNothing was typed."
        Log("receipt: " plan.id " BLOCKED - export " age "h old (limit " CfgStaleHours "h, mode=block)")
        return false
    }
    Gui, SB:+OwnDialogs
    MsgBox, 0x34, Export looks stale - continue?, % "The PO snapshot on the service is " age " hour(s) old (limit " CfgStaleHours ").`n`nAn old export degrades to 'everything flags' and the plan may not match ERA's screen.`n`nContinue anyway?"
    IfMsgBox, No
    {
        Log("receipt: " plan.id " cancelled at the stale-export warning (" age "h old)")
        return false
    }
    Log("receipt: " plan.id " proceeding past stale-export warning (" age "h old, mode=warn)")
    return true
}

; Beep + taskbar flash per the alert settings. kind = "checkpoint" | "finish".
RcpAlert(kind) {
    global CfgAlertWhen, CfgAlertHow, g_sbWinHwnd
    if (CfgAlertWhen != "both" && CfgAlertWhen != kind)
        return
    if (CfgAlertHow = "beep" || CfgAlertHow = "both")
        SoundBeep, % (kind = "finish" ? 900 : 750), 150
    if ((CfgAlertHow = "flash" || CfgAlertHow = "both") && g_sbWinHwnd) {
        ; FLASHWINFO: flash the sidebar's taskbar button + caption 4 times.
        VarSetCapacity(fw, 4 + A_PtrSize + 12, 0)
        NumPut(4 + A_PtrSize + 12, fw, 0, "UInt")
        NumPut(g_sbWinHwnd, fw, 4, "Ptr")
        NumPut(3, fw, 4 + A_PtrSize, "UInt")        ; FLASHW_ALL
        NumPut(4, fw, 8 + A_PtrSize, "UInt")        ; 4 flashes
        NumPut(0, fw, 12 + A_PtrSize, "UInt")
        DllCall("user32\FlashWindowEx", "Ptr", &fw)
    }
}

; Step-counting progress: total = every keystream visit the run will make. The percentage +
; "step X of Y" go in SbProgTxt so the user can SEE it move (a bare bar reads as static).
; mm:ss since the run started. Ticks, not clock time: a run that crosses midnight still reads
; right, and A_TickCount needs no formatting round-trip.
RcpElapsed() {
    global g_rcpT0
    if (!g_rcpT0)
        return "0:00"
    s := Round((A_TickCount - g_rcpT0) / 1000)
    return (s // 60) ":" Format("{:02}", Mod(s, 60))
}
RcpProgBegin(total) {
    global g_rcpStepsTotal, g_rcpStepsDone, g_sbVisible, g_rcpDry, g_rcpT0
    g_rcpStepsTotal := (total > 0 ? total : 1)
    g_rcpStepsDone := 0
    g_rcpT0 := A_TickCount        ; the run clock starts with the first counted step
    ; A clock that only moves when a STEP lands isn't a timer - a page walk can sit still for
    ; seconds. Tick it once a second instead. The tick only ever calls GuiControl, so it can
    ; interrupt the typing thread without touching ERA (nothing here posts a key).
    SetTimer, RcpTickClock, 1000
    if (g_sbVisible) {
        GuiControl, SB:, SbProg, 0
        GuiControl, SB:+c0B5FD4, SbProg   ; back to blue for a fresh run (flat once coloured - by design)
        GuiControl, SB:, SbTick,          ; clear any leftover done-tick from the last run
        GuiControl, SB:+cDefault, SbProgTxt
        GuiControl, SB:, SbProgTxt, % (g_rcpDry ? "Dry run - starting... 0%" : "Typing into ERA... 0%")
    }
}
RcpProgStep() {
    global g_rcpStepsTotal, g_rcpStepsDone, g_sbVisible, g_rcpDry, g_rcpProgTxt
    g_rcpStepsDone += 1
    ; 100% MEANS DONE, AND ONLY RcpProgDone() SAYS DONE (Kaine, 2026-07-18 20:16 recording:
    ; "150%... 175%... that shouldn't be complete since it's not actually done").
    ; Two separate faults were behind that:
    ;   1. every line counted TWICE - RcpTypeLine stepped, then RcpLines stepped again (fixed
    ;      at the call site: RcpTypeLine owns the per-line step now, so an in-place replay
    ;      counts too),
    ;   2. a run can legitimately take MORE steps than planned - a replayed line is an extra
    ;      step - and a fixed denominator turns that into 175%.
    ; So the estimate is a floor, not a promise: if the run outlives it, grow the denominator
    ; and let the bar creep instead of lying. Capped at 99 here by construction; RcpProgDone
    ; is the only thing that ever writes 100 + the green tick.
    if (g_rcpStepsDone >= g_rcpStepsTotal)
        g_rcpStepsTotal := g_rcpStepsDone + 1
    if (g_sbVisible) {
        pct := Round(g_rcpStepsDone / g_rcpStepsTotal * 100)
        if (pct > 99)
            pct := 99
        GuiControl, SB:, SbProg, %pct%
        g_rcpProgTxt := (g_rcpDry ? "Dry run" : "Typing into ERA") . " ... " pct "%   (step " g_rcpStepsDone " of " g_rcpStepsTotal ")   "
        GuiControl, SB:, SbProgTxt, % g_rcpProgTxt RcpElapsed()
    }
}
; The once-a-second clock. Re-renders the SAME line RcpProgStep last wrote, with a fresh mm:ss,
; so the two never fight over the control.
RcpTickClock:
    if (g_sbVisible && g_rcpProgTxt != "")
        GuiControl, SB:, SbProgTxt, % g_rcpProgTxt RcpElapsed()
return
RcpProgDone() {
    global g_sbVisible, GLYPH_OK, g_rcpStepsDone
    if (g_sbVisible) {
        GuiControl, SB:, SbProg, 100
        GuiControl, SB:+c14A04A, SbProg          ; the bar goes GREEN on completion (Kaine's ask)
        GuiControl, SB:, SbTick, % GLYPH_OK      ; big green tick caps the right end of the bar
    }
}

; ============================================================
;  Click-to-receipt (Rcp*) - double-click a READY worklist row and the sender types the
;  receipt into ERA's Order Receipts screen (2062), exactly the way Kaine does it by hand
;  (recorded 2026-07-16): header (PO#, supplier inv#, GST, vendor), then per line:
;  line# / qty / price. THE SENDER NEVER FINALIZES - it stops at the Field: prompt and
;  hands ERA back for review. Receipt-options / commit stay human.
;
;  Mechanics are ported from Speed_Receipting.ahk (production-proven): characters go by
;  PostMessage WM_CHAR straight to ERA's Afx input control, so nothing depends on focus
;  or foreground state. The keystroke SEQUENCE mirrors Speed_Receipting verbatim:
;     2062```r```r```r```r  PO#  ```r  (order loads)  ```r  INV#  ```r  (used-check)  ```r```r
;  then our per-line loop (line# from the plan - READ, never counted; DO36370 has no line 6).
;
;  Safety shape:
;   - only a READY row can start; the plan is re-fetched at click time vs the CURRENT snapshot
;   - confirm dialog BEFORE any keystroke (shows the derived supplier inv#, the mode
;     arithmetic, and in recv-aLL the lines about to be X'd back out)
;   - ONE checkpoint per run: after the X-out set in recv-aLL, else after line 1
;   - abort = stop typing instantly, leave ERA as-is, log it
;   - not-on-PO parts are not even in the plan (flag only, receive nothing)
;   - the sender NEVER finalizes. That is the backstop under every unverifiable step.
;
;  Qty modes (sidebar radios; session-only, defaults to Auto every start):
;   perline - type the shipped qty on every line (the video's flow). OVER lines get the
;             full shipped qty (receive all, the standing rule).
;   recvall - SUBTRACTIVE (Kaine, 2026-07-17, on video): fire ERA's recv-aLL to flag the
;             WHOLE PURCHASE ORDER received, X out the open lines this invoice doesn't
;             ship, then fix prices. The over-receipt is STEP 1, not a bug.
;             CONFIRMED (Kaine's screenshot, 2026-07-16): pressing "L" at the Field:
;             prompt pops a "Receipt All Parts - Flag all parts as received?" dialog;
;             the sender answers Yes (RcpRecvAllFire). FAILED LIVE 2026-07-16 23:32 with
;             a bare WM_CHAR "L" - dialog never appeared (per-line WM_CHAR digits worked
;             right after, so the control was fine). A real keypress delivers the
;             LOWERCASE char plus KEYDOWN/KEYUP; RcpRecvAllFire replicates that in two
;             stages. The X-out stream is "line# \r x \r" per line, typed at its place
;             in line order by the one sequential work loop (v2.4.0, RcpWorkItems).
;   auto    - score both and take the cheaper (RcpPickMode). NOT a safety gate: a 2026-07-17
;             build read recv-aLL's whole-PO receipt as fatal and hard-blocked it whenever
;             covers != 1 - which is nearly always - and silently disabled the mode for a
;             full day. covers != 1 is the NORMAL case. Ask what surprising behaviour is FOR
;             before guarding it.
; ============================================================

; NOTE: the RCP_* constants are assigned in the AUTO-EXECUTE section at the top of the
; script (search "RCP_RECVALL_KEY"). Do NOT re-declare them here: `global X := val`
; below the first `return` never executes the assignment - the variables stay EMPTY.
; That exact mistake shipped recv-aLL typing nothing at all (2026-07-16).

; Sidebar double-click -> fetch a fresh plan -> confirm -> type.
RcpStart(row) {
    global g_wlRowIdx, g_wlIds, g_wlGlyphs, g_wlTips, GLYPH_OK, GLYPH_WARN, g_wlExGst
    global g_rcpBusy, Busy, g_sbBoldIdx, g_sbLvHwnd
    if (g_rcpBusy || Busy)
        return
    idx := g_wlRowIdx[row]
    if (!idx)
        return
    id := g_wlIds[idx]
    ; Mark this invoice's total for bold. Set BEFORE the warn-row bail below, deliberately:
    ; a refused run is still the invoice you just pointed at, and the number is what you
    ; want to read while the dialog tells you why it will not go.
    if (g_sbBoldIdx != idx) {
        g_sbBoldIdx := idx
        if (g_sbLvHwnd)
            DllCall("InvalidateRect", "Ptr", g_sbLvHwnd, "Ptr", 0, "Int", true)
    }
    if (g_wlGlyphs[idx] = GLYPH_WARN) {
        ; A TRIANGLE row can never be receipted - show WHY instead (same text as the
        ; tooltip). 2.25.0: a red-dot row falls through and RUNS like a ready one - the
        ; plan covers the PO-matched lines, and the not-on-PO part is Kaine's to add to
        ; the PO by hand (Kaine, 2026-07-23: "the red dot one let it run").
        Gui, SB:+OwnDialogs
        MsgBox, 0x30, Not ready to receipt, % g_wlTips[idx] "`n`nNothing was typed. Fix the PO / upload a fresh export first."
        return
    }
    RcpLaunch(id, (g_wlExGst.Length() >= idx) ? g_wlExGst[idx] : "", 0)
}

; THE AUTO-RETRY (v2.9.0 - Kaine, off the 10:36-10:44 Stopped screenshots: "every time you
; get this error, reset it like I was double-clicking on it again... even on the wrong
; screen one... keep retrying until it goes green, cap it at 2 tries"). One RcpLaunch is
; EXACTLY what a sidebar double-click always did: fresh plan fetch against the current
; snapshot, stale gate, confirm (when on), full run - so a retry inherits every safety the
; first attempt had, including the preflight. A run that ends anything but GREEN fires
; itself again after a short breather: Stopped/abort runs, wrong-screen preflight aborts
; and amber REVIEW endings all retry; a run the HUMAN stopped (confirm No, checkpoint No,
; focus-pause Cancel) never does - the retry must not overrule a person. Plan-fetch /
; not-ready / empty-plan returns below do NOT retry either: those are server-state answers
; a re-run cannot change, and a retry loop would just hammer recon.
RcpLaunch(id, exRaw, attempt) {
    global g_rcpQtyMode, ReconUrl
    global g_rcpDry, CfgDryRun, CfgStripIsuzuI, CfgSubtractBy, CfgConfirmTyping
    global RCP_RETRY_MAX, RCP_RETRY_DELAY, g_rcpUserAbort
    g_rcpDry := CfgDryRun ? true : false   ; Dry run is now a Settings toggle, not a button
    ; Re-fetch RIGHT NOW: the sidebar may be minutes old and a CSV upload since then changes
    ; everything. The plan is rebuilt server-side against the CURRENT snapshot.
    ShowToast("load", "Fetching receipt plan...", id)
    res := HttpPostJson(ReconUrl "/receipt-plan", "{""id"":""" id """}")
    if (res.status != 200) {
        ShowToast("bad", "Receipt plan failed", "HTTP " res.status " - see log")
        Log("receipt: plan fetch failed " id " http=" res.status " | " SubStr(res.text, 1, 200))
        return
    }
    plan := RcpParsePlan(JsonStr(res.text, "text"))
    ; 2.25.0: "parts" runs too. The server's plan for a parts invoice types only the
    ; PO-matched lines and DELIBERATELY omits the not-on-PO parts (receiptPlan.js: "not on
    ; PO => flag only, receive nothing"), so the run is safe - the missing part is Kaine's
    ; to add to the PO by hand.
    if (plan.status != "ready" && plan.status != "parts") {
        ShowToast("bad", "Not ready to receipt", "Status now '" plan.status "' - refreshing sidebar")
        Log("receipt: " id " no longer ready (status=" plan.status ") - snapshot changed since the sidebar filled")
        SidebarRefresh(true)
        return
    }
    if (plan.status = "parts")
        Log("receipt: " id " has not-on-PO part(s) - typing the matched lines only (red-dot run)")
    if (plan.lines.Length() = 0) {
        ShowToast("bad", "Nothing to type", "The plan came back empty - see log")
        Log("receipt: " id " ready but zero plan lines - refusing")
        return
    }

    ; The invoice's Ex GST total still rides the plan from the worklist row - informational
    ; since v2.5.0 (the money-total check went with the end walk); kept because the wire
    ; carries it anyway and a future log line may want it.
    plan.exGst := RegExReplace(exRaw, "[^0-9.\-]")

    ; Stale-export gate (2.1): warn or hard-block per settings. Never fires on a network
    ; hiccup - an unknowable age counts as fresh.
    if (!g_rcpDry && !RcpStaleGate(plan))
        return

    ; Isuzu supplier inv# strip (2.1, default OFF): whether ERA wants the leading I gone is
    ; UNCONFIRMED. The server always sends the id whole; this is the one place that decides.
    if (CfgStripIsuzuI && RegExMatch(plan.id, "^I\d{7}$") && SubStr(plan.inv, 1, 1) = "I") {
        plan.inv := SubStr(plan.inv, 2)
        Log("receipt: " plan.id " supplier inv# I-strip applied -> " plan.inv)
    }

    overN := 0, boN := 0
    for i, l in plan.lines {
        if (l.over > 0)
            overN++
        if (l.bo > 0)
            boN++
    }
    ; Resolve the mode against THIS plan, not the radio alone: the radio is a preference and
    ; Auto has to score the plan. The confirm dialog shows the arithmetic and, in recv-aLL,
    ; names the lines about to be X'd back out.
    plan.mode := RcpPickMode(plan, g_rcpQtyMode)
    note := RcpModeNote(plan, g_rcpQtyMode, plan.mode)
    mode := (plan.mode = "recvall" ? "recv-aLL, then IN LINE ORDER: X-outs + qty/price fixes (invoice values at the PO's line numbers - one deterministic pass, no review walk)" : "type qty per line")
    msg := plan.id "  ->  order " plan.order "`n`n"
         . plan.lineCount " line(s) of the order's " plan.poLines " open line(s), " plan.chgCount " price change(s)`n"
         . "Supplier Inv#:  " plan.inv "`n"
         . "Qty mode:  " mode
    if (note)
        msg .= "`n" note
    ; v2.21.0: the subtract happens in BOTH modes, so it is named in both - the dialog used to
    ; only mention it under recv-aLL, which read as "per-line has nothing to subtract".
    if (plan.uncovered.Length() > 0) {
        subDesc := (CfgSubtractBy = "zb" ? "receive 0 + backorder (line/0/B)" : "X out (line/x - UNPROVEN on real ERA)")
        msg .= (plan.mode = "recvall"
              ? "`n`nrecv-aLL will receipt ALL " plan.poLines " line(s), then work IN LINE ORDER, subtracting by " subDesc ":`n"
              : "`n`nPer-line types the shipped line(s), and IN LINE ORDER subtracts the line(s) this invoice does not ship by " subDesc ":`n")
              . RcpUncoveredNote(plan)
    }
    if (overN)
        msg .= "`nOver-shipped line(s): " overN "  (received in full)"
    if (boN)
        msg .= "`nBackorder line(s): " boN
    if (g_rcpDry)
        msg .= "`n`nDRY RUN - every keystroke is LOGGED, nothing reaches ERA."
    msg .= "`n`nERA must be at the MAIN MENU.`nHands off the keyboard until the checkpoint.`n`nType this into ERA now?"
    if (CfgConfirmTyping) {
        Gui, SB:+OwnDialogs
        MsgBox, 0x34, Receipt invoice?, %msg%
        IfMsgBox, No
        {
            Log("receipt: " id " cancelled at confirm")
            return
        }
    } else {
        Log("receipt: " id " confirm dialog OFF (settings) - proceeding")
    }
    res := RcpRun(plan)
    ; The retry decision. "green" is the only ending that rests; a dry run never retries
    ; (nothing real failed), and a human stop is final.
    if (g_rcpDry || res = "green" || g_rcpUserAbort)
        return
    if (attempt >= RCP_RETRY_MAX) {
        Log("retry: " id " still not green after " RCP_RETRY_MAX " retr" (RCP_RETRY_MAX = 1 ? "y" : "ies") " - leaving ERA for the human")
        ShowToast("bad", "Not green after " (attempt + 1) " attempts", id ": review ERA + the log before running it again")
        return
    }
    Log("retry: " id " run ended '" res "' - re-running like a fresh double-click (retry " (attempt + 1) " of " RCP_RETRY_MAX ")")
    ShowToast("load", "Retry " (attempt + 1) " of " RCP_RETRY_MAX, id ": run ended '" res "' - firing it again")
    Sleep, %RCP_RETRY_DELAY%     ; let ERA finish the repaint/freeze that killed the attempt
    RcpLaunch(id, exRaw, attempt + 1)
}

; Wire text -> plan object.  H|id|order|supplierInv|status|lineCount|changeCount|poLines|covers
;                            L|eraLine|part|qty|price|bo|over|chg
;                            X|eraLine|part          (recon-5+: open lines this invoice misses)
; poLines/covers arrive from recon-4+, X rows from recon-5+. An older service omits them ->
; poLines/covers stay 0 and uncovered stays EMPTY, which degrades to per-line (the cost model
; scores recvall as 1+0+changes against perline=lines, and with no X rows there is nothing to
; subtract) - never to an unguarded over-receipt.
RcpParsePlan(block) {
    plan := {status: "parse-error", lines: [], uncovered: [], poLines: 0, covers: 0}
    Loop, Parse, block, `n
    {
        f := StrSplit(A_LoopField, "|")
        if (f[1] = "H" && f.Length() >= 7) {
            plan.id := f[2], plan.order := f[3], plan.inv := f[4]
            plan.status := f[5], plan.lineCount := f[6], plan.chgCount := f[7]
            if (f.Length() >= 9)
                plan.poLines := f[8] + 0, plan.covers := f[9] + 0
        } else if (f[1] = "L" && f.Length() >= 8) {
            plan.lines.Push({line: f[2], part: f[3], qty: f[4], price: f[5]
                           , bo: f[6] + 0, over: f[7] + 0, chg: f[8] + 0})
        } else if (f[1] = "X" && f.Length() >= 3) {
            plan.uncovered.Push({line: f[2], part: f[3]})
        }
    }
    return plan
}

; How many lines actually need typing: a price change, a backorder, or an over-shipment.
RcpActionable(plan) {
    n := 0
    for i, l in plan.lines {
        if (l.chg || l.bo || l.over)
            n++
    }
    return n
}

; Is this ERA line in the X-out set? recv-aLL un-receives it, so the fix loop must NOT also
; visit it. Matters for a take=0 waterfall line, which is both "backordered" (bo > 0, so it
; looks actionable) and uncovered (ships nothing, so it gets X'd). None exist in the current
; export - this keeps a latent double-handling bug from ever surfacing.
RcpIsUncovered(plan, lineNo) {
    for i, u in plan.uncovered {
        if (u.line = lineNo)
            return true
    }
    return false
}

; Lines the recv-aLL fix loop actually visits: needs an edit AND wasn't X'd out.
RcpActionableRecvAll(plan) {
    n := 0
    for i, l in plan.lines {
        if ((l.chg || l.bo || l.over) && !RcpIsUncovered(plan, l.line))
            n++
    }
    return n
}

; (RcpDeferredPrice lived here until v2.5.0 - price-only lines are typed deterministically
; now, not deferred to a walk that no longer exists.)

; Cost of each mode in line visits - the ONLY thing that picks the mode under Auto.
;   per-line: every plan line (line# / qty / [B] / price) PLUS one subtract per uncovered line.
;   recv-aLL: one L + dialog, one X per uncovered line, then only the lines needing edits.
; BY36466 (live, 2026-07-17): per-line 31 vs recv-aLL 1 + 1 + 7 = 9.
; E-BYDAU26061461 (1 part on DO35874's 8 open lines): per-line 1 + 7 = 8 vs recv-aLL
; 1 + 7 + 1 = 9 -> per-line. That invoice is the regression guard: it must still resolve
; per-line, but now because it is CHEAPER, not because recv-aLL is forbidden. If it ever
; picks recv-aLL the cost model is inverted.
;
; v2.21.0 (Kaine, 2026-07-22: "it doesn't go to 0 backorder... on some invoices it skips
; that"). The subtract used to be a recv-aLL-only step, so per-line simply LEFT every
; uncovered line untouched - no 0+B, no X, nothing - and the cost model then picked per-line
; precisely BECAUSE it was pricing a job it wasn't going to do. Six invoices went out that
; way (I0973146, I0972304, I0972640, E-BYDAU26061461/-853/-887). Uncovered lines are now
; subtracted in BOTH modes, so this count is honest and the mode choice no longer decides
; whether the invoice is receipted accurately - only how the COVERED lines get received.
RcpCostPerLine(plan) {
    n := 0
    for i, l in plan.lines {
        if (!RcpIsUncovered(plan, l.line))   ; its "sub" entry below IS that line's edit
            n++
    }
    return n + plan.uncovered.Length()
}
RcpCostRecvAll(plan) {
    return 1 + plan.uncovered.Length() + RcpActionableRecvAll(plan)
}

; Can recv-aLL be fired at all? recv-aLL is SUBTRACTIVE (Kaine, 2026-07-17, on video): fire L
; to flag the WHOLE PO received, X out the lines this invoice doesn't ship, then fix prices.
; So `covers != 1` is the NORMAL case - it is precisely what the X-out step exists for, and it
; is NOT a reason to refuse. Reading it as fatal and hard-blocking recv-aLL disabled the mode
; for a full day (2026-07-17); the block is gone.
;
; The one case that still refuses is VERSION SKEW: the header says this invoice does not cover
; the PO, but no X rows arrived to name the gap. That means an old service (recon-4 or older),
; and firing recv-aLL there would receipt the gap with nothing to subtract it back out. Refuse
; rather than guess - the guard now triggers on a genuine contradiction, never on the happy path.
RcpRecvAllSafe(plan) {
    return (plan.covers = 1) || (plan.uncovered.Length() > 0)
}

; Resolve the qty mode for THIS plan. Returns "perline" or "recvall".
; Auto takes the cheaper; an explicit radio choice is honoured (subject only to the skew
; refusal above). Ties go to per-line: it is the proven mode and has fewer moving parts.
RcpPickMode(plan, want := "auto") {
    if (want = "recvall")
        return RcpRecvAllSafe(plan) ? "recvall" : "perline"
    if (want = "perline")
        return "perline"
    if (!RcpRecvAllSafe(plan))
        return "perline"
    ; 1.19.1 (Kaine, 2026-07-21): Hyundai defaults to recv-aLL under auto, cost regardless.
    ; Auto only ever picks recvall when it is STRICTLY cheaper, and every ready HY plan is a
    ; one-line price fix against a big open PO - per-line costs 1, which nothing beats - so
    ; recv-aLL was never once offered on an F-invoice. The safety gate still rules: if
    ; RcpRecvAllSafe said no we already returned perline above, so this can only ever pick a
    ; recv-aLL that was allowed anyway. Brand comes from the invoice id (F###### = HY), the
    ; same rule the sidebar's Make column uses.
    if (SbMakeOf(plan.id) = "HY")
        return "recvall"
    return (RcpCostRecvAll(plan) < RcpCostPerLine(plan)) ? "recvall" : "perline"
}

; Why the resolved mode is what it is - "" when there's nothing worth saying.
RcpModeNote(plan, want, mode) {
    pl := RcpCostPerLine(plan), ra := RcpCostRecvAll(plan)
    sums := "recv-aLL = 1 + " plan.uncovered.Length() " X-out(s) + " RcpActionableRecvAll(plan) " fix(es) = " ra " step(s);  per-line = " pl " step(s)"
          . (plan.uncovered.Length() ? " (includes the same " plan.uncovered.Length() " subtract(s) - both modes do them)." : ".")
    if (want = "recvall" && mode = "perline")
        return "recv-aLL UNAVAILABLE: this invoice covers " plan.lines.Length() " of the order's " plan.poLines " open line(s),"
             . "`nbut the service sent no X-out list to un-receive the rest (needs recon-5+). Using per-line."
    if (want = "auto")
        return "Auto chose " (mode = "recvall" ? "recv-aLL" : "per-line") ": " sums
    return sums
}

; The X-out set, for the confirm dialog. Kaine reads this before saying yes, so it names the
; lines rather than just counting them - "X out line 19 (13699738-00)" is checkable against
; the screen; "1 uncovered line" is not.
RcpUncoveredNote(plan) {
    if (plan.uncovered.Length() = 0)
        return ""
    s := ""
    for i, u in plan.uncovered {
        if (i > 6) {
            s .= ", +" (plan.uncovered.Length() - 6) " more"
            break
        }
        s .= (s = "" ? "" : ", ") "ln " u.line " (" u.part ")"
    }
    return s
}

RcpRun(plan) {
    global g_rcpBusy, g_rcpQtyMode, Busy, g_rcpDry, CfgCkptStop, g_rcpDone, CfgScreenChk
    global g_sbVisible, GLYPH_OK, GLYPH_BAD, g_rcpTyped, g_rcpStepsDone, g_rcpProgTxt, g_rcpNoCost, g_rcpAtLine
    global g_rcpFgOk, g_rcpSeen, g_rcpPage, g_rcpWant, g_rcpUserAbort
    g_rcpUserAbort := false      ; per-run: set only by a human No/Cancel - blocks the auto-retry
    g_rcpTyped := {}             ; per-run: which lines this run actually typed (the line retry uses it)
    g_rcpNoCost := {}            ; per-run: lines ERA closed without a cost prompt (see the check)
    g_rcpSeen := {}              ; per-run: clean grid rows seen on paid-for captures (price skip)
    g_rcpPage := {}              ; per-run: the grid rows of the page the last capture showed (page gate)
    g_rcpWant := {}              ; per-run: what each entry meant to leave on screen (landed sweep)
    g_rcpAtLine := false         ; per-run: no sync-skip until a settle capture earns one
    WinGet, g_rcpFgOk, ID, A     ; per-run: whatever holds the focus NOW (usually this worklist)
                                 ; is approved - the guard only pauses on a NEW focus thief
    if (!g_rcpDry && !RcpAcquire()) {
        ShowToast("bad", "ERA window not found", "Open ERA Port first - nothing was typed")
        Log("receipt: ERA Port window/control not found - aborted before typing")
        return "stopped"
    }
    if (plan.mode = "")          ; RcpRun is only ever reached via RcpLaunch, but never
        plan.mode := RcpPickMode(plan, g_rcpQtyMode)   ; type blind if that changes
    g_rcpBusy := true
    Busy := true                 ; also blocks Send all / bulk send for the duration
    Log("receipt: START " plan.id " -> " plan.order " mode=" plan.mode " (radio=" g_rcpQtyMode ")" (g_rcpDry ? " DRY-RUN" : "") " lines=" plan.lineCount "/" plan.poLines
      . " covers=" plan.covers " changes=" plan.chgCount " uncovered=" plan.uncovered.Length()
      . " cost(perline=" RcpCostPerLine(plan) " recvall=" RcpCostRecvAll(plan) ")")
    ShowToast("load", (g_rcpDry ? "Dry run..." : "Typing into ERA..."), plan.order (g_rcpDry ? " - logging only" : " - hands off the keyboard"))
    ; Progress = typed steps: 1 header + per-line visits (per-line mode) or L + X-outs +
    ; fixes (recv-aLL). Parks where the run parks; the checkpoint holds it mid-bar.
    ; A line replay (the one in-place retry) grows the denominator on its own via
    ; RcpProgStep's overflow rule, so the bar still only reaches 100 via RcpProgDone.
    ; v2.21.0: count the REAL work list rather than re-deriving it - per-line now carries the
    ; subtracts too, and two formulas for one list is how the 175% bar happened.
    steps := 1 + (plan.mode = "recvall" ? 1 : 0) + RcpWorkItems(plan).Length()
    RcpProgBegin(steps)
    ok := false
    if (RcpHeader(plan)) {
        RcpProgStep()
        ; PRE-FLIGHT (2026-07-18): read the screen and prove THIS order is loaded before a
        ; single quantity is typed. Aborting here is free - nothing has been typed yet.
        if (EraPreflight(plan))
            ok := RcpLines(plan, CfgCkptStop ? true : false)
    }
    g_rcpBusy := false
    Busy := false
    ; THE DETERMINISTIC PASS (Kaine, 2026-07-19: "rip it all out, make it deterministic...
    ; speed is king"). There is NO end-of-run page walk, NO finish check and NO repair pass
    ; any more - the review-and-fix machinery was the page-flicking he filmed, and its
    ; re-checks were wrong more often than the typing. Accuracy now comes from the pass
    ; itself: the preflight proves the order, every line visit is gated on the line prompt,
    ; every after-qty answer is read off the screen, the qty echo is checked on the capture
    ; already paid for, and a line that fails is replayed ONCE in place (a line number jumps
    ; ERA to that line - no paging) before the run stops with a precise message.
    ; The run is over - stop the clock before anything reports it, so the number on screen is
    ; the number in the log. RcpElapsed() still reads right after this (it measures from
    ; g_rcpT0; only the 1s re-render stops).
    SetTimer, RcpTickClock, Off
    g_rcpProgTxt := ""
    if (ok) {
        ; PARK THE CARET (Kaine, 20:49 recording: "it keeps going back to doing this where
        ; the caret gets stuck"). A finished run used to leave ERA wherever the last capture
        ; happened to sit - mid-grid, mid-prompt. Walk it back to the line prompt so the
        ; screen he reviews is the screen he expects. Enter-only recovery: a view fix, never
        ; an edit. v2.7.0: no longer best-effort-and-forget - the 08:19 run "parked" into a
        ; FROZEN cost prompt, gave up, and still reported DONE while line 70 sat wrong on
        ; screen. A failed park now gets ONE late re-read (ERA settled seconds after that
        ; freeze), feeds the landed sweep, and if the line prompt still can't be proven the
        ; run ends REVIEW-amber, never green.
        parkOk := true
        if (!g_rcpDry && CfgScreenChk) {
            parkOk := EraSync("line")
            if (!parkOk) {
                Sleep, 3000
                scr := EraScreen()
                if (scr != "") {
                    RcpSeenCache(EraParseRows(scr))   ; the sweep rides this late capture too
                    parkOk := (EraPrompt(scr) = "line")
                    Log("park: late re-read " (parkOk ? "settled at the line prompt" : "still not at the line prompt - REVIEW the last line on ERA"))
                }
            }
        }
        ; THE VERIFY SUMMARY (Kaine, 08:20 video: "review the changes you made to make sure
        ; they actually got received and put in correctly"). Zero extra walks: the sweep rode
        ; every capture the run already paid for; this just reads the verdicts.
        provN := 0, totN := 0, wrongN := 0, wrongTxt := "", unseenN := 0
        for vNo, vW in g_rcpWant {
            totN++
            if (vW.proof = "ok")
                provN++
            else if (vW.proof = "wrong")
                wrongN++, wrongTxt .= (wrongTxt = "" ? "" : ", ") "ln " vNo " (saw " vW.seen ")"
            else
                unseenN++
        }
        if (totN && !g_rcpDry)
            Log("verify: " plan.id " " provN "/" totN " entr" (totN = 1 ? "y" : "ies") " proven on screen"
              . (wrongN ? " - WRONG: " wrongTxt : "") (unseenN ? " - " unseenN " not re-shown after typing" : ""))
        clean := (parkOk && !wrongN)
        RcpProgDone()
        ; "It went through" signal: green tick only when the screen agrees it went through.
        if (g_sbVisible) {
            if (clean) {
                GuiControl, SB:+c1F9E4D, SbProgTxt
                ; 2.23.0: the clean line is order + clock + steps, nothing else. "typed.
                ; Review + finalize on ERA." was narration you already know by heart. The
                ; WARN and STOPPED lines below keep their explanation - that one is a
                ; diagnosis, and the log is the only other place it exists.
                GuiControl, SB:, SbProgTxt, % GLYPH_OK " " (g_rcpDry ? "Dry run complete - nothing was sent to ERA" : "Done - " plan.order) "   " RcpElapsed() " / " g_rcpStepsDone " steps"
            } else {
                GuiControl, SB:, SbTick,               ; no green tick on an unproven run
                GuiControl, SB:+cB26B00, SbProg        ; the bar goes AMBER, not green
                GuiControl, SB:+cB26B00, SbProgTxt
                GuiControl, SB:, SbProgTxt, % GLYPH_BAD " Done, but REVIEW " plan.order " on ERA - " (wrongN ? "screen differs on " wrongTxt : "ERA never settled at the line prompt") "   " RcpElapsed() " / " g_rcpStepsDone " steps"
            }
        }
        RcpAlert("finish")
        if (!g_rcpDry) {
            ; Receipted stamp = "the sender TYPED this at HH:mm". Never-finalize means the
            ; human still commits - accepted overclaim, recorded dissent (card a4).
            ; 2.24.0: `clean` rides along. Both cases are recorded (the invoice WAS typed),
            ; but only a clean one turns the row's tick green.
            StampReceipted(plan.id, clean)
            SidebarFill()
        }
        ; Time + steps in the LOG too (22:41): the bar is gone the moment the next run starts,
        ; and "did that get faster?" can only be answered from a timeline.
        Log("receipt: DONE " plan.id " - " plan.lineCount " line(s) " (g_rcpDry ? "dry-logged" : "typed") " in " RcpElapsed() " over " g_rcpStepsDone " step(s)." (clean ? "" : " REVIEW REQUIRED - see the verify/park lines above.") " Sender does NOT finalize; review on ERA.")
        if (clean)
            ShowToast("ok", (g_rcpDry ? "Dry run complete" : "Worklist typed - review it"), plan.order (g_rcpDry ? ": see sender.log" : ": check the lines, then finalize yourself"))
        else
            ShowToast("bad", "Typed, but REVIEW on ERA", plan.order ": " (wrongN ? "screen differs from the invoice on " wrongTxt : "ERA never settled - check the last line before finalizing"))
        ; ERA-KEPT COSTS (N3, kept through the v2.5.0 strip-down): a line ERA closed without
        ; ever asking for a cost has a price no keystream can set. Counted as it happened -
        ; no screen read here - and the toast OUTLIVES the done-toast on purpose, pointing
        ; the human review (which always happens - never-finalize) straight at those lines.
        keptN := 0, keptLines := ""
        for kLn in g_rcpNoCost
            keptN++, keptLines .= (keptLines = "" ? "" : ", ") "ln " kLn
        if (keptN && !g_rcpDry)
            ShowToast("bad", "Review " keptN " cost(s) on ERA", plan.order ": " keptLines " - ERA kept its own cost; fix by hand if the invoice differs.")
        return (clean ? "green" : "review")   ; v2.9.0: the launcher retries anything but green
    } else {
        ; A failed/aborted run: red stop marker so the green from a prior run can't mislead.
        if (g_sbVisible) {
            GuiControl, SB:, SbTick,               ; no done-tick on a stop
            GuiControl, SB:+cC42B2B, SbProgTxt
            GuiControl, SB:, SbProgTxt, % GLYPH_BAD " Stopped - ERA left as-is. See the toast / log.   " RcpElapsed() " / " g_rcpStepsDone " steps"
        }
        return "stopped"
    }
}

; Find the ERA Port window and its Afx input control (same two class-name candidates as
; Speed_Receipting - one build of ERA exposes 00010003, another 00010005).
RcpAcquire() {
    global g_rcpHwnd, g_rcpCtl
    SetTitleMatchMode, 2
    g_rcpHwnd := WinExist("ERA Port")
    if (!g_rcpHwnd)
        return false
    ControlGet, ctl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %g_rcpHwnd%
    if (!ctl)
        ControlGet, ctl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %g_rcpHwnd%
    g_rcpCtl := ctl
    return (g_rcpCtl != 0)
}

; ================= READING THE ERA SCREEN (2026-07-18) ==========================
; Every "the sender is blind" note in this file predates Kaine's WIS keyboard config
; (Key_Kaine.wis):
;     Key_F11 = "\mInvoke ScrollEndPage;Invoke EditSelectWindow;Invoke EditCopy"
;     Key_ControlShift_D = the same, as a backup binding
; F11 inside ERA puts the ENTIRE screen text on the Windows clipboard. WM_GETTEXT still
; returns 0 - that probe was right - but the terminal will hand us the text if we ask it
; the way a human does. So verification no longer has to be a human at a MsgBox.
;
; EraScreen(): press the binding, wait for the clipboard, hand back the text, put the
; user's clipboard back exactly as it was. Returns "" when the capture fails, and EVERY
; caller treats "" as "unknown" - i.e. it falls back to today's blind behaviour rather
; than inventing a verdict. Cost is one keypress + a contention-free wait: ~0.3-0.7 s,
; against a checkpoint MsgBox that costs however long Kaine takes to look at it.
EraScreen() {
    global g_rcpHwnd, g_rcpCtl, g_rcpDry, ERA_SCR_KEY, ERA_SCR_WAIT, g_eraScrOk
    if (g_rcpDry)
        return ""                       ; a dry run has no ERA screen to read
    if (!g_rcpHwnd && !RcpAcquire())
        return ""
    saved := ClipboardAll               ; the clipboard is global state - always give it back
    ; THE CLIPBOARD RACE (Kaine, 2026-07-19: "a lot of these clipboard message box pop-ups").
    ; wIntegrate's EditCopy and this script both open the same global clipboard; whoever
    ; loses shows "Clip: Unable to open Clipboard". ClipWait POLLS by opening the clipboard,
    ; so the old code could collide with the very copy it was waiting for. Now we wait on
    ; GetClipboardSequenceNumber instead - reading it never OPENS the clipboard, so the copy
    ; can never lose to us - and only open it once, AFTER the terminal has written (+ a short
    ; settle so we don't grab it the same instant). One retry: if the popup still appeared
    ; (e.g. we collided with Kaine's own copy, or a slow macro), close it and press F11 again.
    txt := ""
    Loop, 2
    {
        Clipboard := ""
        seq := DllCall("GetClipboardSequenceNumber", "UInt")
        RcpKey(ERA_SCR_KEY)             ; F11 -> ScrollEndPage + EditSelectWindow + EditCopy
        if (!EraClipSeqWait(seq, ERA_SCR_WAIT)) {
            ; Backup binding. The WIS map may only see a real modifier chord on some builds;
            ; ControlSend assembles one, where a bare PostMessage cannot.
            ControlSend, , ^+d, ahk_id %g_rcpHwnd%
            EraClipSeqWait(seq, ERA_SCR_WAIT)
        }
        Sleep, 30                       ; the write landed; a few ms more so we never open
        txt := Clipboard                ; the clipboard the same instant the terminal does
        if (txt != "")
            break
        ; Nothing arrived. If the terminal's copy died on the popup, close it and go again;
        ; a failure with NO popup is the old plain miss - no point repeating it.
        if (!EraClipPopupClose())
            break
        Sleep, 150
    }
    Clipboard := saved
    saved := ""                         ; free the (possibly large) buffer
    if (txt = "") {
        Log("screen: capture FAILED (no clipboard after F11 and Ctrl+Shift+D)")
        return ""
    }
    g_eraScrOk++
    EraDump(txt)
    return txt
}

; Wait for the clipboard CONTENT to change without ever opening the clipboard: the sequence
; number bumps on every write, and reading it is contention-free (unlike ClipWait's polling).
; Returns true when a write landed inside timeoutSecs.
EraClipSeqWait(seq, timeoutSecs) {
    t0 := A_TickCount
    while (A_TickCount - t0 < timeoutSecs * 1000) {
        if (DllCall("GetClipboardSequenceNumber", "UInt") != seq)
            return true
        Sleep, 25
    }
    return (DllCall("GetClipboardSequenceNumber", "UInt") != seq)
}

; Close wIntegrate's "Clip: Unable to open Clipboard" popup (a #32770 dialog titled
; "wIntegrate" - the terminal's main window is "ERA Port", so this can never match it).
; The popup is pure noise once the capture retries, but LEFT OPEN it sits over the terminal
; and a mid-run one can stall ERA's redraw under our captures. Clicked, never keyed: an OK
; via ControlClick can't leak a keystroke into the ERA screen the run is typing on.
; Also swept by a 2s timer (auto-exec), so popups from Kaine's own copies get mopped up too.
EraClipPopupClose() {
    SetTitleMatchMode, 3                ; the popup title is EXACTLY "wIntegrate"
    h := WinExist("wIntegrate ahk_class #32770")
    SetTitleMatchMode, 2                ; the codebase's working mode - don't leave 3 behind
    if (!h)
        return false
    WinGetText, wtxt, ahk_id %h%
    if (!InStr(wtxt, "Unable to open Clipboard"))
        return false
    ControlClick, Button1, ahk_id %h%, , Left, 1, NA
    WinWaitClose, ahk_id %h%, , 0.5
    if (WinExist("ahk_id " h))
        WinClose, ahk_id %h%
    Log("clip: closed wIntegrate 'Unable to open Clipboard' popup")
    return true
}

; Append captures to era-screens.log. Nobody has ever seen a captured ERA screen, so the
; column positions are unknown - this is how we learn them. Nothing in the run depends on
; it; the checks below are deliberately written to need NO column knowledge.
EraDump(txt) {
    global ERA_SCR_DUMP
    if (!ERA_SCR_DUMP)
        return
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    FileAppend, % "`n===== " ts " =====`n" txt "`n", % A_ScriptDir "\era-screens.log"
}

; ---- WHAT A REAL CAPTURE LOOKS LIKE (Kaine pasted one, 2026-07-18 19:09) ----------
; F11 returns the CURRENT page as plain text, pipes and all - it does NOT jump to the last
; page despite the ScrollEndPage in the binding. Verbatim, trimmed:
;
;   | Ln# Part# / Description         OT  QPR  Recv B/C Exc Cost  Inc Cost|
;   |   1 20537030-00   DRIVER'S SEAT CUS E   1   54 0.13            0.14|
;   |   2 15290965-00   TRIM PANEL ASSY   E   1    9         0.04    0.04|
;   ...
;   |------------------------------------------------------------|1 / 3|-|
;   Help: Enter the cost price exclusive of GST
;
; Three things that capture hands us, none of which the sender had before:
;   1. THE HELP LINE = which field the caret is in, in words. This is the sync signal.
;   2. THE GRID = QPR / Recv / B/C / Exc Cost / Inc Cost per line, so a typed value can be
;      read back and compared to what we meant to type.
;   3. "1 / 3" = pagination. Lines past the page are NOT in the capture; every check below
;      treats an off-page line as "unknown", never as "fine".
; Note line 8 is absent from that PO - ERA line numbers skip, as the data-traps note says.

; The Help line verbatim - for logging a prompt we don't recognise yet, so one run is enough
; to learn its wording instead of guessing at it.
EraHelpLine(scr) {
    Loop, Parse, scr, `n, `r
    {
        if (InStr(A_LoopField, "Help:"))
            return Trim(A_LoopField)
    }
    return "(no Help line on screen)"
}

; The caret's field, read from the Help line. Returns "line" | "qty" | "cost" | "bc" | "".
; Wordings confirmed against era-screens.log (127 real captures, 2026-07-18):
;   "Enter the number of the line you want to edit"  -> line   (79 captures)
;   "Enter the cost price exclusive of GST"          -> cost   (24 captures)
; The qty and B/C wordings have NOT been captured yet - captures only happened at line
; boundaries - so their patterns below are provisional. EraPrompt returns "" for anything it
; doesn't know, and every caller treats "" as "don't assume", never as "probably fine".
EraPrompt(scr) {
    if (scr = "")
        return ""
    Loop, Parse, scr, `n, `r
    {
        if (!InStr(A_LoopField, "Help:"))
            continue
        StringLower, h, A_LoopField
        if (InStr(h, "line to modify") || InStr(h, "number of the line"))
            return "line"
        if (InStr(h, "quantity received"))
            return "qty"
        if (InStr(h, "cost price"))
            return "cost"
        if (InStr(h, "backorder") || InStr(h, "b/c"))
            return "bc"
        return ""                       ; a Help line we don't know yet - say so, don't guess
    }
    return ""
}

; Column SPANS, self-calibrated off the header row rather than hard-coded.
; Deliberately spans, not single offsets: the first attempt here assumed "a value ends where
; its header word ends" and that is not safe - terminal grids drift by a character or two and
; a value can be wider than the word above it (1249.49 under "Exc Cost"). Spans plus the
; overlap rule in EraParseRows survive that; exact offsets do not.
; Returns "" when the grid header isn't on screen (e.g. the header-entry page).
EraCols(scr) {
    Loop, Parse, scr, `n, `r
    {
        h := A_LoopField
        if (!InStr(h, "Ln#") || !InStr(h, "QPR") || !InStr(h, "Recv"))
            continue
        c := {}
        c.otAt := InStr(h, "OT")
        ; Two alignments, both measured off real captures - one rule does not fit both:
        ;   the numerics are RIGHT-aligned to their header's end (QPR ...50, Recv ...55,
        ;   Exc ...68, Inc ...79), but B/C is a single-character flag LEFT-aligned at its
        ;   header's start (the legitimate backorder "B" on BY36466 line 19 sits at col 57,
        ;   where "B/C" begins). Anchoring B/C on its end threw that real flag away.
        for i, f in [["qpr", "QPR", "r"], ["recv", "Recv", "r"], ["bc", "B/C", "l"], ["exc", "Exc Cost", "r"], ["inc", "Inc Cost", "r"]] {
            p := InStr(h, f[2])
            if (!p)
                return ""
            c[f[1]] := { s: p, e: p + StrLen(f[2]) - 1, a: f[3] }
        }
        return (c.otAt > 0) ? c : ""
    }
    return ""
}

; line number -> {qpr, recv, bc, exc, inc} for every line ON THIS PAGE.
; THE ALIGNMENT RULE, measured off the real capture rather than guessed at:
; every value in this grid is RIGHT-ALIGNED to a fixed end column, within one character of
; where its header word ends (QPR ends one past its header, the rest land exactly on it).
;   ln 2:  QPR ...50   Recv ...55   Exc ...68   Inc ...79
;   ln 4:  QPR ...50   Recv ...55   Exc ...68   Inc ...79
; So a token is only accepted for a column when it ENDS where that column ends (+/-1).
; That is what makes the corruption self-announcing: the stray cost on line 1 ends at column
; 62, which is no column's end at all, so it is recorded as MISALIGNED instead of being
; quietly filed under Exc Cost. An earlier overlap-based rule did file it under Exc Cost -
; i.e. it read a corrupt screen as a clean one, the exact failure this is here to prevent.
; r.mis holds any such token; a row with r.mis is a row that must not be called good.
EraParseRows(scr) {
    rows := {}
    c := EraCols(scr)
    if (!IsObject(c))
        return rows
    inGrid := false
    Loop, Parse, scr, `n, `r
    {
        raw := A_LoopField
        if (!inGrid) {                              ; rows only count AFTER the grid header:
            if (InStr(raw, "Ln#") && InStr(raw, "QPR"))   ; the page banner "18 JUL 2026 P121"
                inGrid := true                      ; also starts with digits and is NOT a row
            continue
        }
        if (RegExMatch(raw, "^\s*\|?\s*-{5,}"))     ; the footer rule closes the grid
            break
        if (!RegExMatch(raw, "^\s*\|?\s*(\d+)\s+\S", m))
            continue
        no := m1 + 0
        if (rows.HasKey(no))
            continue
        r := { qpr: "", recv: "", bc: "", exc: "", inc: "", mis: "" }
        pos := 1
        Loop {
            if (!(fnd := RegExMatch(raw, "\S+", tok, pos)))
                break
            pos := fnd + StrLen(tok)
            tv := tok, ts := fnd, te := fnd + StrLen(tok) - 1
            while (SubStr(tv, 0) = "|")             ; the right border can touch the last value
                tv := SubStr(tv, 1, StrLen(tv) - 1), te--
            tv := LTrim(tv, "|")
            ; Skip everything up to and including the OT column. This compared against the
            ; START of "OT" at first, so the OT VALUE itself ("NO" on a BYD order, ending one
            ; column past the header's start) fell through as an unrecognised token and every
            ; single row came back "stray NO@col44" - 10 bad rows on a screen with one real
            ; fault. A check that fires on every row isn't a check.
            if (tv = "" || te <= c.otAt + 1)        ; line no / part / description / OT / border
                continue
            best := "", bestD := ""
            for key, span in {qpr: c.qpr, recv: c.recv, bc: c.bc, exc: c.exc, inc: c.inc} {
                d := (span.a = "l") ? Abs(ts - span.s) : Abs(te - span.e)
                if (d <= 1 && (bestD = "" || d < bestD))
                    bestD := d, best := key
            }
            if (best = "")
                r.mis .= (r.mis = "" ? "" : " ") tv "@col" te
            else if (r[best] = "")
                r[best] := tv
        }
        rows[no] := r
    }
    return rows
}

; ---- THE SYNC GATE. This is the fix for what the 19:09 recording shows.
; That run typed a clean stream into a screen that had moved on without it: line 1 ended up
; with Recv 54 against QPR 1, and a cost ("0.13") sat in the B/C column. Nothing in the
; sender could see any of it, so it finished GREEN on a wrong screen.
; The stream assumes ERA is at the line# prompt when we type a line number, at the qty
; prompt when we type a quantity, and so on. The Help line says which one is actually true.
; Cost control: this is called ONCE PER LINE (before the line number), not per keystroke -
; one capture per line, not four. If the prompt is wrong we try a bounded recovery (Enter
; walks ERA back to the line# prompt) before giving up.
; Returns true when ERA is at `want`. "" capture = unknown = proceed (today's behaviour).
EraSync(want, tries := 2) {
    global CfgScreenChk, RCP_BETWEEN_LINES, RCP_PAGE_SETTLE
    if (!CfgScreenChk)
        return true
    sent := 0
    t0 := A_TickCount
    Loop
    {
        scr := EraScreen()
        if (scr = "")
            return true                 ; unreadable - degrade to blind, never invent a verdict
        RcpSeenCache(EraParseRows(scr)) ; a paid-for capture - remember its clean rows (price skip)
        ; THE FREEZE SAFEGUARD (v2.7.0, off the 08:1x recording). A capture with NO Help line
        ; is a mid-redraw or frozen frame - every real ERA prompt ships its Help text. The old
        ; code treated it as "unknown prompt = proceed", and worse, its recovery Enters could
        ; fire INTO the freeze: the 08:19 run queued two Enters into a frozen wIntegrate (its
        ; captures kept showing a stale cost prompt), declared the park failed, reported DONE
        ; - and the queued keys then committed BLIND seconds after the run ended (line 70's
        ; cost only landed ~10s post-DONE; had the freeze eaten the typed digits instead, the
        ; blind Enters would have committed the old 420.25 over the invoice's 415.31).
        ; A screen that isn't showing a prompt gets NO keystrokes - wait for the paint instead.
        if (!InStr(scr, "Help:")) {
            if (A_TickCount - t0 > RCP_PAGE_SETTLE) {
                Log("sync: ABORT - the screen never settled (no Help line after " RCP_PAGE_SETTLE "ms)")
                return false
            }
            Sleep, %RCP_BETWEEN_LINES%
            continue
        }
        p := EraPrompt(scr)
        if (p = want || p = "")
            return true                 ; matched, or a Help wording we don't know - don't block
        Log("sync: ERA is at the '" p "' prompt, expected '" want "'" (sent < tries ? " - sending Enter to recover" : ""))
        if (sent >= tries)
            break
        sent++
        RcpText("`r")                    ; commit/skip the field ERA is actually sitting on
        Sleep, %RCP_BETWEEN_LINES%
    }
    Log("sync: ABORT - could not get ERA back to the '" want "' prompt")
    return false
}

; (The paging machinery - EraPageNum/EraPageCount/EraPageStep/EraCollectRows - and the
; subtract verify EraVerifySubtractRows lived here until v2.5.0. The deterministic pass
; never pages: a typed line number jumps ERA to its page, ascending line order only ever
; moves the pages forward, and the review walks that paged are gone.)

; ---- THE BACKORDER QUESTION, ANSWERED FROM THE SCREEN INSTEAD OF FROM THE PLAN.
; THIS IS THE ROOT CAUSE of both recordings. The line stream types qty then price, and sends
; "B" only when the PLAN predicted a short line (l.bo > 0). When ERA asks the backorder
; question and the plan didn't predict it, nobody answers: the PRICE answers it instead. That
; is why the price kept landing in the B/C column, and why ERA was then sitting at the cost
; prompt with nothing left to type - both visible in the 19:38 capture, line 3:
;     |   3 12957133-00   EV WORDMARK ASSY  NO     2    2   2.66             3.53|
;                                                            ^ the cost, in the B/C column
; Predicting the question was always the wrong shape. Now we ASK: after the quantity, read
; the prompt and respond to what ERA actually wants.
; Returns 1 when ERA is ready for the price, 2 when ERA already FINISHED the line (it went
; straight back to the line prompt without asking for a cost - seen live 20:45 on DO36465
; line 6; the price must NOT be typed, there is no field for it), 0 = the line failed - the
; caller (RcpLines) replays it once from a proven line prompt, then stops the run.
EraAnswerAfterQty(plan, l) {
    global CfgScreenChk, RCP_BETWEEN_LINES, RCP_PAGE_SETTLE, g_rcpNoCost, g_rcpAtLine
    g_rcpAtLine := false                ; only a settled, recognised prompt re-arms the skip
    if (!CfgScreenChk) {
        if (l.bo > 0)
            RcpText("B`r")              ; no screen reading: the old predicted behaviour
        return 1
    }
    ; THE SETTLE LOOP (2026-07-18 20:49, re-cut v2.7.0). Reading "qty" here does not mean ERA
    ; re-asked - it usually means the capture was taken while ERA was still redrawing after
    ; the qty landed. A capture with NO Help line at all is a mid-redraw frame, not a new ERA
    ; question - a real prompt always ships its Help text. Never retype, never answer either
    ; frame: wait, re-read, and only believe a prompt that holds still.
    ; v2.7.0: the wait is a TIME budget, not a fixed 3 reads - the 08:1x runs died right here
    ; ("UNKNOWN after qty ... no Help line" on lines 18/60/70, all page-boundary lines) when
    ; a page-jump redraw outlived three reads. A no-Help frame can now NEVER fall through to
    ; the UNKNOWN branch: budget expiry fails the line instead (the in-place replay re-syncs
    ; and re-types it once the paint lands - self-healing, and zero keys into a frozen screen).
    p := ""
    lineSeen := 0                       ; v2.8.0: consecutive settled reads showing the line prompt
    t0 := A_TickCount
    Loop
    {
        scr := EraScreen()
        if (scr = "") {
            if (l.bo > 0)
                RcpText("B`r")
            return 1                    ; unreadable degrades to the old behaviour, never worse
        }
        p := EraPrompt(scr)
        ; v2.8.0 STALE-FRAME CONFIRM (the 08:55 run, BY36466): a line-prompt frame here can be
        ; the PRE-ENTRY frame - the capture raced ERA's repaint toward the cost prompt. On a
        ; chg-only line the qty echo cannot catch it (recv-aLL already filled Recv with the same
        ; number), and believing it types the NEXT line number into THIS line's cost prompt:
        ; line 4's "4`r" became line 3's 0.04 cost. A stale frame can only show this line's
        ; past (line/qty prompts), so cost and bc stay act-immediately; only "line" - the one
        ; answer indistinguishable from history - must hold still for two consecutive reads.
        if (p = "line") {
            lineSeen++
            if (lineSeen >= 2)
                break
            if (A_TickCount - t0 > RCP_PAGE_SETTLE) {
                Log("receipt: " plan.id " line " l.line " line prompt seen once but never confirmed in " RCP_PAGE_SETTLE "ms - failing the line for the in-place replay")
                return 0
            }
            Sleep, %RCP_BETWEEN_LINES%
            continue
        }
        lineSeen := 0
        if (p != "qty" && !(p = "" && !InStr(scr, "Help:")))
            break
        if (A_TickCount - t0 > RCP_PAGE_SETTLE) {
            if (p = "qty")
                break                   ; genuinely still at qty - the out-of-step stop below
            Log("receipt: " plan.id " line " l.line " screen never settled after the qty (no Help line for " RCP_PAGE_SETTLE "ms) - failing the line for the in-place replay")
            return 0
        }
        Sleep, %RCP_BETWEEN_LINES%      ; likely our own echo or a page paint - look again
    }
    ; THE QTY ECHO CHECK ("3 wins" pass, 2026-07-18): the settle capture above is already
    ; paid for - read this line's row off it and compare the Recv that LANDED against the
    ; qty we meant to type. Positive evidence only: a missing row, a blank Recv or ANY
    ; stray token stays "unknown" (the 20:49 recording proved a mid-flight echo can read
    ; as a stray - "stray 1@col52" on a row that was fine). A provably wrong landing fails
    ; THIS line right now - RcpLines replays it once in place, then stops if it still
    ; disagrees - instead of letting a desynced run type on for pages.
    rows := EraParseRows(scr)
    RcpSeenCache(rows)                  ; the settle capture is paid for - cache its clean rows too
    if (RcpQtyEcho(rows, l.line, l.qty) = "wrong") {
        Log("receipt: " plan.id " line " l.line " qty echo WRONG on the settle capture - failing the line for the in-place replay")
        return 0
    }
    if (p = "cost") {
        g_rcpAtLine := true             ; the price+Enter that follows lands at the line prompt
        return 1                        ; no question asked - straight to the price
    }
    if (p = "bc") {
        RcpText("B`r")
        return 1
    }
    if (p = "line") {
        ; ERA accepted the qty and moved straight on to the next line number - it never asked
        ; for a cost, so this line's price is not ours to type. Typing it anyway would put a
        ; price into the LINE prompt: the 19:09 corruption by another door.
        g_rcpNoCost[l.line + 0] := (g_rcpNoCost.HasKey(l.line + 0) ? g_rcpNoCost[l.line + 0] : 0) + 1
        Log("receipt: " plan.id " line " l.line " - ERA finished the line without asking for a cost; price left as-is")
        g_rcpAtLine := true             ; the settle capture PROVED the line prompt is up
        return 2
    }
    if (p = "") {
        ; An unrecognised prompt. When the plan expected a backorder this is almost certainly
        ; that question, and "B" is the answer Speed_Receipting has always used - so answer it,
        ; but record the wording verbatim so the guess becomes a known prompt after one run.
        Log("prompt: UNKNOWN after qty on line " l.line " -> " EraHelpLine(scr))
        if (l.bo > 0) {
            RcpText("B`r")
            return 1
        }
        ; Not expected, not understood: stop rather than spray a key at an unknown screen -
        ; the same rule RcpRecvAllFire already follows.
        Log("receipt: " plan.id " ABORT - unexpected prompt after the qty on line " l.line)
        ShowToast("bad", "Stopped - ERA asked something new", "Line " l.line ": " EraHelpLine(scr))
        return 0
    }
    ; Still "qty" after three settled reads, or a prompt with no answer here. Returning 0
    ; fails the line: RcpLines replays it once from a proven line prompt, then stops the run
    ; if the replay fails too. NO blind retype - the 20:43 abort was caused by answering a
    ; prompt the screen had already left.
    Log("receipt: " plan.id " line " l.line " out of step - ERA is at the '" p "' prompt, expected the cost prompt")
    return 0
}

; (EraVerifyLines - the end-of-run walk / finish check - lived here until v2.5.0. Kaine,
; 2026-07-19: "it can't review and fix stuff... rip it all out, make it deterministic".
; Accuracy is now the pass itself: preflight, per-line sync gate, prompt-driven answers,
; the qty-echo check, and one in-place replay - see RcpRun/RcpLines.)

; ---- CHECK 1: PRE-FLIGHT. Before a single line is typed, prove ERA is sitting on THIS
; order. The header keystream is fire-and-forget today: if the PO didn't load (wrong
; screen, slow ERA, a dialog we didn't expect) the line loop types quantities into
; whatever IS there. This is the cheapest check in the whole run - it runs once, before
; anything can go wrong, and an abort here costs nothing because nothing was typed yet.
; Returns true to proceed. "Could not read" proceeds (blind = today's behaviour) but says so.
EraPreflight(plan) {
    global CfgScreenChk
    if (!CfgScreenChk)
        return true
    scr := EraScreen()
    if (scr = "") {
        Log("preflight: " plan.id " screen unreadable - proceeding BLIND (as before)")
        return true
    }
    if (!InStr(scr, plan.order)) {
        Log("preflight: " plan.id " ABORT - order " plan.order " is not on the ERA screen")
        ShowToast("bad", "Wrong screen - nothing typed", plan.order " is not the order loaded in ERA")
        return false
    }
    ; The supplier invoice number is a softer signal: ERA may truncate it in its field, so
    ; a miss is logged, never fatal.
    if (!InStr(scr, plan.inv))
        Log("preflight: " plan.id " note - invoice " plan.inv " not visible on screen (ERA may truncate it)")
    Log("preflight: " plan.id " OK - " plan.order " confirmed on the ERA screen")
    ; The order is PROVEN on this capture, so its grid rows are this PO's rows - seed the
    ; seen-cache with page 1 for free (the accurate-price skip reads it). A capture that
    ; failed the order check above never gets here: wrong-PO rows must not enter the cache.
    RcpSeenCache(EraParseRows(scr))
    return true
}

; (The before/after text-diff subtract verify lived here until 21:35; its value-based
; replacement EraVerifySubtractRows went in the v2.5.0 strip-down with the rest of the
; review machinery.)

; Reset ERA to the main menu - port of Speed_Receipting's ERA_HomePage() (proven daily).
; Backspaces clear any half-typed field, F2 + F1 F1 walk out of any screen, END backs out
; of nested menus, and the "No previous menu" complaint (we sent one END too many on
; purpose) is closed by handle.
RcpHomePage() {
    global g_rcpHwnd, g_rcpCtl
    WinActivate, ahk_id %g_rcpHwnd%
    WinWaitActive, ahk_id %g_rcpHwnd%, , 3
    WinMove, ahk_id %g_rcpHwnd%, , , , 820, 502
    Loop, 13
        RcpKey(0x08)             ; Backspace
    RcpKey(0x71)                 ; F2
    Loop, 2
        RcpKey(0x70)             ; F1
    Loop, 3
        RcpText("END`r")
    Sleep, 250
    WinGet, nm, ID, , No previous menu
    if (nm)
        PostMessage, 0x10, , , , ahk_id %nm%   ; WM_CLOSE
}

; Header fill. Keystroke-for-keystroke the Speed_Receipting sequence with worklist data:
; 2062 + menu enters, PO#, enter through the loaded order, supplier inv#, the used-dialog
; check, then enter-enter (GST default No + vendor preload accepted).
; Split in two so the drill can run the TYPING half against a mock control: RcpHomePage
; needs a real ERA window, RcpHeaderType is pure keystrokes + waits.
RcpHeader(plan) {
    global g_rcpDry
    if (!g_rcpDry)
        RcpHomePage()            ; a dry run needs no ERA window at all
    return RcpHeaderType(plan)
}

RcpHeaderType(plan) {
    global RCP_AFTER_MENU, RCP_AFTER_PO, RCP_AFTER_INV
    RcpText("2062`r`r`r`r")
    Sleep, %RCP_AFTER_MENU%
    RcpTextVar(plan.order)
    RcpText("`r")
    Sleep, %RCP_AFTER_PO%        ; ERA loads the order, preloads vendor + dates
    RcpText("`r")
    RcpTextVar(plan.inv)
    RcpText("`r")
    Sleep, %RCP_AFTER_INV%
    if (!RcpInvoiceUsedCheck(plan))
        return false
    RcpText("`r`r")              ; Include GST (default No) + Vendor (preloaded)
    return true
}

; ERA complains when a supplier invoice number was receipted before ("... previously for
; Vendor ..."). Port of Speed_Receipting's Invoice_used_Dialouge_Box, with a real abort:
; answering the ERA dialog Yes keeps the screen alive, then KAINE decides whether that is
; a legitimate re-use (split shipment) or a double-receipt about to happen.
RcpInvoiceUsedCheck(plan) {
    global CfgContinueInvUsed, g_rcpDry
    if (g_rcpDry)
        return true              ; no ERA, no dialog
    SetTitleMatchMode, 2
    WinWait, , previously for Vendor, 0.5
    if (ErrorLevel)
        return true              ; no dialog - the normal case
    used := WinExist(, "previously for Vendor")
    ControlClick, Button1, ahk_id %used%, , Left, 1, NA
    if (CfgContinueInvUsed) {
        Log("receipt: " plan.id " supplier inv# already used - continuing (setting is ON)")
        return true
    }
    Gui, SB:+OwnDialogs
    MsgBox, 0x34, Invoice number already used, % plan.inv " has been receipted before for this vendor.`n`nContinue anyway?"
    IfMsgBox, Yes
        return true
    Log("receipt: " plan.id " aborted - supplier inv# already used")
    ShowToast("bad", "Receipt aborted", "Invoice number already used - ERA left as-is")
    return false
}

; The ONE ordered work list of a run (Kaine, 2026-07-19: "do it sequentially... in order").
; Per-line mode: every plan line, wire order (already ascending ERA line). recv-aLL: the
; uncovered SUBTRACTS and the actionable FIXES, merged and sorted by ERA line number, so
; the run types straight down the order - page 1 to page N, once - instead of X-outs first
; and then a second pass from the top (the "back orders first, then start from the start"
; page-flicking Kaine flagged).
; DETERMINISTIC (v2.5.0): price-only lines are TYPED, not deferred. The old deferral leaned
; on the end-of-run walk to decide which prices were really wrong - that walk is gone, and
; the invoice is the accuracy authority anyway (Kaine: "the PO for line numbers, the invoice
; for pure accuracy"). ERA's line edit is an overwrite, so typing a price that was already
; right is a no-op - cheaper than any walk that would have decided to skip it.
; v2.6.0 refinement: a priceOnly visit CAN still be dropped at type-time - but only when a
; capture the run already paid for proves the screen's Exc equals the invoice (see the
; accurate-price skip in RcpLines). The builder just marks which items are candidates.
; v2.21.0: THE SUBTRACT IS NOT A recv-aLL FEATURE. An uncovered line - a line the order has
; open that this invoice does not ship - gets its 0+B (or X) in EVERY mode. Per-line used to
; return early here and leave those lines untouched, which is the "it doesn't go to 0
; backorder" Kaine filmed on I0973146/DD35293. The mode now only decides how the COVERED
; lines are received; what happens to the uncovered ones is the Subtract-by setting's job,
; and nothing else's.
RcpWorkItems(plan) {
    items := []
    if (plan.mode != "recvall") {
        ; Per-line mode types the qty on EVERY covered line - that typing IS the receipt, so no
        ; line can be skipped here (priceOnly stays 0; the accurate-price skip is a recv-aLL
        ; saving). The uncovered lines fall through to the subtract loop at the bottom.
        for i, l in plan.lines {
            if (RcpIsUncovered(plan, l.line))   ; never both: the sub entry IS this line's edit
                continue
            items.Push({kind: "fix", line: l.line + 0, l: l, priceOnly: 0})
        }
    } else {
        for i, l in plan.lines {
            ; recv-aLL already received every clean line at ERA's outstanding qty; only visit
            ; lines that need anything (price, backorder-short qty, over-shipment excess)...
            if (!l.chg && !l.bo && !l.over)
                continue
            ; ...and never a line about to be X'd out - un-receiving it IS that line's edit.
            if (RcpIsUncovered(plan, l.line))
                continue
            ; priceOnly = the ONLY reason to visit is the (stale-CSV) chg flag. The work loop
            ; may drop such a visit when a paid-for capture already showed the Exc equal to the
            ; invoice (v2.6.0 accurate-price skip); a line with a qty component is always visited.
            items.Push({kind: "fix", line: l.line + 0, l: l, priceOnly: (l.chg && !l.bo && !l.over) ? 1 : 0})
        }
    }
    ; BOTH modes: subtract every line the invoice does not ship, at its place in line order.
    for i, u in plan.uncovered
        items.Push({kind: "sub", line: u.line + 0, u: u})
    ; Ascending ERA line number - insertion sort; a run is at most a few dozen entries.
    ; Typing a line number makes ERA jump to that line's page, so ascending order IS the
    ; "no flicking" guarantee: the pages only ever move forward while entries go in.
    i := 2
    while (i <= items.Length()) {
        j := i
        while (j > 1 && items[j-1].line > items[j].line) {
            tmp := items[j-1], items[j-1] := items[j], items[j] := tmp
            j--
        }
        i++
    }
    return items
}

; THE FOCUS GUARD (Kaine, 2026-07-19: "if the focus is taken somewhere else, it stops
; where it's at, shows a pop-up saying Continue, and then continues off where it's left
; off"). The typing itself is PostMessage straight to ERA's input control - it lands with
; or without focus - so the real risks are subtler: the F11 capture racing a foreground
; app, or the human typing into ERA without realising a run is live. Checked once per
; work entry, between keystream chunks - never mid-line, so "continue" always resumes on
; a line boundary. One pause per thief: the window approved by Continue is remembered
; (g_rcpFgOk) and never pauses the run twice; ERA's own windows (Receipt All Parts, the
; wIntegrate popups) and this script's dialogs/toasts never pause it at all.
RcpFocusGuard(plan) {
    global g_rcpHwnd, g_rcpDry, g_rcpAtLine, g_rcpFgOk, g_rcpUserAbort
    if (g_rcpDry || !g_rcpHwnd)
        return true              ; no ERA window = dry run / drill - nothing to guard
    WinGet, fg, ID, A
    if (!fg || fg = g_rcpHwnd || fg = g_rcpFgOk)
        return true
    WinGet, fpid, PID, ahk_id %fg%
    WinGet, epid, PID, ahk_id %g_rcpHwnd%
    if (fpid = epid)
        return true              ; ERA's own dialogs (Receipt All Parts, wIntegrate popups)
    if (fpid = DllCall("GetCurrentProcessId"))
        return true              ; our own worklist window / checkpoints / toasts
    WinGetTitle, fgTitle, ahk_id %fg%
    Log("focus: " plan.id " paused - '" fgTitle "' took the foreground mid-run")
    RcpAlert("checkpoint")
    Gui, SB:+OwnDialogs
    MsgBox, 0x31, Focus taken - run paused, % "'" fgTitle "' took the focus mid-run.`n`nNothing has been typed since the last full entry. OK re-proves the ERA caret and continues exactly where the run left off.`nCancel stops - ERA left as-is, nothing finalized."
    IfMsgBox, Cancel
    {
        Log("focus: " plan.id " stopped by the human at the focus pause")
        ShowToast("bad", "Receipt stopped", "Stopped at the focus pause - ERA left as-is, nothing finalized")
        g_rcpUserAbort := true   ; a human said stop - the auto-retry stays down
        return false
    }
    g_rcpFgOk := fg              ; approved - this window won't pause the run again
    g_rcpAtLine := false         ; human time passed - re-prove the caret before typing on
    Log("focus: " plan.id " continuing after the focus pause")
    return true
}

; The work loop. checkpoint=true pauses ONCE for an on-screen cross-check, after the first
; entry typed - subtract or fix, whichever line order puts first. (The drill passes false:
; a MsgBox would hang an unattended run.)
; Returns false on abort.
RcpLines(plan, checkpoint := true) {
    global g_rcpQtyMode, RCP_RECVALL_KEY, RCP_BETWEEN_LINES, CfgScreenChk, g_rcpDry, g_rcpAtLine
    global RCP_UNRECV_KEY, CfgSubtractBy, g_rcpSeen, g_rcpWant, g_rcpUserAbort
    ; plan.mode is the RESOLVED mode (RcpPickMode) - never read the radio here.
    recvall := (plan.mode = "recvall")
    if (recvall) {
        ; STILL SUBTRACTIVE (Kaine, 2026-07-17): L -> Yes -> the dialog is GONE - the whole
        ; PO is flagged received - and then the work loop below subtracts and fixes IN LINE
        ; ORDER (v2.4.0). The old X-first ordering minimised the fully-received window, but
        ; the sender never finalizes, so that window was cosmetic - and the two passes it
        ; cost were the page-flicking Kaine filmed.
        if (!RcpRecvAllFire(plan))
            return false
        Sleep, %RCP_BETWEEN_LINES%
    }
    work := RcpWorkItems(plan)
    zb := (CfgSubtractBy = "zb")
    StringLower, xch, RCP_UNRECV_KEY
    typed := 0
    skipped := 0
    did := 0
    subN := 0
    subbed := ""
    accN := 0
    accLines := ""
    for i, w in work {
        ; THE ACCURATE-PRICE SKIP (v2.6.0, Kaine: "compare what the invoice price is to the
        ; PO, and if it's accurate, don't adjust the price"). Only a priceOnly visit can be
        ; dropped - its qty is already right by definition (recv-aLL received it, no bo/over)
        ; - and only on positive screen evidence: a capture this run already paid for showed
        ; the row CLEAN with Exc equal to the invoice. No evidence = visit as before, where
        ; typing the invoice price over an equal price is a no-op. The step was budgeted in
        ; the denominator, so the bar still earns its 100 through RcpProgDone.
        if (w.kind = "fix" && w.priceOnly && RcpPriceAlreadyRight(g_rcpSeen, w.line, w.l.price)) {
            Log("price: " plan.id " line " w.line " already accurate on screen (Exc = invoice " w.l.price ") - left alone, not adjusted")
            ; a skip IS proven - the paid-for capture that justified it is its evidence
            g_rcpWant[w.line + 0] := {kind: "skip", proof: "ok", seen: "Exc " w.l.price}
            accN++
            accLines .= (accLines = "" ? "" : ", ") w.line
            RcpProgStep()
            continue
        }
        ; THE FOCUS GUARD (2026-07-19): a focus thief pauses the run at the next entry.
        if (!RcpFocusGuard(plan))
            return false
        l := w.l
        ; SYNC GATE (2026-07-18): only type a line number when ERA is asking for one. The
        ; 19:09 recording is what happens without this - a correct stream into a screen that
        ; had drifted, so quantities and costs landed in whichever field was under the caret.
        ; THE SYNC SKIP ("3 wins" pass): when the PREVIOUS line's settle capture ended on a
        ; recognised prompt, the caret's position is already proven and this capture would
        ; re-prove what we just read - skip it. Capped at 3 in a row, so a drift the settle
        ; captures somehow missed can never ride further than 3 lines before a real sync;
        ; the after-qty capture still reads the screen on EVERY line either way. A subtract
        ; entry takes no settle capture, so the entry after it always syncs for real.
        syncSkip := (g_rcpAtLine && skipped < 3)
        g_rcpAtLine := false            ; consumed - only the next settle capture re-arms it
        skipped := syncSkip ? skipped + 1 : 0
        if (syncSkip)
            Log("sync: line " w.line " pre-line capture skipped (previous line settled clean)")
        if (!syncSkip && !EraSync("line")) {
            ; DETERMINISTIC (v2.5.0): out of step is a STOP, not a deferral - the end walk
            ; the old deferral leaned on is gone, and a run that cannot prove the line
            ; prompt must not type another key. EraSync already spent its bounded Enter
            ; recovery getting here, so there is nothing mechanical left to try. The stop
            ; names the exact line; ERA is left as-is and nothing is finalized.
            Log("receipt: " plan.id " ABORT at line " w.line " - out of step (could not reach the line prompt)")
            ShowToast("bad", "Stopped - ERA out of step", plan.order " at line " w.line ". Check the screen; nothing was finalized.")
            return false
        }
        if (w.kind = "sub") {
            ; Un-receive a line this invoice doesn't ship, typed at its place in line order.
            ; The X keystream is the frame-proven one (2026-07-17 video, 84.75s): line# \r
            ; lands the caret on the Recv field, x \r clears it, ERA returns to the line
            ; prompt. zb is the Settings alternative (line# \r 0 \r B \r - a zero receipt
            ; plus a booked backorder).
            RcpTextVar(w.line)
            RcpText("`r")
            RcpPageGate(w.line)      ; v2.7.0: a subtract's line number jumps pages too
            if (zb) {
                RcpText("0`r")
                RcpText("B`r")       ; ERA's backorder question (same answer the short-line path uses)
            } else {
                RcpText(xch)
                RcpText("`r")
            }
            g_rcpWant[w.line + 0] := {kind: "sub", recvWant: (zb ? "0" : ""), proof: "", seen: ""}
            subN++
            subbed .= (subbed = "" ? "" : ", ") w.line
            RcpProgStep()
            Sleep, %RCP_BETWEEN_LINES%
            ; The zb stream parks ERA at the COST prompt of the subtracted line (every 20:4x
            ; run logged "sync: at 'cost', expected 'line'"). Walk it home NOW - the next
            ; entry's line number must land at the line prompt, nowhere else.
            if (zb && CfgScreenChk)
                EraSync("line")
        } else {
            if (!RcpTypeLine(plan, l)) {
                ; ONE IN-PLACE REPLAY (v2.5.0). No repair pass, no page walk: typing the line
                ; number jumps ERA to that line wherever it is, and ERA's line edit is an
                ; overwrite - so a replay from a PROVEN line prompt is the whole fix. The
                ; caret must prove itself first (EraSync's bounded Enter recovery); a replay
                ; that fails too stops the run with the exact line named. Once, not a loop -
                ; the 23:09 corruption came from replaying a line ERA kept refusing.
                synced := EraSync("line")
                replayed := false
                if (synced) {
                    Log("receipt: " plan.id " line " l.line " failed mid-stream - replaying it once in place")
                    Sleep, %RCP_BETWEEN_LINES%
                    replayed := RcpTypeLine(plan, l)
                }
                if (!replayed) {
                    Log("receipt: " plan.id " ABORT at line " l.line " - failed mid-stream (" (synced ? "the replay failed too" : "caret would not come home - replay not attempted") ")")
                    ShowToast("bad", "Stopped - line " l.line " would not go in", plan.order ": check that line on the screen; nothing was finalized.")
                    return false
                }
            }
            typed++
            ; NO RcpProgStep() here - RcpTypeLine already counted this line. Counting it twice is
            ; what put the bar at 175%.
            Sleep, %RCP_BETWEEN_LINES%
        }
        did++
        if (checkpoint && did = 1) {
            left := work.Length() - i
            RcpAlert("checkpoint")
            Gui, SB:+OwnDialogs
            if (w.kind = "sub")
                MsgBox, 0x34, Checkpoint - first entry typed, % "Line " w.line "  " w.u.part "`nsubtracted (" (zb ? "0+backorder" : "X-out") ")`n`nCheck the row on the ERA screen.`nContinue with the remaining " left " entr" (left = 1 ? "y" : "ies") " in line order?"
            else
                MsgBox, 0x34, Checkpoint - first entry typed, % "Line " l.line "  " l.part "`nqty " l.qty "  price " l.price "`n`nCheck the row on the ERA screen.`nContinue with the remaining " left " entr" (left = 1 ? "y" : "ies") " in line order?"
            IfMsgBox, No
            {
                Log("receipt: " plan.id " aborted at the first-entry checkpoint")
                ShowToast("bad", "Receipt aborted", "Stopped after the first entry - ERA left as-is")
                g_rcpUserAbort := true   ; a human said stop - the auto-retry stays down
                return false
            }
            g_rcpAtLine := false     ; a checkpoint pause is human time - re-prove the caret after it
        }
    }
    if (subN)
        Log("receipt: " plan.id " subtracted " subN " uncovered line(s) by " (zb ? "0+backorder" : "X-out") ": " subbed)
    if (accN)
        Log("receipt: " plan.id " left " accN " already-accurate price(s) alone (screen = invoice): " accLines)
    Log("receipt: " plan.id " typed " typed " line(s) mode=" plan.mode)
    return true
}

; One line's keystream: line# -> qty -> (whatever ERA asks) -> price. Extracted from the line
; loop so the one in-place replay sends exactly the same stream - a replay that typed a
; different sequence to the original would be a second thing to trust.
; ERA's line edit is an overwrite, not an append, so replaying a line is how a wrong row is
; corrected: the same keystream that set it wrong sets it right.
RcpTypeLine(plan, l) {
    global RCP_BETWEEN_LINES, g_rcpTyped, g_rcpWant, g_rcpSeen
    RcpTextVar(l.line)
    RcpText("`r")
    ; v2.7.0: a line number on another page makes ERA repaint before it asks for the qty -
    ; never race that repaint (Kaine, 08:20 video). Same-page lines cost nothing here.
    RcpPageGate(l.line)
    RcpTextVar(l.qty)
    RcpText("`r")
    ; ERA's backorder question is ANSWERED FROM THE SCREEN, not predicted from the plan - see
    ; EraAnswerAfterQty. Predicting it is what let the price answer it instead.
    a := EraAnswerAfterQty(plan, l)
    if (!a)
        return false
    if (a = 1) {                     ; a=2: ERA closed the line itself - no cost field to fill
        RcpTextVar(l.price)
        RcpText("`r")
    }
    g_rcpTyped[l.line + 0] := true   ; per-run record of what actually went in (log/diagnosis)
    ; What this entry should have LEFT on the screen - the landed sweep re-reads it off every
    ; later paid-for capture. a=2: ERA kept its own cost - the invoice price is not ours to
    ; verify, but the KEPT cost must STAY the value the settle capture showed (keepExc). The
    ; 08:55 run is why: line 3 closed a=2, then a desynced keystroke made its Exc 0.04 - a
    ; corruption want.price="" could never see. Positive evidence only, verify-only: a false
    ; amber costs Kaine a look, a silent 0.04 costs money.
    keep := (a = 2 && g_rcpSeen.HasKey(l.line + 0)) ? g_rcpSeen[l.line + 0].exc : ""
    g_rcpWant[l.line + 0] := {kind: "fix", qty: l.qty, price: (a = 1 ? l.price : ""), keepExc: keep, proof: "", seen: ""}
    RcpProgStep()
    Sleep, %RCP_BETWEEN_LINES%
    return true
}



; (RcpRowIsWrong and RcpRowAlreadyRight lived here until v2.5.0 - they served the finish
; check and the skip-scan, both gone with the review walks.)

; Did the qty we just typed LAND? Read off the settle capture EraAnswerAfterQty already paid
; for - no extra capture, no extra walk. Returns "wrong" | "ok" | "unknown". Positive
; evidence only: a missing row, a blank Recv, a stray token or no wanted qty is "unknown",
; never "wrong" - a deferral on a hunch costs a needless replay (and the 20:49 mid-flight
; echo showed a fine row can read as a stray while ERA is still painting).
RcpQtyEcho(rows, lineNo, wantQty) {
    if (!IsObject(rows) || !rows.HasKey(lineNo + 0))
        return "unknown"
    g := rows[lineNo + 0]
    if (g.mis != "" || g.recv = "" || wantQty = "")
        return "unknown"
    return ((g.recv + 0) = (wantQty + 0)) ? "ok" : "wrong"
}

; Remember every CLEAN row a capture shows us (v2.6.0). Called only on captures the run
; already pays for - preflight (after the order is proven; a wrong screen's rows must never
; enter the cache), the pre-line sync captures, the after-qty settle captures - so this adds
; ZERO keypresses and ZERO clipboard traffic. Only rows with no misaligned token are kept: a
; row with r.mis is a mid-redraw or corrupt read, and a cache poisoned once would skip a line
; that genuinely needs its price. A later clean sighting overwrites an earlier one; a dirty
; sighting never overwrites anything.
RcpSeenCache(rows) {
    global g_rcpSeen, g_rcpPage
    if (!IsObject(rows))
        return
    n := 0
    for no, r in rows {
        n++
        if (r.mis = "")
            g_rcpSeen[no + 0] := r
    }
    ; v2.7.0: a non-empty grid = the page ERA is showing RIGHT NOW. The page-jump gate reads
    ; this to know whether the next line number will make ERA repaint (a menu/header capture
    ; parses to zero rows and must not clobber the last real page).
    if (n)
        g_rcpPage := rows
    ; ...and every paid-for capture also feeds the landed sweep - the review Kaine asked for
    ; (08:20 video) rides captures the run already takes, never a walk of its own.
    RcpLandedSweep(rows)
}

; THE PAGE-JUMP BUFFER (Kaine, 08:20 video: "it's too fast... it only happens when it
; changes pages - add some more time buffer before you send the input"). Typing a line
; number that lives on another page makes ERA repaint the grid; keystrokes sent into that
; repaint get eaten or land in the wrong field - three 08:1x runs died on page-boundary
; lines 18/60/70, and the 08:19 run committed a wrong cost. So: called right after the
; line number + Enter, and only when the target line was NOT on the page the last capture
; showed (same-page lines skip it - zero cost on the happy path). Waits until the repainted
; screen shows BOTH a Help line and this line's row, then returns; budget expiry types
; anyway (the old behaviour) - the after-qty settle and the landed sweep still judge it.
RcpPageGate(lineNo) {
    global CfgScreenChk, g_rcpDry, g_rcpPage, RCP_BETWEEN_LINES, RCP_PAGE_SETTLE
    if (g_rcpDry || !CfgScreenChk)
        return
    if (IsObject(g_rcpPage) && g_rcpPage.HasKey(lineNo + 0))
        return                          ; the line is on the page already up - no jump, no wait
    t0 := A_TickCount
    Loop
    {
        scr := EraScreen()
        if (scr = "")
            return                      ; unreadable - degrade to the old blind timing
        RcpSeenCache(EraParseRows(scr))
        if (InStr(scr, "Help:") && IsObject(g_rcpPage) && g_rcpPage.HasKey(lineNo + 0))
            return                      ; the new page is painted and this line is on it
        if (A_TickCount - t0 > RCP_PAGE_SETTLE) {
            Log("page: line " lineNo " - the jumped-to page never settled in " RCP_PAGE_SETTLE "ms - typing anyway")
            return
        }
        Sleep, %RCP_BETWEEN_LINES%
    }
}

; THE LANDED SWEEP (Kaine, 08:20 video: "figure out a way to review the changes you made to
; make sure they actually got received and put in correctly"). g_rcpWant records what every
; entry MEANT to leave on the screen; every capture the run pays for anyway (page gates,
; sync gates, after-qty settles, the end-of-run park) re-reads whichever of those rows it
; can see and compares what LANDED: Recv vs the typed qty, Exc vs the typed price (when the
; price was ours to type), Recv 0/blank for a subtract. Latest clean sighting wins - the
; screen outranks history. Positive evidence only: a missing row, a stray token or a blank
; field changes nothing. The 08:19 run is exactly what this catches: it reported DONE while
; line 70's screen still showed the pre-fix 420.25 (the typed 415.31 only committed ~10s
; later, after wIntegrate unfroze) - here the park/late capture reads the row, the summary
; names it, and the run ends REVIEW-amber instead of green.
RcpLandedSweep(rows) {
    global g_rcpWant
    if (!IsObject(rows) || !IsObject(g_rcpWant))
        return
    for no, w in g_rcpWant {
        if (w.kind = "skip" || !rows.HasKey(no + 0))
            continue
        r := rows[no + 0]
        if (r.mis != "")
            continue
        if (w.kind = "sub") {
            ; zb leaves Recv 0; an X-out leaves it blank. A blank where 0 is expected is
            ; "not painted yet", never a verdict (blank is also what mid-paint looks like).
            if (w.recvWant != "" && r.recv = "")
                continue
            w.seen := "Recv " (r.recv = "" ? "blank" : r.recv)
            w.proof := (w.recvWant = "" ? (r.recv = "" ? "ok" : "wrong") : ((r.recv + 0) = (w.recvWant + 0) ? "ok" : "wrong"))
            continue
        }
        if (r.recv = "" || w.qty = "")
            continue
        landed := ((r.recv + 0) = (w.qty + 0))
        seen := "Recv " r.recv
        if (landed && w.price != "") {
            if (r.exc = "")
                continue                ; qty alone cannot prove a line whose price we typed
            landed := (Abs((r.exc + 0) - (w.price + 0)) < 0.005)
            seen .= " Exc " r.exc
        } else if (landed && w.keepExc != "") {
            ; v2.8.0: ERA kept its own cost (a=2) - so the cost must still BE its own. The
            ; 08:55 run's line 3 (kept 3.21, later frames showed 0.04) is what this convicts.
            if (r.exc = "")
                continue                ; blank = mid-paint, never a verdict
            landed := (Abs((r.exc + 0) - (w.keepExc + 0)) < 0.005)
            seen .= " Exc " r.exc
        }
        w.seen := seen
        w.proof := landed ? "ok" : "wrong"
    }
}

; THE ACCURATE-PRICE SKIP (Kaine, 2026-07-19: "compare what the invoice price is to the PO,
; and if it's accurate, don't adjust the price. There's no point... It's only meant to change
; the prices and quantities on the part numbers that are inaccurate compared to the invoice").
; The chg flag can't decide this - it compares the invoice to the stale CSV export and
; overfires (11 of 17 on DO36465) - so the SCREEN decides: true only when a paid-for capture
; showed this line's row CLEAN with an Exc Cost equal to the invoice price. Positive evidence
; only - never seen, blank Exc, any stray token, or a mismatch all return false, and the line
; is visited exactly as before (typing the invoice price over an equal price is a no-op, so
; false-negatives cost a visit, never accuracy). Pure function; the drill feeds it rows.
RcpPriceAlreadyRight(rows, lineNo, price) {
    if (!IsObject(rows) || !rows.HasKey(lineNo + 0))
        return false
    g := rows[lineNo + 0]
    if (g.mis != "" || g.exc = "" || price = "")
        return false
    return (Abs((g.exc + 0) - (price + 0)) < 0.005)
}

; (RcpGridTotal - the money-total check - lived here until v2.5.0; it needed the walked
; grid that no longer exists.)

; (RcpRepairPass and RcpRepair lived here until v2.5.0 - the review-and-fix passes are
; gone; a failed line gets ONE in-place replay inside RcpLines instead.)

; (RcpXOut lived here until v2.4.0. The X-out keystream - read frame-by-frame off Recording
; 2026-07-17 181702.mp4 at 84.75-85.0s: line# \r lands on the Recv field, x \r clears it,
; ERA returns straight to the line prompt, no B/C or Cost question; the x IS echoed into
; the cell first, which is why it needs the Enter - now rides the one sequential work loop
; in RcpLines, typed at its place in line order instead of as a separate X-first pass.)

; (RcpRepairSubtract lived here until v2.5.0 - same strip-down.)

; Fire ERA's recv-aLL and answer its dialog. The 2026-07-16 23:32 live run proved a bare
; WM_CHAR "L" does NOT fire it (dialog never appeared; per-line WM_CHAR digits worked
; right after, so the control itself was fine). A physical keypress delivers
; KEYDOWN + lowercase char + KEYUP - so: try the lowercase char first, and if the
; dialog stays away, backspace any echoed char and escalate once to a real
; KEYDOWN/KEYUP pair. If neither fires it, stop typing rather than spray keys
; at an unknown screen.
RcpRecvAllFire(plan) {
    global RCP_RECVALL_KEY, g_rcpDry
    StringLower, ch, RCP_RECVALL_KEY
    if (g_rcpDry) {
        ; No ERA, no dialog to wait for - log the stream the real run would send.
        Log("dry: recv-aLL '" ch "' -> answer the Receipt All Parts dialog Yes")
        RcpProgStep()
        return true
    }
    RcpText(ch)
    r := RcpRecvAllDialog(2)
    if (r = "none") {
        Log("receipt: " plan.id " recv-aLL char '" ch "' did not pop the dialog - retrying with keydown")
        RcpChar(Chr(8))              ; clear the char if the Field: prompt echoed it
        StringUpper, vkc, RCP_RECVALL_KEY
        RcpKey(Asc(vkc))
        r := RcpRecvAllDialog(3)
    }
    if (r = "ok") {
        RcpProgStep()            ; the L + dialog is one counted step of the run
        return true
    }
    if (r = "stuck") {
        Log("receipt: " plan.id " recv-aLL dialog would not close after Yes - aborted")
        ShowToast("bad", "Receipt aborted", "Receipt All Parts dialog stuck open - answer it, then receipt again")
    } else {
        Log("receipt: " plan.id " recv-aLL dialog never appeared - aborted")
        ShowToast("bad", "Receipt aborted", "Receipt All Parts dialog missing - ERA left as-is")
    }
    return false
}

; The dialog is a real window: title "Receipt All Parts", Yes = Button1 (Window Spy,
; Kaine's screenshot 2026-07-16). Yes = every line flagged received; the fix loop then
; visits only the lines that need qty/price corrections. Kaine (video, 23:48): after
; clicking Yes, type NOTHING until the window is actually GONE - hence WinWaitClose.
; Returns "ok" / "none" (never appeared) / "stuck" (appeared, would not close).
RcpRecvAllDialog(waitS) {
    SetTitleMatchMode, 2
    WinWait, Receipt All Parts, , %waitS%
    if (ErrorLevel)
        return "none"
    ra := WinExist("Receipt All Parts")
    ControlClick, Button1, ahk_id %ra%, , Left, 1, NA   ; Yes
    WinWaitClose, ahk_id %ra%, , 5
    if (ErrorLevel) {
        ControlClick, Button1, ahk_id %ra%, , Left, 1, NA   ; one more nudge
        WinWaitClose, ahk_id %ra%, , 3
        if (ErrorLevel)
            return "stuck"
    }
    return "ok"
}

; --- typing primitives (ports of Speed_Receipting's SendCharToControl / SendKey /
;     SendText / SendText_Variable; target comes from g_rcpCtl) -------------------
; Dry run (2.1): when g_rcpDry is set the primitives post NOTHING - RcpText/RcpTextVar log
; the exact chunk the real run would send instead. The pacing sleeps still run so a dry
; run's rhythm matches a real one.
RcpChar(char) {
    global g_rcpCtl, g_rcpDry
    if (g_rcpDry)
        return
    DllCall("PostMessage", "Ptr", g_rcpCtl, "UInt", 0x102, "Ptr", Asc(char), "Ptr", 0)   ; WM_CHAR
}

RcpKey(vk) {
    global g_rcpCtl, g_rcpDry
    if (g_rcpDry) {
        Log("dry: key vk=" vk)
        return
    }
    DllCall("PostMessage", "Ptr", g_rcpCtl, "UInt", 0x100, "Ptr", vk, "Ptr", 0)   ; WM_KEYDOWN
    DllCall("PostMessage", "Ptr", g_rcpCtl, "UInt", 0x101, "Ptr", vk, "Ptr", 0)   ; WM_KEYUP
    Sleep, 10
}

RcpText(text) {
    global RCP_TEXT_SETTLE, g_rcpDry
    if (g_rcpDry)
        Log("dry: type '" StrReplace(text, "`r", "{Enter}") "'")
    Loop, Parse, text
        RcpChar(A_LoopField)
    Sleep, %RCP_TEXT_SETTLE%
}

RcpTextVar(text) {
    global RCP_VAR_SETTLE, g_rcpDry
    if (g_rcpDry)
        Log("dry: type '" text "'")
    Loop, Parse, text
        RcpChar(A_LoopField)
    Sleep, %RCP_VAR_SETTLE%
}

; ============================================================
;  ERA diagnostics (tray) - capture and paging, typing nothing
; ============================================================
; Prove the capture path WITHOUT typing anything into ERA. F11 only copies, so this is safe
; to run on a live screen. It answers the one thing a paste-by-hand cannot: whether the WIS
; keyboard map fires on a POSTED key (what the sender sends) or only on a physical one.
MenuTestScreen:
    tsScr := EraScreen()
    if (tsScr = "") {
        MsgBox, 0x30, ERA screen read - FAILED, % "Nothing came back on the clipboard.`n`nEither ERA Port isn't open, or the WIS keyboard map ignores a posted F11 and needs a real keypress.`n`nThe sender falls back to running blind, exactly as before."
        return
    }
    tsPrompt := EraPrompt(tsScr)
    tsRows   := EraParseRows(tsScr)
    tsN := 0
    for tsK, tsV in tsRows
        tsN++
    MsgBox, 0x40, ERA screen read - OK, % "Captured " StrLen(tsScr) " characters.`n`nCaret is at the '" (tsPrompt = "" ? "unrecognised" : tsPrompt) "' prompt.`nParsed " tsN " line row(s) off the grid.`n`nFull text appended to era-screens.log."
return

; (The "Test ERA paging" tray item lived here until v2.5.0. The deterministic pass never
; pages - a typed line number makes ERA jump to that line's page on its own - so the paging
; machinery it exercised is gone with the review walks.)

; ============================================================
;  Shared plumbing (copied from the sender - keep the two in step)
; ============================================================
ReadConfig() {
    global IsuzuUrl, BydUrl, ReconUrl, DefaultBrand, EnableEmailDrag
    global CfgSubtractBy, CfgConfirmTyping, CfgDryRun, CfgCkptStop, CfgStripIsuzuI, CfgContinueInvUsed
    global CfgScreenChk
    global CfgStaleMode, CfgStaleHours, CfgAlertWhen, CfgAlertHow, CfgShowLogPane, CfgFanOut, CfgToastSecs
    global CfgQtyModeDefault, CfgBrand, CfgReceiver, CfgTimingPreset
    global CfgHideOrder, CfgHideMake, CfgHideDate, CfgHideExGst, CfgHidePoInv, CfgHideWarnRows, CfgDotBothOnly
    global RCP_AFTER_MENU, RCP_AFTER_PO, RCP_AFTER_INV, RCP_BETWEEN_LINES
    global RCP_TEXT_SETTLE, RCP_VAR_SETTLE, RCP_PAGE_SETTLE, g_rcpQtyMode
    ini := A_ScriptDir "\config.ini"
    IniRead, IsuzuUrl, %ini%, settings, IsuzuApiUrl, https://isuzu-parser-production.up.railway.app
    IniRead, BydUrl,   %ini%, settings, BydApiUrl,   https://byd-parser-production.up.railway.app
    IsuzuUrl := RTrim(IsuzuUrl, "/ `t")
    BydUrl   := RTrim(BydUrl,   "/ `t")
    ; Baked-in default so a fresh machine with no config.ini still finds the recon service.
    ; config.ini still overrides per-machine; set it to a single space there to turn the
    ; recon fan-out off entirely.
    IniRead, ReconUrl, %ini%, settings, ReconApiUrl, https://invoice-recon-production.up.railway.app
    ReconUrl := RTrim(Trim(ReconUrl), "/ `t")
    IniRead, DefaultBrand, %ini%, settings, DefaultBrand, %A_Space%
    StringLower, DefaultBrand, DefaultBrand
    if (DefaultBrand != "isuzu" && DefaultBrand != "byd")
        DefaultBrand := ""
    IniRead, edrag, %ini%, settings, EnableEmailDrag, 1
    EnableEmailDrag := (edrag != "0")
    ; ---- 2.1 settings (defaults = pre-2.1 behaviour) ----
    IniRead, CfgSubtractBy,      %ini%, settings, SubtractBy, zb
    if (CfgSubtractBy != "x")    ; only an explicit "x" leaves the 0+B default
        CfgSubtractBy := "zb"
    IniRead, CfgConfirmTyping,   %ini%, settings, ConfirmBeforeTyping, 0
    IniRead, CfgDryRun,          %ini%, settings, DryRun, 0
    IniRead, CfgCkptStop,        %ini%, settings, StopAfterXOut, 0
    IniRead, CfgScreenChk,       %ini%, settings, ScreenCheck, 1
    IniRead, CfgStripIsuzuI,     %ini%, settings, StripIsuzuI, 0
    IniRead, CfgContinueInvUsed, %ini%, settings, ContinueOnInvoiceUsed, 0
    IniRead, CfgStaleMode,       %ini%, settings, StaleExportMode, warn
    if (CfgStaleMode != "block")
        CfgStaleMode := "warn"
    IniRead, CfgStaleHours,      %ini%, settings, StaleExportHours, 8
    IniRead, CfgAlertWhen,       %ini%, settings, AlertWhen, both
    IniRead, CfgAlertHow,        %ini%, settings, AlertHow, both
    IniRead, CfgToastSecs,       %ini%, settings, ToastSeconds, 1.2
    if CfgToastSecs is not number
        CfgToastSecs := 1.2
    else if (CfgToastSecs < 0.5 || CfgToastSecs > 60)
        CfgToastSecs := 1.2
    IniRead, CfgShowLogPane,     %ini%, settings, ShowLog, 0
    IniRead, CfgFanOut,          %ini%, settings, FanOut, 1
    IniRead, CfgQtyModeDefault,  %ini%, settings, QtyMode, auto
    if (CfgQtyModeDefault != "perline" && CfgQtyModeDefault != "recvall")
        CfgQtyModeDefault := "auto"
    g_rcpQtyMode := CfgQtyModeDefault   ; the quantity mode now lives only in Settings
    IniRead, CfgBrand,           %ini%, settings, Brand, byd
    StringLower, CfgBrand, CfgBrand
    if (CfgBrand != "isuzu" && CfgBrand != "byd")
        CfgBrand := "byd"
    IniRead, CfgReceiver,        %ini%, settings, Receiver, KAINE
    IniRead, CfgTimingPreset,    %ini%, settings, TimingPreset, fast
    IniRead, CfgHideOrder,       %ini%, settings, HideColOrder, 0
    IniRead, CfgHideMake,        %ini%, settings, HideColMake, 0
    IniRead, CfgHideDate,        %ini%, settings, HideColDate, 0
    IniRead, CfgHideExGst,       %ini%, settings, HideColExGst, 0
    IniRead, CfgHidePoInv,       %ini%, settings, HideColPoInv, 0
    ; HideColReceipted is not read any more (2.24.0). A stale key in config.ini is inert -
    ; the column it hid no longer exists.
    IniRead, CfgHideWarnRows,    %ini%, settings, HideWarnRows, 1
    IniRead, CfgDotBothOnly,     %ini%, settings, DotBothOnly, 1
    ; Timing (ms). The six REAL waits the run uses - stored so a slow ERA day is tunable
    ; without editing source. Defaults are the FAST preset (Kaine, 2026-07-22) - the halves of
    ; the Normal values (250/400/0/120/200/150) the runs were proven on, and exactly what his
    ; live config.ini already held. The preset dropdown above defaults to Fast to match: a
    ; dropdown reading "Fast" over Normal waits would be a lie about what the run does.
    IniRead, RCP_AFTER_MENU,     %ini%, settings, WaitAfterMenu, 125
    IniRead, RCP_AFTER_PO,       %ini%, settings, WaitAfterPo, 200
    IniRead, RCP_AFTER_INV,      %ini%, settings, WaitAfterInv, 0
    IniRead, RCP_BETWEEN_LINES,  %ini%, settings, WaitBetweenLines, 60
    IniRead, RCP_TEXT_SETTLE,    %ini%, settings, WaitTextSettle, 100
    IniRead, RCP_VAR_SETTLE,     %ini%, settings, WaitVarSettle, 75
    IniRead, RCP_PAGE_SETTLE,    %ini%, settings, PageSettleMs, 2500
}

; Persist the 2.1 settings. ONLY the keys the settings dialog owns - the URL/routing keys
; are hand-edited in config.ini and never rewritten by the GUI.
WriteConfig() {
    global CfgSubtractBy, CfgConfirmTyping, CfgDryRun, CfgCkptStop, CfgStripIsuzuI, CfgContinueInvUsed
    global CfgScreenChk
    global CfgStaleMode, CfgStaleHours, CfgAlertWhen, CfgAlertHow, CfgShowLogPane, CfgFanOut, CfgToastSecs
    global CfgQtyModeDefault, CfgBrand, CfgReceiver, CfgTimingPreset
    global CfgHideOrder, CfgHideMake, CfgHideDate, CfgHideExGst, CfgHidePoInv, CfgHideWarnRows, CfgDotBothOnly
    global RCP_AFTER_MENU, RCP_AFTER_PO, RCP_AFTER_INV, RCP_BETWEEN_LINES
    global RCP_TEXT_SETTLE, RCP_VAR_SETTLE
    ini := A_ScriptDir "\config.ini"
    IniWrite, %CfgSubtractBy%,      %ini%, settings, SubtractBy
    IniWrite, %CfgConfirmTyping%,   %ini%, settings, ConfirmBeforeTyping
    IniWrite, %CfgDryRun%,          %ini%, settings, DryRun
    IniWrite, %CfgCkptStop%,        %ini%, settings, StopAfterXOut
    IniWrite, %CfgScreenChk%,       %ini%, settings, ScreenCheck
    IniWrite, %CfgStripIsuzuI%,     %ini%, settings, StripIsuzuI
    IniWrite, %CfgContinueInvUsed%, %ini%, settings, ContinueOnInvoiceUsed
    IniWrite, %CfgStaleMode%,       %ini%, settings, StaleExportMode
    IniWrite, %CfgStaleHours%,      %ini%, settings, StaleExportHours
    IniWrite, %CfgAlertWhen%,       %ini%, settings, AlertWhen
    IniWrite, %CfgAlertHow%,        %ini%, settings, AlertHow
    IniWrite, %CfgToastSecs%,       %ini%, settings, ToastSeconds
    IniWrite, %CfgShowLogPane%,     %ini%, settings, ShowLog
    IniWrite, %CfgFanOut%,          %ini%, settings, FanOut
    IniWrite, %CfgQtyModeDefault%,  %ini%, settings, QtyMode
    IniWrite, %CfgBrand%,           %ini%, settings, Brand
    IniWrite, %CfgReceiver%,        %ini%, settings, Receiver
    IniWrite, %CfgTimingPreset%,    %ini%, settings, TimingPreset
    IniWrite, %CfgHideOrder%,       %ini%, settings, HideColOrder
    IniWrite, %CfgHideMake%,        %ini%, settings, HideColMake
    IniWrite, %CfgHideDate%,        %ini%, settings, HideColDate
    IniWrite, %CfgHideExGst%,       %ini%, settings, HideColExGst
    IniWrite, %CfgHidePoInv%,       %ini%, settings, HideColPoInv
    IniWrite, %CfgHideWarnRows%,     %ini%, settings, HideWarnRows
    IniWrite, %CfgDotBothOnly%,      %ini%, settings, DotBothOnly
    IniWrite, %RCP_AFTER_MENU%,     %ini%, settings, WaitAfterMenu
    IniWrite, %RCP_AFTER_PO%,       %ini%, settings, WaitAfterPo
    IniWrite, %RCP_AFTER_INV%,      %ini%, settings, WaitAfterInv
    IniWrite, %RCP_BETWEEN_LINES%,  %ini%, settings, WaitBetweenLines
    IniWrite, %RCP_TEXT_SETTLE%,    %ini%, settings, WaitTextSettle
    IniWrite, %RCP_VAR_SETTLE%,     %ini%, settings, WaitVarSettle
}

; ---- receipted stamps (receipted.ini) -----------------------------------------
; NOTE (approved with recorded dissent, card a4): never-finalize is on, so the sender only
; knows it TYPED the receipt. The stamp says "typed at HH:mm", and dry runs never stamp.
LoadReceipted() {
    global g_rcpDone
    g_rcpDone := {}
    f := A_ScriptDir "\receipted.ini"
    if (!FileExist(f))
        return
    IniRead, sect, %f%, receipted
    Loop, Parse, sect, `n
    {
        p := InStr(A_LoopField, "=")
        if (p > 1)
            g_rcpDone[SubStr(A_LoopField, 1, p - 1)] := SubStr(A_LoopField, p + 1)
    }
}

; 2.24.0: the stamp is no longer PRINTED anywhere - it is the colour of the row's tick - so
; it has to carry whether the run was clean. Clean = "HH:mm", REVIEW = "HH:mm R", and only
; the clean form draws green. Entries written before 2.24.0 have no suffix and read as
; clean, which is what they were: runs that finished.
StampReceipted(id, clean := true) {
    global g_rcpDone
    FormatTime, hm, , HH:mm
    v := clean ? hm : hm " R"
    g_rcpDone[id] := v
    f := A_ScriptDir "\receipted.ini"
    IniWrite, %v%, %f%, receipted, %id%
}

; Extract a JSON string value, honouring backslash escapes. The flag text is multi-line, so a
; plain regex would stop at the first \n and a non-greedy match would trip over escaped quotes.
JsonStr(json, key) {
    needle := """" key """:"""
    p := InStr(json, needle)
    if (!p)
        return ""
    i := p + StrLen(needle)
    out := ""
    Loop {
        c := SubStr(json, i, 1)
        if (c = "")
            break
        if (c = "\") {
            e := SubStr(json, i + 1, 1)
            if (e = "n")
                out .= "`n"
            else if (e = "r")
                out .= "`r"
            else if (e = "t")
                out .= "`t"
            else if (e = "u") {
                out .= Chr("0x" . SubStr(json, i + 2, 4))
                i += 6
                continue
            }
            else
                out .= e            ; \" \\ \/ and anything else: take it literally
            i += 2
            continue
        }
        if (c = """")               ; unescaped quote = end of value
            break
        out .= c
        i += 1
    }
    return out
}

JsonBool(json, key) {
    RegExMatch(json, "i)""" key """\s*:\s*(true|false)", m)
    return (m1 = "true")
}

;
;     async=true -> fire-and-forget: returns the instant the request is handed off, WITHOUT
;     waiting for a response. This is what keeps the recon fan-out from slowing the existing
;     send. Status/text are NOT read in that mode (they throw on an async handle) and no
;     retry is possible, so the result is {status:0} by design - callers must ignore it.
; connectMs/maxAttempts default to the original behaviour - the parse path (the send itself)
; must stay patient and keep retrying. Callers that merely decorate the send pass a short
; bound instead: a dead host costs 34s (DNS never resolves) to 51s (packets dropped) at the
; defaults, because the resolve/connect timeout is charged PER ATTEMPT on top of the sleeps.
; GET sibling of HttpPostJson (2.13). Same {status, text} shape, same retry ladder, so a
; caller can swap one for the other without changing how it reads the answer. Added
; because /po-data/status and /po-data/snapshots are GET routes and POSTing at them
; silently 404s - which is exactly how the stale-export gate went dark for months.
HttpGetJson(url, connectMs := 15000, maxAttempts := 3) {
    out := {status: 0, text: ""}
    attempts := 0
    Loop {
        attempts++
        try {
            whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
            whr.Open("GET", url, false)
            whr.SetTimeouts(connectMs, connectMs, 60000, 180000)
            try whr.Option(9) := 0x0800 | 0x2000
            try whr.Option(4) := 0x3300
            whr.Send()
            out.status := whr.Status
            out.text   := whr.ResponseText
            return out
        } catch e {
            out.status := 0
            out.text   := e.message
            if (attempts >= maxAttempts)
                return out
            Sleep, % (attempts = 1 ? 250 : 500)
        }
    }
}

; Async POST that PUMPS the message loop while waiting (Sleep dispatches messages), so
; the sidebar's marquee bar animates during the fetch instead of freezing. Returns the
; same {status, text} shape as the sync HttpPostJson. 2026-07-20, for the loading bar.
HttpPostJsonPumped(url, body, ctype := "application/json", timeoutS := 60) {
    out := {status: 0, text: ""}
    whr := HttpPostJson(url, body, true, ctype)
    if (!IsObject(whr))
        return out
    if (ComObjType(whr) = "") {          ; the async catch path returns a plain {status:0} object
        return whr
    }
    t0 := A_TickCount
    Loop {
        done := false
        try done := whr.WaitForResponse(0)
        if (done)
            break
        if (A_TickCount - t0 > timeoutS * 1000) {
            out.text := "timeout after " timeoutS "s"
            return out
        }
        Sleep, 60
    }
    try {
        out.status := whr.Status
        out.text   := whr.ResponseText
    }
    return out
}

HttpPostJson(url, body, async := false, ctype := "application/json"
           , connectMs := 15000, maxAttempts := 3) {
    out := {status: 0, text: ""}
    attempts := 0
    Loop {
        attempts++
        try {
            whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
            whr.Open("POST", url, async)
            whr.SetRequestHeader("Content-Type", ctype)
            whr.SetTimeouts(connectMs, connectMs, 60000, 180000)  ; resolve, connect, send, receive
            try whr.Option(9) := 0x0800 | 0x2000           ; SecureProtocols: TLS1.2 | TLS1.3
            try whr.Option(4) := 0x3300                     ; SslErrorIgnoreFlags
            whr.Send(body)
            if (async)
                return whr                                  ; the LIVE COM object: caller must keep a
                                                            ; reference or the send is aborted. Do NOT
                                                            ; touch .Status/.ResponseText on it here.
            out.status := whr.Status
            out.text   := whr.ResponseText
            return out
        } catch e {
            if (async)
                return out                                  ; never retry, never surface: fire-and-forget
            out.status := 0
            out.text   := e.message
            if (attempts >= maxAttempts)
                return out
            if (attempts = 1) {
                Sleep, 250
                continue
            }
            if (attempts < 3) {
                Sleep, 500
                continue
            }
            return out
        }
    }
}

; --- MsgBox positioning ---------------------------------------------------------
; A dialog can't be moved from inside the message handler (it isn't up yet), so this only
; arms a timer. See the OnMessage(0x44) note in the auto-exec section for the why.
DlgCenter(wParam) {
    static AHK_DIALOG := 1027
    if (wParam = AHK_DIALOG)
        SetTimer, DlgCenterNow, -10
}

DlgCenterNow:
    DlgCenterMove()
return

; Centre the dialog on the ERA Port window, else on the primary screen. Scoped to OUR pid:
; ERA's own dialogs ("Receipt All Parts") are #32770 too and must not be touched - the
; sender clicks those by handle and moving one under itself would be its own bug.
DlgCenterMove() {
    global DLG_ERA_TITLE
    DetectHiddenWindows, Off
    SetTitleMatchMode, 2
    Process, Exist
    pid := ErrorLevel
    WinWait, ahk_class #32770 ahk_pid %pid%, , 2
    if (ErrorLevel)
        return
    dlg := WinExist()
    WinGetPos, , , dw, dh, ahk_id %dlg%
    era := WinExist(DLG_ERA_TITLE)
    if (era) {
        WinGetPos, ex, ey, ew, eh, ahk_id %era%
        x := ex + (ew - dw) // 2
        y := ey + (eh - dh) // 2
    } else {
        x := (A_ScreenWidth - dw) // 2
        y := (A_ScreenHeight - dh) // 2
    }
    ; Never leave it off-screen, whatever ERA's own position is.
    x := (x < 0) ? 0 : (x + dw > A_ScreenWidth ? A_ScreenWidth - dw : x)
    y := (y < 0) ? 0 : (y + dh > A_ScreenHeight ? A_ScreenHeight - dh : y)
    WinMove, ahk_id %dlg%, , %x%, %y%
}

Log(msg) {
    global g_sbVisible, CfgShowLogPane, g_logTag, g_dataDir
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    ; [wl] = this line came from the WORKLIST script (the sender writes [snd]). Both scripts
    ; share one sender.log on purpose - one timeline - and the tag is what tells the two
    ; processes apart in it (Kaine asked for the tags 2026-07-19). The sidebar pane line
    ; below stays untagged: everything in that pane is [wl] by definition.
    FileAppend, % ts " | " g_logTag " " msg "`n", % g_dataDir "\sender.log"
    ; Mirror into the sidebar's activity-log pane (the mockup's MsgBox/TrayTip replacement).
    ; Appending via EM_SETSEL+EM_REPLACESEL keeps the view scrolled to the newest line.
    if (g_sbVisible && CfgShowLogPane) {
        GuiControlGet, hLogPane, SB:Hwnd, SbLogPane
        if (hLogPane) {
            line := SubStr(ts, 12) " | " msg "`r`n"
            SendMessage, 0xB1, -1, -1, , ahk_id %hLogPane%        ; EM_SETSEL end
            SendMessage, 0xC2, 0, &line, , ahk_id %hLogPane%      ; EM_REPLACESEL
        }
    }
}

; --- Custom on-screen toast (bottom-right). States: "load" / "ok" / "bad".
ShowToast(state, line1, line2 := "", secs := 0) {
    global GLYPH_OK, GLYPH_BAD, ToastHwnd, CfgToastSecs, g_toastFast, g_progOn, g_headless
    if (g_headless)                 ; child job process: log only, never draw
        return
    ; 1.21.0: during a Full refresh the progress panel owns that corner. Toasts would stack
    ; on top of it and say the same thing, so they are folded into the panel's detail line
    ; instead of being drawn. Failures still get through as toasts AFTER the panel closes.
    if (g_progOn) {
        ProgSub(line1 (line2 = "" ? "" : " - " line2))
        return
    }
    prevDef := A_DefaultGui
    static built := false, TGlyph, TL1, TL2
    if (state = "ok")
        glyph := GLYPH_OK, accent := "33C966"
    else if (state = "bad")
        glyph := GLYPH_BAD, accent := "F25A5A"
    else
        glyph := Chr(0x25CF), accent := "4DA3FF"   ; filled dot = working
    if (!built) {
        Gui, Toast:New, +AlwaysOnTop -Caption +ToolWindow +HwndToastHwnd +E0x08000000
        Gui, Toast:Margin, 16, 14
        Gui, Toast:Color, 26262B
        Gui, Toast:Font, s22 Bold, Segoe UI
        Gui, Toast:Add, Text, vTGlyph w30 cWhite, % glyph
        Gui, Toast:Font, s11 Bold, Segoe UI
        Gui, Toast:Add, Text, x+10 yp+1 vTL1 cWhite w320, % line1
        Gui, Toast:Font, s9 Norm, Segoe UI
        Gui, Toast:Add, Text, xp y+3 vTL2 cBBBBBB w320, % line2
        built := true
    }
    GuiControl, Toast:+c%accent%, TGlyph
    GuiControl, Toast:, TGlyph, % glyph
    GuiControl, Toast:, TL1, % line1
    GuiControl, Toast:, TL2, % line2
    Gui, Toast:Show, Hide AutoSize
    DetectHiddenWindows, On
    WinGetPos, , , tw, th, ahk_id %ToastHwnd%
    DetectHiddenWindows, Off
    SysGet, wa, MonitorWorkArea
    if (tw = "")
        tw := 400
    if (th = "")
        th := 90
    ; Park it INSIDE the ERA window, hard into the bottom-right corner (Kaine 2026-07-20:
    ; "I still want it all within the window... flushed up against the back"). The monitor
    ; corner is only the fallback for when no ERA window is being tracked.
    if (ToastAnchorRect(ax, ay, aw, ah)) {
        x := ax + aw - tw
        y := ay + ah - th
        if (x < ax)                       ; window narrower than the toast: never spill out
            x := ax
        if (y < ay)
            y := ay
    } else {
        x := waRight - tw - 18
        y := waBottom - th - 18
    }
    Gui, Toast:Show, NoActivate x%x% y%y%
    ToastSetGlass(ToastHwnd)
    if (state = "load") {
        SetTimer, HideToast, Off     ; "load" keeps NO timer - it is a progress toast and
                                     ; has to sit there until the ok/bad result replaces
                                     ; it, or an upload goes silent.
    } else {
        ; Dwell from Settings > Service (2.18.0, default 2.5s). Belt-and-braces floor:
        ; a mangled config value must never flash the toast away unreadably.
        ; 1.20.0: `secs` overrides the Settings dwell for one call. Full refresh uses 1.3s
        ; on its step toasts so a six-step run does not take 15s of reading to get through.
        ; The 500ms floor still applies - a caller cannot make a toast unreadable either.
        tDwell := Round((secs > 0 ? secs : (g_toastFast ? 1.3 : CfgToastSecs)) * 1000)
        if (tDwell < 500)
            tDwell := (secs > 0) ? 500 : 2500
        SetTimer, HideToast, % -tDwell
    }
    Gui, %prevDef%:Default   ; Toast:New hijacks the thread's default GUI - hand it back to
                             ; whoever called (sender threads need Gui 1, worklist threads Gui SB).
}

HideToast:
    Gui, Toast:Hide
return

; ---- toast glass (Kaine 2026-07-20: "a little bit more see-through... while maintaining
; the density of the wording") ------------------------------------------------------
; WinSet,Transparent would fade the TEXT along with the panel, which is the thing he did
; not want. Acrylic blur-behind fades only what is BEHIND the window, so both lines stay
; at full strength. Two parts, and both are needed:
;   1. SetWindowCompositionAttribute asks DWM to blur + tint the window's backdrop.
;   2. TransColor keys out the Gui's own solid background - without it GDI paints 26262B
;      straight over the blur DWM just drew and nothing looks different.
; Applied once (static guard): the settings survive Hide/Show, and re-keying every toast
; makes the first paint flicker.
ToastSetGlass(hwnd) {
    static done := false
    if (done)
        return
    done := true
    ; 4 = ACCENT_ENABLE_ACRYLICBLURBEHIND (Win10 1803+), 3 = ACCENT_ENABLE_BLURBEHIND.
    ; Tint is AABBGGRR, so 0x99201A18 is #181A20 at 60%.
    if (ToastAccent(hwnd, 4, 0x99201A18) || ToastAccent(hwnd, 3, 0x99201A18)) {
        WinSet, TransColor, 26262B, ahk_id %hwnd%
        Log("toast: acrylic glass on")
    } else {
        ; No desktop composition (RDP session, Win7 basic theme): fall back to fading the
        ; whole window. 215 is as far as it goes before the small grey line stops reading.
        WinSet, Transparent, 215, ahk_id %hwnd%
        Log("toast: acrylic unavailable, using flat alpha 215")
    }
}

ToastAccent(hwnd, state, tint) {
    VarSetCapacity(accent, 16, 0)
    NumPut(state, accent,  0, "Int")     ; AccentState
    NumPut(2,     accent,  4, "Int")     ; AccentFlags - 2 = paint the whole client area
    NumPut(tint,  accent,  8, "UInt")    ; GradientColor, AABBGGRR
    ; WINCOMPATTRDATA { DWORD Attrib; PVOID pvData; SIZE_T cbData; } - pointer-aligned
    off := (A_PtrSize = 8) ? 8 : 4
    VarSetCapacity(data, off + (A_PtrSize * 2), 0)
    NumPut(19,       data, 0,               "Int")   ; WCA_ACCENT_POLICY
    NumPut(&accent,  data, off,             "Ptr")
    NumPut(16,       data, off + A_PtrSize, "Ptr")
    return DllCall("user32\SetWindowCompositionAttribute", "Ptr", hwnd, "Ptr", &data)
}

; Visible rect of the ERA window the dock is tracking, for parking the toast inside it.
; DWM extended frame bounds, not GetWindowRect: on Win10/11 the window rect carries an
; invisible resize border, and the toast would look like it was hanging off the edge.
; Returns false (and the caller falls back to the monitor corner) when there is no ERA
; window, it is minimised, or the measurement is nonsense.
ToastAnchorRect(ByRef x, ByRef y, ByRef w, ByRef h) {
    global trackedHwnd
    if (!trackedHwnd || !WinExist("ahk_id " trackedHwnd))
        return false
    WinGet, mm, MinMax, ahk_id %trackedHwnd%
    if (mm = -1)
        return false
    VarSetCapacity(fr, 16, 0)
    if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", trackedHwnd, "UInt", 9, "Ptr", &fr, "UInt", 16) != 0) {
        WinGetPos, wx, wy, ww, wh, ahk_id %trackedHwnd%
        x := wx, y := wy, w := ww, h := wh
    } else {
        x := NumGet(fr, 0, "Int"), y := NumGet(fr, 4, "Int")
        w := NumGet(fr, 8, "Int") - x, h := NumGet(fr, 12, "Int") - y
    }
    return (w > 40 && h > 40)
}

; ---- reload hotkey (1.17.0, Kaine 2026-07-20: "Ctrl+Escape... reloads the whole script") --
; Ctrl+Esc normally opens the Start menu; the keyboard hook claims it here instead. Guarded:
; a reload mid-receipt-run would orphan half-typed lines on the ERA screen, so a live run
; blocks it with a toast - stop the run first, then reload. #SingleInstance Force makes
; Reload the clean equivalent of the manual kill-and-relaunch.
^Esc::
    if (g_rcpBusy) {
        ShowToast("bad", "Reload blocked", "A receipt run is typing - stop it first")
        return
    }
    Log("reload: Ctrl+Esc pressed - reloading (dock v" DOCK_VERSION ", worklist v" VERSION ")")
    Reload
return

; ============================================================
;  ERA-driven PO export  (1.19.0)
; ============================================================
; "Export + upload PO data" - the manual "Upload PO Data..." with the file picker step
; replaced by ERA itself: report 6913, saved query KAINE, wait for the CSV to land in
; PSdata, then hand that path to PoUploadRun. Everything after the path is resolved is
; the SAME code as the manual route - preflight, 409 cliff gate, po-cache.csv, toasts -
; so there is exactly one place where the snapshot can be replaced.
;
; This blocks the dock thread for 30-60s while ERA is driven. That is deliberate: ERA
; cannot be driven while anything else is typing into it, so there is nothing useful to
; stay responsive FOR. The dot sits on busy for the duration.
;
; Password: the same SettingsPwOk() gate as the manual upload, and it fires BEFORE ERA is
; touched - no point driving a 60s export that the gate is going to refuse at the end.

PoExportRun(silent := false, doImport := true) {
    global ReconUrl
    static busy := false

    if (ReconUrl = "") {
        ShowToast("bad", "PO export unavailable", "Set ReconApiUrl in config.ini")
        return false
    }
    if (busy)
        return false
    ; 1.20.0: silent (Full refresh) skips the gate here AND in PoUploadRun - one run used to
    ; ask twice.
    if (!silent && !SettingsPwOk())
        return false

    busy := true
    StatusDot("busy")
    ShowToast("load", "Driving ERA...", "Report 6913 - don't touch the keyboard")

    csv := EraExportPo()
    if (csv = "") {
        busy := false
        StatusRunCheck(false)
        return false
    }

    ok := PoUploadRun(false, csv, silent)
    ; doImport=false when Full refresh is driving: the invoice CSVs go up straight after
    ; this, and ONE import at the end of the whole run beats two 30s imports back to back.
    if (ok && doImport)
        DockImportRun(true)          ; upload, then import - agreed 2026-07-21
    busy := false
    StatusRunCheck(false)
    return ok
}

; Drives the export. Returns the path of the freshly written CSV, or "" having already
; logged + toasted the reason.
;
; No hard-coded output filename. ERA derives it from the report name, so instead of
; guessing "KAINE Data.csv" this snapshots every .csv in both PSdata candidates and takes
; whichever one changes or appears. A renamed report cannot silently break it.
EraExportPo() {
    global hEraCtl

    dirs := []
    dirs.Push("C:\Users\" A_UserName "\Documents\PSdata\")
    dirs.Push("C:\Users\" A_UserName "\OneDrive - Hopper Motor Group\Documents\PSdata\")

    pre := {}
    for i, d in dirs {
        Loop, Files, %d%*.csv
            pre[A_LoopFileLongPath] := A_LoopFileTimeModified
    }

    if !WinExist("ERA Port")
        return EraFail("ERA Port window not found. Is ERA open?")

    EraHome()
    if (!hEraCtl)
        return EraFail("ERA control handle not found after HomePage.")

    EraSendText(hEraCtl, "6913`r")
    EraSendText(hEraCtl, "KAINE`r")
    EraSendText(hEraCtl, "o")
    EraSendText(hEraCtl, "4")
    EraSendText(hEraCtl, "`r")
    EraSendText(hEraCtl, "`r")
    EraSendText(hEraCtl, "`r")

    if !EraWaitAndSend("PC destination format", "ListBox1", "{Enter}", 6)
        return ""
    if !EraWaitAndSend("Select the destination file for the ERA data", "Button2", "{Enter}", 6)
        return ""
    if !EraWaitAndSend("Confirm Save As", "Button1", "{Left}{Enter}", 6)
        return ""

    ; Non-fatal - the monitor can flash past faster than WinWaitActive can catch it.
    WinWaitActive, File Import Monitor,, 10
    if !ErrorLevel
        WinWaitNotActive, File Import Monitor,, 80

    ShowToast("load", "Waiting for the CSV...", "Watching PSdata for a fresh file")

    found := ""
    Loop, 60 {
        for i, d in dirs {
            Loop, Files, %d%*.csv
            {
                p := A_LoopFileLongPath
                if (!pre.HasKey(p) || pre[p] != A_LoopFileTimeModified) {
                    found := p
                    break
                }
            }
            if (found != "")
                break
        }
        if (found != "")
            break
        Sleep, 1000
    }
    if (found = "") {
        list := ""
        for i, d in dirs
            list .= d "`n"
        return EraFail("No fresh CSV appeared in PSdata within 60s:`n" list)
    }

    Sleep, 800                       ; let ERA finish flushing the handle
    Log("po-export: ERA wrote " found)

    WinActivate, ERA Port
    Sleep, 200
    Send, {F1}
    return found
}

EraFail(msg) {
    flat := StrReplace(msg, "`n", " | ")
    Log("po-export: FAILED - " flat)
    ShowToast("bad", "ERA export failed", SubStr(flat, 1, 90))
    return ""
}

EraWaitAndSend(winTitle, control, keys, timeout) {
    WinWait, %winTitle%,, %timeout%
    if ErrorLevel
        return EraFail("Window not found within " timeout "s: " winTitle)
    Sleep, 500
    ControlSend, %control%, %keys%, %winTitle%
    if ErrorLevel
        return EraFail("ControlSend failed on '" control "' in: " winTitle)
    return true
}

; Home page + the 13-backspace / F2 / F1 x2 / END x3 unwind, lifted from the standalone
; export script. hEraWnd/hEraCtl are declared global INSIDE the function and assigned
; here - never `global x := v` below the auto-exec return, which declares but never
; assigns (the empty-CsvBase class of bug).
EraHome() {
    global hEraWnd, hEraCtl
    WinActivate, ERA Port
    WinWaitActive, ERA Port
    hEraWnd := WinExist("ERA Port")
    Sleep, 100
    ControlGet, hEraCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hEraWnd%
    if (!hEraCtl)
        ControlGet, hEraCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hEraWnd%
    img := "C:\Program Files (x86)\PowerLink\image\i_pageb.bmp"
    ControlClick, Button18, ahk_id %hEraWnd%, %img%, Left, 1, NA
    Loop, 13
        EraSendKey(hEraCtl, 0x08)
    EraSendKey(hEraCtl, 0x71)
    Loop, 2
        EraSendKey(hEraCtl, 0x70)
    Loop, 3
        EraSendText(hEraCtl, "END`r")
    Sleep, 250
    WinGet, hNoPrev, ID,, No previous menu
    if (hNoPrev)
        PostMessage, 0x10,,,, ahk_id %hNoPrev%
}

EraSendKey(hwnd, vk) {
    DllCall("PostMessage", "Ptr", hwnd, "UInt", 0x100, "Ptr", vk, "Ptr", 0)   ; WM_KEYDOWN
    DllCall("PostMessage", "Ptr", hwnd, "UInt", 0x101, "Ptr", vk, "Ptr", 0)   ; WM_KEYUP
}

EraSendText(hwnd, text) {
    Loop, Parse, text
        DllCall("PostMessage", "Ptr", hwnd, "UInt", 0x102, "Ptr", Asc(A_LoopField), "Ptr", 0)
    Sleep, 150
}
