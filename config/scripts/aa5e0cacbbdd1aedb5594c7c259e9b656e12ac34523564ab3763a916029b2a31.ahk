SetEmbeddedIcon()

#NoEnv
#SingleInstance, Force
SetBatchLines, -1
SetWorkingDir, %A_ScriptDir%

; ============================================================================
; BydStock.ahk - BYD DMS stock check by plain HTTP
; ----------------------------------------------------------------------------
; Paste a material code, press Look up, get every warehouse's quantity back. No
; browser is driven: the script POSTs straight to the DMS's own stock inquiry
; action, the same call the "OEM spare part stock inquiry" tab makes. The
; endpoint and its fields were read out of the app's JavaScript - see
; chrome-lab\BYD-DMS-NOTES.md for how, and for what the server's headers mean.
;
; ---- IT RIDES ITS OWN BROWSER'S SESSION. The DMS is cookie-authenticated and
; the login is RSA-encrypted client side, so the script never mints a cookie
; itself. It keeps a Chrome of its own (separate profile, debug port, window
; HIDDEN) signed in to the DMS and runs each query as a fetch() inside that
; tab, so Chrome attaches the session and nothing here ever sees it.
;
; The login is the one thing that needs a human, and only for one field. The
; form is username + password + a picture captcha, and the captcha is the
; whole reason a script cannot sign in alone. So the script does everything
; else: it launches the browser hidden, fills the saved username and password
; into the login form, ticks the privacy box, brings the window up with the
; cursor in the captcha field, and waits. Type the code, press Enter, and the
; window is hidden again the moment the DMS lands on main.html. From then on
; every query is silent until the session dies, when the same dance repeats.
;
; The username and password are built into this script - see LUSER and LPASS
; below - so the one .ahk file is the whole tool: nothing to copy beside it,
; nothing to type on a new machine. Those two lines ARE the login, in plain
; text. That is the trade the tool makes.
;
; Signing the script's browser in signs the everyday Chrome's DMS tab out -
; one session per account is the server's rule ("sessionstatus: aready" is
; the other tab being told). Use the script's browser for the DMS, or accept
; the re-login.
;
; The pasted-cookie route is still underneath as a fallback (a JSESSIONID
; pasted at the prompt, held in memory for the run; NOBROWSER := true forces
; it).
;
; ---- THE WAREHOUSE NAMES COME BACK IN CHINESE. The action returns
; SUB_LOCATION as the site's Chinese name; the web grid shows English only
; because it looks each row's SUB_LOCATION_ID up in a dictionary the page
; fetches after login, which is not in the static language file. So the four
; Australian sites are mapped in WarehouseName() by their Chinese names, with a
; word-by-word fallback for any site the map does not know. An unmapped name
; still shows - translated roughly, never dropped.
;
; This file is saved UTF-8 WITH BOM on purpose: the map keys are Chinese and
; AutoHotkey v1 reads a BOM-less file as ANSI, which would turn every key into
; mojibake and match nothing.
;
; ---- A DEAD SESSION IS NOT AN ERROR CODE. The server answers 404 with a
; "sessionstatus: timeout" header and a fresh throwaway JSESSIONID. The script
; reads the header, asks for a new cookie, and retries once. "limit" on the
; same header is the rate limiter: one minute's wait, not a retry.
;
; ---- USAGE.
;   BydStock.ahk                  window; part number prefilled from the
;                                 clipboard when the clipboard looks like one
;   BydStock.ahk 15079287-00      query straight away
;   BydStock.ahk --selftest       parse a canned response, print to stdout
;   BydStock.ahk --cdptest        attach to the DMS browser and report
;   BydStock.ahk --cdpquery CODE  the real browser route, headless, to a file
;
; One-shot by design: it opens, answers, and exits with its window. The pad
; stays the only resident. The hidden Chrome is not a resident of ours - it is
; the DMS session, and it outlives the script on purpose.
; ============================================================================

global BASE     := "https://oadms.byd.com/"
global ENDPOINT := "part/masterdata/StockSearchAction/stockSearchQuery.json"
global SID      := ""
global LOGUSER  := ""
global LASTSUMMARY := ""
global BUSY := false

; ---- the browser route. CPORT is this tool's own debug port: 9222 is the
; rego lookup's and 9412 is the Isuzu one, and sharing a port would mean
; hunting for a DMS tab in a browser that has none.
global CPORT    := 9413
global CPROFILE := ""
global CSOCK    := 0        ; live CDP WebSocket, 0 when not attached
global CDPID    := 0        ; CDP message counter
global NOBROWSER := false   ; true forces the pasted-cookie route
global ROUTE     := ""      ; which route answered, for the status line
global BROWSERWHY := ""     ; why the browser route declined, if it did
global VERSION  := "1.1"            ; shown at the end of the window title; bump on each release
global LUSER    := "APAU3029S_PM"   ; DMS login, filled into the DMS form
global LPASS    := "12345678@BYD"
global CHWND    := 0        ; the hidden Chrome's window, once known

; The DMS browser lives hidden, so every window lookup has to see hidden ones.
; Title match "contains": Chrome appends " - Google Chrome" to the tab title.
DetectHiddenWindows, On
SetTitleMatchMode, 2

; Everything that used to come from byd-stock.ini is set above. The Chrome
; profile goes under LOCALAPPDATA so it lands somewhere writable on any
; machine, and beside the script if there is no LOCALAPPDATA.
if (CPROFILE = "")
{
    EnvGet, la, LOCALAPPDATA
    CPROFILE := (la != "" ? la : A_ScriptDir) . "\byd-dms-chrome"
}

part = %1%
if (part = "--selftest") {
    outFile = %2%
    SelfTest(outFile)
    ExitApp
}
if (part = "--probe") {
    ; one raw call with whatever cookie SID holds, no prompts: proves the
    ; HTTP layer and shows what the server said. Writes to %2% or stdout.
    outFile = %2%
    status := 0, sess := ""
    body := HttpPost(ENDPOINT, "PART_CODE=15079287-00&page=1&start=0&limit=100", status, sess)
    out := "status=" . status . " sessionstatus=" . sess . " cookie=" . (SID = "" ? "none" : "set") . " bodylen=" . StrLen(body) . "`n" . SubStr(body, 1, 300) . "`n"
    if (outFile != "")
        FileAppend, %out%, %outFile%
    else
        FileAppend, %out%, *
    ExitApp
}
if (part = "--cdptest") {
    ; Proves the browser route's transport without needing a signed-in
    ; session: attach to whatever oadms.byd.com tab the debug Chrome has,
    ; round-trip one expression, and decode one base64 payload the same way a
    ; real answer comes back. Writes to %2% or stdout.
    outFile = %2%
    err := ""
    ok := CdpAttach(err)
    out := "port=" . CPORT . "  attach=" . (ok ? "yes" : "no (" . err . ")")
    if (ok) {
        out .= "  eval=" . CdpEval("'pong'")
        out .= "  host=" . CdpEval("location.host")
        out .= "  b64=" . B64Utf8(CdpEval("btoa('hello')"))
        out .= "  getLang=" . CdpEval("(typeof getLang=='function')?'yes':'no'")
    }
    out .= "`n"
    if (outFile != "")
        FileAppend, %out%, %outFile%
    else
        FileAppend, %out%, *
    ExitApp
}
if (part = "--cdpquery") {
    ; Runs the real signed-in-tab path for one code and writes a readable
    ; summary to %3% (or stdout). No cookie fallback, no prompts: this tests
    ; the browser route alone, so it says plainly whether the tab is logged in.
    code = %2%
    outFile = %3%
    err := ""
    body := CdpEnsureLogin(err) ? CdpStock(code, err) : ""
    if (body = "") {
        out := "ROUTE=browser  RESULT=FAIL  " . err . "`n"
    } else {
        res := ParseStock(body)
        if (!res.ok) {
            out := "ROUTE=browser  RESULT=FAIL  " . res.err . "`n"
        } else {
            total := 0, lines := ""
            for i, r in res.rows {
                total += (r.qty + 0)
                lines .= "  " . r.where . "  qty=" . r.qty . "  normal=" . r.normal . " " . r.currency . "  raw=" . r.whereRaw . "`n"
            }
            head := res.rows.MaxIndex() ? (res.rows[1].code . "  " . res.rows[1].name) : ""
            out := "ROUTE=browser  RESULT=OK  rows=" . res.rows.MaxIndex() . "  total=" . total . "`n" . head . "`n" . lines
        }
    }
    if (outFile != "")
        FileAppend, %out%, %outFile%
    else
        FileAppend, %out%, *
    ExitApp
}
if (part = "") {
    cb := Clipboard
    if RegExMatch(cb, "i)^\s*(?:BY)?\d{6,}(?:-\d{1,2})?\s*$")
        part := Trim(cb)
}

; ---- THE WINDOW. Built to read like the Isuzu Parts & VIN Lookup, because
; the same people use both across the same counter and one set of habits is
; enough: the number you typed small and grey in monospace, the description
; big and black under it against a steel rule, one verdict pill hard right,
; a Consolas table with the state glyph on the end of each row, and the
; prices as a grey rail on the bottom edge. The row tint and the glyph ink
; come from a WM_NOTIFY / NM_CUSTOMDRAW handler further down; the steel
; button is BS_OWNERDRAW painted from WM_DRAWITEM. No library for any of it,
; so the whole tool stays one .ahk file that runs on any machine.
;
; Colours are RRGGBB strings for Gui/GuiControl and go through Bgr() for the
; GDI calls, which want them the other way round.

global MAINHWND  := 0
global LVHWND    := 0        ; the table's hwnd, for the custom-draw filter
global LOOKHWND  := 0        ; the steel button's hwnd, for WM_DRAWITEM
global PILLHWND  := 0
global ROWSTATE  := []       ; per-row: "stock" | "wait" | "none" | "dead"
global PILLON    := false, PILLW := 0, PILLH := 0
global BUSYHWND  := 0        ; the sweep bar under the input, shown while a query runs
global BUSYDOTS  := 0        ; the button reads Working, Working ., Working .. while BUSY
global RAILON    := false
global SESSSTATE := "", SESSDETAIL := ""
global BRANDPNG  := ""

; The BYD wordmark is built into the script (base64, at the bottom) and
; written out under %TEMP% on every start, so the one .ahk still carries its
; own header mark. The window keeps the stock AutoHotkey icon.
BrandFiles()

Menu, SessMenu, Add, Show the DMS browser, MenuShowDms
Menu, SessMenu, Add, Sign in again, MenuRelogin
Menu, SessMenu, Add
Menu, SessMenu, Add, Copy summary, CopyOut
Menu, SessMenu, Add
Menu, SessMenu, Add, Show the window`tCtrl+PgUp, MenuShowWindow
Menu, SessMenu, Add, Exit (leave the browser running), MenuExit
Menu, MainMenuBar, Add, &Session, :SessMenu
Gui, Menu, MainMenuBar
Gui, +HwndMAINHWND
Gui, Font, s10, Segoe UI

; the input row: label, box, and the steel Look up button on its right edge,
; with the wordmark top right over the button (64x13, baked on the F0F0F0
; ground the window paints, so no alpha to get wrong)
if (BRANDPNG != "")
    Gui, Add, Picture, x406 y8 w64 h13 vBrand, %BRANDPNG%
Gui, Add, Text, x20 y12, Part number:
Gui, Add, Edit, x20 y32 w330 vPartEdit, %part%
Gui, Add, Button, x360 y31 w110 h27 gDoQuery Default vQueryBtn hwndLOOKHWND, &Look up
OwnerDrawButton(LOOKHWND)

; the busy bar: a 3px marquee (PBS_MARQUEE 0x8) under the input row, steel on
; pale grey. Classic, not themed, so it takes those colours; the marquee block
; still sweeps in the classic look. Hidden until a query is running.
Gui, -Theme
Gui, Add, Progress, x20 y62 w450 h3 c2C4A66 BackgroundD7DDE3 0x8 vBusyBar hwndBUSYHWND Hidden
Gui, +Theme

; the part header against a 3px steel rule. A themed Progress bar ignores a
; custom background, hence -Theme around it.
Gui, -Theme
Gui, Add, Progress, x20 y72 w3 h36 Background2C4A66 vPartRule Hidden
Gui, +Theme
Gui, Font, s8 Bold, Consolas
Gui, Add, Text, x31 y72 w439 vPartNum c6E7B87,
Gui, Font, s12 Bold, Segoe UI
Gui, Add, Text, x31 y85 w439 vPartTitle,
; The series tag that sat right of the number and the "Total N across M
; warehouses" line under the title are both gone: number, name and the table
; say it all. The pill keeps a 28px band of its own, hard right, between the
; title and the table.
Gui, Font, s8 Norm, Segoe UI

; the table. Consolas so the quantities line up; the last column is nameless
; and 22px wide, the glyph column. Added with LV_InsertCol: a TRAILING empty
; title in the column list is dropped by the parser.
Gui, Font, s10 Norm, Consolas
Gui, Add, ListView, x20 y140 w450 h26 Grid -Multi vLV hwndLVHWND, Warehouse|Available
LV_ModifyCol(1, 300)
LV_ModifyCol(2, "124 Right")
LV_InsertCol(3, 22)

; the price rail: three figures and the currency, small and grey, under
; everything that is actually read. FitWindow() drops it to the table bottom.
Gui, Add, Text, x20 y180 w450 h2 0x10 vPriceRule Hidden
Gui, Font, s7 Norm, Segoe UI
; DAILY is the DMS's NORMAL_ORDER_PRICE, LIST its SALE_PRICE - the names the
; counter uses. A second grey line under the figures says they are ex GST.
Gui, Add, Text, x20  y188 w48 vPriceLbl1 cA2A2A2 Hidden, DAILY
Gui, Add, Text, x170 y188 w34 vPriceLbl2 cA2A2A2 Hidden, VOR
Gui, Add, Text, x300 y188 w34 vPriceLbl3 cA2A2A2 Hidden, LIST
Gui, Add, Text, x426 y188 w44 Right vPriceCur cB4B4B4 Hidden,
Gui, Add, Text, x20  y204 w200 vPriceNote cB4B4B4 Hidden, All prices exclude GST
Gui, Font, s8 Norm, Consolas
Gui, Add, Text, x68  y186 w90 vPrice1 c3E3E3E Hidden,
Gui, Add, Text, x204 y186 w90 vPrice2 c3E3E3E Hidden,
Gui, Add, Text, x334 y186 w90 vPrice3 c3E3E3E Hidden,

; the session line, the only footer
Gui, Font, s8, Segoe UI
Gui, Add, Text, x12 y220 w470 vSess c808080, Paste a BYD part number and press Look up.

OnMessage(0x2B, "OnDrawItem")      ; WM_DRAWITEM - the steel button
OnMessage(0x4E, "OnLvNotify")      ; WM_NOTIFY   - row tint and glyph ink

; Starts minimised on the taskbar, the way the Isuzu tool does: it is a
; counter tool that is wanted when a number is in hand, not at boot. Ctrl+
; PageUp or a lookup from AUDOS Switch brings it up. The one exception is a
; part number on the command line - that is the Switch starting it to look
; something up right now, so the window comes up to show the answer.
if (part != "")
    Gui, Show, w490 h250, % "BYD Stock Lookup  v" . VERSION
else
    Gui, Show, Minimize w490 h250, % "BYD Stock Lookup  v" . VERSION
FitWindow()
GuiControl, Focus, PartEdit

; The verdict pill: a child window, because a Win32 Text control paints on
; its parent's ground and a coloured ground has to BE a window. Built after
; the main window so it has a parent, and every line names it, because
; Gui,New makes it the thread's default GUI.
Gui, Pill:New, -Caption +Border +Parent%MAINHWND% +HwndPILLHWND
Gui, Pill:Color, FFFFFF
Gui, Pill:Font, s10 Norm, Segoe UI Symbol
Gui, Pill:Add, Text, x6 y1 w18 h18 Center vPillGlyph
Gui, Pill:Font, s8 Bold, Segoe UI
Gui, Pill:Add, Text, x26 y4 w88 vPillWord
Gui, Pill:Font, s7 Norm, Segoe UI
Gui, Pill:Add, Text, x26 y17 w88 vPillEta
Gui, 1:Default

if (part != "")
    GoSub, DoQuery
return

; ---------------------------------------------------------------------------
; window plumbing

; The X does not close this app, it minimises it. It comes back instantly
; because nothing was torn down: the DMS browser stays signed in behind the
; minimised window. Escape does the same. Quitting for real is Session > Exit.
GuiClose:
GuiEscape:
    WinMinimize, ahk_id %MAINHWND%
return

; Ctrl+PageUp from anywhere: bring it back and put the cursor in the box. If
; it is up but buried, this raises it. System-wide, so it is taken from
; Chrome's previous-tab and Excel's previous-sheet while this app runs.
^PgUp::
    Gosub, MenuShowWindow
return

MenuShowWindow:
    ; Show alone leaves a minimised window minimised; Restore brings it up
    if (DllCall("IsIconic", "Ptr", MAINHWND))
        Gui, Show, Restore
    else
        Gui, Show
    WinActivate, ahk_id %MAINHWND%
    GuiControl, Focus, PartEdit
return

MenuExit:
    ExitApp

BusyTick:
    BUSYDOTS := Mod(BUSYDOTS + 1, 4)
    d := ""
    Loop, %BUSYDOTS%
        d .= "."
    GuiControl,, QueryBtn, % "Working" . (d != "" ? " " . d : "")
    DllCall("InvalidateRect", "Ptr", LOOKHWND, "Ptr", 0, "Int", 1)
return

MenuShowDms:
    if (BUSY)
        return
    BUSY := true
    err := ""
    if (CdpEnsureLogin(err)) {
        ShowDms()
        SessRestore()
    } else
        SetSessState("down", err)
    BUSY := false
return

; Back to the login form and through the flow again - for a session the
; server has quietly dropped, or a password that changed.
MenuRelogin:
    if (BUSY)
        return
    BUSY := true
    err := ""
    CdpEval("location.href='/'")
    Sleep, 500
    if (CdpEnsureLogin(err))
        SetSessState("ready", "signed in again")
    else
        SetSessState("down", err)
    BUSY := false
return

CopyOut:
    if (LASTSUMMARY = "")
        return
    Clipboard := LASTSUMMARY
    SetStatus("Copied.")
    SetTimer, SessRestoreT, -2500
return

SessRestoreT:
    SessRestore()
return

DoQuery:
    if (BUSY)                            ; Enter and the button can both fire; one query at a time
        return
    GuiControlGet, code,, PartEdit
    code := Trim(code)
    if (code = "")
        return
    BUSY := true
    GuiControl, Disable, QueryBtn
    BusySet(true)
    Gui, ListView, LV                    ; LV_* work on the thread's default ListView; name it every time
    LV_Delete()
    ROWSTATE := []
    HeaderSet(code, "", "")
    PillSet("", "")
    RailSet("", "", "", "")
    FitWindow()
    SetStatus("Looking up " . code . " ...")
    res := StockQuery(code)
    BusySet(false)
    GuiControl, Enable, QueryBtn
    BUSY := false
    Gui, ListView, LV
    if (!res.ok) {
        SetSessState("down", res.err)
        LASTSUMMARY := ""
        FitWindow()
        return
    }
    SetSessState("ready", "signed in via the " . ROUTE)
    if (res.rows.Length() = 0) {
        HeaderSet(code, "NO RECORD   " . Chr(0xB7) . "   the DMS returned nothing for that number", "")
        PillSet("ask", "NO RECORD")
        LASTSUMMARY := code . " | no stock rows"
        FitWindow()
        return
    }
    rows := SortMelbourneFirst(res.rows)
    first := rows[1]
    HeaderSet(first.code, first.name, first.series)
    total := 0, parts := "", n := rows.Length(), unmapped := ""
    for i, r in rows {
        if r.qty is number
            total += r.qty
        ; A warehouse the map does not know shows its raw name in the table
        ; and is called out on the status line, so a new site turns up as a
        ; thing to add to WarehouseName() rather than a blank row.
        if (r.where = "")
            r.where := (r.whereRaw != "" ? r.whereRaw : "(unnamed warehouse)")
        if (r.unmapped)
            unmapped .= (unmapped ? ", " : "") . r.whereRaw
        parts .= (parts ? ", " : "") . r.where . " " . r.qty
    }
    if (unmapped != "")
        SetSessState("ready", "new warehouse name, not in the map: " . unmapped)
    VerdictSet(rows)
    for i, r in rows
        LV_Add("", r.where, r.qty, StateGlyph(ROWSTATE[i]))
    RailSet(Money(first.normal), Money(first.vor), Money(first.sale), first.currency)
    ListFit(n)
    LASTSUMMARY := first.code . "  " . first.name . " | " . parts . " | total " . total
return

; Progress and failures borrow the session line; SessRestore() gives it back.
; The loading look: the bar sweeps, the button goes lighter steel and reads
; Working with dots that tick over every 400ms. StockQuery() sleeps between
; polls, so the timer gets its turns while the query is on.
BusySet(on) {
    global BUSYHWND, BUSYDOTS, LOOKHWND
    if (on) {
        BUSYDOTS := 0
        GuiControl,, QueryBtn, Working
        GuiControl, Show, BusyBar
        SendMessage, 0x40A, 1, 40, , ahk_id %BUSYHWND%     ; PBM_SETMARQUEE on, 40ms step
        SetTimer, BusyTick, 400
    } else {
        SetTimer, BusyTick, Off
        SendMessage, 0x40A, 0, 0, , ahk_id %BUSYHWND%
        GuiControl, Hide, BusyBar
        GuiControl,, QueryBtn, &Look up
    }
    DllCall("InvalidateRect", "Ptr", LOOKHWND, "Ptr", 0, "Int", 1)
}

SetStatus(msg) {
    GuiControl, +c808080, Sess
    GuiControl,, Sess, %msg%
}

; One state word, plain English after it, and a colour you can judge without
; reading it: green ready, amber working, red needs a human.
SetSessState(state, detail := "") {
    global SESSSTATE, SESSDETAIL
    SESSSTATE := state, SESSDETAIL := detail
    colour := (state = "ready") ? "c1B7F1B" : (state = "working") ? "cA35B00" : "cB00000"
    word   := (state = "ready") ? "Ready" : (state = "working") ? "Working" : "Not connected"
    GuiControl, +%colour%, Sess
    dot := A_IsUnicode ? Chr(0x25CF) " " : ""
    GuiControl,, Sess, % dot word (detail != "" ? "  -  " detail : "")
}

SessRestore() {
    global SESSSTATE, SESSDETAIL
    if (SESSSTATE != "")
        SetSessState(SESSSTATE, SESSDETAIL)
}

; Two decimals when it is a number, untouched when it is not (blank, or
; whatever the server sent instead).
Money(v) {
    if v is number
        return Format("{:.2f}", v)
    return v
}

; ---------------------------------------------------------------------------
; the header, the pill, the rail

; tag (the car series) is taken and ignored: the label that showed it is
; gone, and the copy summary never carried it.
HeaderSet(num, title, tag) {
    GuiControl,, PartNum, %num%
    GuiControl,, PartTitle, %title%
    GuiControl, % (num != "" ? "Show" : "Hide"), PartRule
}

; state "" hides it. Width is measured from the font, not guessed, because
; the amber word is a warehouse name and nobody knows the longest one.
PillSet(state, word, eta := "") {
    global PILLON, PILLHWND, PILLW, PILLH
    PILLON := (state != "")
    if (!PILLON) {
        Gui, Pill:Hide
        return
    }
    ww := PillTextW("PillWord", word)
    we := (eta != "") ? PillTextW("PillEta", eta) : 0
    PILLW := 35 + ((ww > we) ? ww : we)
    PILLH := (eta != "") ? 30 : 20
    Gui, Pill:Color, % StateBg(state)
    gl := StateInk(state, "glyph"), tx := StateInk(state, "text"), et := StateInk(state, "eta")
    GuiControl, Pill:+c%gl%, PillGlyph
    GuiControl, Pill:+c%tx%, PillWord
    GuiControl, Pill:+c%et%, PillEta
    tw := PILLW - 35
    GuiControl, Pill:Move, PillGlyph, % "y" ((eta != "") ? 6 : 1)
    GuiControl, Pill:Move, PillWord, % "y4 w" tw
    GuiControl, Pill:Move, PillEta, % "y17 w" tw
    GuiControl, Pill:, PillGlyph, % StateGlyph(state)
    GuiControl, Pill:, PillWord, %word%
    GuiControl, Pill:, PillEta, %eta%
    ; hard right at 470, centred in the 28px band under the title
    px := 470 - PILLW, py := 110 + (28 - PILLH) // 2
    Gui, Pill:Show, % "x" px " y" py " w" PILLW " h" PILLH " NoActivate"
    WinSet, Redraw, , ahk_id %PILLHWND%
}

; How wide is this string in the font that control actually uses?
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
    return w + 2          ; ClearType overhang past the reported extent
}

RailSet(normal, vor, sale, cur) {
    global RAILON
    RAILON := (normal != "" || sale != "")
    GuiControl,, Price1, %normal%
    GuiControl,, Price2, % (vor != "" ? vor : "-")
    GuiControl,, Price3, %sale%
    GuiControl,, PriceCur, %cur%
    for i, c in ["PriceRule", "PriceLbl1", "PriceLbl2", "PriceLbl3", "PriceCur", "Price1", "Price2", "Price3", "PriceNote"]
        GuiControl, % (RAILON ? "Show" : "Hide"), %c%
}

; ---------------------------------------------------------------------------
; row order, row state, the verdict

; Melbourne first, always; then the rest by quantity, most first, so the eye
; lands on where the part actually is.
SortMelbourneFirst(rows) {
    mel := [], other := []
    for i, r in rows {
        if InStr(r.where, "Melbourne")
            mel.Push(r)
        else
            other.Push(r)
    }
    n := other.Length()
    Loop, % n - 1 {
        Loop, % n - A_Index {
            j := A_Index
            if ((other[j].qty + 0) < (other[j + 1].qty + 0)) {
                t := other[j], other[j] := other[j + 1], other[j + 1] := t
            }
        }
    }
    out := []
    for i, r in mel
        out.Push(r)
    for i, r in other
        out.Push(r)
    return out
}

; The rules: Melbourne holding it is green with a tick, and then every other
; row is plain - nothing else matters once it is on the shelf here. Only when
; Melbourne has none does another warehouse holding it go amber with an
; hourglass (it has to travel); a warehouse with none while somebody has it is
; a quiet grey dot; and nothing anywhere turns every row red. The pill says
; the same thing before the eye reaches the rows.
VerdictSet(rows) {
    global ROWSTATE
    ROWSTATE := []
    anyStock := false, melHas := false
    for i, r in rows {
        if ((r.qty + 0) > 0)
            anyStock := true
        if (InStr(r.where, "Melbourne") && (r.qty + 0) > 0)
            melHas := true
    }
    pick := 0, pickWord := ""
    for i, r in rows {
        if (!anyStock)
            ROWSTATE[i] := "none"
        else if ((r.qty + 0) <= 0)
            ROWSTATE[i] := "dead"
        else if InStr(r.where, "Melbourne")
            ROWSTATE[i] := "stock"
        else
            ROWSTATE[i] := melHas ? "plain" : "wait"
        if (ROWSTATE[i] = "stock" && !pick)
            pick := i
    }
    if (!anyStock) {
        PillSet("none", "NO STOCK", "none at any warehouse")
        return
    }
    if (pick) {
        PillSet("stock", "MELBOURNE IN STOCK")
        return
    }
    ; not in Melbourne: name the first branch that has it - that is who to ring
    for i, r in rows {
        if (ROWSTATE[i] = "wait") {
            nm := RegExReplace(r.where, "i)\s*warehouse\s*$")
            PillSet("wait", Format("{:U}", nm), "available interstate")
            return
        }
    }
}

StateGlyph(state) {
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
    if (state = "plain")
        return ""               ; stocked elsewhere while Melbourne has it: no mark
    return Chr(0x25CF)          ; a quiet dot
}

StateBg(state) {
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

; the glyph carries a touch more saturation than the words beside it
StateInk(state, which) {
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

; ---------------------------------------------------------------------------
; the brand file: decoded from the base64 below into %TEMP%\byd-stock

BrandFiles() {
    global BRANDPNG
    dir := A_Temp . "\byd-stock"
    FileCreateDir, %dir%
    png := dir . "\byd-logo.png"
    if (B64ToFile(BydPngB64(), png))
        BRANDPNG := png
}

; CryptStringToBinaryW, flag 1 = CRYPT_STRING_BASE64: sized first, then filled.
B64ToFile(b64, path) {
    n := 0
    if (!DllCall("Crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1
               , "Ptr", 0, "UInt*", n, "Ptr", 0, "Ptr", 0) || n = 0)
        return false
    VarSetCapacity(buf, n, 0)
    if (!DllCall("Crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", 0, "UInt", 1
               , "Ptr", &buf, "UInt*", n, "Ptr", 0, "Ptr", 0))
        return false
    f := FileOpen(path, "w")
    if (!f)
        return false
    f.RawWrite(buf, n)
    f.Close()
    return true
}

; byd-logo.png: 64x13, the wordmark in black on the window grey
BydPngB64() {
    return ""
    . "iVBORw0KGgoAAAANSUhEUgAAAEAAAAANCAIAAACWzf87AAADR0lEQVR42q1Wv0t6bxR+f2UIFkRgQTa2dOdCaKghoSWXFhfD"
    . "aMhq0aFo05YoWhwtKKQp2iIiFbcIbvQP1NCgSUQavkX24/r++Azny0WM/F6hZ5DX47nnPO95zrlHRDuBy+Wan5+/v7/nnFcq"
    . "Fc55oVBACCGEIpEI57xarfK2AIdIJAJPFQoFsE9PT0P831IzxiilPp8vGo3m83nO+cvLS61WI7ITWJZ1dHQUCoUqlQohBP0d"
    . "3t/fIf5vqYUQUspyuZxOp4PB4Pr6OqVUa838fr/zNB8fH7e3tzc3N2tra5lM5q/Ya62BBqVUStnGs1QqPT4+Wpa1v7+PMd7a"
    . "2mLZbNZ5Js756OioEOLt7e0nCSGEUkopBRZCiH22oZSSUmqtW4zJZNIJgaenp0wms729zRjb29sbHh5mHZWqVCpJKZVS39/f"
    . "LT+5XC7GWqP9bDOXy2V/ttyhfWqMsdZ6cHBwY2Ojp6dnc3OTUppKpVg0GnWoMkLo6urKsiyEUCAQsO2UUoRQPp9/fX0Nh8ND"
    . "Q0Naa7fbPTAw8PDw0MwMgpyenuZyOcaY1tqWwslEYYxB4dXV1Ww2e3l5Wa1W2fHxcUciYIwRQrOzs/CVMQZdWywWi8XiyclJ"
    . "V1eXUmpkZOTw8HBqakoIgTEmhABdjLEQwo72U7T2gHsqpbq7u/+TPRQKOSk/xrhWq+VyOZDy7OwsFosJIQzDSCQSBwcH5XIZ"
    . "nBuNBkLo8/NTCNFoNKDGP0fT5/MtLi4ahmFr6BBKKcYY9LBlWZhz7vzhi4uLhYWFr6+viYmJ8/NzpRSU5Pn5uVwuw91AaI/H"
    . "gxDy+/1gnJubW1lZAX+w+Hw+r9frfAaa2ZumGQwGpZR9fX2dKTg5OUkIIYSAggAppdfrbWYDuLu7g/JrrePxuGEYLQ5SSrv2"
    . "DrcKISSdTqdSKa21lDIWi7GZmRnnF6jX6/Cu7O3ttYcSFkpzCZVSLV1Rr9dhHzUzhjPIkkwmTdP83z2gtb6+vobz0tLS8vIy"
    . "M02z070zNja2u7tr9w9MdjNjmNqWyoHDb+1umqZzJm63OxwO7+zsKKVYRwNEKQ2FQolEor+/XykFb6Q/gcfjgf88bRSAdIFA"
    . "IB6Pj4+PSykJIf8AbTVMI2Djyl0AAAAASUVORK5CYII="
}

; RRGGBB text -> the BBGGRR integer GDI wants
Bgr(hex) {
    v := "0x" hex
    v += 0
    return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

; ---------------------------------------------------------------------------
; fitting the window to what it holds

; A list is only as tall as the rows it holds - gridlines drawn across an
; empty tail read as warehouses that came back blank. Row pitch is measured
; from the control and sanity-checked, because LVM_GETITEMRECT can fail and
; leave the buffer holding the last thing written to it.
ListFit(rows) {
    global LVHWND
    static good := 0
    VarSetCapacity(rc, 16, 0)
    hHdr := DllCall("SendMessage", "Ptr", LVHWND, "UInt", 0x101F, "Ptr", 0, "Ptr", 0, "Ptr")
    DllCall("GetWindowRect", "Ptr", hHdr, "Ptr", &rc)
    hdrH := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    if (hdrH <= 0)
        hdrH := 22
    rowH := 0
    if (rows > 1) {
        VarSetCapacity(r0, 16, 0), VarSetCapacity(r1, 16, 0)
        NumPut(0, r0, 0, "Int"), NumPut(0, r1, 0, "Int")
        ok0 := DllCall("SendMessage", "Ptr", LVHWND, "UInt", 0x100E, "Ptr", 0, "Ptr", &r0)
        ok1 := DllCall("SendMessage", "Ptr", LVHWND, "UInt", 0x100E, "Ptr", 1, "Ptr", &r1)
        if (ok0 && ok1)
            rowH := NumGet(r1, 4, "Int") - NumGet(r0, 4, "Int")
    }
    if (rowH <= 0 && rows > 0) {
        VarSetCapacity(r0, 16, 0)
        NumPut(0, r0, 0, "Int")
        if DllCall("SendMessage", "Ptr", LVHWND, "UInt", 0x100E, "Ptr", 0, "Ptr", &r0)
            rowH := NumGet(r0, 12, "Int") - NumGet(r0, 4, "Int")
    }
    if (rowH < 12 || rowH > 40)
        rowH := good ? good : 20
    else
        good := rowH
    h := hdrH + rows * rowH + 4
    if (h > 260)
        h := 260
    GuiControl, Move, LV, % "h" h
    FitWindow()
}

; The window is only as tall as the table plus whatever is under it.
FitWindow() {
    global RAILON, PILLON, MAINHWND
    GuiControlGet, lv, Pos, LV
    bottom := lvY + lvH
    if (RAILON) {
        GuiControl, Move, PriceRule, % "y" (bottom + 12)
        Loop, 3 {
            GuiControl, Move, PriceLbl%A_Index%, % "y" (bottom + 20)
            GuiControl, Move, Price%A_Index%, % "y" (bottom + 18)
        }
        GuiControl, Move, PriceCur, % "y" (bottom + 20)
        GuiControl, Move, PriceNote, % "y" (bottom + 36)
        bottom += 50
    }
    if (bottom < 180)
        bottom := 180
    GuiControl, Move, Sess, % "y" (bottom + 14)
    ; Gui,Show is the only way to set the height, and a plain Show pops a
    ; minimised window open. This runs at startup and after every result,
    ; so ask the window whether it is minimised and keep it that way.
    if (MAINHWND && DllCall("IsIconic", "Ptr", MAINHWND))
        Gui, Show, % "Minimize w490 h" (bottom + 38)
    else
        Gui, Show, % "NoActivate w490 h" (bottom + 38)
    if (PILLON)
        DllCall("SetWindowPos", "Ptr", PILLHWND, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
}

; ---------------------------------------------------------------------------
; painting: the steel button and the tinted rows

; A Win32 button paints itself in the system's colours. BS_OWNERDRAW hands
; the painting to us: WM_DRAWITEM arrives at the parent and we fill it steel
; and write the caption in white.
OwnerDrawButton(h) {
    st := DllCall("GetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "Ptr", h, "Int", -16, "Ptr")
    DllCall("SetWindowLong" (A_PtrSize = 8 ? "Ptr" : ""), "Ptr", h, "Int", -16
          , "Ptr", (st & ~0xF) | 0xB)      ; BS_OWNERDRAW in the low nibble
    DllCall("InvalidateRect", "Ptr", h, "Ptr", 0, "Int", 1)
}

OnDrawItem(wParam, lParam, msg, hwnd) {
    global LOOKHWND, BUSY
    if (A_PtrSize = 8)
        oHwnd := 24, oDC := 32, oRc := 40
    else
        oHwnd := 20, oDC := 24, oRc := 28
    if (NumGet(lParam + 0, oHwnd, "Ptr") != LOOKHWND)
        return
    hdc   := NumGet(lParam + 0, oDC, "Ptr")
    state := NumGet(lParam + 0, 16, "UInt")   ; ODS_SELECTED 0x1, DISABLED 0x4
    ; disabled is beige, except while a query runs: then a lighter steel, so
    ; the button reads as "working" rather than "off"
    face := (state & 0x4) ? (BUSY ? 0x785A3D : 0xBEB4A8) : (state & 0x1) ? 0x52330F : 0x6B4617   ; #17466B steel
    edge := (state & 0x4) ? (BUSY ? 0x6B4617 : 0xA89C8E) : 0x52330F
    hb := DllCall("CreateSolidBrush", "UInt", face, "Ptr")
    DllCall("FillRect", "Ptr", hdc, "Ptr", lParam + oRc, "Ptr", hb)
    DllCall("DeleteObject", "Ptr", hb)
    hb := DllCall("CreateSolidBrush", "UInt", edge, "Ptr")
    DllCall("FrameRect", "Ptr", hdc, "Ptr", lParam + oRc, "Ptr", hb)
    DllCall("DeleteObject", "Ptr", hb)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)          ; TRANSPARENT
    DllCall("SetTextColor", "Ptr", hdc, "UInt", ((state & 0x4) && !BUSY) ? 0xF0F0F0 : 0xFFFFFF)
    VarSetCapacity(txt, 260 * 2, 0)
    DllCall("GetWindowText", "Ptr", LOOKHWND, "Str", txt, "Int", 256)
    DllCall("DrawText", "Ptr", hdc, "Str", txt, "Int", -1, "Ptr", lParam + oRc, "UInt", 0x25)   ; centre, no NOPREFIX so &L underlines
    return true
}

; ---- WM_NOTIFY / NM_CUSTOMDRAW. The list asks its parent before it paints;
; we answer once per row (ground and ink) and once per cell, because the
; glyph column carries more saturation than the words beside it. The struct
; is REUSED for every cell, so every branch sets clrText and none falls
; through. Every early return is a BARE return: a value returned from a
; WM_NOTIFY monitor becomes the message result, and swallowing the ones meant
; for other controls breaks them. Offsets follow A_PtrSize so the same file
; runs under 32- and 64-bit AutoHotkey.
OnLvNotify(wParam, lParam, msg, hwnd) {
    global LVHWND, ROWSTATE
    if (NumGet(lParam + 0, 0, "Ptr") != LVHWND)
        return
    if (NumGet(lParam + 0, 2 * A_PtrSize, "Int") != -12)          ; NM_CUSTOMDRAW
        return
    oStage := (A_PtrSize = 8) ? 24 : 12
    oItem  := (A_PtrSize = 8) ? 56 : 36
    oText  := (A_PtrSize = 8) ? 80 : 48
    oBack  := (A_PtrSize = 8) ? 84 : 52
    oSub   := (A_PtrSize = 8) ? 88 : 56
    stage := NumGet(lParam + 0, oStage, "UInt")
    if (stage = 1)                                             ; CDDS_PREPAINT
        return 0x20                                     ; CDRF_NOTIFYITEMDRAW
    row := NumGet(lParam + 0, oItem, "UPtr") + 1
    st := ROWSTATE[row]
    if (st = "")
        st := "dead"
    if (stage = 0x10001) {                                ; CDDS_ITEMPREPAINT
        if (st != "dead" && st != "plain") {
            NumPut(Bgr(StateInk(st, "text")), lParam + 0, oText, "UInt")
            NumPut(Bgr(StateBg(st)),          lParam + 0, oBack, "UInt")
        }
        return 0x20                                  ; CDRF_NOTIFYSUBITEMDRAW
    }
    if (stage != 0x30001)                    ; CDDS_SUBITEM|CDDS_ITEMPREPAINT
        return
    if (NumGet(lParam + 0, oSub, "Int") = 2)
        NumPut(Bgr((st = "dead" || st = "plain") ? "B4B4B4" : StateInk(st, "glyph")), lParam + 0, oText, "UInt")
    else if (st = "dead" || st = "plain")
        NumPut(0xFF000000, lParam + 0, oText, "UInt")             ; CLR_DEFAULT
    else
        NumPut(Bgr(StateInk(st, "text")), lParam + 0, oText, "UInt")
    return 0x2                                                 ; CDRF_NEWFONT
}

; ---------------------------------------------------------------------------
; the query

; Returns {ok, err, rows}. rows[i] = {code, name, series, where, qty, normal,
; vor, sale, currency}. Asks for a session cookie when the server says the
; current one is dead, and tries once more with the new one.
StockQuery(code) {
    global SID, LOGUSER, ENDPOINT, ROUTE, NOBROWSER, BROWSERWHY
    ROUTE := "", BROWSERWHY := ""

    ; ---- THE BROWSER FIRST, BECAUSE IT NEEDS NO COOKIE. The DMS tab is
    ; already signed in, so the query is run as a fetch() inside that page and
    ; Chrome attaches the session itself. Nothing here ever sees JSESSIONID,
    ; nothing is stored, and a session that rolls over is not our problem.
    if (!NOBROWSER) {
        berr := ""
        body := ""
        ; Twice at most: the second pass is for a session that died while the
        ; tab still sat on main.html, which only the query itself can notice.
        Loop, 2 {
            if (!CdpEnsureLogin(berr))
                break
            body := CdpStock(code, berr)
            if (body != "" || !InStr(berr, "signed out"))
                break
            CdpEval("location.href='/'")     ; back to the login form for pass two
            Sleep, 500
        }
        if (body != "") {
            ROUTE := "browser"
            return ParseStock(body)
        }
        BROWSERWHY := berr
    }

    ; ---- the cookie route, unchanged, for when no DMS browser is running
    ROUTE := "cookie"
    post := "PART_CODE=" . UriEncode(code) . "&page=1&start=0&limit=100"
    if (LOGUSER != "")
        post .= "&logUser=" . UriEncode(LOGUSER)
    Loop, 2 {
        if (SID = "") {
            ; The browser route was tried and said why; a cookie prompt on top
            ; of that would only be a second question about the same login.
            if (BROWSERWHY != "")
                return {ok: false, err: BROWSERWHY}
            if (!AskSession())
                return {ok: false, err: "No session. Session > Sign in again, or paste a JSESSIONID."}
        }
        status := 0, sess := ""
        body := HttpPost(ENDPOINT, post, status, sess)
        if (body = "" && status = 0)
            return {ok: false, err: "No answer from oadms.byd.com (offline, or not on the dealer network)."}
        if (sess = "timeout" || status = 404) {
            SID := ""
            if (A_Index = 2)
                return {ok: false, err: "Session still rejected. Is the DMS tab itself logged in?"}
            continue
        }
        if (sess = "limit")
            return {ok: false, err: "Server rate limit: wait a minute before the next query."}
        if (sess = "aready")
            return {ok: false, err: "Server says another login took over this browser session. Re-login in Chrome, then paste the new cookie."}
        if (status != 200)
            return {ok: false, err: "HTTP " . status}
        return ParseStock(body)
    }
}

; Both routes hand their body here, so there is one reader and the two cannot
; drift apart. EN_LOCATION is only ever present on the browser route: the page
; resolved the warehouse name with the DMS's own dictionary, which beats
; WarehouseName()'s guesswork - see the note above it.
ParseStock(body) {
    if (!RegExMatch(body, """success""\s*:\s*true")) {
        msg := JVal(body, "message")
        return {ok: false, err: "DMS said: " . (msg != "" ? msg : SubStr(body, 1, 200))}
    }
    rows := []
    for i, obj in JsonDataObjects(body) {
        en := JVal(obj, "EN_LOCATION")
        raw := JVal(obj, "SUB_LOCATION")
        where := (en != "" ? en : WarehouseName(raw))
        ; unmapped: neither the page's dictionary nor WarehouseName() turned
        ; the whole name into English - some CJK is left in it.
        rows.Push({ code: JVal(obj, "PART_CODE")
                  , name: JVal(obj, "PART_NAME")
                  , series: JVal(obj, "USED_CAR_SERIES")
                  , where: where
                  , whereRaw: raw
                  , unmapped: (raw != "" && RegExMatch(where, "[\x{4E00}-\x{9FFF}]") > 0)
                  , qty: JVal(obj, "STOCK_COUNT")
                  , normal: JVal(obj, "NORMAL_ORDER_PRICE")
                  , vor: JVal(obj, "URGENT_ORDER_PRICE")
                  , sale: JVal(obj, "SALE_PRICE")
                  , currency: JVal(obj, "CURRENCY_CODE") })
    }
    return {ok: true, rows: rows}
}

; The value is accepted bare, as "JSESSIONID=...", or as a whole pasted Cookie
; header - whichever the user grabbed.
AskSession() {
    global SID
    InputBox, v, BYD stock - session cookie
        , % "The DMS wants a live session. In the DMS tab press F12, then`n"
          . "Application > Cookies > https://oadms.byd.com > JSESSIONID,`n"
          . "and paste the Value here. It is kept for this run only."
        , , 560, 210
    if (ErrorLevel)
        return false
    if RegExMatch(v, "i)JSESSIONID\s*=\s*([0-9A-Za-z!_\-]{16,})", m)
        sid := m1
    else if RegExMatch(v, "^\s*([0-9A-Za-z!_\-]{16,})\s*$", m)
        sid := m1
    else
        return false
    SID := sid
    return true
}

; Form-encoded POST with the session cookie. status comes back 0 when the
; connection itself failed. sess is the DMS's own "sessionstatus" header, or
; "" when the server sent none.
HttpPost(path, body, ByRef status, ByRef sess) {
    global BASE, SID
    status := 0, sess := ""
    try {
        req := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(5000, 5000, 10000, 30000)
        req.Option(6) := false                       ; no redirect following - a bounce to index.html is a signal
        req.Open("POST", BASE . path, false)
        req.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
        req.SetRequestHeader("X-Requested-With", "XMLHttpRequest")
        req.SetRequestHeader("Accept", "application/json, text/javascript, */*")
        if (SID != "")
            req.SetRequestHeader("Cookie", "JSESSIONID=" . SID)
        req.Send(body)
        status := req.Status
        try sess := req.GetResponseHeader("sessionstatus")   ; throws when absent
        return BodyUtf8(req.ResponseBody)
    } catch e {
        return ""
    }
}

; ResponseText guesses the charset; the DMS is UTF-8, so decode the bytes.
BodyUtf8(bin) {
    st := ComObjCreate("ADODB.Stream")
    st.Type := 1
    st.Open()
    st.Write(bin)
    st.Position := 0
    st.Type := 2
    st.Charset := "utf-8"
    txt := st.ReadText()
    st.Close()
    return txt
}

UriEncode(s) {
    out := ""
    Loop, Parse, s
    {
        c := A_LoopField
        if RegExMatch(c, "[A-Za-z0-9\-_.~]")
            out .= c
        else {
            VarSetCapacity(buf, 8, 0)
            n := StrPut(c, &buf, "UTF-8") - 1
            Loop, % n
                out .= Format("%{:02X}", NumGet(buf, A_Index - 1, "UChar"))
        }
    }
    return out
}

; ---------------------------------------------------------------------------
; warehouse names

; Exact map first. "?????" is literally "Australia branch office"; it is
; Melbourne by elimination - the web grid names Melbourne, Perth, Brisbane and
; Sydney, and the other three sites carry their city in the name.
WarehouseName(cn) {
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

; ---------------------------------------------------------------------------
; just enough JSON: the objects of the top-level "data" array, and one scalar
; field out of an object. AHK v1 has no JSON; the response is flat rows, so a
; bracket walk that respects strings is all it takes.

JsonDataObjects(body) {
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

JVal(obj, key) {
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

; ---------------------------------------------------------------------------

; --selftest [file]: stdout by default, a file when the caller's stdout is
; not a console (the GUI-subsystem exe drops it in some shells)
SelfTest(outFile := "") {
    sample := "{""success"":true,""total"":2,""data"":[{""PART_ID"":123,""PART_CODE"":""15079287-00"",""PART_NAME"":""Three-phase 11KW AC charging box assy.-English ve\""quoted\"""",""USED_CAR_SERIES"":""SEALION 8 DM-RIGHT"",""MODEL_IDS"":""A,B"",""SUB_LOCATION"":""Melbourne warehouse"",""SUB_LOCATION_ID"":""7"",""STOCK_COUNT"":""793"",""NORMAL_ORDER_PRICE"":""508.8"",""URGENT_ORDER_PRICE"":null,""SALE_PRICE"":""726.36"",""CURRENCY_CODE"":""AUD""},{""PART_CODE"":""15079287-00"",""PART_NAME"":""x"",""SUB_LOCATION"":""Perth warehouse"",""STOCK_COUNT"":123,""NORMAL_ORDER_PRICE"":508.8}]}"
    objs := JsonDataObjects(sample)
    out := "objects: " . objs.Length() . "`n"
    for i, o in objs
        out .= JVal(o, "SUB_LOCATION") . " | " . JVal(o, "STOCK_COUNT") . " | " . JVal(o, "NORMAL_ORDER_PRICE") . " | " . JVal(o, "URGENT_ORDER_PRICE") . " | " . JVal(o, "PART_NAME") . "`n"
    out .= "uri: " . UriEncode("15079287-00 a/b") . "`n"
    for i, cn in ["??????", "?????", "??????", "????????", "?????????", "????"]
        out .= "wh: " . cn . " -> " . WarehouseName(cn) . "`n"
    if (outFile != "")
        FileAppend, %out%, %outFile%
    else
        FileAppend, %out%, *
}


; ===========================================================================
; THE BROWSER ROUTE - no cookie, ever
; ---------------------------------------------------------------------------
; ---- WHY THIS EXISTS. The cookie route below needs a JSESSIONID pasted out
; of DevTools, and that value is the login. It also dies on its own schedule,
; so the paste is not a one-off. Every way of reading the cookie back out of
; Chrome is closed on this machine, and each for its own reason:
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
;
; ---- STILL OPTIONAL. If the browser cannot be started the script falls
; straight back to the pasted cookie and behaves exactly as it did before.
; Set NOBROWSER := true at the top to skip the browser route entirely.
; ===========================================================================

; Chrome first, Edge after it. Edge is Chromium with the same DevTools
; protocol and the same Chrome_WidgetWin_1 window class, and it is on every
; Windows 11 box, so a machine with no Chrome still gets the browser route.
ChromeExe() {
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
CdpHttp(path) {
    global CPORT
    try {
        whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://127.0.0.1:" . CPORT . path, true)
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
; keeps it that way: the window is only ever shown by ShowDms().
LaunchDmsChrome(ByRef err) {
    global CPORT, CPROFILE, BASE, CHWND
    if (InStr(CdpHttp("/json/version"), "webSocketDebuggerUrl"))
        return true
    exe := ChromeExe()
    if (exe = "") {
        err := "Could not find chrome.exe or msedge.exe."
        return false
    }
    FileCreateDir, %CPROFILE%
    args := " --remote-debugging-port=" . CPORT
          . " --user-data-dir=""" . CPROFILE . """"
          . " --remote-allow-origins=*"
          . " --no-first-run --no-default-browser-check"
          . " " . BASE
    Run, %exe%%args%, , UseErrorLevel, pid
    if ErrorLevel {
        err := "Chrome would not start."
        return false
    }
    ; Chrome opens its window before the page is up; hide it the moment it
    ; exists. One flash at most, and only on the first launch. The process
    ; owns several Chrome_WidgetWin_1 windows, most of them titleless helpers,
    ; so only the titled one is the browser - and CHWND is left for
    ; DmsWindow() to settle by its own, surer method.
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
DmsWindow() {
    global CPORT, CHWND
    if (CHWND && WinExist("ahk_id " . CHWND))
        return CHWND
    CHWND := 0
    mark := "BydStock " . CPORT
    old := CdpEval("(function(){var t=document.title;document.title='" . mark . "';return t;})()")
    Loop, 20 {
        WinGet, hw, ID, %mark% ahk_class Chrome_WidgetWin_1
        if (hw)
            break
        Sleep, 100
    }
    CdpEval("document.title='" . JsStr(old) . "'")
    if (hw)
        CHWND := hw
    return CHWND
}

ShowDms() {
    hw := DmsWindow()
    if (!hw)
        return false
    WinShow, ahk_id %hw%
    WinActivate, ahk_id %hw%
    return true
}

HideDms() {
    hw := DmsWindow()
    if (hw)
        WinHide, ahk_id %hw%
}

; ---- THE LOGIN FLOW. True when a DMS tab is signed in, launching, filling
; and waiting as needed. The only thing it will not do is read the picture.
CdpEnsureLogin(ByRef err) {
    global CSOCK, LUSER, LPASS
    err := ""
    if (!CdpAttach(err)) {
        if (!LaunchDmsChrome(err))
            return false
        Loop, 60 {                        ; the tab takes a moment to list
            Sleep, 250
            if (CdpAttach(err))
                break
        }
        if (!CSOCK)
            return false
    }
    path := CdpEval("location.pathname")
    if (InStr(path, "main.html"))
        return true
    if (InStr(path, "poseSel")) {
        ShowDms()
        SetStatus("The DMS wants a position picked - choose one in its window.")
        return WaitForMain(err)
    }
    if (LUSER = "" || LPASS = "") {
        if (!AskLogin()) {
            err := "No DMS login saved."
            return false
        }
    }
    ; Anywhere but the login form (a sign-out landing, an error page): go to
    ; the form and wait for its fields, because that is all the fill can use.
    if (CdpEval(JsHasLoginForm()) != "yes") {
        CdpEval("location.href='/'")
        Loop, 40 {
            Sleep, 250
            if (CdpEval(JsHasLoginForm()) = "yes")
                break
        }
    }
    r := CdpEval(JsFillLogin(LUSER, LPASS))
    if (r != "FILLED") {
        err := "Could not reach the DMS login form" . (r != "" ? " (" . r . ")" : "") . "."
        return false
    }
    ShowDms()
    CdpEval("document.getElementById('checkCode').focus()")   ; again, now that the window can take focus
    SetStatus("Type the picture code in the DMS window and press Enter.")
    return WaitForMain(err)
}

; Polls the tab's URL until the DMS lands on main.html, then hides the window
; again. Four minutes is long enough to misread the picture twice. A wrong
; code just leaves the page where it is, so the wait simply continues.
WaitForMain(ByRef err) {
    Loop, 480 {                           ; 500ms x 480 = 4 min
        Sleep, 500
        path := CdpEval("location.pathname")
        if (path = "") {                  ; mid-navigation, or the socket dropped
            e2 := ""
            CdpAttach(e2)
            continue
        }
        if (InStr(path, "main.html")) {
            HideDms()
            return true
        }
        if (InStr(path, "poseSel"))
            SetStatus("The DMS wants a position picked - choose one in its window.")
    }
    err := "The DMS login was not completed."
    return false
}

; Only reached if LUSER or LPASS at the top is blank. Held for this run only;
; the lasting fix is to fill the two lines in. The password box is masked.
AskLogin() {
    global LUSER, LPASS
    InputBox, u, BYD stock - DMS login, % "DMS username (the same one used in Chrome).`n"
        . "Kept for this run only - fill LUSER and LPASS in the script to keep it.", , 460, 170, , , , , %LUSER%
    if (ErrorLevel || Trim(u) = "")
        return false
    InputBox, p, BYD stock - DMS login, % "DMS password for " . Trim(u) . ".", HIDE, 460, 150
    if (ErrorLevel || p = "")
        return false
    LUSER := Trim(u), LPASS := p
    return true
}

JsHasLoginForm() {
    return "(document.getElementById('userName')&&document.getElementById('passWord')&&document.getElementById('checkCode'))?'yes':'no'"
}

; Fills the two fields a script can, ticks the privacy box login() checks,
; clears the captcha field and puts the cursor in it. The values are JS string
; literals, so JsStr() closes the injection door the same way CdpStock()'s
; character whitelist does for part codes.
JsFillLogin(user, pass) {
    return ""
    . "(function(){"
    .   "var u=document.getElementById('userName'),p=document.getElementById('passWord'),c=document.getElementById('checkCode');"
    .   "if(!u||!p||!c)return 'NOFORM';"
    .   "u.value='" . JsStr(user) . "';p.value='" . JsStr(pass) . "';"
    .   "var d=document.getElementById('READ_AND_AGREE_CHECKBOX');if(d)d.checked=true;"
    .   "c.value='';c.focus();"
    .   "return 'FILLED';"
    . "})()"
}

; For a single-quoted JS literal. CdpEsc() then wraps the whole expression for
; JSON, and it escapes backslashes first, so the two layers do not collide.
JsStr(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, "'", "\'")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    return s
}

; Attach to a signed-in DMS tab. Reuses the socket when it still answers, so a
; run of queries costs one handshake, not one per part.
CdpAttach(ByRef err) {
    global CPORT, CSOCK
    if (CSOCK) {
        if (CdpEval("'pong'") = "pong")
            return true
        WS_Close(CSOCK), CSOCK := 0
    }
    list := CdpHttp("/json/list")
    if (list = "") {
        err := "No DMS browser on port " . CPORT . "."
        return false
    }
    pos := 1
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (!InStr(blk, "oadms.byd.com") || !InStr(blk, """page"""))
            continue
        if !RegExMatch(blk, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/page/[^""]+)""", wm)
            continue
        s := WS_Connect("127.0.0.1", CPORT, wm1)
        if (!s)
            continue
        CSOCK := s
        if (CdpEval("'pong'") = "pong")
            return true
        WS_Close(CSOCK), CSOCK := 0
    }
    err := "DMS browser is open but has no oadms.byd.com tab."
    return false
}

; The whole point of the file: the response body, fetched by the page itself.
; Returns "" with err set on any failure, and every failure is survivable -
; StockQuery() falls back to the cookie route.
CdpStock(code, ByRef err) {
    err := ""
    ; Also the injection guard: this goes into a JavaScript string literal, and
    ; a code that cannot contain a quote cannot close one.
    safe := RegExReplace(code, "[^0-9A-Za-z\-]")
    if (safe = "") {
        err := "Nothing usable in that code."
        return ""
    }
    if (!CdpAttach(err))
        return ""
    if (CdpEval(JsFetch(safe)) != "STARTED") {
        err := "The DMS tab would not start the query."
        return ""
    }
    ; Ten seconds, not thirty: a counter query that has not answered by then
    ; is not going to, and the status line should say so rather than spin.
    ; At four seconds the login is checked once - a dead session is the usual
    ; reason for silence - and "signed out" in err sends StockQuery() back
    ; through the login, captcha window and all.
    t0 := A_TickCount, probed := false
    Loop {
        Sleep, 250
        r := CdpEval(JsPoll())
        if (r = "") {
            err := "Lost the DMS tab mid-query."
            return ""
        }
        if (r = "WAIT" || r = "NONE") {
            waited := A_TickCount - t0
            if (waited >= 10000) {
                err := "The DMS did not answer within 10 seconds."
                return ""
            }
            if (waited >= 4000 && !probed) {
                probed := true
                SetStatus("The DMS is slow to answer - checking the login ...")
                if (!CdpSignedIn()) {
                    err := "The DMS browser is signed out - signing in again."
                    return ""
                }
                SetStatus("Still signed in - waiting on the DMS ...")
            }
            continue
        }
        p := StrSplit(B64Utf8(r), Chr(1))
        st := p[1], http := p[2], sess := p[3], payload := p[4]
        if (st = "ERR") {
            err := "The page's own fetch failed: " . payload
            return ""
        }
        if (sess = "timeout" || http = 404) {
            err := "The DMS browser is signed out - sign in again in that window."
            return ""
        }
        if (sess = "limit") {
            err := "Server rate limit: wait a minute."
            return ""
        }
        if (sess = "aready") {
            err := "Another login took that session over."
            return ""
        }
        if (http != 200) {
            err := "HTTP " . http . " from the DMS."
            return ""
        }
        return payload
    }
}

; Is the DMS tab still signed in? Two looks: where the tab is - anything but
; main.html means the server bounced it - and then the page fetched again by
; the page itself, which a dead session answers with the login form or the
; "sessionstatus: timeout" header. Three seconds at most; when the probe
; itself cannot say, the tab is taken to be signed in and the query wait
; carries on, since a wrong "signed out" would throw a live login away.
CdpSignedIn() {
    path := CdpEval("location.pathname")
    if (path != "" && !InStr(path, "main.html"))
        return false
    if (CdpEval(JsProbe()) != "STARTED")
        return true
    Loop, 12 {                        ; 250ms x 12 = 3s
        Sleep, 250
        r := CdpEval("(function(){var d=window.__bp;return d?d.s:'NONE';})()")
        if (r = "IN")
            return true
        if (r = "OUT")
            return false
        if (r != "WAIT")
            return true
    }
    return true
}

JsProbe() {
    return ""
    . "(function(){"
    .   "window.__bp={s:'WAIT'};"
    .   "try{"
    .     "fetch(location.href,{credentials:'same-origin',cache:'no-store'})"
    .     ".then(function(r){"
    .       "var ss=r.headers.get('sessionstatus')||'';"
    .       "return r.text().then(function(t){"
    .         "var out=(ss=='timeout'||r.status==404||t.indexOf('checkCode')>=0||t.indexOf('passWord')>=0);"
    .         "window.__bp.s=out?'OUT':'IN';"
    .       "});"
    .     "})"
    .     ".catch(function(e){window.__bp.s='ERR';});"
    .   "}catch(e){window.__bp.s='ERR';}"
    .   "return 'STARTED';"
    . "})()"
}

; ---- WHY THE PAGE ALSO TRANSLATES. The action returns SUB_LOCATION in
; Chinese and the grid shows English only because it looks the id up with the
; app's own getLang(). In here that function is in scope, so the names come
; back the way the dealer reads them on the web page - which beats
; WarehouseName()'s by-hand map, and settles the one entry that map had to
; guess. If getLang is missing the rows are passed through untouched and the
; map takes over.
JsFetch(code) {
    global ENDPOINT
    return ""
    . "(function(){"
    .   "window.__bs={s:'WAIT'};"
    .   "try{"
    .     "fetch('/" . ENDPOINT . "',{method:'POST',credentials:'same-origin',"
    .       "headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8','X-Requested-With':'XMLHttpRequest'},"
    .       "body:'PART_CODE=" . code . "&page=1&start=0&limit=100'})"
    .     ".then(function(r){window.__bs.http=r.status;window.__bs.sess=r.headers.get('sessionstatus')||'';return r.text();})"
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
    .       "window.__bs.body=t;window.__bs.s='OK';"
    .     "})"
    .     ".catch(function(e){window.__bs.err=String(e);window.__bs.s='ERR';});"
    .   "}catch(e){window.__bs.err=String(e);window.__bs.s='ERR';}"
    .   "return 'STARTED';"
    . "})()"
}

; ---- BASE64 ON THE WAY BACK, AND IT IS NOT DECORATION. CdpEval() reads the
; result with a regex that stops at the first quote, and a JSON body is made of
; quotes. Base64 has none, so the body survives the trip whole. Chr(1)
; separates the fields: a control character, so nothing in a part name or a
; warehouse name can split a record by accident.
JsPoll() {
    return ""
    . "(function(){"
    .   "var d=window.__bs;"
    .   "if(!d)return 'NONE';"
    .   "if(d.s=='WAIT')return 'WAIT';"
    .   "var p=d.s+'\u0001'+(d.http||'')+'\u0001'+(d.sess||'')+'\u0001'"
    .     "+(d.s=='ERR'?(d.err||''):(d.body||''));"
    .   "return btoa(unescape(encodeURIComponent(p)));"
    . "})()"
}

B64Utf8(b64) {
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

CdpEsc(s) {
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
CdpCmd(method, paramsJson) {
    global CSOCK, CDPID
    if (!CSOCK)
        return ""
    id := ++CDPID
    if !WS_SendText(CSOCK, "{""id"":" . id . ",""method"":""" . method . """,""params"":" . paramsJson . "}")
        return ""
    Loop, 500 {
        r := WS_Recv(CSOCK)
        if (r = "") {
            WS_Close(CSOCK)
            CSOCK := 0
            return ""
        }
        if (RegExMatch(r, """id""\s*:\s*" . id . "\b"))
            return r
        ; an event, or somebody else's id - keep reading
    }
    return ""
}

CdpEval(js) {
    r := CdpCmd("Runtime.evaluate", "{""expression"":""" . CdpEsc(js) . """,""returnByValue"":true}")
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
WS_Startup() {
    static done := 0
    if (done)
        return
    VarSetCapacity(wsadata, 408, 0)
    DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", &wsadata)
    done := 1
}

; TCP connect plus the upgrade handshake for `path`. Socket handle, or 0.
WS_Connect(host, port, path) {
    WS_Startup()
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
        WS_Close(sock)
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
    if !WS_SendRaw(sock, req) {
        WS_Close(sock)
        return 0
    }
    resp := ""
    Loop {
        chunk := WS_RecvSome(sock, 1)
        if (chunk = "")
            break
        resp .= chunk
        if (InStr(resp, "`r`n`r`n") || StrLen(resp) > 8192)
            break
    }
    if !InStr(resp, " 101 ") {
        WS_Close(sock)
        return 0
    }
    return sock
}

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

; up to `max` bytes back as one char per byte, for reading the handshake
WS_RecvSome(sock, max) {
    VarSetCapacity(b, max, 0)
    n := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", &b, "Int", max, "Int", 0, "Int")
    if (n <= 0)
        return ""
    return StrGet(&b, n, "CP0")
}

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

WS_SendText(sock, text) {
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
    return WS_SendBuf(sock, &frame, total)
}

; one whole application message, handling fragments, pings and close
WS_Recv(sock) {
    latin1 := ""
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
            len := (NumGet(e, 0, "UChar") << 8) | NumGet(e, 1, "UChar")
        } else if (len = 127) {
            if !WS_RecvN(sock, 8, e)
                return ""
            len := 0
            Loop 8
                len := (len * 256) + NumGet(e, A_Index - 1, "UChar")
        }
        if (masked) {
            if !WS_RecvN(sock, 4, mk)
                return ""
        }
        if (len > 0) {
            if !WS_RecvN(sock, len, pb)
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
                WS_Pong(sock, &pb, len)
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

WS_Pong(sock, ptr, len) {
    total := 2 + 4 + len
    VarSetCapacity(f, total, 0)
    NumPut(0x8A, f, 0, "UChar")
    NumPut(0x80 | (len < 126 ? len : 0), f, 1, "UChar")
    NumPut(0,f,2,"UChar"), NumPut(0,f,3,"UChar"), NumPut(0,f,4,"UChar"), NumPut(0,f,5,"UChar")
    Loop %len%
        NumPut(NumGet(ptr, A_Index - 1, "UChar") ^ 0, f, 6 + A_Index - 1, "UChar")
    WS_SendBuf(sock, &f, total)
}

WS_Close(sock) {
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