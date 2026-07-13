#SingleInstance, Force
SetBatchLines, -1
SetWorkingDir, %A_ScriptDir%
#NoEnv
SetEmbeddedIcon()



; ------------------------------------------------------------
;  Prefer 64-bit AutoHotkey. The OLE drag-drop engine (IDropTarget)
;  is 64-bit only. If we were launched 32-bit, try to relaunch with
;  a 64-bit AHK we can find. If none exists, we DON'T quit -- we keep
;  running 32-bit (GUI + Send all + Grab + Paste + Add files all work;
;  only drag-straight-from-email is disabled). This way the tool always
;  starts, regardless of which exe the user double-clicked.
; ------------------------------------------------------------
if (!A_IsCompiled && A_PtrSize != 8) {
    u64 := Find64BitAhk()
    if (u64 != "") {
        Run, "%u64%" "%A_ScriptFullPath%", , UseErrorLevel
        if (!ErrorLevel)
            ExitApp                              ; 64-bit copy took over
    }
    ; No 64-bit AHK found -> fall through and run 32-bit (drop disabled).
}

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
;  v2.0.1 - FIX: buttons stayed grey after "Send all" (toast GUI
;  hijacked the thread's default GUI; all GuiControls now 1:-prefixed
;  and ShowToast restores Gui 1 as default).
; ============================================================

global VERSION    := "2.0.1"
global IsuzuUrl   := ""
global BydUrl     := ""
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
global HINT_IDLE  := ""
global HINT_MORE  := ""

HINT_IDLE := GLYPH_DOWN "   Drag Isuzu + BYD invoice PDFs here   " GLYPH_DOWN
HINT_MORE := GLYPH_DOWN "   Drop more, or click ""Send all""   " GLYPH_DOWN

ReadConfig()


; ---- GUI is built by the BuildGui label (called at startup + by the SC029 hotkey) ----

; ---- Tray menu ---------------------------------------------
Menu, Tray, NoStandard
Menu, Tray, Add, Open window, ShowMainWindow
Menu, Tray, Add
Menu, Tray, Add, Grab from Outlook, GrabFromOutlook
Menu, Tray, Add, Paste copied attachment, PasteFromClipboard
Menu, Tray, Add, Add files..., MenuAddFiles
Menu, Tray, Add, Open log, MenuOpenLog
Menu, Tray, Add
Menu, Tray, Add, Exit, MenuExit
Menu, Tray, Default, Open window
Menu, Tray, Tip, Invoice Sender (Isuzu + BYD) v%VERSION%

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

Log("startup v" VERSION " | isuzu=" IsuzuUrl " | byd=" BydUrl " | bits=" (A_PtrSize * 8))
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
    ; tear down the old window's drag-drop registration, then the window
    if (g_oleActive) {
        DllCall("ole32\RevokeDragDrop", "Ptr", hwndMain)
        g_oleActive := false
    }
    Gui, 1:Destroy
    Paths  := {}          ; reset row maps so the new window starts clean
    Brands := {}
    Seen   := {}
    Busy   := false       ; FIXED: rebuild always clears a stuck Busy flag

    Gui, 1:+HwndhwndMain +AlwaysOnTop
    Gui, 1:Margin, 12, 12
    Gui, 1:Font, s11 Bold, Segoe UI
    Gui, 1:Add, Text, w460 Center, Invoice Sender  -  Isuzu + BYD
    Gui, 1:Font, s9 Norm cGray, Segoe UI
    Gui, 1:Add, Text, w460 Center, Drop invoice PDFs below (auto-routed by brand), then click "Send all"

    Gui, 1:Font, s11 Norm, Segoe UI
    Gui, 1:Add, GroupBox, x12 w460 h64 vDropBox,
    Gui, 1:Add, Text, xp+12 yp+24 w436 Center vDropHint, %HINT_IDLE%

    Gui, 1:Font, s9, Segoe UI
    Gui, 1:Add, ListView, x12 y+32 w460 r10 Grid -Multi vLV gLV, #|File|Brand|Status
    Gui, 1:Default        ; FIXED: guarantee LV_* below (and everywhere) target Gui 1
    LV_ModifyCol(1, 28)
    LV_ModifyCol(2, 215)
    LV_ModifyCol(3, 60)
    LV_ModifyCol(4, 145)

    Gui, 1:Add, Button, x12 y+12 w130 h32 gSendAll vBtnSend, Send all
    Gui, 1:Add, Button, x+10 yp w90 h32 gClearList vBtnClear, Clear
    Gui, 1:Font, s9 cGray, Segoe UI
    Gui, 1:Add, Text, x+90 yp+8, % "v" . VERSION

    Gui, 1:Show, Hide w484 h470, Invoice Sender   ; built hidden; Ctrl+Alt+I shows it

    ; re-register drag-drop on the NEW window handle
    if (EnableEmailDrag && g_oleInit) {
        if InitOleDrop(hwndMain)
            Log("email-drag: OLE drop target active (real files + classic-Outlook drags)")
        else
            Log("email-drag: init failed; basic drop + Grab + Paste still work")
    } else if (EnableEmailDrag) {
        Log("email-drag: needs 64-bit AHK; using basic drop + Grab + Paste")
    }
    if (A_PtrSize != 8) {
        GuiControl, 1:, DropHint, % "32-bit AHK: drag disabled. Use Add files / Grab / Paste, then Send all."
        Menu, Tray, Tip, Invoice Sender (32-bit: no drag) v%VERSION%
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
    if (Busy)                 ; FIXED: don't touch rows mid-send
        return
    SetRowBrand(LV_GetSelRow(), "isuzu")
return
RowSetByd:
    if (Busy)                 ; FIXED
        return
    SetRowBrand(LV_GetSelRow(), "byd")
return
RowRemove:
    if (Busy)                 ; FIXED: deleting mid-send corrupts row maps
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
    Gui, 1:Default            ; FIXED: guarantee LV_* target Gui 1 even after a toast
    total := LV_GetCount()
    if (!total) {
        ShowToast("bad", "Nothing to send", "Drop some invoice PDFs first")
        return
    }
    ; Resolve any "unknown" rows before sending (prompt or default).
    if (!ResolveUnknowns())
        return
    Busy := true
    GuiControl, 1:Disable, BtnSend      ; FIXED: explicit Gui 1 target
    GuiControl, 1:Disable, BtnClear     ; FIXED
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
    GuiControl, 1:Enable, BtnSend       ; FIXED: was silently hitting the Toast GUI
    GuiControl, 1:Enable, BtnClear      ; FIXED
    Log("batch done: " okCount " ok, " failCount " failed")
    if (okCount = 0)
        ShowToast("bad", "Send failed", "Tray icon > Open log for details")
    else {
        msg := okCount " invoice" (okCount = 1 ? "" : "s") " sent"
        if (failCount)
            msg .= ", " failCount " failed"
        ShowToast((failCount ? "bad" : "ok"), "Send all complete", msg)
    }
return

ClearList:
    if (Busy)
        return
    Gui, 1:Default            ; FIXED
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
BrandFor(path) {
    SplitPath, path, fname
    b := BrandFromName(fname)
    if (b != "unknown") {
        Log("route: '" fname "' -> " b " (filename)")
        return b
    }
    b := BrandFromBytes(path)
    Log("route: '" fname "' -> " b " (text scan)")
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

BrandFromBytes(path) {
    f := FileOpen(path, "r")
    if (!IsObject(f))
        return "unknown"
    len := f.Length
    cap := (len < 262144 ? len : 262144)
    VarSetCapacity(buf, cap + 1, 0)
    f.RawRead(buf, cap)
    f.Close()
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

SetRowBrand(row, brand) {
    global Brands
    if (!row)
        return
    Gui, 1:Default
    Brands[row] := brand
    LV_Modify(row, "Col3", BrandLabel(brand))
}

RebuildRowMaps() {
    global Paths, Brands
    Gui, 1:Default
    newPaths  := {}
    newBrands := {}
    Loop % LV_GetCount() {
        r := A_Index
        LV_GetText(fn, r, 2)
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
    Loop % LV_GetCount()
        LV_Modify(A_Index, "Col1", A_Index)
}

ObjHasValue(obj, val) {
    for k, v in obj
        if (v = val)
            return true
    return false
}

LV_GetSelRow() {
    Gui, 1:Default
    row := LV_GetNext(0, "F")
    if (!row)
        row := LV_GetNext(0)
    return row
}

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
        Log("skip non-pdf " path)
        return false
    }
    if Seen.HasKey(path) {
        return false
    }
    if (!FileExist(path)) {
        Log("skip missing " path)
        return false
    }
    Seen[path] := true
    brand := BrandFor(path)
    row := LV_Add("", LV_GetCount() + 1, fname, BrandLabel(brand), "Queued")
    Paths[row]  := path
    Brands[row] := brand
    Log("queued " path " (" brand ")")
    return true
}

SendOne(path, brand) {
    global GLYPH_OK, GLYPH_BAD, g_lastId, g_lastLines
    SplitPath, path, fname
    if (!FileExist(path)) {
        Log("send: missing " path)
        return GLYPH_BAD . " file missing"
    }
    url := UrlFor(brand)
    if (url = "") {
        Log("send: no endpoint for brand '" brand "' " fname)
        return GLYPH_BAD . " no route"
    }
    b64 := Base64FromFile(path)
    if (b64 = "") {
        Log("send: read failed " fname)
        return GLYPH_BAD . " read failed"
    }
    body := "{""dataBase64"":""" b64 """}"
    res := HttpPostJson(url "/parse-invoice", body)
    if (res.status = 0) {
        Log("send: network error " fname " | " res.text)
        return GLYPH_BAD . " network"
    }
    okMatch := ""
    RegExMatch(res.text, "i)""ok""\s*:\s*(true|false)", m)
    okMatch := m1
    if (res.status = 200 && okMatch = "true") {
        id := "", conf := "", lines := 0
        RegExMatch(res.text, "U)""id""\s*:\s*""([^""]*)""", mId)
        id := mId1
        StrReplace(res.text, """partNumber""", "", lines)
        RegExMatch(res.text, "U)""confidence""\s*:\s*([0-9.]+)", mConf)
        conf := mConf1
        g_lastId    := id        ; stash for the Ctrl+Right menu toast
        g_lastLines := lines
        Log("send: OK " fname " [" brand "] -> id=" id " lines=" lines " conf=" conf " http=" res.status)
        out := GLYPH_OK . " Sent"
        if (id != "")
            out .= " " id
        if (lines > 0)
            out .= " (" lines ")"
        return out
    }
    err := ""
    RegExMatch(res.text, "U)""errors""\s*:\s*\[\s*""([^""]*)""", mErr)
    err := mErr1
    if (err = "")
        err := "HTTP " res.status
    Log("send: FAIL " fname " [" brand "] http=" res.status " err=" err " | " SubStr(res.text, 1, 200))
    return GLYPH_BAD . " " . err
}

HttpPostJson(url, body) {
    out := {status: 0, text: ""}
    attempts := 0
    Loop {
        attempts++
        try {
            whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
            whr.Open("POST", url, false)
            whr.SetRequestHeader("Content-Type", "application/json")
            whr.SetTimeouts(15000, 15000, 60000, 180000)   ; resolve, connect, send, receive
            try whr.Option(9) := 0x0800 | 0x2000           ; SecureProtocols: TLS1.2 | TLS1.3
            try whr.Option(4) := 0x3300                     ; SslErrorIgnoreFlags
            whr.Send(body)
            out.status := whr.Status
            out.text   := whr.ResponseText
            return out
        } catch e {
            out.status := 0
            out.text   := e.message
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

ReadConfig() {
    global IsuzuUrl, BydUrl, DefaultBrand, EnableEmailDrag
    ini := A_ScriptDir "\config.ini"
    IniRead, IsuzuUrl, %ini%, settings, IsuzuApiUrl, https://isuzu-parser-production.up.railway.app
    IniRead, BydUrl,   %ini%, settings, BydApiUrl,   https://byd-parser-production.up.railway.app
    IsuzuUrl := RTrim(IsuzuUrl, "/ `t")
    BydUrl   := RTrim(BydUrl,   "/ `t")
    IniRead, DefaultBrand, %ini%, settings, DefaultBrand, %A_Space%
    StringLower, DefaultBrand, DefaultBrand
    if (DefaultBrand != "isuzu" && DefaultBrand != "byd")
        DefaultBrand := ""
    IniRead, edrag, %ini%, settings, EnableEmailDrag, 1
    EnableEmailDrag := (edrag != "0")
}

Log(msg) {
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    FileAppend, % ts " | " msg "`n", % A_ScriptDir "\sender.log"
}

; --- Custom on-screen toast (bottom-right). States: "load" / "ok" / "bad".
;     FIXED: "Gui, Toast:New" makes Toast the thread's DEFAULT GUI, which
;     hijacked every later un-prefixed GuiControl/LV_* -> buttons stayed
;     grey after Send all. Now we restore Gui 1 as default before returning.
ShowToast(state, line1, line2 := "") {
    global GLYPH_OK, GLYPH_BAD, ToastHwnd
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
    x := waRight - tw - 18
    y := waBottom - th - 18
    Gui, Toast:Show, NoActivate x%x% y%y%
    if (state = "load")
        SetTimer, HideToast, Off
    else
        SetTimer, HideToast, -5000
    Gui, 1:Default          ; FIXED: hand the default GUI back to the main window
}

HideToast:
    Gui, Toast:Hide
return

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
        Log("clip: OleGetClipboard hr=" pcHr)
        return 0
    }
    Log("clip: reading clipboard")
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
        Log("grab(" src "): no running classic Outlook COM (new Outlook? falling back to clipboard)")
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
        Log("grab(" src "): no open or selected email")
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
                Log("grab(" src "): SaveAsFile failed " fn " | " e.message)
            }
        }
    }
    Log("grab(" src "): " grabbed " pdf(s) from " mails.Length() " mail(s)")
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
    GuiControl, 1:Disable, BtnSend      ; FIXED
    GuiControl, 1:Disable, BtnClear     ; FIXED
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
    GuiControl, 1:Enable, BtnSend       ; FIXED
    GuiControl, 1:Enable, BtnClear      ; FIXED
    Log("auto-send: " okCount " ok, " failCount " failed (from row " startCount ")")
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
    Gui, 1:Default            ; FIXED: ShowToast above changed default GUI; LV_GetCount below needs Gui 1
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
        Log("bg auto-drag: nothing captured from " gDragX "," gDragY)
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
        Log("RegisterDragDrop failed hr=" hr)
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
        Log("drop fired")
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
            Log("drop: nothing read from that drag")
    } catch e {
        Log("drop handler error: " e.message)
        if (pAsync)
            EndAsync(pAsync, false)
    }
    return 0
}

ReadHdrop(pData) {
    static CF_HDROP := 15
    if (!HasFormat(pData, CF_HDROP)) {
        Log("hdrop: CF_HDROP not offered")
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
            Log("hdrop: GetData failed hr=" hr " after " tries " tries")
            return -1
        }
        Sleep, 100
    }
    hDrop := NumGet(stg, 8, "Ptr")
    count := hDrop ? DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0, "UInt") : 0
    Log("hdrop: tymed=" NumGet(stg, 0, "UInt") " hDrop=" hDrop " count=" count " tries=" tries)
    added := 0
    Loop % count {
        idx := A_Index - 1
        len := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", idx, "Ptr", 0, "UInt", 0, "UInt")
        VarSetCapacity(buf, (len + 1) * 2, 0)
        DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", idx, "Ptr", &buf, "UInt", len + 1, "UInt")
        path := StrGet(&buf, "UTF-16")
        Log("hdrop: file " idx " = '" path "' exists=" (FileExist(path) ? 1 : 0))
        if (path != "" && AddDroppedFile(path))
            added++
    }
    DllCall("ole32\ReleaseStgMedium", "Ptr", &stg)
    Log("hdrop: added=" added)
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
        Log("hdrop: folder " srcPath " -> " added " pdf(s)")
        return (added > 0)
    }
    SplitPath, srcPath, fname, , ext
    StringLower, el, ext
    if (el != "pdf") {
        Log("hdrop: skip non-pdf " srcPath)
        return false
    }
    size := WaitForFile(srcPath, 4000)
    if (size <= 0) {
        Log("hdrop: missing/empty after wait " srcPath)
        return false
    }
    dest := GrabDir() "\" SafeName(fname)
    if (srcPath = dest)
        return AddFile(srcPath)
    FileCopy, %srcPath%, %dest%, 1
    if (ErrorLevel) {
        Log("hdrop: copy failed " srcPath " -> " dest)
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
    Log("  std: CF_HDROP=" (HasFormat(pData,15)?1:0) " CF_UNICODETEXT=" (HasFormat(pData,13)?1:0) " CF_TEXT=" (HasFormat(pData,1)?1:0))
    for idx, nm in ["FileGroupDescriptorW","FileGroupDescriptor","FileContents","FileNameW","FileName","UniformResourceLocatorW","text/html"] {
        cf := DllCall("RegisterClipboardFormatW", "WStr", nm, "UInt")
        if HasFormat(pData, cf)
            Log("  reg: " nm "=1")
    }
}

EnumFormats(pData) {
    vt := NumGet(pData + 0, 0, "Ptr")
    pEnumFn := NumGet(vt + 8 * 8, 0, "Ptr")
    pEnum := 0
    hr := DllCall(pEnumFn, "Ptr", pData, "UInt", 1, "Ptr*", pEnum, "UInt")
    if (hr != 0 || !pEnum) {
        Log("  enum: EnumFormatEtc unavailable hr=" hr)
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
        Log("  enum: cf=" cf " " CfName(cf) " aspect=" aspect " lindex=" lindex " tymed=" tymed)
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
        Log("  async: not supported (synchronous source)")
        return 0
    }
    vt := NumGet(pAsync + 0, 0, "Ptr")
    isAsync := 0
    DllCall(NumGet(vt + 4 * 8, 0, "Ptr"), "Ptr", pAsync, "Int*", isAsync, "UInt")
    hr := DllCall(NumGet(vt + 5 * 8, 0, "Ptr"), "Ptr", pAsync, "Ptr", 0, "UInt")
    Log("  async: supported, mode=" isAsync " StartOperation hr=" hr)
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
        Log("virtual: FileGroupDescriptorW not offered")
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
            Log("virtual: GetData descriptor failed hr=" hr " after " tries " tries")
            return 0
        }
        Sleep, 100
    }
    hG := NumGet(stg, 8, "Ptr")
    pDesc := DllCall("GlobalLock", "Ptr", hG, "Ptr")
    added := 0
    if (pDesc) {
        cItems := NumGet(pDesc + 0, 0, "UInt")
        Log("virtual: " cItems " item(s) in descriptor (tries=" tries ")")
        Loop % cItems {
            i := A_Index - 1
            fname := StrGet(pDesc + 4 + i * 592 + 72, 260, "UTF-16")   ; cFileName offset
            SplitPath, fname, , , ext
            StringLower, el, ext
            if (el != "pdf") {
                Log("virtual: skip non-pdf '" fname "'")
                continue
            }
            dest := GrabDir() "\" SafeName(fname)
            if ExtractContents(pData, cfCont, i, dest) {
                if AddFile(dest)
                    added++
            } else {
                Log("virtual: extract failed '" fname "'")
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
            Log("virtual: GetData FileContents idx " index " hr=" hr " after " tries " tries")
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
        Log("virtual: unexpected tymed=" tym " idx " index)
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

; FIXED: backtick rebuild is now scoped to the tool window + Outlook only.
; Previously it was GLOBAL and typing ` in any app (Notepad, ERA, browser)
; silently wiped your queue and rebuilt the window.
#If WinActive("ahk_id " hwndMain) or WinActive("ahk_exe OUTLOOK.EXE") or WinActive("ahk_exe olk.exe")
SC029::
    Gosub, BuildGui      ; tears down old window + builds new (hidden)
    Gui, 1:Show          ; show the fresh window
return
#If



; ============================================================================
;  EMBEDDED ICON BLOCK  -  paste this whole block into ANY AHK v1 script.
;  Then call  SetEmbeddedIcon()  once, near the top (before creating GUIs).
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

