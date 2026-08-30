;=============================================================================
;
;   AUDOS_Switch.ahk        AutoHotkey v1
;
;   Tells the two AUDOS windows apart and gives you one hotkey per brand.
;
;   PART NUMBER LOOKUP - copy a part number, then:
;
;       Ctrl + Left click    look it up in the KIA window
;       Ctrl + Right click   look it up in the HYUNDAI window
;
;   JUST BRING A WINDOW UP
;
;       Insert       activate the KIA window
;       Home         activate the HYUNDAI window
;       Ctrl+Alt+A   show what it detected (rescans from scratch)
;
;   It also watches in the background. If an AUDOS times out and you log back
;   in, it spots the new window on its own and pops a toast telling you which
;   brand it is. Toasts stay put until you dismiss them - click the X in the
;   corner, or click anywhere on the toast. Both work.
;
;   Right-click the tray icon for the same options plus Exit.
;
;   Uses nothing but AutoHotkey v1 and plain Windows API calls through DllCall.
;   No UIA, no COM, no external libraries, no downloads, nothing to install.
;   The Windows functions it calls are all standard user32 ones:
;   EnumChildWindows, SendMessageTimeoutW, SystemParametersInfo,
;   GetClassNameW, GetWindowRect, IsWindowVisible, IsWindowEnabled,
;   GetParent, GetWindowThreadProcessId and GetGUIThreadInfo.
;
;=============================================================================
;
;   THE PROBLEM
;
;   Both AUDOS windows are the same program: MiPlatform320U.exe. Same window
;   title, same window class, same command line. Windows cannot tell them
;   apart and neither can you from the outside.
;
;   Things that DO NOT work (all tested, all dead ends):
;
;     UIA                  does not attach to this app at all
;     The header banner    "3029KAINE" / "Kaine Turner" is PAINTED by the app.
;                          It is not a control, so there is nothing to read.
;                          WM_GETTEXT returns nothing. MSAA returns nothing.
;     The left menu tree   owner-drawn. Item text comes back empty, and a
;                          plain SendMessage to it hangs forever.
;     The menu bar         there isn't one
;     Command line / PID   changes every launch, says nothing about brand
;     Local app files      shared between both, no dealer info
;
;=============================================================================
;
;   HOW IT WORKS  -  read the dealer code out of the controls   (~50-90 ms)
;
;   Every AUDOS screen you open is a little dialog full of ordinary Windows
;   edit boxes (class "EditTobe"). The dealer code sits in one of those boxes
;   as plain readable text.
;
;       Hyundai   a box containing exactly  H3029
;       Kia       a box containing exactly  83340
;
;   The good part: when you switch tabs, AUDOS does not destroy the old
;   screen, it just hides it. So those boxes are STILL THERE and still
;   readable even while you are looking at Notice Board, and even while the
;   window is minimised - a control exists whether or not it is drawn.
;
;   The catch: a brand new AUDOS that has only ever shown Notice Board has
;   not created any of those boxes yet. Notice Board on its own is identical
;   between the two brands - same 16 strings either side - so detection can
;   come back "Unknown" until you open any screen that shows the dealer code.
;
;   Two things soften that:
;     * "Unknown" is never remembered, so the next attempt starts clean.
;     * The self-heal retry below has a second go before giving up, and the
;       background watcher keeps rechecking an Unknown window every 10 s.
;
;=============================================================================
;
;   ONE THING TO KNOW ABOUT PIDs
;
;   Windows gives a program a brand new PID and brand new window handles every
;   single time it launches, and it recycles old numbers later. So a PID is
;   only meaningful while that exact process is alive.
;
;   Because of that, this script NEVER writes anything to disk. It works the
;   answer out fresh each time it starts, keeps it in memory, and throws that
;   memory away if a handle ever points at a different process.
;
;=============================================================================


#NoEnv                      ; don't read old-style environment variables
#SingleInstance, Force      ; relaunching replaces the running copy
#Persistent                 ; stay running so the hotkeys keep working
SetBatchLines, -1           ; run at full speed, never sleep between lines
SetTitleMatchMode, 2        ; "AUDOS" matches anywhere in a window title


;=============================================================================
;   SETTINGS
;
;   Everything you might want to change lives in this one function.
;
;   It is a function rather than plain lines at the top so this file also
;   works if you #Include it at the BOTTOM of your own script. Every public
;   function calls AUDOS_Init() first, and the "static done" flag makes sure
;   the settings are only applied once no matter how often it is called.
;=============================================================================
AUDOS_Init() {
    global                          ; every variable set below is global
    static done := false
    if (done)
        return
    done := true

    ;--- which windows count as AUDOS ---------------------------------------
    AUDOS_EXE        := "MiPlatform320U.exe"   ; the program AUDOS runs as
    AUDOS_TITLE_HINT := "AUDOS"                ; must appear in the title

    ;--- the two dealer codes -----------------------------------------------
    ; Your dealer codes never change, so we match them exactly.
    ;
    ; These are regular expressions:
    ;   i)    ignore upper/lower case
    ;   ^     start of the text
    ;   \s*   any spaces
    ;   $     end of the text
    ;
    ; The ^ and $ mean the box must contain ONLY the code. A box holding
    ; "H30295" or "833401" will not match, which is the point.
    ;
    ; Verified against both live windows: the Kia one had "83340" 8 times and
    ; "H3029" zero times; the Hyundai one had "H3029" 4 times and "83340"
    ; zero times. No crossover in either direction.
    AUDOS_HYUNDAI_RE := "i)^\s*H3029\s*$"    ; Hyundai dealer code
    AUDOS_KIA_RE     := "i)^\s*83340\s*$"    ; Kia dealer code

    ;--- self-heal retry ----------------------------------------------------
    ; If the first scan finds nothing, wait a moment and scan once more.
    ; This covers a window that is still building its screens - AUDOS creates
    ; those dialogs a fraction of a second after the window itself appears, so
    ; a scan fired the instant it opens can genuinely be too early.
    ;
    ; Costs nothing when detection works first time. Set to 0 to turn off.
    AUDOS_RETRY_MS := 400

    ;--- background watcher -------------------------------------------------
    AUDOS_WATCH_ENABLED := true
    AUDOS_WATCH_MS      := 2000   ; how often to look for new/closed windows
                                  ; this poll is cheap - just a window list.
                                  ; controls are only scanned when something
                                  ; has actually changed.

    ; How many polls to wait before re-checking a window that came back
    ; Unknown. 5 x 2000 ms = every 10 seconds. This is what catches the
    ; moment you open a tab on a fresh Notice-Board-only AUDOS.
    AUDOS_RECHECK_POLLS := 5

    ;--- the part number lookup ---------------------------------------------
    ; The screen code typed into the box on the bottom bar, and the name of
    ; the screen it opens. Change both together if you point this at a
    ; different screen.
    AUDOS_PART_SCREEN  := "DS007"
    AUDOS_PART_TITLE   := "Part Master"

    ; How long to wait for that screen to open before giving up.
    AUDOS_PART_WAIT_MS := 10000

    ; The name the bottom bar reports itself as. This is how we find the
    ; screen box without relying on a control number - see the notes down in
    ; the PART NUMBER LOOKUP section.
    AUDOS_BOTTOM_BAR   := "bottom_frame"

    ;--- toast pop-ups ------------------------------------------------------
    AUDOS_TOAST_ENABLED := true

    ; 0 = stay on screen until you dismiss it. Any other number is how many
    ; milliseconds to wait before it closes itself, e.g. 4000 for 4 seconds.
    AUDOS_TOAST_MS      := 0

    AUDOS_TOAST_W       := 260    ; toast size in pixels
    AUDOS_TOAST_H       := 48
    AUDOS_TOAST_GAP     := 8      ; space between stacked toasts
    AUDOS_TOAST_EDGE    := 14     ; space from the screen edge
    AUDOS_TOAST_MAX     := 6      ; most toasts on screen at once
    AUDOS_HOVER_MS      := 80     ; how often to check if you are hovering
                                  ; the X. Only runs while a toast is open.

    ;--- internal state, leave alone ----------------------------------------
    gAUDOS_Texts      := []    ; scratch list used while scanning controls
    gAUDOS_Kids       := []    ; scratch list used while mapping out controls
    gAUDOS_Cache      := {}    ; window handle -> {brand, pid}
    gAUDOS_Announced  := {}    ; brand -> the handle we last toasted about
    gAUDOS_LastSig    := ""    ; fingerprint of the last seen window list
    gAUDOS_IdleTicks  := 0     ; polls since we last rechecked an Unknown
    gAUDOS_SlotUsed   := []    ; which toast slots are occupied
    gAUDOS_SlotTimers := []    ; the auto-close timer for each slot
    gAUDOS_SlotSeq    := []    ; age of each toast, so we know the oldest
    gAUDOS_SlotXRect  := []    ; screen position of each toast's X button
    gAUDOS_SlotXHwnd  := []    ; handle of each toast's X control
    gAUDOS_SlotHot    := []    ; is the mouse currently over that X?
    gAUDOS_Seq        := 0     ; ever-increasing counter for SlotSeq
    gAUDOS_HoverOn    := false ; is the hover timer running?

    Loop, %AUDOS_TOAST_MAX%
    {
        gAUDOS_SlotUsed[A_Index]   := false
        gAUDOS_SlotTimers[A_Index] := ""
        gAUDOS_SlotSeq[A_Index]    := 0
        gAUDOS_SlotXRect[A_Index]  := ""
        gAUDOS_SlotXHwnd[A_Index]  := 0
        gAUDOS_SlotHot[A_Index]    := false
    }
}


;=============================================================================
;   STARTUP  -  runs once when the script loads
;=============================================================================
AUDOS_Init()

Menu, Tray, Tip, % "AUDOS Switch"
                 . "`nCtrl+Left click = part lookup in Kia"
                 . "`nCtrl+Right click = part lookup in Hyundai"
                 . "`nInsert = Kia`nHome = Hyundai"
Menu, Tray, NoStandard
Menu, Tray, Add, Show detected, TrayShow
Menu, Tray, Add, Rescan now, TrayRescan
Menu, Tray, Add, Dismiss all toasts, TrayDismissAll
Menu, Tray, Add
Menu, Tray, Add, Exit, TrayExit
Menu, Tray, Default, Show detected

; Start the watcher. The first run happens straight away rather than after a
; 2 second wait, so you get your toasts the moment the script loads.
if (AUDOS_WATCH_ENABLED) {
    SetTimer, AUDOS_WatchTick, % AUDOS_WATCH_MS
    SetTimer, AUDOS_WatchFirst, -300
}
return                              ; end of the startup section


;=============================================================================
;   HOTKEYS
;=============================================================================
; Copy a part number, then Ctrl+click to look it up.
;
; Heads up: these take Ctrl+click over for the whole machine, so Ctrl+click
; will not do its normal job in other programs while this script is running.
; That is deliberate - the whole point is that you can copy a part number in
; any program and go straight to AUDOS from there.
^LButton::AUDOS_PartLookup("Kia")
^RButton::AUDOS_PartLookup("Hyundai")

; Just bring a window up, no lookup.
Insert::AUDOS_Activate("Kia")
Home::AUDOS_Activate("Hyundai")
^!a::AUDOS_Report()                 ; ^ = Ctrl, ! = Alt

TrayShow:
    AUDOS_Report()
return

TrayRescan:
    AUDOS_ClearCache()
    AUDOS_Report()
return

TrayDismissAll:
    AUDOS_ToastCloseAll()
return

TrayExit:
    ExitApp
return


;=============================================================================
;   PUBLIC FUNCTIONS  -  the ones you'd call from your own code
;=============================================================================

;-----------------------------------------------------------------------------
;   AUDOS_Activate("Kia")
;
;   Brings that brand's window to the front. Returns its handle, or 0.
;-----------------------------------------------------------------------------
AUDOS_Activate(brand) {
    hwnd := AUDOS_Hwnd(brand)

    ; Nothing found. Most likely the remembered answer is stale because AUDOS
    ; was closed and reopened. Wipe the memory and look again from scratch.
    if (!hwnd) {
        AUDOS_ClearCache()
        hwnd := AUDOS_Hwnd(brand)
    }

    if (!hwnd) {
        MsgBox, 48, AUDOS Switch
            , % brand " window not found.`n`nPress Ctrl+Alt+A to see what was detected."
        return 0
    }

    WinGet, state, MinMax, ahk_id %hwnd%
    if (state = -1)                      ; -1 means minimised
        WinRestore, ahk_id %hwnd%
    WinActivate, ahk_id %hwnd%
    WinWaitActive, ahk_id %hwnd%, , 1    ; wait up to 1 second
    return hwnd
}

;-----------------------------------------------------------------------------
;   AUDOS_Hwnd("Hyundai")   ->  window handle, or 0 if not found
;-----------------------------------------------------------------------------
AUDOS_Hwnd(brand, forceRescan := false) {
    for index, win in AUDOS_Detect(forceRescan)
        if (win.brand = brand)
            return win.hwnd
    return 0
}

;-----------------------------------------------------------------------------
;   AUDOS_Detect()
;
;   Returns a list, one entry per AUDOS window:
;
;       win.hwnd    window handle
;       win.pid     process id
;       win.title   window title
;       win.brand   "Hyundai", "Kia" or "Unknown"
;
;   allowRetry controls the self-heal second attempt. The watcher passes false
;   so its background polling never stalls the script; everything you trigger
;   yourself passes true, because there a 400 ms pause is worth a right answer.
;-----------------------------------------------------------------------------
AUDOS_Detect(forceRescan := false, allowRetry := true) {
    result := []
    for index, win in AUDOS_Windows() {
        win.brand := AUDOS_BrandOf(win.hwnd, forceRescan, allowRetry)
        result.Push(win)
    }
    return result
}

;-----------------------------------------------------------------------------
;   Forget everything we worked out. The next call re-detects from scratch.
;-----------------------------------------------------------------------------
AUDOS_ClearCache() {
    global gAUDOS_Cache, gAUDOS_Announced, gAUDOS_LastSig
    AUDOS_Init()
    gAUDOS_Cache     := {}
    gAUDOS_Announced := {}
    gAUDOS_LastSig   := ""      ; makes the next watcher poll re-announce
}


;=============================================================================
;   STEP 1  -  FIND THE AUDOS WINDOWS
;=============================================================================
AUDOS_Windows() {
    global AUDOS_EXE, AUDOS_TITLE_HINT
    AUDOS_Init()

    result := []

    ; Only look at windows that are actually on screen. Without this we'd also
    ; pick up MiPlatform's hidden helper windows.
    previous := A_DetectHiddenWindows
    DetectHiddenWindows, Off

    ; Ask Windows for every window owned by MiPlatform320U.exe.
    ; This puts the count in "ids" and the handles in ids1, ids2, ...
    WinGet, ids, List, % "ahk_exe " AUDOS_EXE

    Loop, %ids%
    {
        hwnd := ids%A_Index%
        WinGetTitle, title, ahk_id %hwnd%

        if !InStr(title, AUDOS_TITLE_HINT)     ; skip anything not AUDOS
            continue

        WinGet, pid, PID, ahk_id %hwnd%
        result.Push({hwnd: hwnd, pid: pid, title: title})
    }

    DetectHiddenWindows, %previous%
    return result
}


;=============================================================================
;   STEP 2  -  WORK OUT WHICH BRAND ONE WINDOW IS, THEN REMEMBER IT
;=============================================================================
AUDOS_BrandOf(hwnd, forceRescan := false, allowRetry := true) {
    global gAUDOS_Cache, AUDOS_RETRY_MS
    AUDOS_Init()

    WinGet, pid, PID, ahk_id %hwnd%

    ; Already know this one? Use the remembered answer.
    ;
    ; The pid check matters. Windows reuses window handles, so if AUDOS was
    ; closed and reopened this handle could now belong to a different process
    ; and the old answer would be wrong. Comparing the pid catches that and
    ; forces a fresh look.
    if (!forceRescan && gAUDOS_Cache.HasKey(hwnd)) {
        cached := gAUDOS_Cache[hwnd]
        if (cached.pid = pid)
            return cached.brand
    }

    brand := AUDOS_BrandFromFields(hwnd)

    ; SELF-HEAL: nothing found, so give it one more go after a short pause.
    ; A window that has only just opened is often still building its dialogs.
    if (brand = "Unknown" && allowRetry && AUDOS_RETRY_MS > 0) {
        Sleep, %AUDOS_RETRY_MS%
        brand := AUDOS_BrandFromFields(hwnd)
    }

    ; Deliberately do NOT remember "Unknown". That way, once you open a screen
    ; that shows the dealer code, the next press succeeds instead of being
    ; stuck on a bad answer.
    if (brand != "Unknown")
        gAUDOS_Cache[hwnd] := {brand: brand, pid: pid}

    return brand
}


;=============================================================================
;   STEP 3  -  READ THE DEALER CODE OUT OF THE CONTROLS
;=============================================================================
AUDOS_BrandFromFields(hwnd) {
    global AUDOS_HYUNDAI_RE, AUDOS_KIA_RE
    AUDOS_Init()

    hyundai := 0
    kia     := 0

    ; Look through every control's text for the two dealer codes.
    for index, text in AUDOS_ChildTexts(hwnd) {
        if RegExMatch(text, AUDOS_HYUNDAI_RE)
            hyundai++
        else if RegExMatch(text, AUDOS_KIA_RE)
            kia++
    }

    ; Hyundai wins if both somehow turn up in the same window.
    ;
    ; Why: "83340" is a bare number, so on some screen we have not looked at
    ; yet it could collide with an amount, a quantity or a part number.
    ; "H3029" starts with a letter and cannot collide the same way, so it is
    ; the more trustworthy of the two signals.
    if (hyundai)
        return "Hyundai"
    if (kia)
        return "Kia"

    return "Unknown"        ; no dealer code on screen yet - see header notes
}

;-----------------------------------------------------------------------------
;   Collect the text of every control inside a window.
;
;   A window's controls are nested - dialogs inside dialogs inside dialogs.
;   EnumChildWindows walks the whole tree for us, all the way down, and calls
;   our function once per control. Around 500 of them in an AUDOS window.
;
;   RegisterCallback turns an AHK function into something Windows can call.
;   It's built once and kept in a "static" so we don't rebuild it every scan.
;-----------------------------------------------------------------------------
AUDOS_ChildTexts(hwnd) {
    global gAUDOS_Texts
    AUDOS_Init()
    static callback := RegisterCallback("AUDOS_EnumChildProc", "Fast", 2)

    gAUDOS_Texts := []
    DllCall("EnumChildWindows", "Ptr", hwnd, "Ptr", callback, "Ptr", 0)
    return gAUDOS_Texts
}

;-----------------------------------------------------------------------------
;   Called by Windows once for each control. Grabs its text.
;-----------------------------------------------------------------------------
AUDOS_EnumChildProc(hChild, lParam) {
    global gAUDOS_Texts

    VarSetCapacity(buf, 512 * 2, 0)      ; room for 512 characters (2 bytes each)
    junk := 0

    ; WM_GETTEXT (0x000D) asks a control for its text.
    ;
    ; We use SendMessageTimeoutW instead of plain SendMessage on purpose.
    ; Plain SendMessage waits forever if the target is busy, and MiPlatform's
    ; owner-drawn tree control never answers - which hangs the whole script.
    ; The timeout version gives up after 200 ms and moves on.
    ;
    ; SMTO_ABORTIFHUNG (0x0002) also bails out instantly if Windows already
    ; knows the app is not responding.
    ok := DllCall("SendMessageTimeoutW"
        , "Ptr",  hChild
        , "UInt", 0x000D          ; WM_GETTEXT
        , "Ptr",  512             ; how many characters we can accept
        , "Str",  buf             ; where to put the text
        , "UInt", 0x0002          ; SMTO_ABORTIFHUNG
        , "UInt", 200             ; give up after 200 ms
        , "PtrP", junk)

    VarSetCapacity(buf, -1)              ; tell AHK the buffer now holds text

    if (ok && buf != "")
        gAUDOS_Texts.Push(buf)

    return true                          ; true = keep going to the next control
}


;=============================================================================
;   THE PART NUMBER LOOKUP
;
;       Ctrl + Left click    look the copied part number up in KIA
;       Ctrl + Right click   look it up in HYUNDAI
;
;   Copy a part number anywhere - an email, a spreadsheet, a web page - then
;   hold Ctrl and click. The script does the rest:
;
;       1. brings that brand's AUDOS to the front
;       2. types DS007 into the screen box on the bottom bar, presses Enter
;       3. waits for Part Master to open
;       4. puts the clipboard into the part field and presses Enter
;
;-----------------------------------------------------------------------------
;   HOW IT FINDS THE TWO BOXES
;
;   The old way was to name them: EditTobe44, and so on. That breaks, and you
;   already know it breaks. The 44 is not part of the box's identity - it just
;   means "the 44th EditTobe Windows happened to hand out in this window", so
;   it comes out different every time AUDOS is opened.
;
;   So we never use those names. We ask two questions that stay true no matter
;   what number anything got given:
;
;     THE SCREEN BOX
;       The bottom bar is a container, and that container tells you its name
;       when you ask it: "bottom_frame". The screen box is the EditTobe living
;       inside it. There is only one, so there is nothing to guess.
;
;     THE PART FIELD
;       The Part Master screen is a dialog, and it tells you its name too:
;       "Part Master". Every box on that screen is read-only except the one
;       you type in - so the part field is the only EditTobe underneath it
;       that is both visible AND enabled. Again, only one.
;
;   Both are found by what they ARE, not by what they were numbered. Names and
;   the enabled flag survive a restart; control numbers do not.
;
;   "Underneath it" is a real parent-child check, walked with GetParent, not a
;   guess from screen position. It has to be: AUDOS stacks every screen you
;   have opened in exactly the same spot, so Order Entry and Part Master have
;   identical rectangles and position alone cannot tell them apart.
;=============================================================================
AUDOS_PartLookup(brand) {
    global AUDOS_PART_SCREEN, AUDOS_PART_TITLE, AUDOS_PART_WAIT_MS
    AUDOS_Init()

    ; The part number comes from the clipboard. An empty clipboard is fine -
    ; we still open Part Master, we just leave the part field alone.
    part := Trim(Clipboard, " `t`r`n")

    ; AUDOS_Activate already clears the cache and re-detects if its remembered
    ; answer has gone stale, and it shows the "not found" box for us.
    hwnd := AUDOS_Activate(brand)
    if (!hwnd)
        return

    ; Control commands address a control by its own handle, and AHK will only
    ; look at handles it can "see", so hidden windows have to be detectable
    ; while we do this. Put the setting back afterwards.
    previous := A_DetectHiddenWindows
    DetectHiddenWindows, On

    ;--- 1. the screen box on the bottom bar --------------------------------
    box := AUDOS_BottomBox(hwnd)
    if (!box) {
        DetectHiddenWindows, %previous%
        MsgBox, 48, AUDOS Switch
            , % "Could not find the screen box on the bottom bar of the "
              . brand " window."
        return
    }

    ControlFocus, , ahk_id %box%
    Sleep, 60

    ; Prefer real keystrokes - they go through AUDOS exactly the way your own
    ; typing does, so anything the app hangs off a keypress still happens.
    ; If the box did not actually take the keyboard, fall back to setting the
    ; text on it directly rather than typing into thin air.
    if (AUDOS_FocusedHwnd(hwnd) = box) {
        SendInput, {End}{BS 20}%AUDOS_PART_SCREEN%
        Sleep, 100
        SendInput, {Enter}
    } else {
        ControlSetText, , %AUDOS_PART_SCREEN%, ahk_id %box%
        ControlSend, , {Enter}, ahk_id %box%
    }

    ;--- 2. wait for Part Master to open -------------------------------------
    ; We watch THIS window's title rather than using WinWait, because the other
    ; brand could be sitting on Part Master already and WinWait would happily
    ; match that one instead.
    if (!AUDOS_WaitTitle(hwnd, AUDOS_PART_TITLE, AUDOS_PART_WAIT_MS)) {
        DetectHiddenWindows, %previous%
        MsgBox, 48, AUDOS Switch
            , % "The " AUDOS_PART_TITLE " screen did not open within "
              . Round(AUDOS_PART_WAIT_MS / 1000) " seconds."
        return
    }

    ;--- 3. the part field ---------------------------------------------------
    ; The title changes a moment before the screen is finished being built, so
    ; give it a few goes instead of one. Two seconds all up.
    fld := 0
    Loop, 20
    {
        fld := AUDOS_PartField(hwnd)
        if (fld)
            break
        Sleep, 100
    }

    if (!fld) {
        DetectHiddenWindows, %previous%
        MsgBox, 48, AUDOS Switch
            , % "Found the " AUDOS_PART_TITLE " screen but not the part field."
        return
    }

    ; Nothing on the clipboard: put the cursor in the box and stop there, so
    ; you can type the part number yourself. Searching on blank would only
    ; make AUDOS complain.
    if (part = "") {
        ControlFocus, , ahk_id %fld%
    } else {
        ControlSetText, , %part%, ahk_id %fld%
        ControlSend, , {Enter}, ahk_id %fld%
    }

    DetectHiddenWindows, %previous%

    ; Park the window where you want it. Delete the semicolon to switch on.
    ; WinMove, ahk_id %hwnd%, , -1256, 0
}

;-----------------------------------------------------------------------------
;   Find the screen box on the bottom bar. Returns its handle, or 0.
;-----------------------------------------------------------------------------
AUDOS_BottomBox(hwnd) {
    global AUDOS_BOTTOM_BAR
    AUDOS_Init()

    kids := AUDOS_Kids(hwnd)

    ; The container that names itself.
    frame := 0
    for index, kid in kids {
        if (kid.text = AUDOS_BOTTOM_BAR) {
            frame := kid
            break
        }
    }

    if (IsObject(frame)) {
        best := 0
        for index, kid in kids {
            if (kid.cls != "EditTobe" || !kid.vis)
                continue
            if (!AUDOS_IsUnder(kid.hwnd, frame.hwnd))
                continue
            if (!IsObject(best) || (kid.r - kid.l) > (best.r - best.l))
                best := kid
        }
        if (IsObject(best))
            return best.hwnd
    }

    ; Fallback, in case a future AUDOS renames that container: the widest
    ; visible EditTobe sitting in the bottom 40 pixels of the window.
    WinGetPos, wx, wy, ww, wh, ahk_id %hwnd%
    floorY := wy + wh - 40

    best := 0
    for index, kid in kids {
        if (kid.cls != "EditTobe" || !kid.vis)
            continue
        if (kid.b < floorY)
            continue
        if (!IsObject(best) || (kid.r - kid.l) > (best.r - best.l))
            best := kid
    }
    return IsObject(best) ? best.hwnd : 0
}

;-----------------------------------------------------------------------------
;   Find the part number field on Part Master. Returns its handle, or 0.
;-----------------------------------------------------------------------------
AUDOS_PartField(hwnd) {
    global AUDOS_PART_TITLE
    AUDOS_Init()

    kids := AUDOS_Kids(hwnd)

    ; The dialog that names itself.
    dlg := 0
    for index, kid in kids {
        if (kid.cls = "#32770" && kid.text = AUDOS_PART_TITLE) {
            dlg := kid
            break
        }
    }
    if (!IsObject(dlg))
        return 0                    ; screen has never been opened yet

    ; The only box on it you can type in.
    best := 0
    for index, kid in kids {
        if (kid.cls != "EditTobe" || !kid.vis || !kid.en)
            continue
        if (!AUDOS_IsUnder(kid.hwnd, dlg.hwnd))
            continue

        ; Highest on screen wins, then leftmost. Today there is exactly one
        ; match, so this never gets used - it is here so that if AUDOS ever
        ; adds a second typeable box we pick the top-left one rather than
        ; whichever Windows happened to list first.
        if (!IsObject(best) || kid.t < best.t
        || (kid.t = best.t && kid.l < best.l))
            best := kid
    }
    return IsObject(best) ? best.hwnd : 0
}

;-----------------------------------------------------------------------------
;   Is one control genuinely inside another? Walks up the parent chain.
;
;   This is the real question, not "do their rectangles overlap". AUDOS piles
;   every screen you have opened into the same rectangle, so overlap proves
;   nothing.
;-----------------------------------------------------------------------------
AUDOS_IsUnder(child, ancestor) {
    p := child
    Loop, 20                        ; the tree is about 5 deep, 20 is plenty
    {
        p := DllCall("GetParent", "Ptr", p, "Ptr")
        if (!p)
            return false            ; reached the top without finding it
        if (p = ancestor)
            return true
    }
    return false
}

;-----------------------------------------------------------------------------
;   Which control currently has the keyboard in this window? 0 if none.
;
;   GetGUIThreadInfo fills a GUITHREADINFO struct. We only want one field out
;   of it, hwndFocus, which is the second handle in the struct:
;
;       0                cbSize          4 bytes
;       4                flags           4 bytes
;       8                hwndActive
;       8 + A_PtrSize    hwndFocus       <- the one we want
;       ...              four more handles, then a RECT
;-----------------------------------------------------------------------------
AUDOS_FocusedHwnd(winHwnd) {
    tid := DllCall("GetWindowThreadProcessId", "Ptr", winHwnd, "Ptr", 0, "UInt")
    if (!tid)
        return 0

    size := 8 + (A_PtrSize * 6) + 16
    VarSetCapacity(gti, size, 0)
    NumPut(size, gti, 0, "UInt")            ; it wants to be told its own size

    if !DllCall("GetGUIThreadInfo", "UInt", tid, "Ptr", &gti)
        return 0

    return NumGet(gti, 8 + A_PtrSize, "Ptr")
}

;-----------------------------------------------------------------------------
;   Wait for a word to appear in one particular window's title.
;-----------------------------------------------------------------------------
AUDOS_WaitTitle(hwnd, needle, timeoutMs) {
    endTime := A_TickCount + timeoutMs
    Loop
    {
        WinGetTitle, title, ahk_id %hwnd%
        if InStr(title, needle)
            return true
        if (A_TickCount >= endTime)
            return false
        Sleep, 100
    }
}

;-----------------------------------------------------------------------------
;   Map out every control in a window.
;
;   Same EnumChildWindows walk the brand detection uses, but this one keeps
;   the whole picture of each control rather than just its text:
;
;       kid.hwnd            its handle
;       kid.cls             its class name, e.g. "EditTobe"
;       kid.text            what it calls itself
;       kid.l .t .r .b      where it is on screen
;       kid.vis             is it shown?
;       kid.en              can you interact with it?
;
;   Takes about the same time as the brand scan, roughly 90 ms.
;-----------------------------------------------------------------------------
AUDOS_Kids(hwnd) {
    global gAUDOS_Kids
    AUDOS_Init()
    static callback := RegisterCallback("AUDOS_KidProc", "Fast", 2)

    gAUDOS_Kids := []
    DllCall("EnumChildWindows", "Ptr", hwnd, "Ptr", callback, "Ptr", 0)
    return gAUDOS_Kids
}

AUDOS_KidProc(hChild, lParam) {
    global gAUDOS_Kids

    VarSetCapacity(cls, 256 * 2, 0)
    DllCall("GetClassNameW", "Ptr", hChild, "Str", cls, "Int", 256)
    VarSetCapacity(cls, -1)

    VarSetCapacity(rect, 16, 0)                  ; RECT: left, top, right, bottom
    DllCall("GetWindowRect", "Ptr", hChild, "Ptr", &rect)

    ; Same timeout rule as the brand scan - the tree control never answers a
    ; plain SendMessage and would hang the whole script.
    VarSetCapacity(buf, 512 * 2, 0)
    junk := 0
    DllCall("SendMessageTimeoutW"
        , "Ptr",  hChild
        , "UInt", 0x000D          ; WM_GETTEXT
        , "Ptr",  512
        , "Str",  buf
        , "UInt", 0x0002          ; SMTO_ABORTIFHUNG
        , "UInt", 200
        , "PtrP", junk)
    VarSetCapacity(buf, -1)

    gAUDOS_Kids.Push({ hwnd: hChild
                     , cls:  cls
                     , text: buf
                     , l:    NumGet(rect,  0, "Int")
                     , t:    NumGet(rect,  4, "Int")
                     , r:    NumGet(rect,  8, "Int")
                     , b:    NumGet(rect, 12, "Int")
                     , vis:  DllCall("IsWindowVisible", "Ptr", hChild)
                     , en:   DllCall("IsWindowEnabled", "Ptr", hChild) })

    return true
}


;=============================================================================
;   THE BACKGROUND WATCHER
;
;   Runs every 2 seconds. Almost always does nothing.
;
;   It builds a fingerprint of the current AUDOS windows - their handles and
;   process ids joined into one string. If that fingerprint is the same as
;   last time, nothing has opened or closed, so it stops right there. That
;   costs well under a millisecond.
;
;   It only scans controls when:
;       * the fingerprint changed - a window opened, closed or was replaced
;       * or a window is still Unknown and 10 seconds have gone by
;
;   The second case is what notices the moment you open a tab on a fresh
;   AUDOS that had only ever shown Notice Board.
;=============================================================================
AUDOS_WatchFirst:
    AUDOS_Watch()
return

AUDOS_WatchTick:
    AUDOS_Watch()
return

AUDOS_Watch() {
    global gAUDOS_LastSig, gAUDOS_IdleTicks, gAUDOS_Cache, gAUDOS_Announced
    global AUDOS_RECHECK_POLLS
    AUDOS_Init()

    windows := AUDOS_Windows()

    ; Build the fingerprint.
    sig := ""
    for index, win in windows
        sig .= win.hwnd "-" win.pid "|"

    changed := (sig != gAUDOS_LastSig)

    ; Is anything still unidentified? If so we want to keep checking back.
    pending := false
    for index, win in windows
        if (!gAUDOS_Cache.HasKey(win.hwnd))
            pending := true

    if (!changed) {
        if (!pending) {
            gAUDOS_IdleTicks := 0
            return                          ; nothing to do at all
        }
        if (++gAUDOS_IdleTicks < AUDOS_RECHECK_POLLS)
            return                          ; not time for a recheck yet
    }

    gAUDOS_LastSig   := sig
    gAUDOS_IdleTicks := 0

    ; Drop remembered answers for windows that have gone away, so a reopened
    ; AUDOS is treated as genuinely new and gets announced again.
    AUDOS_ForgetClosed(windows)

    ; Identify each window. allowRetry is false here on purpose - the watcher
    ; must never pause the script in the background. It gets another look in
    ; 10 seconds anyway, and anything you trigger yourself does use the retry.
    for index, win in windows {
        brand := AUDOS_BrandOf(win.hwnd, false, false)
        if (brand = "Unknown")
            continue

        ; Only toast when this is news: either we have never announced this
        ; brand, or it now lives in a different window than the one we
        ; announced. That is exactly the timeout-and-log-back-in case.
        if (gAUDOS_Announced[brand] != win.hwnd) {
            gAUDOS_Announced[brand] := win.hwnd
            AUDOS_Toast(brand)
        }
    }
}

;-----------------------------------------------------------------------------
;   Throw away cache and announcement entries for windows that no longer exist.
;-----------------------------------------------------------------------------
AUDOS_ForgetClosed(windows) {
    global gAUDOS_Cache, gAUDOS_Announced

    alive := {}
    for index, win in windows
        alive[win.hwnd] := true

    for hwnd, entry in gAUDOS_Cache.Clone()
        if (!alive.HasKey(hwnd))
            gAUDOS_Cache.Delete(hwnd)

    for brand, hwnd in gAUDOS_Announced.Clone()
        if (!alive.HasKey(hwnd))
            gAUDOS_Announced.Delete(brand)
}


;=============================================================================
;   THE TOAST POP-UP
;
;   A small borderless always-on-top window in the bottom-right corner:
;
;       [ v ]  Kia AUDOS found                    X
;
;   Several can be on screen at once - they stack upwards. Each one owns a
;   "slot", which is both its position in the stack and its GUI number, so
;   two toasts can never collide.
;
;   To dismiss: click the X, or click anywhere on the toast. Both do the same
;   thing - the X is there so it is obvious the toast can be closed, and
;   click-anywhere means you never have to aim at it.
;
;   By default a toast stays put until you dismiss it. Set AUDOS_TOAST_MS in
;   the settings to a number of milliseconds if you want it to close itself.
;=============================================================================
AUDOS_Toast(brand) {
    global AUDOS_TOAST_ENABLED, AUDOS_TOAST_MS, AUDOS_TOAST_MAX
    global AUDOS_TOAST_W, AUDOS_TOAST_H, AUDOS_TOAST_GAP, AUDOS_TOAST_EDGE
    global gAUDOS_SlotUsed, gAUDOS_SlotTimers, gAUDOS_SlotSeq
    global gAUDOS_SlotXRect, gAUDOS_SlotHot, gAUDOS_Seq
    AUDOS_Init()

    if (!AUDOS_TOAST_ENABLED)
        return

    slot := AUDOS_ClaimSlot()
    if (!slot)
        return

    gAUDOS_SlotUsed[slot] := true
    gAUDOS_SlotSeq[slot]  := ++gAUDOS_Seq
    gAUDOS_SlotHot[slot]  := false

    ; GUI numbers 90 and up, one per slot, so they never clash with any GUI
    ; you might add to your own script.
    g := 89 + slot

    Gui, %g%:Destroy                          ; in case one was left behind
    Gui, %g%:New, +AlwaysOnTop -Caption +ToolWindow
    Gui, %g%:Margin, 0, 0
    Gui, %g%:Color, 202124                    ; dark card background

    ; The green tick. Chr(0x2713) is the check-mark character, so there is no
    ; image file to ship - it is just text in a symbol font.
    Gui, %g%:Font, s18 c2ECC71, Segoe UI Symbol
    Gui, %g%:Add, Text, x14 y11 w28 h28 Center gAUDOS_ToastClick, % Chr(0x2713)

    Gui, %g%:Font, s10 Bold cFFFFFF, Segoe UI
    Gui, %g%:Add, Text, x48 y15 w176 h20 gAUDOS_ToastClick, % brand " AUDOS found"

    ; The X in the top-right corner. Chr(0x2715) is the multiplication-X, which
    ; looks like a close button rather than the letter x.
    ;
    ; We grab the control's HWND with the "hwnd" option rather than naming it
    ; with a "v" variable. AHK v1 insists a control's v-variable is global or
    ; static, and we cannot declare one of those per slot from inside a
    ; function. A HWND has no such rule and works just as well with GuiControl.
    Gui, %g%:Font, s9 Norm c6E7175, Segoe UI
    Gui, %g%:Add, Text, % "x" (AUDOS_TOAST_W - 26) " y7 w18 h18 Center"
                       . " hwndhX gAUDOS_ToastClick", % Chr(0x2715)
    gAUDOS_SlotXHwnd[slot] := hX

    ; Work out where to put it: bottom-right of the usable desktop, stacking
    ; upwards. We ask Windows for the WORK AREA rather than the whole screen
    ; so the toast sits above the taskbar instead of behind it.
    ;
    ; SPI_GETWORKAREA is 0x0030. It fills a RECT: left, top, right, bottom.
    VarSetCapacity(area, 16, 0)
    if !DllCall("SystemParametersInfo", "UInt", 0x0030, "UInt", 0
              , "Ptr", &area, "UInt", 0) {
        NumPut(0,              area,  0, "Int")     ; fall back to the whole
        NumPut(0,              area,  4, "Int")     ; screen if that fails
        NumPut(A_ScreenWidth,  area,  8, "Int")
        NumPut(A_ScreenHeight, area, 12, "Int")
    }
    right  := NumGet(area,  8, "Int")
    bottom := NumGet(area, 12, "Int")

    px := right  - AUDOS_TOAST_W - AUDOS_TOAST_EDGE
    py := bottom - AUDOS_TOAST_EDGE
        - (slot * (AUDOS_TOAST_H + AUDOS_TOAST_GAP)) + AUDOS_TOAST_GAP

    ; NoActivate is important - the toast must not steal your keyboard focus.
    Gui, %g%:Show, % "x" px " y" py " w" AUDOS_TOAST_W " h" AUDOS_TOAST_H " NoActivate"

    ; Remember where the X ended up on screen. The toast never moves, so we
    ; can work out "is the mouse over the X" with plain arithmetic instead of
    ; asking Windows every time. A few pixels of padding makes it forgiving.
    gAUDOS_SlotXRect[slot] := { l: px + AUDOS_TOAST_W - 30
                              , t: py + 3
                              , r: px + AUDOS_TOAST_W - 4
                              , b: py + 29 }
    AUDOS_HoverStart()

    ; Optional auto-close. A negative period means "run once".
    ; The timer object is stored so we can cancel it if you click first.
    if (AUDOS_TOAST_MS > 0) {
        timer := Func("AUDOS_ToastClose").Bind(slot)
        gAUDOS_SlotTimers[slot] := timer
        SetTimer, % timer, % -AUDOS_TOAST_MS
    }
}

;-----------------------------------------------------------------------------
;   Pick a slot for a new toast.
;
;   Normally that is the first free one. If every slot is taken - which can
;   happen now that toasts wait for you - we recycle the oldest instead of
;   dropping the new one, because the newest is the one you have not seen.
;-----------------------------------------------------------------------------
AUDOS_ClaimSlot() {
    global AUDOS_TOAST_MAX, gAUDOS_SlotUsed, gAUDOS_SlotSeq

    Loop, %AUDOS_TOAST_MAX%
        if (!gAUDOS_SlotUsed[A_Index])
            return A_Index

    oldest    := 1
    oldestSeq := gAUDOS_SlotSeq[1]
    Loop, %AUDOS_TOAST_MAX%
    {
        if (gAUDOS_SlotSeq[A_Index] < oldestSeq) {
            oldestSeq := gAUDOS_SlotSeq[A_Index]
            oldest    := A_Index
        }
    }
    AUDOS_ToastClose(oldest)
    return oldest
}

;-----------------------------------------------------------------------------
;   Clicked a toast - either the X or anywhere else on it. A_Gui tells us
;   which toast, and the GUI number tells us the slot.
;-----------------------------------------------------------------------------
AUDOS_ToastClick:
    AUDOS_ToastClose(A_Gui - 89)
return

;-----------------------------------------------------------------------------
;   Close one toast and free its slot.
;-----------------------------------------------------------------------------
AUDOS_ToastClose(slot) {
    global AUDOS_TOAST_MAX, gAUDOS_SlotUsed, gAUDOS_SlotTimers
    global gAUDOS_SlotXRect, gAUDOS_SlotXHwnd, gAUDOS_SlotHot

    if (slot < 1 || slot > AUDOS_TOAST_MAX)
        return

    ; Cancel the auto-close timer. Harmless if it has already fired.
    if (gAUDOS_SlotTimers[slot] != "") {
        timer := gAUDOS_SlotTimers[slot]
        SetTimer, % timer, Off
        gAUDOS_SlotTimers[slot] := ""
    }

    g := 89 + slot
    Gui, %g%:Destroy

    gAUDOS_SlotUsed[slot]   := false
    gAUDOS_SlotXRect[slot]  := ""
    gAUDOS_SlotXHwnd[slot]  := 0
    gAUDOS_SlotHot[slot]    := false

    AUDOS_HoverStop()          ; turns the hover timer off if that was the last
}

;-----------------------------------------------------------------------------
;   Close every toast at once. On the tray menu.
;-----------------------------------------------------------------------------
AUDOS_ToastCloseAll() {
    global AUDOS_TOAST_MAX
    AUDOS_Init()
    Loop, %AUDOS_TOAST_MAX%
        AUDOS_ToastClose(A_Index)
}


;=============================================================================
;   THE X HOVER HIGHLIGHT
;
;   The X sits grey and goes white when your mouse is over it, so it reads as
;   a real button rather than decoration.
;
;   AHK v1 Text controls have no hover event, so instead of wiring up mouse
;   messages we just check where the pointer is every 80 ms. The timer only
;   runs while at least one toast is open, so it costs nothing the rest of
;   the time - and all it does is compare four numbers per toast.
;=============================================================================
AUDOS_HoverStart() {
    global gAUDOS_HoverOn, AUDOS_HOVER_MS
    if (gAUDOS_HoverOn)
        return
    gAUDOS_HoverOn := true
    SetTimer, AUDOS_HoverTick, % AUDOS_HOVER_MS
}

AUDOS_HoverStop() {
    global gAUDOS_HoverOn, AUDOS_TOAST_MAX, gAUDOS_SlotUsed

    if (!gAUDOS_HoverOn)
        return
    Loop, %AUDOS_TOAST_MAX%
        if (gAUDOS_SlotUsed[A_Index])
            return              ; something is still on screen, keep going

    gAUDOS_HoverOn := false
    SetTimer, AUDOS_HoverTick, Off
}

AUDOS_HoverTick:
    AUDOS_Hover()
return

AUDOS_Hover() {
    global AUDOS_TOAST_MAX, gAUDOS_SlotUsed, gAUDOS_SlotXRect
    global gAUDOS_SlotXHwnd, gAUDOS_SlotHot

    CoordMode, Mouse, Screen
    MouseGetPos, mx, my

    Loop, %AUDOS_TOAST_MAX%
    {
        slot := A_Index
        if (!gAUDOS_SlotUsed[slot])
            continue

        box := gAUDOS_SlotXRect[slot]
        if (!IsObject(box))
            continue

        over := (mx >= box.l && mx <= box.r && my >= box.t && my <= box.b)
        if (over = gAUDOS_SlotHot[slot])
            continue                    ; nothing changed, leave it alone

        gAUDOS_SlotHot[slot] := over

        hCtrl  := gAUDOS_SlotXHwnd[slot]
        colour := over ? "cFFFFFF" : "c6E7175"
        if (!hCtrl)
            continue

        ; MoveDraw forces the control to repaint. Without it the colour change
        ; does not always show until something else makes the window redraw.
        GuiControl, +%colour%, %hCtrl%
        GuiControl, MoveDraw, %hCtrl%
    }
}


;=============================================================================
;   THE Ctrl+Alt+A REPORT BOX
;=============================================================================
AUDOS_Report() {
    global AUDOS_EXE, AUDOS_TITLE_HINT
    AUDOS_Init()

    start   := A_TickCount
    windows := AUDOS_Detect(true)          ; true = ignore the cache, redo it
    elapsed := A_TickCount - start

    body := ""
    for index, win in windows {
        body .= win.brand "`n"
              . "    hwnd  : " Format("0x{:X}", win.hwnd) "`n"
              . "    pid   : " win.pid "`n"
              . "    title : " win.title "`n"

        if (win.brand = "Unknown")
            body .= "    note  : no dealer code on screen yet - open any tab`n"

        body .= "`n"
    }

    if (body = "")
        body := "No AUDOS windows found.`n(looking for " AUDOS_EXE
              . " with """ AUDOS_TITLE_HINT """ in the title)`n`n"

    body .= "scan time: " elapsed " ms`n`n"
    body .= "Ctrl+Left click   part lookup in Kia`n"
    body .= "Ctrl+Right click  part lookup in Hyundai`n"
    body .= "Insert            activate Kia`n"
    body .= "Home              activate Hyundai"
    MsgBox, 64, AUDOS Switch, %body%
}
