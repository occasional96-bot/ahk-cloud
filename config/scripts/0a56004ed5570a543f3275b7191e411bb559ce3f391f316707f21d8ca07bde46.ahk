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
#NoEnv
#SingleInstance Force
SetBatchLines, -1
SetWorkingDir %A_ScriptDir%

;------------------------- CONFIG (edit here) --------------------------------
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
global gMainHwnd := 0      ; main window handle (tray show/activate)

FileCreateDir, %CFG_CACHE%

global gSelfTest := ""
; self-test GUI mode:  AutoHotkeyU64.exe IsuzuVIN.ahk --selftest <VIN>
if (A_Args.Length() >= 1 && A_Args[1] = "--selftest") {
    gSelfTest := (A_Args.Length() >= 2 ? A_Args[2] : "MPATFR85JKT003256")
    BuildGui()
    return
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

;=============================== GUI =========================================
BuildGui() {
    global
    Menu, SessMenu, Add, Exit (leave Chrome running), MenuExitKeep
    Menu, SessMenu, Add, Exit and stop Chrome, MenuExitKill
    Menu, SessMenu, Add, Force fresh sign-in now, MenuRelogin
    Menu, MainMenuBar, Add, &Session, :SessMenu
    Gui, Main:New, +Resize, Isuzu VIN Lookup
    Gui, Main:Menu, MainMenuBar
    Gui, Main:Font, s10, Segoe UI
    Gui, Main:Add, Text, x12 y12, VIN / Rego / Serial / Engine:
    Gui, Main:Add, Edit, x12 y32 w300 vVinInput
    Gui, Main:Add, DropDownList, x318 y32 w90 vKindInput Choose1, VIN|Rego|Serial|Engine
    Gui, Main:Add, Button, x414 y31 w90 h26 gDoLookup Default, &Lookup
    Gui, Main:Font, s9, Segoe UI
    Gui, Main:Add, Text, x12 y66 w492 vStatus, Connecting to background Chrome...
    Gui, Main:Font, s10, Consolas
    Gui, Main:Add, ListView, x12 y88 w492 h420 Grid vLV, Field|Value
    LV_ModifyCol(1, 150)
    LV_ModifyCol(2, 330)
    Gui, Main:Font, s8, Segoe UI
    Gui, Main:Add, Text, x12 y514 w492 vSess cGray, Session: starting...
    ; live in the tray: the window is created but starts hidden, so launching
    ; the script just parks a signed-in session in the notification area
    Gui, Main:Show, Hide w516 h544
    Gui, Main:+HwndgMainHwnd
    BuildTray()
    ; kick off session setup shortly after the window is created
    SetTimer, InitSession, -300
}

BuildTray() {
    global
    Menu, Tray, NoStandard
    Menu, Tray, Add, &Open Isuzu VIN Lookup, TrayShow
    Menu, Tray, Add
    Menu, Tray, Add, Force fresh sign-in now, MenuRelogin
    Menu, Tray, Add
    Menu, Tray, Add, Exit (leave Chrome running), MenuExitKeep
    Menu, Tray, Add, Exit and stop Chrome, MenuExitKill
    Menu, Tray, Default, &Open Isuzu VIN Lookup
    Menu, Tray, Click, 1        ; single click opens the window
    Menu, Tray, Tip, Isuzu VIN Lookup - starting...
}

TrayShow:
    Gui, Main:Show
    if (gMainHwnd)
        WinActivate, ahk_id %gMainHwnd%
    GuiControl, Main:Focus, VinInput
return

; the minimize button parks the window back in the tray, not the taskbar
MainGuiSize:
    if (A_EventInfo = 1)
        Gui, Main:Hide
return

InitSession:
    gBusy := true
    ; gBusy MUST clear even if setup throws, or every later lookup is stuck
    ; on "Busy - wait a moment" until the app is restarted
    try {
        tInit := A_TickCount
        SetStatus("Connecting to background Chrome...")
        if !EnsureChrome() {
            SetStatus("ERROR: could not start Chrome on port " CFG_PORT)
            return
        }
        if !OpenPage() {
            SetStatus("ERROR: could not open IDS page target")
            return
        }
        if (gAttached && IsLoggedIn() && SessionAlive()) {
            gReady := true
            SetStatus("Ready in " Round((A_TickCount-tInit)/1000,1) "s (reused running session). Paste a VIN and press Lookup.")
        } else {
            SetStatus("Signing in as " CFG_USER " ...")
            if !RecoverSession() {
                SetStatus("ERROR: sign-in failed (check password / lockout)")
                return
            }
            gReady := true
            SetStatus("Ready in " Round((A_TickCount-tInit)/1000,1) "s. Paste a VIN and press Lookup.")
        }
        CleanupForms()
        DetectPoke()
        SetSess("alive (keepalive: " (InStr(gPokeMode,"rap") ? "native RAP ping" : "menu poke") ")")
        SetTimer, KeepAlive, %CFG_KEEPALIVE%
        if (gSelfTest != "") {
            GuiControl, Main:, VinInput, %gSelfTest%
            SetTimer, DoLookup, -500
        }
    } catch e {
        SetStatus("Startup error: " e.Message " (line " e.Line ")")
    } finally {
        gBusy := false
    }
return

DoLookup:
    Gui, Main:Submit, NoHide
    if (gBusy) {
        SetStatus("Busy - wait a moment...")
        return
    }
    if (!gReady) {
        SetStatus("Not ready yet - still connecting...")
        return
    }
    v := Trim(VinInput)
    if (v = "") {
        SetStatus("Enter a VIN (or rego/serial/engine).")
        return
    }
    kind := "vin"
    if (KindInput = "Rego")
        kind := "rego"
    else if (KindInput = "Serial")
        kind := "serial"
    else if (KindInput = "Engine")
        kind := "engine"
    gBusy := true
    ; --- cached result first (instant), then live refresh ---
    cf := CacheFile(kind, v)
    cached := ""
    if FileExist(cf) {
        FileRead, cached, %cf%
        cached := Trim(cached, "`r`n")
    }
    if (cached != "") {
        ShowResult(cached)
        FileGetTime, cft, %cf%
        FormatTime, cfts, %cft%, dd/MM HH:mm
        SetStatus("Cached result (from " cfts ") shown - refreshing live...")
    } else {
        LV_Delete()
        SetStatus("Looking up " v " ...")
    }
    if !MxAcquire(30000) {
        SetStatus("Another IsuzuVIN process is using the session - try again shortly.")
        gBusy := false
        return
    }
    ; mutex + busy flag ALWAYS released, even if the drive throws mid-lookup -
    ; a leaked mutex/flag blocked every later lookup until the app restarted
    try {
        ; make sure the session is healthy before driving it
        if (CDP_Eval("'pong'") != "pong" || !IsLoggedIn()) {
            SetStatus("Session dropped - recovering...")
            if !Reconnect() {
                SetStatus(cached != "" ? "Live refresh failed - cached result kept." : "Session recovery failed.")
                return
            }
        }
        CleanupForms()
        res := Lookup(kind, v)
        if (res = "") {
            SetStatus("Hiccup - reconnecting and retrying once...")
            if Reconnect() {
                CleanupForms()
                res := Lookup(kind, v)
            }
        }
        if (gSelfTest != "")
            FileAppend, % "DOLOOKUP res len=" StrLen(res) " [" SubStr(res,1,60) "]`n", %gLog%
        if (res = "NOTFOUND") {
            ShowResult("")
            SafeDelete(cf)
        } else if (res != "") {
            ShowResult(res)
            CacheWrite(kind, v, res)
        } else {
            SetStatus(cached != "" ? "Live lookup failed - cached result (above) kept." : "Lookup failed (no response).")
        }
        CleanupForms()
    } catch e {
        SetStatus("Lookup error: " e.Message " (line " e.Line ") - try again.")
    } finally {
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

SessionCheck() {
    global
    if (CDP_Eval("'pong'") != "pong") {
        SetSess("connection lost - reconnecting...")
        if !Reconnect() {
            gReady := false
            SetSess("DOWN - will retry in " Round(CFG_KEEPALIVE/60000) " min")
            return false
        }
    }
    if (!IsLoggedIn() || !SessionAlive()) {
        SetSess("session expired - signing back in...")
        if !RecoverSession() {
            gReady := false
            SetSess("re-sign-in FAILED - will retry in " Round(CFG_KEEPALIVE/60000) " min")
            return false
        }
    }
    CleanupForms()
    Poke()
    gReady := true
    FormatTime, kats,, HH:mm:ss
    SetSess("alive (checked " kats ", keepalive: " (InStr(gPokeMode,"rap") ? "native RAP ping" : "menu poke") ")")
    return true
}

MenuRelogin:
    if (gBusy)
        return
    gBusy := true
    if !MxAcquire(15000) {
        gBusy := false
        return
    }
    try {
        SetStatus("Reloading IDS and signing in fresh...")
        if (!NewTab()) {
            SetStatus("Fresh sign-in failed (could not open a new IDS tab).")
            return
        }
        if EnsureLogin() {
            gReady := true
            SetStatus("Ready (fresh session).")
        } else {
            SetStatus("Fresh sign-in failed.")
        }
    } finally {
        MxRelease()
        gBusy := false
    }
return

ShowResult(res) {
    ; res is a string of key=value lines
    order := ["vin","rego","year","model","model_desc","group","colour_code","colour"
        ,"trim_code","trim","engine","status_code","status","activity","key_number"
        ,"build_date","retail_sale","warranty_start","warranty_expiry","kms","campaign"
        ,"selling_dealer","sold_to_dealer","date_to_dealer","purpose_code","comments"]
    pretty := {vin:"VIN", rego:"Registration", year:"Year", model:"Model code"
        , model_desc:"Model", group:"Group", colour_code:"Paint code", colour:"Paint colour"
        , trim_code:"Trim code", trim:"Trim", engine:"Engine No.", status_code:"Status code"
        , status:"Status", activity:"Activity", key_number:"Key number"
        , build_date:"Build date", retail_sale:"Retail sale", warranty_start:"Warranty start"
        , warranty_expiry:"Warranty EXPIRY", kms:"Warranty kms", selling_dealer:"Selling dealer"
        , sold_to_dealer:"Sold-to dealer", date_to_dealer:"Date to dealer"
        , purpose_code:"Purpose code", comments:"Owner / comments", campaign:"Campaign"}
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
    LV_Delete()
    if (map["vin"] = "") {
        SetStatus("No record found for that " . "query.")
        LV_Add("", "(no record)", "Nothing returned by DC611")
        return
    }
    dump := ""
    for i, k in order {
        label := pretty[k] ? pretty[k] : k
        LV_Add("", label, map[k])
        dump .= label ": " map[k] "`r`n"
    }
    ; persist last result (handy export + lets you copy/paste)
    SafeDelete(A_ScriptDir "\last_result.txt")
    FileAppend, %dump%, %A_ScriptDir%\last_result.txt
    exp := map["warranty_expiry"]
    SetStatus("Done. " map["model_desc"] "  -  warranty expiry " exp)
}

SetStatus(s) {
    global gBatch, gLog, gSelfTest
    if (gBatch || gSelfTest != "")
        FileAppend, % A_Now " " s "`n", %gLog%
    if (!gBatch)
        GuiControl, Main:, Status, %s%
}

SetSess(s) {
    global gBatch
    if (gBatch)
        return
    GuiControl, Main:, Sess, % "Session: " s
    ; tray tooltip is capped at 127 chars - trim so Menu,Tray,Tip can't fail
    Menu, Tray, Tip, % SubStr("Isuzu VIN Lookup - " s, 1, 120)
}

; X / Esc only HIDE the window - the script keeps running in the tray with the
; session alive, so reopening is instant. Quit via the tray / Session menu.
MainGuiClose:
MainGuiEscape:
    Gui, Main:Hide
return

; exiting LEAVES Chrome running (signed in) so the next launch is instant
MenuExitKeep:
    if (gSock)
        WS_CloseSocket(gSock)
    ExitApp
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
    global gSock, gId
    if (!gSock)
        return ""
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
    if !SetLoginField("u", CFG_USER)
        return false
    if !SetLoginField("p", CFG_PW)
        return false
    local jsS := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){return x.children.length<=1&&(x.innerText||'').trim()==='Sign in'&&x.getBoundingClientRect().width>0;});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    local sx, sy
    if !Coord(jsS, sx, sy)
        return false
    Click(sx, sy)
    local err
    Loop, 50 {
        Sleep, 300
        if IsLoggedIn()
            return true
        err := CDP_Eval("(function(){var e=Array.from(document.querySelectorAll('*')).find(function(x){return /incorrect|invalid|locked/i.test(x.innerText||'');});return e?'ERR':'';})()")
        if (err = "ERR") {
            if (gBatch)
                BLog("login: server said credentials incorrect/locked")
            return false
        }
    }
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
Lookup(field, value) {
    global gBatch, gLog, gDump
    labelmap := {vin:"Vin Number", serial:"Serial Number", rego:"Registration No.", engine:"Engine Number"}
    ; open DC611 via the Menu search box
    jsMenu := "(function(){var e=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&r.width>0&&r.top<140&&r.left<400;})[0];if(!e)return'';var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !Coord(jsMenu, mx, my)
        return ""
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
            return ""
        Click(mx, my)
        SelAllDel()
        TypeText("DC611")
        Sleep, 300
        KeyPress("Enter", 13)
        if !WaitCoord(jsField, fx, fy, 8000, 250)
            return ""
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
        return ""
    ; click OK
    jsOK := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='OK';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !Coord(jsOK, ox, oy)
        return ""
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
    return txt
}

; close any open DC611 screens (Exit F3) until none remain (max 3 levels)
CleanupForms() {
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