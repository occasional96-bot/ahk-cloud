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
;   RegoCheckSolo.ahk tabs <hwnd> <file>    one window's tab titles, exit
;   RegoCheckSolo.ahk selectin <hwnd> <brand> <loose>   pick a tab in ONE window
;
; The last two are the sweep's own helpers, one window each, for the same
; once-per-process reason - a sweep looking at a second browser window has to
; send a second process to do it.
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
;
; Isuzu's catalog is EQ-HIT on isuzu.snaponepc.com and it wears two different
; titles depending on where it is up to: "EQ-Hit EPC" once a session is live,
; and "global.applicationName.isuzu" - an untranslated resource key - sitting on
; the login page. The first carries no brand word at all, which is why EQ-Hit
; has to be listed in its own right rather than left to the word Isuzu.
;
; Pentana used to be listed here and is not any more. It is the dealership
; management system - "Pentana XT Client", "PENTANA MDS Enterprise", on
; idserp.iua.net.au - and while that IS an Isuzu system it holds no parts
; catalog at all, so a tab on it lit the Isuzu box and the jump then landed on
; a page with no VIN box to fill.
global CP_WORDS := { kia:     ["\bkia\b"]
                   , hyundai: ["\bhyundai\b", "\bgenesis\b"]
                   , isuzu:   ["\beq.?hit\b", "\bisuzu\b"]
                   , byd:     ["\bbyd\b"] }

; Titles that name a brand but are NOT that brand's catalog. Checked before the
; words above and only for the brand they are listed under, so a tab vetoed here
; is simply not a candidate rather than being pushed down the order.
;
; Isuzu UTE's Extranet is the one that matters: it says "Isuzu" twice over, it
; is usually open beside the catalog, and whichever of the two sits further left
; in the tab strip is the one the jump used to take - so the search would land
; on the dealer portal, find no VIN box and give up. Matched against the
; punctuation-stripped title, same as CP_VETO.
;
; Pentana is here as well as being off the word list, for the title that names
; both - "Isuzu Pentana MDS" and the like would otherwise come back through the
; word Isuzu.
; BYD-DMS is the same story on the BYD side: oadms.byd.com, the dealer
; management system, whose title reads "BYD-DMS" and matches the word BYD
; as readily as the catalog does. It holds no parts catalog either.
global CP_ANTI := { isuzu: ["extranet", "pentana"]
                  , byd:   ["dms"] }

; Brands whose word turns up all over a dealership's browser on pages that are
; NOT the catalog - the public site, the dealer portal, the warranty system, a
; parts price list - and where an ANTI list would have to grow forever to keep
; up. For these the word alone is not enough: the title has to look like a
; catalog as well, which is what CP_MaybeCatalog reads.
;
; This is what had a VIN going into the wrong Hyundai tab. "Hyundai" in any
; title matched, the tab was brought forward, and its URL named no brand at
; all - not a contradiction - so it was accepted and the VIN was typed into
; whatever box that page happened to have.
global CP_MUSTCAT := { kia: true, hyundai: true }

; The host a brand's catalog must be on, as a plain substring of the URL. Only
; the brands whose sites are a real risk are listed; a brand not named here is
; not host-checked. Kia and Hyundai are both Microcat, so the host does not
; tell those two apart - CP_URLMARK does that - but it does tell either of
; them from the rest of the brand's own web estate.
global CP_HOST := { kia:     "microcat"
                  , hyundai: "microcat"
                  , byd:     "bydauto" }

; A word the title itself must carry before the brand word counts, for the
; brands whose name alone is not enough. BYD TIS - the parts catalog - says
; TIS in its title; BYD-DMS and the rest of the BYD estate do not. This is
; the third tell on top of the DMS veto and the bydauto host, and it is the
; only one that works on a tab that is never brought forward, since a tab's
; URL cannot be read until it is showing.
;
; A tab with a car loaded is not lost if the title stops saying it: the VIN
; in the title is read below and LC0/LGX/LC6 names BYD on its own.
global CP_MUSTSAY := { byd: ["tis"] }

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

; The browsers looked in, best first. This IS the preference order: a catalog
; open in Chrome is the one that gets used, and Edge or Firefox only answer for
; a brand Chrome has not got open. The catalogs live in Chrome; the other two
; are there for the day one of them does not.
global CP_EXES := ["chrome.exe", "msedge.exe", "firefox.exe"]

global CP_OUT := A_ScriptDir . "\CatalogProbe.txt"
global CP_TRACE := ""
global CP_pUia := 0

; Whether this process has spent its one tab-strip read - see CP_TabsOf.
global CP_READ := false


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
; The two one-window jobs. A browser hands its tab strip to a client process
; once and once only, so a sweep that has to look at a second window sends one
; of these to do it - a process whose one read is still unspent. See CP_TabsOf.
if (A_Args.Length() >= 3 && A_Args[1] = "tabs") {
    CP_TabsOut(A_Args[2], A_Args[3])
    ExitApp
}
if (A_Args.Length() >= 4 && A_Args[1] = "selectin") {
    ExitApp, % CP_SelectIn(A_Args[2], A_Args[3], A_Args[4] = "1") ? 0 : 1
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
; AutoHotkey and WinHTTP only - the WinHttpRequest object, asked async and
; polled, so the window keeps taking clicks while a website thinks (the
; transport is lib\AudosHttp.ahk). No browser.
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

; The Isuzu dealer system, IDS. This is the factory's own record of a truck,
; so for an Isuzu it is asked before anybody else and the tyre shops only fill
; what it left blank. The sign-in is shared with IsuzuVIN.ahk in the folder
; beside this one - one Chrome, one session, one login between the two apps -
; and the whole of it lives at the bottom of this file under RC_Ids. Plain
; text by necessity, same as the account above: keep this file to yourself.
global RC_IDS_USER := "D7334KT"
global RC_IDS_PW   := "aB7xK2qLlp"

; What that Chrome has already been asked, and what came back. IDS answers the
; same VIN with the same record forever - the truck was built once - so a plate
; looked at twice never costs a second round trip. The rest is the state of the
; conversation: the mutex the two apps take turns on, the socket and message
; counter, when the server was last known to be answering, and when it last
; would not come up at all.
;
; These live up here with the other globals and NOT beside the code that uses
; them, at the bottom of the file. A `global x := y` sitting past the end of
; the auto-execute section still makes x a super-global - the name works
; everywhere - but the `:= y` never runs, so the map would stay blank and the
; first HasKey on it would take the leg down.
global RC_IdsSeen := {}
global RC_IdsMx   := 0
global RC_IdsSock := 0
global RC_IdsId   := 0
global RC_IdsOk   := 0
global RC_IdsCold := 0
; Up while somebody is in the Chrome - a lookup, the warm-up at start, or the
; once-a-minute poke. A search that finds it up goes without IDS this once
; rather than typing into a form the other one is halfway through.
global RC_IdsBusy := 0

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

; Where a search's seconds went, leg by leg. Turned on, every finished search
; leaves one extra line in the day book - "state=1830 build=940" - so a slow
; answer can be blamed on the leg that actually took them rather than guessed
; at. Off in the ordinary way of things.
global RC_TIMING := 1
global RC_TSEQ   := ""
global RC_TLAST  := 0

; The window's own controls. AHK v1 insists a Gui control's variable is global,
; and RC_BuildGui below is a function, so they have to be declared out here.
global RC_Plate    := ""
; How much of the chain a search is allowed to SHOW. 0 is ultra - the make,
; the expiry and the VIN, which is all most askings ever want - 1 is fast, the
; register's whole answer, 2 is the lot, the fitment shop and the wiper sizes
; with it. The choice is written to the ini file beside the script whenever it
; is changed AND read back at the next start, so the window opens the way it
; was left. RC_T0 is when the search started; turning the speed up on a car
; already on screen starts it again, so the clock times the top-up rather than
; the minutes the answer sat there being looked at.
;
; Ultra only decides what is shown, not what is fetched: the whole chain runs
; behind it either way, into a list nobody can see, so that turning the speed
; up is a repaint and not another search. See RC_QSeed.
;
; There used to be an RC_STEPS beside these - how many notches the bar had at
; the setting in force. Nothing counted them: the bar was only ever told step
; one, so it sat at a third of the way along for the whole search. See the
; loading bar's own note for what it does now.
global RC_SPEED := 1
global RC_T0    := 0
global RC_INI   := A_ScriptDir . "\RegoCheck.ini"

; The quiet half of Ultra. RC_QUIET is up while the later legs are running
; into the hidden list instead of the window: every drawing thing in this file
; asks it first and does nothing while it is up, and RC_Use sends the LV_
; functions to the hidden list rather than the real one. RC_QOn says a hidden
; answer is sitting there waiting to be shown. The rest is what the window
; would otherwise be holding for us - the make line, the state, and which row
; the expiry is on in the FULL list, since the visible list has been cut back
; and its numbering no longer matches.
;
; RC_NOFIT is a smaller thing: it stops the window resizing itself for a list
; that is about to be trimmed, so it does not grow and shrink in one breath.
global RC_QUIET  := 0
global RC_QOn    := 0
; RC_QBAR: the bar and the clock keep going behind Ultra all the same. An
; Isuzu's Ultra is not really quiet - the block of rows lands in the window
; as IDS answers - so the window is still building and should look it. Set
; for the length of RC_Rest, and only when that is so.
global RC_QBAR   := 0
global RC_QMake  := ""
global RC_QMakeX := ""
global RC_QSt    := ""
global RC_QRed   := 0
global RC_NOFIT  := 0
global RC_hQGui  := 0

; Whether copying the VIN, or jumping to a catalog, puts the window away to the
; tray. On by default - both are the last thing wanted from the window, and it
; is then sitting over the top of wherever the VIN is going. Off for anyone who
; would rather it stayed put; unlike the speed, this one is remembered between
; sittings, because it is a preference rather than a per-search choice.
global RC_HIDEAFTER := true
global RC_List     := ""
global RC_Make     := ""
global RC_MakeX    := ""

; The VIN band's controls - the strip, the value on it, the copied pill -
; and the four dealership-brand checkboxes under it. Gui control variables
; must be global when the Gui is built inside a function.
global RC_VinBand := ""
global RC_VinTxt  := ""
global RC_SearchBtn  := ""
global RC_hSearchBtn := 0
global RC_LoadBar   := ""
global RC_hLoadBar  := 0
global RC_hSB       := 0

; GDI+'s token and the loading bar's measurements - it is redrawn as it moves
; and needs them every time.
; RC_BAR_PX is the fill width last drawn, in whole pixels: the bar is asked to
; move far oftener than it can actually look any different, and a redraw that
; would come out the same picture is not worth doing. It starts at -1 so the
; first ask always draws.
global RC_GDIP      := 0
global RC_hEpcBtn   := 0
global RC_BAR_W     := 0
global RC_BAR_H     := 0
global RC_BAR_R     := 0
global RC_BAR_BG    := 0
global RC_BAR_PX    := -1
global RC_CopyBtn := ""
global RC_EpcBtn := ""
global RC_EpcRing := ""

; The painted buttons - Search and EPC. Both are real Win32 buttons wearing
; BS_OWNERDRAW, which hands their whole face to RC_OnDrawItem: a button is the
; one common control Windows will not colour for you, and owner-draw is the
; supported way round that rather than a picture with a label laid over it.
;
; RC_BTN_FILL maps a button's handle to the six-digit colour its face is
; painted, so a face changes by writing one word here and asking for a repaint.
; The font and the corner radius are made once at build time - a repaint runs
; on every press and hover and has no business making either again.
;
; RC_BTN_RAD is the corner in unscaled pixels: two, so the face is a square
; slab with the points taken off rather than a pill. RC_BTN_R is that scaled,
; and the EPC ring is drawn to the same number so the band round it follows
; the same corner.
;
; RC_BTN_HOT is the one the cursor is over, or 0. A button does not get told
; about the mouse on its own - Windows sends the move to it and nothing else -
; so the move is watched for and TrackMouseEvent asked for the matching leave.
;
; RC_BTN_CACHE holds every face already drawn, keyed by the colour, the state,
; the size and the label - which is everything a face depends on. A face is
; drawn once and blitted from then on. Drawing it fresh inside the paint was
; what made the hover crawl: a rounded path, a brush and a text run, all on
; the device context the screen is watching, several times a second.
global RC_BTN_FILL  := {}
global RC_BTN_CACHE := {}
global RC_BTN_FONT  := 0
global RC_BTN_RAD   := 2
global RC_BTN_R     := 2
global RC_BTN_HOT   := 0
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

; Whether Enter would open the catalog rather than search again. Set when a
; search lands on a car one of the four catalogs covers, and shown by the pale
; ring round the EPC button, so where the next Enter goes is never a guess.
; Cleared by anything that says the user has moved on - a click, a keystroke in
; the plate box, or the jump itself.
global RC_EPCHOT := false

; Whether a search is under way and the button is still waiting on it. From
; the start of a search until the VIN lands on the band the button reads
; "Loading..." - it is not ready, and saying so beats a press that does
; nothing. The moment the VIN is up and a catalog knows the make, the ring
; goes up and the label with it; a search that ends any other way puts the
; plain word back.
global RC_EPCWAIT := false

; How the EPC button reads and how it is painted, resting, waiting and armed.
; The ring says where the next Enter goes; the return arrow on the label says
; it is the Enter key that goes there, which the ring alone cannot. The deeper
; green carries the same news for anyone who does not see a two pixel band.
global RC_EPC_LBL      := "EPC"
global RC_EPC_LBL_HOT  := "EPC " . Chr(0x21B5)
global RC_EPC_LBL_WAIT := "Loading..."
global RC_EPC_BG      := "0F6E56"
global RC_EPC_BG_HOT  := "085041"

; Search wears the accent blue, the same one the loading bar fills with. EPC
; keeps the catalog green, so the pair either side of the VIN band stay
; tellable apart at a glance.
global RC_SEARCH_BG   := "0067C0"

; The ring the mouse puts round a button. Measured straight off the stock
; button next to these - the copy button - with the cursor on it: Windows
; draws a one pixel border in this colour, one pixel in from the edge. Same
; colour on both buttons on purpose. It is the mouse being reported, not the
; button saying something about itself, so it has no business changing with
; whichever button it is over.
global RC_BTN_RIM     := "0078D4"

; Shown in the title bar. Goes up by one every time the script changes.
global RC_VER := "4.9"

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

; The Isuzu dealer system is got ready before anybody asks for it - the
; attach to Chrome, or the whole start-up when Chrome is not there, is paid
; now instead of inside the first Isuzu search. Then once a minute the
; session is prodded so it is still warm at the next one.
SetTimer, RC_IdsWarm, -1500
SetTimer, RC_IdsKeep, 60000

; Started with a plate on the command line: fill it in and search straight away.
if (A_Args.Length() >= 1) {
    GuiControl, RC:, RC_Plate, % A_Args[1]
    RC_OnSearch()
}
return


; --- the window ------------------------------------------------------------

RC_BuildGui() {
    global RC_hEdit, RC_hGui, RC_PadW, RC_PadH
    ; -DPIScale, because AHK's own scaling rounds every control's position on
    ; its own and fonts scale by a slightly different ratio again - at 125% or
    ; 150% the hand-tuned overlays below drift apart and text shifts inside
    ; the buttons. Instead every number here goes through RC_S: one rule, one
    ; rounding, and the raw pixels WinMove, MoveWindow and GetItemRect speak
    ; elsewhere are the same pixels the controls were laid out in. Fonts are
    ; in points, which Windows scales to the screen by itself, so they stay.
    Gui, RC:New, -MaximizeBox -Resize -DPIScale +HwndRC_hGui, Rego check
    RC_Use()
    Gui, Margin, % RC_S(12), % RC_S(12)
    Gui, Font, s10, Segoe UI

    ; The box takes the whole top line - no label; the window's own title
    ; already says what goes in it. 17 characters so a whole VIN fits.
    Gui, Font, s11, Segoe UI
    Gui, Add, Edit,   % RC_P(12, 12, 304, 30) . " vRC_Plate gRC_OnPlate HwndRC_hEdit Uppercase Limit17"
    Gui, Font, s10, Segoe UI
    ; Enter searches through a real Default button parked out of sight
    ; off-screen - through RC_OnEnter rather than the search itself, because
    ; after a search Enter has a second job: opening the catalog the ring is
    ; pointing at. It stays off-screen now that Search is a button of its own:
    ; the default push style follows the focus, and the plate box is where the
    ; focus sits while anyone is typing.
    Gui, Add, Button, x-200 y-200 w1 h1 Default gRC_OnEnter, S
    RC_GdipOn()
    bg := RC_BgArgb()
    RC_BTN_R := RC_S(RC_BTN_RAD)

    ; The Search button. A real BUTTON control - it takes the focus, answers
    ; the space bar, draws its own pressed state and tells the accessibility
    ; layer what it is - wearing BS_OWNERDRAW so its face is painted here
    ; rather than by the theme. What replaced: a Picture with a Text laid over
    ; it, which looked the part and was not a button in any other sense.
    Gui, Add, Button, % RC_P(324, 12, 84, 30) . " gRC_OnSearch vRC_SearchBtn HwndRC_hSearchBtn", Search
    RC_BtnSkin(RC_hSearchBtn, RC_SEARCH_BG)

    ; The VIN band sits right under the search box, the same height as the
    ; edit above it so the left column reads as one aligned stack. One line:
    ; the small VIN label, the value, the copied pill, and the copy icon at
    ; the band's right end. Strip and pill are Progress controls as flat
    ; colour.
    Gui, Add, Progress, % RC_P(12, 50, 304, 30) . " BackgroundE8F1FA vRC_VinBand Disabled"
    Gui, Font, s8 c4A6A90, Segoe UI
    Gui, Add, Text, % RC_P(22, 59, 26, 13) . " BackgroundTrans", VIN
    Gui, Font, s11 w700 c003E73, Consolas
    ; Double-clicking the value copies it, same as the copy button beside it.
    Gui, Add, Text, % RC_P(52, 56, 148, 18) . " BackgroundTrans gRC_OnVinDbl vRC_VinTxt", %A_Space%
    Gui, Font, s10 w400 cDefault, Segoe UI
    ; The copy button - the two-squares glyph - filling the band's right end,
    ; the same size as the EPC button under Search. Hovering it says what it
    ; does; the feedback for pressing it is the VIN tooltip at the cursor.
    Gui, Font, s12, Segoe UI Symbol
    Gui, Add, Button, % RC_P(232, 50, 84, 30) . " gRC_OnCopy vRC_CopyBtn", % Chr(0x29C9)
    Gui, Font, s10 w400 cDefault, Segoe UI

    ; The EPC button, directly under Search and the same size, in the catalog
    ; green. It jumps the detected make's catalog - the make read off the
    ; VIN's WMI, the same way CatalogProbe reads it - and searches the VIN
    ; there. Same owner-drawn button as Search.
    ; The ring goes in first, so the button is laid over the hole in its middle.
    ; Hidden until a search finds a car one of the catalogs covers; while it is
    ; up, Enter opens the catalog instead of searching again.
    ; Every number below comes off the button's own scaled rectangle rather than
    ; being scaled a second time, so the band stays the same width on all four
    ; sides at 125% and 150% instead of drifting a pixel per edge.
    bx := RC_S(324), by := RC_S(50), bw := RC_S(84), bh := RC_S(30)
    br := RC_BTN_R                               ; corner ellipse, the button's own
    pad := RC_S(2) < 2 ? 2 : RC_S(2)             ; band width
    Gui, Add, Picture, % "x" . (bx - pad) . " y" . (by - pad) . " w" . (bw + pad * 2) . " h" . (bh + pad * 2) . " vRC_EpcRing HwndRC_hEpcRing Hidden Disabled"
       , % "HBITMAP:*" . RC_RingBmp(bw + pad * 2, bh + pad * 2, pad, br, RC_Argb("1D9E75"), bg)

    ; The two faces are a colour apiece rather than a bitmap apiece now: the
    ; face is repainted on demand, so arming the button is one word written
    ; into RC_BTN_FILL and a repaint, and nothing has to be kept alive between
    ; swaps.
    Gui, Add, Button, % RC_P(324, 50, 84, 30) . " gRC_OnEpc vRC_EpcBtn HwndRC_hEpcBtn", % RC_EPC_LBL
    RC_BtnSkin(RC_hEpcBtn, RC_EPC_BG)

    ; The make in bold on its own line, the build spelled out underneath in
    ; ordinary weight. The state lives in the status bar only.
    Gui, Font, s13 w600, Segoe UI
    Gui, Add, Text, % RC_P(12, 88, 396, 24) . " vRC_Make", %A_Space%
    Gui, Font, s10 w400 c606060, Segoe UI
    Gui, Add, Text, % RC_P(12, 114, 396, 34) . " Hidden vRC_MakeX", %A_Space%
    Gui, Font, s10 w400 cDefault, Segoe UI

    ; Tall enough for the header and every row the tyre shops can fill at
    ; once. If it is any shorter a scrollbar appears, which then eats the
    ; width and brings a second scrollbar along the bottom with it.
    Gui, Add, ListView, % RC_P(12, 150, 396, 348) . " vRC_List HwndRC_hLV gRC_OnList -Multi +Grid NoSortHdr", Field|Value

    ; The dealership brands, centred under the list. These are lights, not
    ; settings: a tick means CatalogProbe found that brand's parts catalog
    ; open in a browser, and clicking one brings that tab to the front
    ; and searches the VIN in it. The tick is put back the way the probe left
    ; it on every click, so they cannot be toggled by hand. RC_FitList slides
    ; the row up and down with the bottom of the list.
    Gui, Add, Checkbox, % RC_P(70, 506, 52, 20) . " vRC_ChkKia gRC_OnCatKia", Kia
    Gui, Add, Checkbox, % RC_P(134, 506, 76, 20) . " vRC_ChkHyu gRC_OnCatHyu", Hyundai
    Gui, Add, Checkbox, % RC_P(222, 506, 62, 20) . " vRC_ChkIsu gRC_OnCatIsu", Isuzu
    Gui, Add, Checkbox, % RC_P(296, 506, 54, 20) . " vRC_ChkByd gRC_OnCatByd", BYD

    ; Wide enough for the longest field name - "Tyres (front & rear)" - with
    ; the rest left for the values, which are mostly short.
    LV_ModifyCol(1, RC_S(138))
    LV_ModifyCol(2, RC_S(240))

    ; Row colouring is not something a ListView does on its own - Windows has to
    ; be asked, row by row, while it paints. RC_OnNotify answers.
    OnMessage(0x004E, "RC_OnNotify")

    ; An owner-drawn button asks its PARENT to paint it, which is what this
    ; message is. RC_OnDrawItem paints the two coloured buttons and lets
    ; everything else through.
    OnMessage(0x002B, "RC_OnDrawItem")

    ; Mouse moves feed the copy button's hover tooltip and the painted
    ; buttons' lit face.
    OnMessage(0x0200, "RC_MouseTip")

    ; ...and the matching leave, which only arrives because RC_TrackLeave asks
    ; for it. Without this the face stays lit after the cursor has gone.
    OnMessage(0x02A3, "RC_OnMouseLeave")

    ; Any press of the left button anywhere in the window puts the EPC ring
    ; away: the mouse has been picked up, so Enter goes back to searching.
    OnMessage(0x0201, "RC_OnLDown")

    ; A real status bar closes the window: what happened, how long it took,
    ; and which speed it ran at. It keeps itself glued to the bottom edge
    ; whenever RC_FitList resizes the window. The right cell doubles as the
    ; speed switch - "Fast v" - and clicking it pops the little mode menu;
    ; the click lands in RC_OnNotify as an NM_CLICK from the bar.
    Gui, Add, StatusBar, HwndRC_hSB
    SB_SetParts(RC_S(266), RC_S(64))

    ; A blue progress bar - the app's accent blue, rounded ends - that rides
    ; on the status bar's first cell while a search runs, one notch per step,
    ; the counter in the middle cell. It disappears for the tick. Made a child
    ; of the status bar itself, so it stays glued inside the first cell
    ; however the window resizes.
    ; Drawn, like the buttons, and for the same reason - but this one is drawn
    ; again every time it moves, so its measurements are kept where RC_BarPos
    ; can reach them. Sitting on the status bar, it is drawn onto the same
    ; button face the window is.
    RC_BAR_W := RC_S(260), RC_BAR_H := RC_S(17), RC_BAR_R := RC_S(12)
    RC_BAR_BG := bg, RC_BAR_PX := -1
    Gui, Add, Picture, % RC_P(2, 556, 260, 17) . " Hidden vRC_LoadBar HwndRC_hLoadBar Disabled"
       , % "HBITMAP:*" . RC_BarBmp(RC_BAR_W, RC_BAR_H, RC_BAR_R, 0, RC_Argb("E8E8E8"), RC_Argb("0067C0"), bg)
    DllCall("SetParent", "Ptr", RC_hLoadBar, "Ptr", RC_hSB)
    DllCall("MoveWindow", "Ptr", RC_hLoadBar, "Int", RC_S(2), "Int", RC_S(3), "Int", RC_S(260), "Int", RC_S(17), "Int", 1)

    ; The menu bar. It goes on before the Show below, so the frame measured
    ; there already counts the row it adds - RC_FitList resizes with WinMove,
    ; which speaks in whole-window pixels, and a menu bar put on afterwards
    ; would make every later resize that much too short.
    RC_BuildMenus()

    ; The band opens on a quiet dash so it never sits there broken-looking
    ; before the first search.
    RC_SetVin("")

    ; Built at full size but left out of sight, so starting the script does not
    ; interrupt whatever is on screen. Page Down brings it up when it is wanted.
    Gui, Show, % "Hide w" . RC_S(420) . " h" . RC_S(560), Rego check v%RC_VER%

    ; How much the frame - border and title bar - adds to the drawing area.
    ; RC_FitList resizes with WinMove, which counts the frame in, so the two
    ; numbers have to be known before the first answer arrives.
    prev := A_DetectHiddenWindows
    DetectHiddenWindows, On
    WinGetPos, , , ow, oh, ahk_id %RC_hGui%
    DetectHiddenWindows, %prev%
    RC_PadW := ow - RC_S(420)
    RC_PadH := oh - RC_S(560)

    RC_QInit()
    RC_SpeedLoad()
    RC_Ready()

    ; The window opens compact - the list trimmed to its six-row floor, the
    ; same trim a short answer gets - instead of sitting at full height with
    ; nothing in it. The first search grows it to fit.
    RC_FitList()

    ; The catalog lights. One sweep runs straight away so the row is honest
    ; before the window is first shown, then every few seconds after that.
    RC_CatTick()
    SetTimer, RC_CatTick, 6000
}

; The one scaling rule. Every layout number in this file is written for a
; 100% screen and multiplied up here, so a 125% or 150% machine gets the
; same window, only bigger. Same input, same rounding - which is what keeps
; the text sitting still inside the bands and buttons.
RC_S(n) {
    return Round(n * A_ScreenDPI / 96)
}

; --- the rounded shapes ----------------------------------------------------

; The buttons, the ring and the loading bar are all flat colour with rounded
; corners, and all four used to get that shape from SetWindowRgn - the control
; drawn square and the corners clipped away afterwards.
;
; A window region is a stencil with one bit to a pixel: every pixel is wholly
; in or wholly out, and a curve made of whole pixels is a staircase. That is
; the fuzziness round the corners - not blur, but the bare steps.
;
; So nothing is clipped any more. Each shape is drawn once by GDI+, with
; antialiasing on, straight onto the colour it will be sitting on, and the
; finished picture is handed to a Picture control. A pixel half inside the
; curve comes out half the shape's colour and half the background's, which is
; what the eye reads as a smooth edge. The text overlays and every click path
; are untouched: only what is underneath them changed.

; GDI+ has to be started before any of it will answer, and stays up for the
; life of the process.
RC_GdipOn() {
    global RC_GDIP
    if (RC_GDIP)
        return true
    if (!DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr"))
        return false
    ; GdiplusStartupInput: version 1, no debug callback, and the two flags
    ; left at zero. Wider on 64-bit for the alignment of the pointer field.
    VarSetCapacity(si, A_PtrSize = 8 ? 24 : 16, 0)
    NumPut(1, si, 0, "UInt")
    token := 0
    if (DllCall("gdiplus\GdiplusStartup", "Ptr*", token, "Ptr", &si, "Ptr", 0) != 0)
        return false
    RC_GDIP := token
    return true
}

; The colour the shapes are drawn onto. Both places one of them sits - the
; window itself and the status bar - are the system's button face, and nothing
; here sets a background of its own, so one answer serves both. Read at run
; time rather than written down: a high-contrast theme moves it.
RC_BgArgb() {
    static COLOR_BTNFACE := 15
    c := DllCall("GetSysColor", "Int", COLOR_BTNFACE, "UInt")
    ; GetSysColor answers in BGR and GDI+ wants ARGB.
    return 0xFF000000 | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
}

; The six-digit colours the controls are written in, as opaque ARGB.
;
; Written out in three steps, and it has to be. AHK will read "0x0067C0" as a
; number out of a VARIABLE, but not out of a concatenation it has just made:
;
;     n := ("0x" . hex) + 0      ; blank
;     n := "0x" . hex
;     n += 0                     ; 26560
;
; The first form fails silently - no error, no warning, an empty result that
; then goes on being used. Here it became the fill colour, which meant every
; shape was drawn in transparent black onto its own background, and a shape
; drawn in nothing looks exactly like a shape that was never drawn at all.
; That is worth the extra line.
RC_Argb(hex) {
    n := "0x" . hex
    n += 0
    return 0xFF000000 | n
}

; A rounded rectangle as a path. Four arcs and the lines between them, which
; is what GDI+ closing the figure supplies. The diameter is held to the
; rectangle so a radius bigger than the shape gives a capsule rather than a
; tangle.
RC_RoundPath(x, y, w, h, r) {
    path := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", path)
    if (!path)
        return 0
    d := r * 2
    if (d > w)
        d := w
    if (d > h)
        d := h
    if (d <= 0) {
        DllCall("gdiplus\GdipAddPathRectangle", "Ptr", path, "Float", x, "Float", y, "Float", w, "Float", h)
        return path
    }
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x,         "Float", y,         "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y,         "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0,   "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x,         "Float", y + h - d, "Float", d, "Float", d, "Float", 90,  "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
    return path
}

; A bitmap to draw on, already flooded with the colour it will sit on. The
; flooding is the whole trick: the curve is antialiased against this, so the
; edge pixels come out the right blend for where the picture is going.
;
; The bitmap is a plain 24-bit DIB section and GDI+ is pointed at its device
; context, rather than GDI+ making a bitmap of its own and being asked for an
; HBITMAP at the end. That way round does not survive the handover: what comes
; back carries an alpha channel, and a Picture control blits it without ever
; reading the alpha, so the drawing arrives invisible. Something with no alpha
; to misread cannot go wrong that way - and nothing here wants transparency in
; the first place, since every shape is drawn onto its own background already.
;
; Top-down, by the negative height: which way up a DIB runs is otherwise a
; coin toss to read later, and every shape here would come out mirrored if the
; coin landed the other way.
RC_Canvas(w, h, bg, ByRef dc, ByRef hbm, ByRef oldbm, ByRef g) {
    static ANTIALIAS := 4
    dc := 0, hbm := 0, oldbm := 0, g := 0
    dc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    if (!dc)
        return false
    VarSetCapacity(bi, 40, 0)
    NumPut(40, bi,  0, "UInt")
    NumPut(w,  bi,  4, "Int")
    NumPut(-h, bi,  8, "Int")
    NumPut(1,  bi, 12, "UShort")
    NumPut(24, bi, 14, "UShort")
    NumPut(0,  bi, 16, "UInt")                      ; BI_RGB
    bits := 0
    hbm := DllCall("CreateDIBSection", "Ptr", dc, "Ptr", &bi, "UInt", 0, "Ptr*", bits, "Ptr", 0, "UInt", 0, "Ptr")
    if (!hbm) {
        DllCall("DeleteDC", "Ptr", dc)
        return false
    }
    oldbm := DllCall("SelectObject", "Ptr", dc, "Ptr", hbm, "Ptr")
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", dc, "Ptr*", g)
    if (!g) {
        DllCall("SelectObject", "Ptr", dc, "Ptr", oldbm)
        DllCall("DeleteObject", "Ptr", hbm)
        DllCall("DeleteDC", "Ptr", dc)
        hbm := 0
        return false
    }
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", ANTIALIAS)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", bg)
    return true
}

RC_FillPath(g, path, argb) {
    br := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", br)
    if (!br)
        return
    DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", br, "Ptr", path)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
}

; The finished drawing, and the scaffolding put away behind it. The bitmap
; itself is left alive and handed back - it is the drawing.
RC_Finish(dc, hbm, oldbm, g) {
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("SelectObject", "Ptr", dc, "Ptr", oldbm)
    DllCall("DeleteDC", "Ptr", dc)
    return hbm
}

; A flat rounded slab - the Search and EPC buttons.
RC_PillBmp(w, h, r, fill, bg) {
    if (!RC_Canvas(w, h, bg, dc, hbm, oldbm, g))
        return 0
    if (path := RC_RoundPath(0, 0, w, h, r)) {
        RC_FillPath(g, path, fill)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
    return RC_Finish(dc, hbm, oldbm, g)
}

; The band round the EPC button. Drawn as the whole rounded slab and then the
; middle painted back out in the background colour - both edges antialiased,
; which two stacked regions could never be. The middle is behind the button
; anyway, so what it holds only has to be something that will not show at the
; seam.
RC_RingBmp(w, h, pad, r, ring, bg) {
    if (!RC_Canvas(w, h, bg, dc, hbm, oldbm, g))
        return 0
    if (path := RC_RoundPath(0, 0, w, h, r + pad)) {
        RC_FillPath(g, path, ring)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
    if (path := RC_RoundPath(pad, pad, w - pad * 2, h - pad * 2, r)) {
        RC_FillPath(g, path, bg)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
    return RC_Finish(dc, hbm, oldbm, g)
}

; The loading bar at one position: the whole capsule in the track colour, and
; the filled part as a capsule of its own on top.
;
; A capsule rather than the track clipped off at the fill's width, because a
; clip is the one-bit stencil again - GDI+ clips hard-edged whatever the
; smoothing is set to, and the left end would come back the staircase this was
; all meant to be rid of. A pill that grows keeps every edge drawn rather than
; cut, and its radius is held to half its own width so a bar just starting is
; a small round dot instead of a sliver with the ends bitten off.
RC_BarBmp(w, h, r, fw, track, fill, bg) {
    if (!RC_Canvas(w, h, bg, dc, hbm, oldbm, g))
        return 0
    if (path := RC_RoundPath(0, 0, w, h, r)) {
        RC_FillPath(g, path, track)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
    if (fw > 0) {
        fr := (r > fw / 2) ? fw / 2 : r
        if (path := RC_RoundPath(0, 0, fw, h, fr)) {
            RC_FillPath(g, path, fill)
            DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        }
    }
    return RC_Finish(dc, hbm, oldbm, g)
}

; --- the painted buttons ---------------------------------------------------

; Turn a plain button into one this script paints, and say what colour.
;
; The type of a button lives in the bottom four bits of its style, so
; BS_OWNERDRAW is not ORed in - the old type is masked out first, or the value
; left behind is some other kind of button entirely.
RC_BtnSkin(hCtl, hex) {
    global RC_BTN_FILL
    static GWL_STYLE := -16, BS_TYPEMASK := 0xF, BS_OWNERDRAW := 0xB
    if (!hCtl)
        return
    RC_BTN_FILL[hCtl] := hex
    s := DllCall((A_PtrSize = 8) ? "GetWindowLongPtr" : "GetWindowLong"
        , "Ptr", hCtl, "Int", GWL_STYLE, "Ptr")
    s := (s & ~BS_TYPEMASK) | BS_OWNERDRAW
    DllCall((A_PtrSize = 8) ? "SetWindowLongPtr" : "SetWindowLong"
        , "Ptr", hCtl, "Int", GWL_STYLE, "Ptr", s)

    ; The resting face is drawn now rather than the first time it is asked
    ; for. The first ask lands while the window is opening, which is the one
    ; moment there is nothing to spare for building a bitmap.
    VarSetCapacity(rc, 16, 0)
    if (DllCall("GetClientRect", "Ptr", hCtl, "Ptr", &rc)) {
        w := NumGet(rc, 8, "Int"), h := NumGet(rc, 12, "Int")
        if (w > 0 && h > 0)
            RC_BtnFace(hCtl, w, h, 0)
    }
    RC_BtnPaint(hCtl)
}

; Ask both painted buttons for a fresh face.
;
; Called off a -1 timer straight after the window is shown, and that timing is
; the whole point. An owner-drawn control is painted by its PARENT, and the
; parent here is this script: a WM_DRAWITEM that turns up while the script is
; mid-command cannot be answered until the command finishes, so the button
; comes back unpainted and stays that way until something invalidates it
; again. Showing the window is exactly such a command - which is why these two
; were the last things on screen every time, long after the list and the boxes
; that Windows draws for itself. A -1 timer runs the moment the thread goes
; idle, which is the first moment the paint can actually be served.
RC_BtnsUp() {
    global RC_hSearchBtn, RC_hEpcBtn
    RC_BtnPaint(RC_hSearchBtn)
    RC_BtnPaint(RC_hEpcBtn)
}

; Ask a painted button to draw itself again. Changing its colour or its label
; is a change to what the face says, and nothing else knows to repaint it.
;
; Without erasing first. The face covers the control corner to corner, so an
; erase only paints the whole button grey a moment before the face lands on
; top of it - which is the flash, and it happens on every single repaint.
RC_BtnPaint(hCtl) {
    if (hCtl)
        DllCall("InvalidateRect", "Ptr", hCtl, "Ptr", 0, "Int", 0)
}

; The cursor has moved over something. If that something is a painted button
; and it is not the one already lit, the lit one goes out and this one comes
; up.
;
; A move over anything else is left alone rather than putting the light out:
; the cursor cannot cross from a button to another control without leaving the
; button first, and the leave is what RC_OnMouseLeave answers. Doing it here
; as well would put the face out twice and flicker it.
RC_BtnHover(hCtl) {
    global RC_BTN_FILL, RC_BTN_HOT
    if (!hCtl || RC_BTN_HOT = hCtl || !RC_BTN_FILL.HasKey(hCtl))
        return
    old := RC_BTN_HOT
    RC_BTN_HOT := hCtl
    if (old)
        RC_BtnPaint(old)
    RC_BtnPaint(hCtl)
    RC_TrackLeave(hCtl)
}

; Ask Windows for one WM_MOUSELEAVE when the cursor next leaves this control.
; It is a one-shot - the request is made again on every fresh entry, which is
; where RC_BtnHover calls it from.
RC_TrackLeave(hCtl) {
    static TME_LEAVE := 0x00000002
    ; TRACKMOUSEEVENT: two DWORDs, then the handle - 8-aligned on 64 bit, so
    ; the struct runs to 24 bytes there and 16 on 32 bit. cbSize has to be the
    ; real one or the call is refused.
    size := (A_PtrSize = 8) ? 24 : 16
    VarSetCapacity(t, size, 0)
    NumPut(size,      t, 0, "UInt")
    NumPut(TME_LEAVE, t, 4, "UInt")
    NumPut(hCtl,      t, 8, "Ptr")
    NumPut(0,         t, 8 + A_PtrSize, "UInt")
    DllCall("TrackMouseEvent", "Ptr", &t)
}

; WM_MOUSELEAVE. The cursor has gone off the button that asked to be told, so
; its face goes back to resting.
;
; Except when it has not. A leave turns up for reasons that are nothing to do
; with the cursor having moved - the window losing activation, a tooltip
; appearing over the button, a capture ending somewhere else - and taking each
; one at its word is what makes a hovered button blink: out on the leave, back
; on the very next mouse move, over and over. So the cursor is looked at, and
; a leave that disagrees with where it actually is buys a fresh request to be
; told and nothing else.
RC_OnMouseLeave(wParam, lParam, msg, hwnd) {
    global RC_BTN_HOT
    if (!RC_BTN_HOT || RC_BTN_HOT != hwnd)
        return
    if (RC_CursorOn(hwnd)) {
        RC_TrackLeave(hwnd)
        return
    }
    h := RC_BTN_HOT
    RC_BTN_HOT := 0
    RC_BtnPaint(h)
}

; Is the cursor inside this control's rectangle? Screen coordinates both
; sides, so nothing here depends on which window is active or where it sits.
RC_CursorOn(hCtl) {
    VarSetCapacity(pt, 8, 0)
    if (!DllCall("GetCursorPos", "Ptr", &pt))
        return false
    VarSetCapacity(rc, 16, 0)
    if (!DllCall("GetWindowRect", "Ptr", hCtl, "Ptr", &rc))
        return false
    x := NumGet(pt, 0, "Int"), y := NumGet(pt, 4, "Int")
    return (x >= NumGet(rc, 0, "Int") && x < NumGet(rc, 8, "Int")
         && y >= NumGet(rc, 4, "Int") && y < NumGet(rc, 12, "Int"))
}

; The label font, made once. Segoe UI semibold at the same ten points the rest
; of the window is set in - the Gui is -DPIScale, so points are points and the
; height is worked out against the screen rather than assumed at 96.
RC_BtnFont() {
    global RC_BTN_FONT
    static DEFAULT_CHARSET := 1, CLEARTYPE_QUALITY := 5
    if (RC_BTN_FONT)
        return RC_BTN_FONT
    h := -Round(10 * A_ScreenDPI / 72)
    RC_BTN_FONT := DllCall("CreateFont", "Int", h, "Int", 0, "Int", 0, "Int", 0
        , "Int", 600, "UInt", 0, "UInt", 0, "UInt", 0
        , "UInt", DEFAULT_CHARSET, "UInt", 0, "UInt", 0, "UInt", CLEARTYPE_QUALITY
        , "UInt", 0, "Str", "Segoe UI", "Ptr")
    return RC_BTN_FONT
}

; A colour a step darker or lighter. Negative walks it towards black - the
; pressed face - positive towards white, which is what a disabled one gets.
RC_Shade(argb, pct) {
    r := (argb >> 16) & 0xFF
    g := (argb >>  8) & 0xFF
    b :=  argb        & 0xFF
    if (pct < 0) {
        f := (100 + pct) / 100
        r := Round(r * f), g := Round(g * f), b := Round(b * f)
    } else {
        r := Round(r + (255 - r) * pct / 100)
        g := Round(g + (255 - g) * pct / 100)
        b := Round(b + (255 - b) * pct / 100)
    }
    return 0xFF000000 | (r << 16) | (g << 8) | b
}

; WM_DRAWITEM. An owner-drawn control does not paint itself - it hands its
; device context to its parent and asks for a face, which is this.
;
; Only the two buttons registered in RC_BTN_FILL are answered. Anything else
; owner-drawn in this window - now or later - falls through untouched and
; Windows carries on as it would have.
RC_OnDrawItem(wParam, lParam, msg, hwnd) {
    global RC_hGui, RC_BTN_FILL
    static ODT_BUTTON := 4
    if (hwnd != RC_hGui)
        return
    if (NumGet(lParam + 0, 0, "UInt") != ODT_BUTTON)
        return
    ; DRAWITEMSTRUCT: five UINTs, then the handle - which is 8-aligned on 64
    ; bit, so the run of integers is padded out to 24 there and stops at 20 on
    ; 32 bit. Everything after it follows on pointer by pointer.
    state := NumGet(lParam + 0, 16, "UInt")
    oh    := (A_PtrSize = 8) ? 24 : 20
    hCtl  := NumGet(lParam + 0, oh, "Ptr")
    hdc   := NumGet(lParam + 0, oh + A_PtrSize, "Ptr")
    if (!hCtl || !hdc || !RC_BTN_FILL.HasKey(hCtl))
        return
    rc := oh + A_PtrSize * 2
    w := NumGet(lParam + 0, rc + 8, "Int") - NumGet(lParam + 0, rc, "Int")
    h := NumGet(lParam + 0, rc + 12, "Int") - NumGet(lParam + 0, rc + 4, "Int")
    RC_PaintBtn(hCtl, hdc, w, h, state)
    return true
}

; One button's face onto the screen. The face itself is a bitmap made once and
; kept, so all that happens here is a single blit - one write, covering the
; control corner to corner, with nothing part-drawn ever on screen.
;
; This is the whole of the anti-flicker. Painting the shape and the text
; straight onto the device context Windows handed over means the screen shows
; the cleared background, then the slab, then the text, as three separate
; states a few milliseconds apart - and on a button under a moving cursor that
; reads as a flicker rather than as drawing.
RC_PaintBtn(hCtl, hdc, w, h, state) {
    static SRCCOPY := 0x00CC0020
    if (w <= 0 || h <= 0)
        return
    hbm := RC_BtnFace(hCtl, w, h, state)
    if (!hbm)
        return
    mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
    if (!mdc)
        return
    old := DllCall("SelectObject", "Ptr", mdc, "Ptr", hbm, "Ptr")
    DllCall("BitBlt", "Ptr", hdc, "Int", 0, "Int", 0, "Int", w, "Int", h
        , "Ptr", mdc, "Int", 0, "Int", 0, "UInt", SRCCOPY)
    DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("DeleteDC", "Ptr", mdc)
}

; The bitmap for one button in one state, drawn on first sight and kept.
;
; The key is everything the picture depends on - the colour, which of the four
; faces, whether the focus line is on, the size and the label - so a face that
; has been asked for before is handed straight back, and one that has changed
; in any way is a new key rather than a stale picture. There are two buttons,
; four faces, a focus line and two labels between them, so the cache tops out
; at a couple of dozen small bitmaps and never grows again.
RC_BtnFace(hCtl, w, h, state) {
    global RC_BTN_FILL, RC_BTN_CACHE, RC_BTN_R, RC_BTN_HOT
    static ODS_SELECTED := 0x0001, ODS_DISABLED := 0x0004, ODS_FOCUS := 0x0010
    static TRANSPARENT := 1
    static DT := 0x0825          ; CENTER | VCENTER | SINGLELINE | NOPREFIX

    ; Four faces, and only one of them at a time. Held down beats hovered - the
    ; cursor is over the button in both, and the press is the newer news.
    if (state & ODS_DISABLED)
        face := "off"
    else if (state & ODS_SELECTED)
        face := "down"
    else if (RC_BTN_HOT = hCtl)
        face := "hot"
    else
        face := "rest"
    down  := (state & ODS_SELECTED) ? 1 : 0
    focus := (state & ODS_FOCUS) ? 1 : 0
    label := RC_WinText(hCtl)
    key := RC_BTN_FILL[hCtl] . "|" . face . "|" . focus . "|" . w . "x" . h . "|" . label
    if (RC_BTN_CACHE.HasKey(key))
        return RC_BTN_CACHE[key]

    ; Hovering does NOT touch the fill. The ring below is the whole of it -
    ; same as the stock buttons, where the mouse is reported by a line round
    ; the edge and the button keeps its own colour. Anything done to the fill
    ; here was read as the button going dull rather than lighting up.
    argb := RC_Argb(RC_BTN_FILL[hCtl])
    if (face = "off")
        argb := RC_Shade(argb, 55)
    else if (face = "down")
        argb := RC_Shade(argb, -18)

    ; The canvas is flooded with the window's own background first, for the
    ; same reason the other drawn shapes do it - the curve is antialiased
    ; against what is behind it, so the corners blend into the window rather
    ; than carrying a fringe of whatever was there before.
    if (!RC_Canvas(w, h, RC_BgArgb(), dc, hbm, oldbm, g))
        return 0
    if (path := RC_RoundPath(0, 0, w, h, RC_BTN_R)) {
        RC_FillPath(g, path, argb)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }

    ; The ring, and the whole of what the mouse does to these buttons.
    ;
    ; Laid out to match the stock button exactly: one pixel wide, one pixel in
    ; from the edge, so the outermost pixel stays the button's own colour and
    ; the line sits just inside it. The path is at 1.5 because a stroke is
    ; centred on its path - at 1.0 half of it would land on pixel 0 and the
    ; ring would read as two half-lit pixels instead of one clean one.
    if ((face = "hot" || face = "down")
        && (path := RC_RoundPath(1.5, 1.5, w - 3, h - 3, RC_BTN_R))) {
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", RC_Argb(RC_BTN_RIM), "Float", 1.0
            , "Int", 2, "Ptr*", pen)
        if (pen) {
            DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
    ; Focus is a pale line just inside the edge rather than the dotted
    ; rectangle Windows draws: the dots are drawn by XOR against the face and
    ; all but disappear on a colour this dark.
    if (focus) {
        pad := RC_S(3) < 1 ? 1 : RC_S(3)
        ir := (RC_BTN_R - pad > 1) ? RC_BTN_R - pad : 1
        if (path := RC_RoundPath(pad, pad, w - pad * 2, h - pad * 2, ir)) {
            pen := 0
            DllCall("gdiplus\GdipCreatePen1", "UInt", 0x70FFFFFF, "Float", 1.0
                , "Int", 2, "Ptr*", pen)
            if (pen) {
                DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
                DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
            }
            DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        }
    }
    ; GDI+ is finished with the device context before GDI writes on it. The
    ; two do not queue together, and text drawn while the Graphics is still
    ; alive can be painted over by it when the Graphics is finally let go.
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)

    ; The label through GDI, not GDI+. The text is the one part of this that
    ; is not a curve, and DrawText with ClearType is sharper at ten points
    ; than GDI+ manages.
    VarSetCapacity(rect, 16, 0)
    NumPut(0,        rect,  0, "Int")
    NumPut(down,     rect,  4, "Int")          ; pressed: the label goes down a pixel
    NumPut(w,        rect,  8, "Int")
    NumPut(h + down, rect, 12, "Int")
    old := DllCall("SelectObject", "Ptr", dc, "Ptr", RC_BtnFont(), "Ptr")
    DllCall("SetBkMode", "Ptr", dc, "Int", TRANSPARENT)
    DllCall("SetTextColor", "Ptr", dc, "UInt", (face = "off") ? 0x909090 : 0xFFFFFF)
    DllCall("DrawText", "Ptr", dc, "Str", label, "Int", -1, "Ptr", &rect, "UInt", DT)
    DllCall("SelectObject", "Ptr", dc, "Ptr", old)

    ; The bitmap is kept, so only the scaffolding round it is put away.
    DllCall("SelectObject", "Ptr", dc, "Ptr", oldbm)
    DllCall("DeleteDC", "Ptr", dc)
    RC_BTN_CACHE[key] := hbm
    return hbm
}

; A window's text as a string. Only the painted buttons ask, and only for
; their own label.
RC_WinText(hCtl) {
    len := DllCall("GetWindowTextLength", "Ptr", hCtl)
    VarSetCapacity(s, (len + 2) * 2, 0)
    DllCall("GetWindowText", "Ptr", hCtl, "Str", s, "Int", len + 1)
    return s
}

; Put a drawing on a Picture control, and throw away the one it was showing.
;
; Straight to the control rather than through GuiControl, so what happens to
; the old drawing is decided here: the loading bar makes a new one every time
; it moves and would pile them up otherwise, while the EPC button's two are
; made once and swapped back and forth for the life of the window - freeing
; either of those would leave the next swap showing nothing.
RC_SetPic(hCtl, hbm, freeOld := true) {
    static STM_SETIMAGE := 0x172, IMAGE_BITMAP := 0
    if (!hbm)
        return
    old := DllCall("SendMessage", "Ptr", hCtl, "UInt", STM_SETIMAGE, "Ptr", IMAGE_BITMAP, "Ptr", hbm, "Ptr")
    if (freeOld && old && old != hbm)
        DllCall("DeleteObject", "Ptr", old)
}

; A position string for Gui Add, every number scaled. Width and height are
; optional - a DropDownList sizes its own drop.
RC_P(x, y, w := "", h := "") {
    o := "x" . RC_S(x) . " y" . RC_S(y)
    if (w != "")
        o .= " w" . RC_S(w)
    if (h != "")
        o .= " h" . RC_S(h)
    return o
}

; The list nobody sees. It is a real ListView on a Gui that is never shown,
; and it is where the later legs write while Ultra is on - same columns, same
; code, same functions, only pointed somewhere else. LV_ talks to whichever
; Gui is the thread's default, which is the whole trick: RC_Use picks, and not
; one leg had to be told about any of this.
;
; Built at the end of the window's own building, then the default handed back,
; so the bare "Gui, Add" lines above are not left adding controls to it.
RC_QInit() {
    global RC_hQGui
    Gui, RCQ:New, +HwndRC_hQGui -Caption +ToolWindow
    Gui, RCQ:Add, ListView, x0 y0 w300 h300, Field|Value
    Gui, RC:Default
}

; The speed the window was left on. Unlike the old build this IS read back:
; the tool opens on Fast, the way it always did, and then stays wherever it
; is put - a machine left on Ultra comes up on Ultra tomorrow.
RC_SpeedLoad() {
    global RC_SPEED, RC_INI
    IniRead, v, %RC_INI%, RegoCheck, Speed, 1
    v += 0
    if (v < 0 || v > 2)
        v := 1
    RC_SPEED := v
}

; Which list the LV_ functions are talking to. Everywhere in this file that
; used to say "Gui, RC:Default" says this instead, so a leg running behind
; Ultra fills the hidden list and the window does not move.
RC_Use() {
    global RC_QUIET
    if (RC_QUIET)
        Gui, RCQ:Default
    else
        Gui, RC:Default
}

; Whether the bar and the clock are to stay still. Behind Ultra they do -
; unless the rows are landing in the window as the legs run, which is an
; Isuzu's Ultra, and then a bar standing still under rows still arriving
; would be a lie. The bar and the status cells live on the window, never on
; the hidden list, so whoever asks this and goes on to draw names the RC
; window first and puts the default back with RC_Use after.
RC_BarHush() {
    global RC_QUIET, RC_QBAR
    return (RC_QUIET && !RC_QBAR)
}

; Ultra with rows still to come in the window: an Isuzu the VIN letters
; named, whose block IDS finishes a few seconds after the register answered.
RC_QLive() {
    global RC_SPEED, RC_CTX
    return (RC_SPEED = 0 && IsObject(RC_CTX) && RC_CTX.isu) ? true : false
}

; --- the menu bar ----------------------------------------------------------

; The four menus across the top. Everything in them can already be done some
; other way - a button, a click on the status bar, the Escape key - which is
; the point: the menu is where someone who does not know the window yet can
; find out what it does, and the shortcuts beside the items say what to press
; next time instead.
RC_BuildMenus() {
    global RC_HIDEAFTER
    RC_HideAfterLoad()

    Menu, RC_MFile, Add, Hide to tray`tEsc, RC_MenuHide
    Menu, RC_MFile, Add
    Menu, RC_MFile, Add, Exit, RC_MenuExit

    ; Ultra, Fast and Full are the same three the status bar's right cell
    ; offers, and go through the same handler, so a change made in either place
    ; is the change the other one shows.
    Menu, RC_MOpt, Add, Ultra, RC_ModePick
    Menu, RC_MOpt, Add, Fast, RC_ModePick
    Menu, RC_MOpt, Add, Full, RC_ModePick
    Menu, RC_MOpt, Add
    Menu, RC_MOpt, Add, Hide after copy, RC_MenuHideAfter

    ; The tray menu is built here too rather than in the startup lines, so the
    ; hide setting has both the places it is shown in existence before the sync
    ; below goes looking for them to tick.
    Menu, Tray, Add, Show Rego check, RC_TrayShow
    Menu, Tray, Default, Show Rego check
    Menu, Tray, Add
    Menu, Tray, Add, Hide after copy, RC_MenuHideAfter

    RC_ModeSync()
    RC_HideAfterSync()

    ; The same four jumps as the tick boxes under the list, by name. Whether
    ; the catalog is actually open is not shown here - the boxes downstairs are
    ; the lights for that, kept fresh by the probe - and an item picked with no
    ; catalog open says so in the status bar, same as clicking the box does.
    Menu, RC_MCat, Add, Kia, RC_MenuCat
    Menu, RC_MCat, Add, Hyundai, RC_MenuCat
    Menu, RC_MCat, Add, Isuzu, RC_MenuCat
    Menu, RC_MCat, Add, BYD, RC_MenuCat

    Menu, RC_MHelp, Add, About Rego check, RC_MenuAbout

    Menu, RC_MBar, Add, &File, :RC_MFile
    Menu, RC_MBar, Add, &Options, :RC_MOpt
    Menu, RC_MBar, Add, &Catalogs, :RC_MCat
    Menu, RC_MBar, Add, &Help, :RC_MHelp
    Gui, RC:Menu, RC_MBar
}

; Put the tick beside whichever speed is in force. Called by RC_ModePick, so
; the menu agrees with the status bar however the speed was changed.
RC_ModeSync() {
    global RC_SPEED
    Menu, RC_MOpt, % (RC_SPEED = 0) ? "Check" : "Uncheck", Ultra
    Menu, RC_MOpt, % (RC_SPEED = 1) ? "Check" : "Uncheck", Fast
    Menu, RC_MOpt, % (RC_SPEED = 2) ? "Check" : "Uncheck", Full
}

; The same for the hide setting, in both places it is shown.
RC_HideAfterSync() {
    global RC_HIDEAFTER
    Menu, RC_MOpt, % RC_HIDEAFTER ? "Check" : "Uncheck", Hide after copy
    Menu, Tray, % RC_HIDEAFTER ? "Check" : "Uncheck", Hide after copy
}

; Read at startup, written the moment it is changed. Unlike the speed this one
; is kept: it is how someone wants the window to behave, not what they want out
; of the next search.
RC_HideAfterLoad() {
    global RC_HIDEAFTER, RC_INI
    IniRead, v, %RC_INI%, RegoCheck, HideAfterCopy, 1
    RC_HIDEAFTER := (v != 0)
}

RC_MenuHideAfter() {
    global RC_HIDEAFTER, RC_INI
    RC_HIDEAFTER := !RC_HIDEAFTER
    IniWrite, % RC_HIDEAFTER ? 1 : 0, %RC_INI%, RegoCheck, HideAfterCopy
    RC_HideAfterSync()
}

RC_MenuHide() {
    Gui, RC:Hide
}

RC_MenuExit() {
    ExitApp
}

; Named rather than read off the VIN - picking Isuzu from the menu means the
; Isuzu catalog, whatever is on screen. RC_CatJump says in the status bar if
; that catalog is not open.
RC_MenuCat(ItemName) {
    static BRAND := { Kia: "kia", Hyundai: "hyundai", Isuzu: "isuzu", BYD: "byd" }
    RC_CatJump(BRAND[ItemName], ItemName)
}

RC_MenuAbout() {
    global RC_VER
    MsgBox, 64, About Rego check
        , % "Rego check v" . RC_VER . "`n`n"
          . "Plate or VIN to registration details, wiper sizes and tyres.`n`n"
          . "Page Down brings the window up from anywhere.`n"
          . "Escape puts it away to the tray.`n"
          . "Enter searches - or opens the catalog when EPC is ringed.`n"
          . "Double-click any row to copy its value."
}

; The status bar's right cell names the speed in force, with a chevron to
; say it can be clicked.
RC_ModeCell() {
    global RC_SPEED
    ; SB_SetText only talks to the thread's default Gui - a menu pick's
    ; thread has none until it is named, and the cell silently stays stale.
    RC_Use()
    SB_SetText("  " . RC_SpeedWord(RC_SPEED) . " " . Chr(0x25BE), 3)
}

; The three settings by name, in the one place, so the cell, the two menus and
; the ini file cannot drift apart from one another.
RC_SpeedWord(n) {
    return (n = 2) ? "Full" : (n = 1) ? "Fast" : "Ultra"
}

; The right cell was clicked: a two-item menu pops where the mouse is, the
; current speed ticked. Picking writes the choice out like the old radios
; did, so the next start still knows it.
RC_ModeMenu() {
    global RC_SPEED
    Menu, RC_Mode, Add, Ultra, RC_ModePick
    Menu, RC_Mode, Add, Fast, RC_ModePick
    Menu, RC_Mode, Add, Full, RC_ModePick
    Menu, RC_Mode, % (RC_SPEED = 0) ? "Check" : "Uncheck", Ultra
    Menu, RC_Mode, % (RC_SPEED = 1) ? "Check" : "Uncheck", Fast
    Menu, RC_Mode, % (RC_SPEED = 2) ? "Check" : "Uncheck", Full
    Menu, RC_Mode, Show
}

RC_ModePick(ItemName) {
    global RC_SPEED, RC_INI, RC_CTX, RC_LastKey, RC_WipeRow, RC_T0
    global RC_QOn, RC_CACHE
    was := RC_SPEED
    RC_SPEED := (ItemName = "Full") ? 2 : (ItemName = "Fast") ? 1 : 0
    IniWrite, %RC_SPEED%, %RC_INI%, RegoCheck, Speed
    RC_ModeCell()
    ; Whichever of the two ways in was used, the other one shows the change.
    RC_ModeSync()

    ; Turning it down asks for nothing. What is on screen stays on screen -
    ; taking rows away from a car already looked up would only lose work that
    ; has been done - and the next search is the one that comes back thinner.
    if (RC_SPEED <= was)
        return

    ; Coming up off Ultra with a car on screen. The whole chain already ran
    ; behind it, into the hidden list, so the rest of the car goes up now -
    ; whole, in one go, without a single request leaving the machine. That is
    ; the point of Ultra: nothing was skipped, only kept out of the way.
    ; RC_QOn is put down by every new search, so if it is up it belongs to the
    ; car on screen. No need to ask RC_CTX, which a cache hit never builds.
    if (was = 0 && RC_QOn) {
        RC_QReveal()
        ; An Isuzu's Ultra never walked the shops - see RC_WipesWanted - so
        ; Full has a leg still to fetch, and carries on to the top-up below.
        if (!(RC_SPEED = 2 && IsObject(RC_CTX) && RC_CTX.key = RC_LastKey && !RC_CTX.full))
            return
    }

    ; An Isuzu on Fast is showing Fast's cut of what the legs found. Full
    ; wants every row, and the day's kept copy holds every row - so the list
    ; is painted back from there first, and the shops fetched on top of it.
    if (RC_SPEED = 2 && RC_IsIsu() && RC_LastKey != "" && RC_CACHE.HasKey(RC_LastKey)
        && IsObject(RC_CTX) && RC_CTX.key = RC_LastKey) {
        RC_Use()
        LV_Delete()
        RC_CachePaint(RC_LastKey)
        if (RC_CTX.full && RC_CTX.stage >= 3)
            return
    }

    ; Already showing everything this setting would ask for - a car revealed
    ; out of Ultra a moment ago, whose background legs went all the way. There
    ; is nothing to fetch and nothing to repaint.
    if (RC_LastKey != "" && RC_CACHE.HasKey(RC_LastKey)
        && (RC_CACHE[RC_LastKey].speed + 0) >= RC_SPEED
        && IsObject(RC_CTX) && RC_CTX.key = RC_LastKey && RC_CTX.stage >= 3)
        return

    ; Turning it up to Full with a car already on screen asks for the rest of
    ; that car straight away rather than making the plate be typed again. The
    ; register and the maker are already in, so only the shops and the wiper
    ; sizes are fetched - the three wiper rows Fast left out go in first, so
    ; there is somewhere for the sizes to land.
    if (RC_SPEED = 2 && was != 2 && IsObject(RC_CTX) && RC_CTX.key = RC_LastKey
        && !RC_CTX.full) {
        RC_CTX.full := true
        RC_Use()
        LV_Insert(RC_WipeRow,     "", "Wiper driver", "")
        LV_Insert(RC_WipeRow + 1, "", "Wiper passenger", "")
        LV_Insert(RC_WipeRow + 2, "", "Wiper rear", "")
        RC_FitList()
        ; The clock starts again from here. What the shops cost is worth
        ; reading; the minutes the car sat on screen first are not, and adding
        ; them in would have the top-up claiming to have taken all afternoon.
        RC_T0 := A_TickCount
        ; A leg still in the air will see the change and carry on into the
        ; shops itself; a finished search needs the timer started again.
        if (RC_CTX.stage >= 2)
            SetTimer, RC_Rest, -60
        return
    }

    ; Nothing on screen to build on - the plate in the box is searched afresh.
    if (RC_SPEED = 2 && was != 2 && RC_LastKey != "")
        RC_OnSearch()
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

; How long the search has taken so far, in the status bar's middle cell. The
; later legs call this as they go, so the number climbs while the shops are
; being asked and comes to rest on the whole search rather than on the first
; leg of it. Nothing to say before a search has started.
RC_TimeCell() {
    global RC_T0
    if (!RC_T0 || RC_BarHush())
        return
    Gui, RC:Default
    SB_SetText("  " . Round((A_TickCount - RC_T0) / 1000, 1) . " s", 2)
    RC_Use()
}

; Waiting for a plate. Just the invitation, in the status bar.
RC_Ready() {
    global RC_SPEED, RC_SB_LAST
    RC_Use()
    RC_BarDown()
    RC_SB_LAST := "  Type a plate or VIN and press Enter."
    SB_SetText(RC_SB_LAST, 1)
    SB_SetText("", 2)
    RC_ModeCell()
}

; A leg of the search just finished. Note how long it took, measured from the
; end of the leg before it, and hand the clock on.
RC_Tick(label) {
    global RC_TIMING, RC_TSEQ, RC_TLAST
    if (!RC_TIMING)
        return
    now := A_TickCount
    if (RC_TLAST = 0)
        RC_TLAST := now
    RC_TSEQ .= (RC_TSEQ = "" ? "" : " ") . label . "=" . (now - RC_TLAST)
    RC_TLAST := now
}

; Write what has been noted so far into the day book and start again. Called
; once when the register's answer goes up and once more when the later legs
; have finished, so the two halves of a search are timed apart.
RC_TFlush(tag) {
    global RC_TIMING, RC_TSEQ, RC_LOG, RC_SPEED, RC_T0
    if (!RC_TIMING || RC_TSEQ = "")
        return
    line := A_YYYY . "-" . A_MM . "-" . A_DD . " " . A_Hour . ":" . A_Min
          . "  timing " . tag . " speed=" . RC_SPEED
          . " at=" . (A_TickCount - RC_T0) . " " . RC_TSEQ . "`n"
    FileAppend, %line%, %RC_LOG%
    RC_TSEQ := ""
}

; --- the loading bar --------------------------------------------------------
;
; What it can and cannot do, because the second half decides the design.
;
; Every request this tool makes used to be a blocking WinHTTP call on the
; window's own thread - frozen while one was in flight, no timers, no
; repaints. The transport (lib\AudosHttp.ahk) now asks async and polls with a
; sleep between, so the window takes its clicks and its timers during a
; request. The bar was not changed to match: it still moves on the real
; events and slides rather than jumps between them, so every position it
; takes is something that actually happened. A bar that crawled along on a
; timer during a request would be painting a guess about work it cannot see.
;
; The distance is Zeno's: a leg that finishes covers a share of what is LEFT,
; not a share of the whole. A search cannot know how many legs it will need -
; VicRoads usually answers on the first and the other five never run - so there
; is no honest denominator to count towards. Closing a third of the gap each
; time always advances, never overstates, and never runs out of room. It stops
; short of the end until the search is genuinely finished.
;
; This replaces a counter that only ever reported step 1 of 3, so the bar sat
; at a third for the whole search and then vanished - the "loads halfway and
; then boom, done" of it.

; How far the bar is allowed to creep before the answer is actually in. The
; last few percent belong to being finished and nothing else.
global RC_BAR_CEIL := 96

; Where the bar is now, so a slide knows where it is starting from, and
; whether it is up at all - an answer that came out of the cache never put it
; up, and must not be made to sit through it being filled and taken down.
global RC_BAR := 0
global RC_BAR_ON := false

; What the first status cell said before the bar went up over the top of it.
global RC_SB1 := ""

; And what it says now - kept as it is written rather than asked of the control
; when it is wanted, because a status bar read back inside the process that owns
; it answers with nothing often enough to lose the line entirely.
global RC_SB_LAST := ""

; Put the bar where it is told, now.
;
; The bar is a drawing, so this draws it: there is nothing here that could set
; off towards a position on its own and arrive later.
;
; That is worth saying, because a themed progress bar - which this was - does
; exactly that, and every position it was given was set immediately before the
; thread went off and blocked on somebody's website. The glide never got its
; timer messages and the bar stopped dead wherever the blocking caught it, six
; times a search. There is no glide left to lose.
;
; A move too small to look any different is not drawn at all. The easing asks
; for six positions a leg and most of them land on the same pixel.
RC_BarPos(pct) {
    global RC_hLoadBar, RC_BAR_W, RC_BAR_H, RC_BAR_R, RC_BAR_BG, RC_BAR_PX
    ; A search that has already answered and is quietly filling itself in
    ; behind the scenes is finished as far as anyone watching is concerned,
    ; and a bar creeping along the bottom says the opposite. Unless the rows
    ; are still landing in the window - see RC_BarHush.
    if (RC_BarHush())
        return
    if (pct < 0)
        pct := 0
    else if (pct > 100)
        pct := 100
    fw := Round(RC_BAR_W * pct / 100)
    if (fw = RC_BAR_PX)
        return
    RC_BAR_PX := fw
    RC_SetPic(RC_hLoadBar, RC_BarBmp(RC_BAR_W, RC_BAR_H, RC_BAR_R, fw
                                   , RC_Argb("E8E8E8"), RC_Argb("0067C0"), RC_BAR_BG))
}

; The bar up, and the words underneath it out of sight.
;
; The bar rides on the first status cell but it does not cover it: it sits a
; couple of pixels in on every side and its ends are rounded, so whatever the
; cell last said reads out around the edges and through the two corners - the
; leftover text behind the loading bar. The cell is emptied while the bar is
; up and given its words back when it comes down.
RC_BarUp() {
    global RC_BAR_ON, RC_SB1, RC_SB_LAST
    if (RC_BarHush())
        return
    Gui, RC:Default
    if (!RC_BAR_ON) {
        ; What the cell says is remembered as it is written, never read back off
        ; the control. StatusBarGetText asked from inside the process that owns
        ; the bar hands back nothing as often as not - it did here - and the
        ; line was then blanked with an empty stash behind it and lost for good.
        ; It never showed on an ordinary search, because the register's answer
        ; writes the line again a moment later; turning the speed up writes no
        ; line of its own, so there the cell simply stayed empty.
        RC_SB1 := RC_SB_LAST
        SB_SetText("", 1)
    }
    GuiControl, RC:Show, RC_LoadBar
    RC_BAR_ON := true
    RC_Use()
}

; The bar away, and the words back. Whoever wanted something else in the cell
; writes it straight after this and never sees the old line.
RC_BarDown() {
    global RC_BAR, RC_BAR_ON, RC_SB1, RC_SB_LAST
    if (RC_BarHush())
        return
    Gui, RC:Default
    GuiControl, RC:Hide, RC_LoadBar
    RC_BarPos(0)
    RC_BAR := 0
    RC_BAR_ON := false
    if (RC_SB1 != "") {
        RC_SB_LAST := RC_SB1
        SB_SetText(RC_SB1, 1)
        RC_SB1 := ""
    }
    RC_Use()
}

; The start of a search: back to nothing, and up.
RC_BarStart() {
    global RC_BAR
    RC_Use()
    RC_BAR := 0
    RC_BarPos(0)
    RC_BarUp()
    ; Nothing of the last search's line is wanted back after this one - it will
    ; have its own to say - so the stash is dropped rather than restored.
    RC_BarForget()
}

; Keep the bar up but stop it handing any words back when it goes down.
RC_BarForget() {
    global RC_SB1, RC_SB_LAST
    RC_SB1 := ""
    ; The line itself is dropped too, not just the stash: a search that is
    ; starting has no use for what the one before it found, and leaving it
    ; behind would let the old state's name come back under the new answer.
    RC_SB_LAST := ""
}

; Say something in the first status cell - or hold it until there is somewhere
; to say it. The register's answer lands while the bar is still up and working
; through the later legs, and a line written under the bar shows only in the
; gaps around it. Held here, it goes in whole the moment the bar is down.
RC_Say(text) {
    global RC_BAR_ON, RC_SB1, RC_SB_LAST
    if (RC_BarHush())
        return
    Gui, RC:Default
    if (RC_BAR_ON) {
        RC_SB1 := text
        SB_SetText("", 1)
    } else {
        RC_SB_LAST := text
        SB_SetText(text, 1)
    }
    RC_Use()
}

; Slide to a position. Eased out - most of the distance goes by early, which is
; what reads as movement rather than a slow even crawl. Backwards is set
; straight, since the later legs pick the bar up again lower down than the
; register leg left it.
;
; Only ever called where the thread is its own. The sleeps are the animation;
; they are also why nothing calls this in a tight loop.
RC_BarTo(pct, ms := 90) {
    global RC_BAR
    ; Not just invisible - not even the tenth of a second the easing sleeps
    ; for. A background leg should cost the window nothing at all.
    if (RC_BarHush())
        return
    Gui, RC:Default
    pct := Round(pct)
    if (pct > 100)
        pct := 100
    if (pct <= RC_BAR) {
        RC_BAR := pct
        RC_BarPos(pct)
        RC_Use()
        return
    }
    steps := 6
    from := RC_BAR
    gap := pct - from
    Loop, %steps%
    {
        f := 1 - (1 - A_Index / steps) ** 2
        RC_BarPos(from + gap * f)
        Sleep, % Round(ms / steps)
    }
    RC_BAR := pct
    RC_BarPos(pct)
    RC_Use()
}

; About to go under: a small step in, quickly, so the bar has visibly moved
; before the window stops answering for a second or two.
RC_BarBusy() {
    global RC_BAR, RC_BAR_CEIL
    RC_BarTo(RC_BAR + (RC_BAR_CEIL - RC_BAR) * 0.18, 40)
}

; A leg came back and another one is going to run: a third of what is left.
RC_BarLeg() {
    global RC_BAR, RC_BAR_CEIL
    RC_BarTo(RC_BAR + (RC_BAR_CEIL - RC_BAR) * 0.34)
}

; The end of the search. Full, held long enough to be seen, then away.
;
; park is for the search that is not really over: on Full the later legs pick
; the bar straight back up, so the register leg hands over at the mark those
; legs start from instead of filling and emptying for no reason.
RC_BarEnd(park := 0) {
    global RC_BAR_ON, RC_hLoadBar
    if (RC_BarHush())
        return
    ; Nothing was ever put up - an answer straight out of the cache. There is
    ; no bar to fill and a quarter of a second spent filling one nobody can see
    ; would be a quarter of a second off the fastest answer the tool gives.
    ;
    ; If one is on screen all the same then the flag has come loose from what
    ; the eye can see, and the flag is not the thing to believe: take it down,
    ; without the filling, rather than leave a bar sitting there for good.
    if (!RC_BAR_ON) {
        if (DllCall("IsWindowVisible", "Ptr", RC_hLoadBar))
            RC_BarDown()
        return
    }
    if (park > 0) {
        RC_BarTo(park)
        return
    }
    RC_BarTo(100, 110)
    Sleep, 140
    RC_BarDown()
}

; The end of it: the word - "Found in VIC" when a state answered - the time
; it took, and the speed it ran at, one status bar cell each.
RC_Done(ok, word, detail := "") {
    global RC_T0, RC_SPEED, RC_FoundIn, RC_VinVal
    RC_Use()
    RC_TFlush("first")
    ; The search is over one way or the other, so the button stops saying
    ; "Loading...". A ring the VIN put up stays up; the plain word comes back
    ; for a no-record, a bad plate, or a make no catalog covers.
    RC_EpcWait(false)
    ; Read before the bar is finished off, never after: filling it takes a
    ; quarter of a second and that quarter is the animation's, not the search's.
    ; A 2.3 s search has to still say 2.3 s.
    took := RC_T0 ? "  " . Round((A_TickCount - RC_T0) / 1000, 1) . " s" : ""
    mark := ok ? Chr(0x2713) : Chr(0x2715)
    ; Taken before the word is rewritten below: a car came back, as opposed to
    ; "Copied" off a double-click, which says nothing about what is on screen.
    hit := (ok && word = "Success")
    ; A car that came back is only half the job. The later legs - the VIN
    ; decode, the fitment shops, the wiper sizes - are armed on a timer by every
    ; path that gets here with one, on Fast as much as on Full, and they take
    ; the bar on from 45. So the register leg hands over at 42 rather than
    ; filling the bar and emptying it to start again a fifth of a second later,
    ; which is the double-fill this used to do.
    ;
    ; "kept" is the exception: that answer came out of the cache, no leg ran and
    ; none is going to.
    ;
    ; Ultra is the other exception. Its legs do run, but they run behind the
    ; window and never touch the bar, so a bar parked at 42 waiting for them
    ; would sit there part-filled for good. On Ultra the search really is over
    ; the moment this is reached: fill it and take it down.
    ;
    ; Except an Isuzu's Ultra, whose block of rows keeps landing in the window
    ; after this while IDS is asked. There the bar carries on as it does on
    ; Fast, and comes down with the clock's final number when the last row
    ; is in - RC_QLive says which, RC_QBAR lets the bar through.
    RC_BarEnd((hit && detail != "kept" && (RC_SPEED != 0 || RC_QLive())) ? 42 : 0)
    ; "Success" becomes the state's name when one answered; other words -
    ; "Copied" off a double-click - say what they came to say.
    if (ok && word = "Success" && RC_FoundIn != "")
        word := "Found in " . RC_FoundIn
    if (detail != "")
        word .= "  " . Chr(0xB7) . " " . detail
    RC_Say("  " . mark . "  " . word)
    SB_SetText(took, 2)
    RC_ModeCell()

    ; A search that came back with one of the four catalogs' cars leaves the
    ; ring up round EPC, so the next Enter goes there.
    if (hit)
        RC_EpcHot(RC_BrandOfVin(RC_VinVal) != "")
}

; Put the ring round the EPC button up or down, and with it the meaning of the
; next Enter. Cheap to call with the answer it already has, so callers need not
; keep track of which way it was left.
RC_EpcHot(on) {
    global RC_EPCHOT, RC_EPCWAIT, RC_EPC_BG, RC_EPC_BG_HOT
    global RC_hEpcBtn, RC_BTN_FILL
    if (RC_EPCHOT = on)
        return
    RC_EPCHOT := on
    ; Armed is ready: whatever "Loading..." was waiting on has arrived.
    if (on)
        RC_EPCWAIT := false
    RC_Use()
    GuiControl, % "RC:" . (on ? "Show" : "Hide"), RC_EpcRing
    ; The face is a colour the paint reads, so arming the button is a word and
    ; a repaint - no second bitmap kept alive waiting for the swap back.
    RC_BTN_FILL[RC_hEpcBtn] := on ? RC_EPC_BG_HOT : RC_EPC_BG
    GuiControl, RC:, RC_EpcBtn, % RC_EpcLabel()
    RC_BtnPaint(RC_hEpcBtn)
}

; The word on the button for the state it is in: armed beats waiting beats
; resting.
RC_EpcLabel() {
    global RC_EPCHOT, RC_EPCWAIT, RC_EPC_LBL, RC_EPC_LBL_HOT, RC_EPC_LBL_WAIT
    return RC_EPCHOT ? RC_EPC_LBL_HOT : (RC_EPCWAIT ? RC_EPC_LBL_WAIT : RC_EPC_LBL)
}

; "Loading..." up or down. Up at the start of every search; down when the ring
; goes up (RC_EpcHot does that itself) or when the search ends without one.
; With the ring up there is nothing to paint - the armed label already says
; more than the waiting one would.
RC_EpcWait(on) {
    global RC_EPCWAIT, RC_EPCHOT, RC_hEpcBtn
    if (RC_EPCWAIT = on)
        return
    RC_EPCWAIT := on
    if (RC_EPCHOT)
        return
    RC_Use()
    GuiControl, RC:, RC_EpcBtn, % RC_EpcLabel()
    RC_BtnPaint(RC_hEpcBtn)
}

; Enter. With the ring up it opens the catalog for the car already on screen;
; otherwise it searches, the way it always has.
RC_OnEnter() {
    global RC_EPCHOT
    if (RC_EPCHOT) {
        RC_EpcHot(false)
        RC_OnEpc()
        return
    }
    RC_OnSearch()
}

; Typing in the plate box means the next Enter is meant for a new search, not
; for the car the ring is still pointing at. GuiControl's own writes do not
; come through here, so filling the box in code leaves the ring alone.
RC_OnPlate() {
    RC_EpcHot(false)
}

; Any click in the window: the mouse is in use, so Enter is not being aimed at
; the EPC button any more. The window the click landed on is walked up to its
; top-level owner rather than trusting A_Gui, which is only filled in when the
; message went to the window itself and not to one of its controls.
RC_OnLDown(wParam, lParam, msg, hwnd) {
    global RC_hGui
    static GA_ROOT := 2
    if (DllCall("GetAncestor", "Ptr", hwnd, "UInt", GA_ROOT, "Ptr") = RC_hGui)
        RC_EpcHot(false)
}

; The list is built at its tallest, then trimmed to whatever the answer
; actually filled - and everything under it, right down to the bottom edge of
; the window, comes up to meet it. A short answer gets a short window; a long
; one grows until the list would be taller than a screenful of rows.
RC_FitList() {
    global RC_hLV, RC_hGui, RC_PadW, RC_PadH, RC_QUIET, RC_NOFIT, RC_SPEED
    ; Nothing to fit while the legs are filling the hidden list - there is no
    ; window behind it - and nothing to fit for a list that is one line away
    ; from being cut back to two rows either, or it would grow and shrink in
    ; the one breath and be seen doing it.
    if (RC_QUIET || RC_NOFIT)
        return
    ; The list starts at 150 and the base window puts its bottom at 498;
    ; under it sit the catalog tick boxes and then the status bar, which
    ; docks itself to the bottom edge on every resize. The tick boxes are
    ; slid to follow the list's bottom below. All scaled the same way the
    ; layout was, so this arithmetic and the built window agree at any DPI.
    LIST_Y := RC_S(150), BASE_B := RC_S(498), BASE_H := RC_S(560)
    RC_Use()
    n := LV_GetCount()

    ; Rows are measured, not guessed - the row height follows the font and the
    ; screen's scaling. The top of the first row is the header's height.
    top := RC_S(22)
    rowH := RC_S(20)
    if (n >= 1) {
        VarSetCapacity(rc, 16, 0)
        NumPut(0, rc, 0, "Int")
        SendMessage, 0x100E, 0, &rc, , ahk_id %RC_hLV%     ; LVM_GETITEMRECT
        if (ErrorLevel != "FAIL" && ErrorLevel) {
            t := NumGet(rc, 4, "Int")
            r := NumGet(rc, 12, "Int") - t
            if (t > 0 && t < RC_S(60) && r >= RC_S(12) && r <= RC_S(44)) {
                top := t
                rowH := r
            }
        }
    }

    ; Never so short that the window looks broken, never so tall that it runs
    ; off the bottom of the screen.
    ;
    ; Ultra is the exception at the short end. Its answer is three rows by
    ; design, and three rows of answer sitting on three rows of nothing reads
    ; as a list that failed to fill rather than one that is meant to be short.
    ; With an empty list it keeps the floor all the same: that is the window
    ; before the first search, and it would come up as a bare header strip.
    min := (RC_SPEED = 0 && n > 0) ? 1 : 6
    if (n < min)
        n := min
    if (n > 22)
        n := 22

    h := top + rowH * n + RC_S(8)
    delta := (LIST_Y + h) - BASE_B
    GuiControl, RC:MoveDraw, RC_List, h%h%

    ; The catalog tick boxes ride 8px under the list, wherever it ends.
    cbY := LIST_Y + h + RC_S(8)
    GuiControl, RC:MoveDraw, RC_ChkKia, y%cbY%
    GuiControl, RC:MoveDraw, RC_ChkHyu, y%cbY%
    GuiControl, RC:MoveDraw, RC_ChkIsu, y%cbY%
    GuiControl, RC:MoveDraw, RC_ChkByd, y%cbY%

    prev := A_DetectHiddenWindows
    DetectHiddenWindows, On
    WinGetPos, wx, wy, , , ahk_id %RC_hGui%
    WinMove, ahk_id %RC_hGui%, , wx, wy, RC_S(420) + RC_PadW, BASE_H + delta + RC_PadH
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
    RC_Use()
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
    static ACRO := ",CVT,AT,MT,DCT,DSG,AMT,AWD,RWD,FWD,2WD,4WD,SUV,LPG,GT,EV,BEV,PHEV,MHEV,HEV,ABS,LWB,SWB,VIN,USA,LED,LSU,LST,LSM,"
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
RC_PrettyRows(hint := "", make := "") {
    ; Not called CASE - that is a keyword, and a variable by that name is not
    ; the same thing to the parser.
    static WORDS := ",Colour,Version,Series,Runflat,Factory spec,Model,"
    static BODY  := ",Body type,Cab/Body,"
    RC_Use()
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        LV_GetText(v, A_Index, 2)
        if (v = "")
            continue
        if InStr(BODY, "," . f . ",")
            v2 := RC_BodyText(v, hint, make)
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
    global RC_TSEQ, RC_TLAST, RC_GEN, RC_CTX
    RC_Use()
    RC_T0 := A_TickCount
    RC_TSEQ := ""
    RC_TLAST := RC_T0

    ; A new search. Anything the last one still has in the air is now stale -
    ; the count says so, and the legs check it before they paint. The ring goes
    ; down with it: it belongs to the car being replaced, and the VIN landing
    ; on the band puts it back up if the new one is a catalog make too. Until
    ; then the button reads "Loading..." - waiting goes up first so the one
    ; repaint below shows it.
    ;
    ; gen is this search's number. The requests below let the window pump
    ; while they wait, so an Enter can start another search in the middle of
    ; this one; when that one is done and this one resumes, the number has
    ; moved and this one says nothing more.
    RC_GEN += 1
    gen := RC_GEN
    RC_CTX := ""
    RC_EpcWait(true)
    RC_EpcHot(false)
    GuiControlGet, plate, RC:, RC_Plate
    plate := RC_Norm(plate)

    ; Seventeen characters is a VIN, anything shorter is a plate. Only VicRoads
    ; will take a VIN - the other four states only have a box for a plate.
    isVIN := (StrLen(plate) = 17)

    ; Whatever Ultra was holding back for the last car goes with it.
    RC_QClear()
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

    ; A typed VIN is the VIN: it goes on the band before a single request
    ; leaves, and with it the ring, when a catalog knows the make - the EPC
    ; jump needs nothing the register is about to say.
    if (isVIN)
        RC_SetVin(plate)

    ; An Isuzu VIN names most of the truck by itself - the model, the year,
    ; the engine and the drive are all in the letters - so that much goes up
    ; before a single request leaves, and the register only adds the plate
    ; and the expiry to it.
    if (isVIN && SubStr(plate, 1, 3) = "MPA") {
        t := { vin: plate, badge: "ISUZU" }
        if RC_IsuSeed(t)
            RC_SetMake("ISUZU", RC_IsuLine(t), "")
    }

    ; Something is going to go over the wire now - a cache hit turned back
    ; above without one. The bar starts empty here and nowhere else.
    RC_BarStart()

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
    if (RC_GEN != gen)
        return

    if (isVIN) {
        if RC_FillEzyVin(plate)
            return
        if (RC_GEN != gen)
            return
        msg := "No record of that VIN in VIC or on EzyParts."
    } else {
        if RC_FillEzyPlate(plate)
            return
        if (RC_GEN != gen)
            return
        if RC_Walk(["SA", "ACT", "WA", "QLD"], plate, mode, tried, errors)
            return
        if (RC_GEN != gen)
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
    global RC_CTX, RC_GEN
    RC_Use()
    gen := RC_GEN
    for i, st in order {
        ; Move the bar in a little, then let the window repaint, before the
        ; state is asked and the bar stands still for a second or two.
        RC_BarBusy()
        Sleep, 20

        text := RC_State(st, plate, mode)
        ; Another search started while this state was being asked, and has
        ; had its say. Whatever this one holds is about the wrong car now:
        ; answered, so the caller stops too, and nothing painted.
        if (RC_GEN != gen)
            return true
        ; The tick says how the state answered as well as how long it took:
        ; a plate it does not hold, a site that would not answer, or a car.
        RC_Tick("state." . st . ((SubStr(text, 1, 1) = "!") ? ".err" : (text = "") ? ".none" : ""))

        ; A leading "!" is the state itself failing, not the plate being absent.
        ; Note it, keep going - another state may still have the car.
        if (SubStr(text, 1, 1) = "!") {
            errors .= (errors = "" ? "" : "; ") . st . ": " . SubStr(text, 2)
            tried  .= (tried = "" ? "" : ", ") . st
            RC_BarLeg()
            continue
        }

        tried .= (tried = "" ? "" : ", ") . st

        ; Empty means that state simply has no such plate. Try the next one.
        if (text = "") {
            RC_BarLeg()
            continue
        }

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
        if (IsObject(RC_CTX))
            RC_CTX.note := note
        ; Kept as a register-only copy - speed 0 - so a second asking today
        ; still walks the legs this one has not run yet.
        RC_CacheSave(plate, note, 0)

        ; The register has answered and the window is the user's again. The
        ; rest of the chain runs from a timer, which means typing the next
        ; plate does not have to wait on a website nobody is looking at yet.
        SetTimer, RC_Rest, -60
        return true
    }
    return false
}

; Put the answer in the list. Only the rows worth reading are kept, and the
; labels each state uses are close enough to match by pattern rather than by
; exact wording. Anything else the state sent is dropped on the floor.
RC_Fill(text, plate, vin := "", ByRef make := "", st := "") {
    global RC_RedRow, RC_WipeRow, RC_ModelPick
    global RC_CTX, RC_GEN, RC_LastKey, RC_SPEED
    RC_Use()
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
        ; "Current - 16/05/2027" reads as a sentence, not a sum.
        exp := StrReplace(exp, " - ", ", ")
        row := LV_Add("", "Expiry", exp)
        ymd := RC_ExpiryDate(exp)
        if (ymd != "" && ymd < SubStr(A_Now, 1, 8))
            RC_RedRow := row
    }

    rest := [ ["Year",          "i)^year|year of manufacture|build year"]
            , ["Body type",     "i)body"]
            , ["Colour",        "i)colou?r"]
            , ["Engine number", "i)engine"] ]
    ; On Fast an Isuzu shows the dealer system's rows and not the register's:
    ; the year and the drive go in the line under the make, the colour comes
    ; back from IDS with its paint code on, and the body is in the model
    ; words. Ultra still takes all four - they go to the hidden list, which
    ; holds the whole car for Full.
    isuThin := (InStr(make, "ISUZU") && RC_SPEED = 1 && SubStr(vin, 1, 3) = "MPA")
    for i, r in rest {
        val := RC_Pick(labels, values, r[2])
        if (val != "" && !isuThin)
            LV_Add("", r[1], val)
    }

    ; Three wiper rows on Full, and on Ultra too - Ultra walks the whole chain
    ; behind the window, so it needs somewhere to put the sizes. Only Fast
    ; skips them, and there the anchor still has to point past the last row so
    ; the extra rows the VIN decode turns up know where to land.
    if RC_WipesWanted(make) {
        RC_WipeRow := LV_Add("", "Wiper driver", "")
        LV_Add("", "Wiper passenger", "")
        LV_Add("", "Wiper rear", "")
    } else
        RC_WipeRow := LV_GetCount() + 1
    year := RC_Pick(labels, values, "i)^year|year of manufacture|build year")
    body := RC_Pick(labels, values, "i)body")
    colour := RC_Pick(labels, values, "i)colou?r")

    ; That is the register's whole answer, and it cost one request - about two
    ; seconds. Everything past here is somebody else's website and another two
    ; to five on top, so it is left to RC_Rest, which runs from a timer once
    ; this answer is already on screen and the window is the user's again.
    ; What those later legs need is put aside now.
    rego := (plate != "") ? plate : RC_Norm(reg)
    RC_CTX := { gen: RC_GEN, key: RC_LastKey, rego: rego, st: st, src: "state"
        , make: make, badge: make, vin: vin, year: year, body: body
        , colour: colour
        , bodyHint: "", vinModel: "", vinYear: "", genTag: "", mkX: "", trm: ""
        , yearWeak: false, note: "", stage: 1, full: RC_WipesWanted(make)
        , cabDone: false }

    ; The states register a Genesis as a HYUNDAI, but the badge says GENESIS -
    ; a Hyundai's VIN starts KMH, a Genesis' KMT or KMU. The badge is put right
    ; for the window straight away; the registered name is what the lookups
    ; below keep using, because that is the name those sites know.
    if (InStr(make, "HYUNDAI") && (SubStr(vin, 1, 3) = "KMT" || SubStr(vin, 1, 3) = "KMU"))
        RC_CTX.badge := "GENESIS"

    ; An Isuzu is read off its VIN here and now. The model, the year, the
    ; engine and the drive cost nothing, so they go up with the register's
    ; answer instead of queueing behind the dealer system in the next leg.
    if (InStr(RC_CTX.badge, "ISUZU") && RC_IsuSeed(RC_CTX)) {
        RC_NOFIT := (RC_SPEED = 0)
        RC_TagShow()
        RC_NOFIT := 0
    } else
        RC_SetMake(RC_CTX.badge, "", st)
    RC_PrettyRows("", RC_CTX.badge)
    RC_DropDupes()
    ; Ultra: the answer just built is handed to the hidden list and the window
    ; cut back to the rego and the expiry. Done before the list is fitted, so
    ; the window is sized once, to what it is going to show.
    if (RC_SPEED = 0)
        RC_QSeed()
    RC_FitList()
    RC_Tick("rows")
}

; The slow half of a search, one leg at a time, run from a timer after the
; register's answer is already up. Between the legs the window pumps its own
; messages, so a second search can overtake this one - RC_GEN says whether it
; has, and an overtaken leg throws away whatever it came back with rather than
; painting it over somebody else's car.
RC_Rest() {
    global RC_SPEED, RC_QUIET, RC_QOn, RC_QBAR
    ; On Ultra the whole of the rest of the chain runs behind the window: same
    ; legs, same order, same everything, written into the hidden list. The
    ; guard is a try because a leg that throws must not leave the window mute
    ; - every drawing thing in this file is asking RC_QUIET, and one left
    ; standing would silence the tool until it was restarted.
    RC_QUIET := (RC_SPEED = 0 && RC_QOn) ? 1 : 0
    ; An Isuzu's rows land in the window as these legs run, so for that one
    ; the bar and the clock run with them and stop when the rows do.
    RC_QBAR := (RC_QUIET && RC_QLive()) ? 1 : 0
    try {
        RC_Rest0()
    } catch e {
        RC_QUIET := 0
        RC_QBAR  := 0
        RC_Use()
        throw e
    }
    RC_QUIET := 0
    RC_QBAR  := 0
    RC_Use()
}

RC_Rest0() {
    global RC_CTX, RC_GEN
    if (!IsObject(RC_CTX) || RC_CTX.gen != RC_GEN)
        return
    ; A plate the states answered and a plate only EzyParts holds are put
    ; together from different sources, so each has its own pair of later legs.
    ezy := (RC_CTX.src = "ezy")
    if (RC_CTX.stage = 1) {
        if (ezy)
            RC_EzyStage2()
        else
            RC_Stage2()
        if (!IsObject(RC_CTX) || RC_CTX.gen != RC_GEN)
            return
        RC_CTX.stage := 2
    }
    if (RC_CTX.stage = 2 && RC_CTX.full) {
        if (ezy)
            RC_EzyStage3()
        else
            RC_Stage3()
        if (!IsObject(RC_CTX) || RC_CTX.gen != RC_GEN)
            return
        RC_CTX.stage := 3
    } else if (RC_CTX.stage = 2 && !RC_CTX.cabDone && InStr(RC_CTX.badge, "ISUZU")
               && RC_SPEED != 0
               && RC_HasCab(RC_CTX.body)
               && (RC_CabType(RC_CTX.bodyHint) = "" || RC_BodyStyle(RC_CTX.bodyHint) = "")) {
        RC_IsuzuCab()
        if (!IsObject(RC_CTX) || RC_CTX.gen != RC_GEN)
            return
        ; The stage stays at two. This leg is not leg three and must not be
        ; mistaken for it: turning the speed up afterwards comes back through
        ; here for the shops and the wiper sizes, and a search left sitting at
        ; three matches neither arm above and quietly does nothing at all - the
        ; window keeps its blank wiper rows and never says why.
        RC_CTX.cabDone := true
    }
    RC_TimeCell()
    RC_RestBar(0, false)
    RC_TFlush("rest")
}

; The bar along the bottom keeps moving while the later legs run - a window
; that is still working should not look like one that has finished. The status
; line is left alone: it already says where the car was found and how long
; that took, which is the number worth reading.
; These legs DO know how far along they are - each one is a named shop being
; asked a named question - so they name their own percentages rather than going
; through Zeno. They slide there like everything else.
RC_RestBar(pct, show := true) {
    ; Behind Ultra there is no bar and no clock - the search said its piece
    ; and sat down. Everything past here is for a window that is watching,
    ; and an Isuzu's Ultra is watching (RC_BarHush).
    if (RC_BarHush())
        return
    ; Every leg out here moves the clock on as well as the bar. RC_Done wrote
    ; the seconds when the register answered and never wrote them again, so a
    ; five second search sat there claiming two: the number stopped at the end
    ; of the first leg and the other three ran on underneath it. Read before
    ; the bar is finished off, the same as RC_Done reads it - the quarter
    ; second the bar takes to fill is the animation's, not the search's.
    RC_TimeCell()
    if (!show) {
        RC_BarEnd()
        return
    }
    ; Up through RC_BarUp, never a bare Show. A bar shown behind the flag's
    ; back is a bar RC_BarEnd will decline to take down again: these legs run
    ; on every answer, including the ones served out of the cache with the bar
    ; never raised, and that was the bar left standing at the end of a Full
    ; search. RC_BarUp is also what gets the words out from under it.
    RC_BarUp()
    RC_BarTo(pct)
}

; Leg two: some maker will name the car from its VIN, which is the one thing
; the states never say. Kia answers for its own cars; Hyundai and Genesis have
; no such page, but the US regulator's decoder knows most of them. Any other
; make, or no VIN, and this is skipped.
RC_Stage2() {
    global RC_CTX, RC_RedRow, RC_WipeRow
    RC_Use()
    c := RC_CTX
    vin := c.vin, make := c.make, year := c.year, body := c.body
    vinModel := ""
    vinYear  := ""
    genTag   := ""
    mkX      := ""
    trm      := ""
    RC_RestBar(45)
    if (vin != "" && InStr(make, "KIA")) {
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
        hX := ""
        hTrim := ""
        vinModel := RC_HmcVin(vin, genTag, hX, hTrim, vinYear)
        if (vinModel != "") {
            mkX := hX
            trm := hTrim
        } else {
            RC_RestBar(60)
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
    RC_Tick("build")

    ; Isuzu names nothing itself. Its own VIN sheet settles most of it though -
    ; the model, the exact build year, the generation, the engine and the
    ; driveline all sit in the VIN. When the sheet has nothing the body type
    ; still names the model: Isuzu builds exactly two cars, the ute is a D-MAX
    ; and the SUV is an MU-X. The year alone cannot always name the generation
    ; - 2019 and 2020 sit in two of them at once - but the VIN can: characters
    ; seven and eight carry the engine, and Isuzu's own engine guide names
    ; them. 54 is the 4JA1 and 77 the 4JH1 of the first ute, 85 the 4JJ1 and
    ; 86 the 4JK1 of the second, 87 the 4JJ3 of the current one. Every one of
    ; them burns diesel, so the engine code also fills the brackets beside the
    ; make. The trim is the one thing the VIN does not carry - the fitment
    ; shops have the last word on that, in leg three.
    if (InStr(make, "ISUZU")) {
        ; Isuzu's own dealer system first. It is the only place that knows the
        ; model code this truck was built to, what that code says in words, the
        ; group and the paint - and the words carry the cab, which is the one
        ; thing the register never says and the VIN does not hold. Everything
        ; below is a guess off the VIN by comparison, so it goes second and
        ; fills what IDS left blank. When IDS cannot be reached the search
        ; carries on exactly as it did before any of this existed.
        if (vin != "") {
            RC_RestBar(50)
            ids := RC_IdsVin(vin)
            RC_Tick("ids")
            if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
                return
            if (IsObject(ids)) {
                RC_IdsRows(ids, vin)
                iW := RC_IsuFromIds(c, ids, vin)
                c.bodyHint := Trim(c.bodyHint . " " . iW)
                if (vinYear = "" && ids.year != "")
                    vinYear := ids.year
                ; The shops are let off when the record settled BOTH the cab
                ; and the back of the truck. IDS writes C/C for a cab chassis
                ; and nothing at all for a tub, and RC_IdsWords now spells the
                ; nothing out as Tub - so a description that names the cab
                ; has said both halves, and no shop is needed.
                if (RC_CabType(iW) != "" && RC_BodyStyle(iW) != "")
                    RC_CTX.cabDone := true
            } else if (RC_SPEED = 1 && c.colour != "") {
                ; No dealer record to hand the colour over with its paint
                ; code, so the register's word for it goes in after all.
                RC_SetRow("Colour", c.colour)
            }
        }
        if (vinModel = "") {
            if RegExMatch(body, "i)util|\bute\b")
                vinModel := "D-MAX"
            else if RegExMatch(body, "i)suv|wagon")
                vinModel := "MU-X"
        }
        iEng := ""
        iDrive := ""
        iYr := ""
        iGen := ""
        RC_RestBar(60)
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
                c.bodyHint .= " " . iDrive
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

    if (InStr(make, "ISUZU"))
        RC_Tick("isuzu")

    ; BYD sorts itself out by body type and, for the SUVs, by the VIN.
    if (vinModel = "" && InStr(make, "BYD")) {
        bFuel := ""
        vinModel := RC_BydVin(vin, year, body, bFuel)
        mkX := bFuel
    }

    ; Overtaken by a newer search while the maker was being asked - whatever
    ; came back belongs to a car nobody is looking at any more.
    if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
        return
    c.vinModel := vinModel
    c.vinYear  := vinYear
    c.genTag   := genTag
    c.mkX      := mkX
    c.trm      := trm
    RC_TagShow()
    RC_CacheSave(c.key, c.note, 1)
}

; The cab an Isuzu was built with, on a Fast search. It is the one thing about
; a D-MAX that nobody upstream says: the register only ever writes "UTIL", and
; the VIN sheet does not carry it either - position nine is the wheelbase, not
; the cab. Full learns it from the fitment shops in leg three; Fast does not
; walk that far, so for an Isuzu alone one shop is asked, for the cab and
; nothing else. Like every other leg out here it runs after the answer is
; already on screen, so the wait it costs is nobody's.
RC_IsuzuCab() {
    global RC_CTX
    RC_Use()
    c := RC_CTX
    if (c.rego = "" || c.st = "")
        return
    sX := ""
    sTrim := ""
    sYear := ""
    sCab := ""
    sMake := ""
    sInfo := ""
    RC_RestBar(80)
    RC_MtsRego(c.rego, c.st, sX, sTrim, sYear, sCab, sMake, sInfo)
    if (RC_CabType(sCab) = "") {
        RC_RestBar(88)
        sCab := ""
        RC_JaxRego(c.rego, c.st, sX, sTrim, sYear, sCab)
    }
    ; Both shops blank. That is not the same as the truck having no cab - a
    ; plate whose registration was cancelled years back has simply aged out of
    ; their books - so the parts trade gets the last word.
    if (RC_CabType(sCab) = "") {
        RC_RestBar(92)
        sCab := RC_EzyCab(c.rego, c.st)
    }
    RC_Tick("isuzu.cab")

    ; Overtaken while the shop was being asked - this cab belongs to a truck
    ; nobody is looking at any more.
    if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
        return
    ; Either half is worth having. The dealer system may already have named the
    ; cab and said nothing about the back of the truck, which is what this leg
    ; was rung for - so a shop that only says "tub" is still an answer.
    if (RC_CabType(sCab) = "" && RC_BodyStyle(sCab) = "")
        return

    c.bodyHint := Trim(c.bodyHint . " " . sCab)
    ; A state that gave no body row at all leaves nowhere to write it, so the
    ; shop's own words become the row and the last pass tidies them. Not on
    ; Fast for a VIN-read Isuzu, whose cab goes in the line under the make.
    if (!RC_HasRow("Body type") && !(c.isu && RC_SPEED = 1))
        RC_SetRow("Body type", sCab)
    RC_TagShow()
    RC_CacheSave(c.key, c.note, 1)
}

; Leg three, Full only: the fitment shops, and then the wiper sizes. The shops
; are asked on every plate the state answered, not only when something came
; back blank - the chassis code, the model-year range, the gearbox and the
; tyre sizes come from nowhere else. Mobile Tyre Shop first, JAX second,
; Autobarn as the very last resort, and Autobarn not at all for an Isuzu,
; whose VIN sheet has already had the last word. Whatever the maker's own
; sources named in leg two stays; the shops only fill blanks - the trim
; included, which for an Isuzu is the whole reason they are rung.
RC_Stage3() {
    global RC_CTX, RC_WipeRow
    RC_Use()
    c := RC_CTX
    if (c.rego != "" && c.st != "") {
        sX := ""
        sTrim := ""
        sYear := ""
        sCab := ""
        sMake := ""
        sInfo := ""
        RC_RestBar(72)
        sModel := RC_MtsRego(c.rego, c.st, sX, sTrim, sYear, sCab, sMake, sInfo)
        if (sModel = "") {
            RC_RestBar(78)
            sInfo := ""
            sModel := RC_JaxRego(c.rego, c.st, sX, sTrim, sYear, sCab)
        }
        if (sModel = "" && !InStr(c.make, "ISUZU")) {
            RC_RestBar(84)
            sModel := RC_AbVin(c.rego, c.st, sX, sTrim)
        }
        RC_Tick("fitment")
        if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
            return
        if (c.vinModel = "" && sModel != "") {
            c.vinModel := sModel
            if (sYear != "")
                c.vinYear := sYear
        }
        if (sX != "" && c.mkX = "")
            c.mkX := sX
        if (sTrim != "" && c.trm = "")
            c.trm := sTrim

        ; The shop's rows go in above the wipers, so the red expiry row above
        ; keeps its place. JAX and Autobarn only carry the cab, so that goes
        ; in on its own when they answered.
        if IsObject(sInfo)
            RC_MtsRows(sInfo)
        else if (sCab != "") {
            LV_Insert(RC_WipeRow, "", "Cab/Body", sCab)
            RC_WipeRow += 1
        }
        c.bodyHint := IsObject(sInfo) ? sInfo.name . " " . sInfo.cab : sCab

        ; An Isuzu whose cab neither shop named. On a D-MAX the cab decides the
        ; doors, the glass, the seats and half the panels, so it is worth one
        ; more ask - and the parts trade holds plates the tyre shops have let
        ; go, a registration cancelled years back among them.
        if (InStr(c.badge, "ISUZU") && RC_HasCab(c.body)
            && RC_CabType(c.bodyHint) = "") {
            RC_RestBar(88)
            eCab := RC_EzyCab(c.rego, c.st)
            if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
                return
            if (eCab != "") {
                c.bodyHint := Trim(c.bodyHint . " " . eCab)
                if !RC_HasRow("Body type")
                    RC_SetRow("Body type", eCab)
            }
        }
        RC_TagShow()
    }

    RC_RestBar(92)
    RC_WipeFind(c.badge, c.year, c.body, c.vinModel, c.vinYear, c.genTag, c.trm)
    RC_WipeShow()
    if (c.rego != "")
        RC_WipeOnline(c.rego, c.st, c.badge)
    RC_Tick("wipers")
    if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
        return
    RC_FitList()
    RC_CacheSave(c.key, c.note, 2)
    RC_Tick("paint")
}

; A row whose value is only learned in a later leg - the year an Isuzu VIN
; spells out, the cab words the shop knows - written again where it already
; sits, or slid in above the wipers when the earlier legs had nothing to say.
RC_SetRow(field, value) {
    global RC_WipeRow, RC_QUIET
    if (value = "")
        return
    RC_Use()
    hit := 0
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        ; "==" and not "=": row names are compared as written, so a field
        ; is never confused with one that differs only in case.
        if (f == field) {
            LV_Modify(A_Index, "Col2", value)
            hit := 1
            break
        }
    }
    if (!hit) {
        LV_Insert(RC_WipeRow, "", field, value)
        RC_WipeRow += 1
    }
    ; Behind Ultra this went into the hidden list. If it is one of the few
    ; rows the window is still showing, it goes in both.
    if (RC_QUIET && RC_QKeep(field))
        RC_QMirror(field, value)
}

; The make goes up in bold with the car spelled out beside it in ordinary
; weight - model and trim first, then the engine and fuel. Every leg that
; learns something new about the car calls this again, so the line fills out
; as the answers arrive rather than all at the end.
RC_TagShow() {
    global RC_CTX
    RC_Use()
    c := RC_CTX
    if (c.isu) {
        ; An Isuzu read off its VIN says only the model up here - D-MAX or
        ; MU-X - and the rest of the truck in rows of its own. See RC_IsuRows.
        tag := RC_IsuLine(c)
        RC_IsuRows(c)
    } else {
        if (c.trm != "" && !InStr(" " . c.vinModel . " ", " " . c.trm . " "))
            tag := RC_NiceName(c.vinModel . " " . c.trm)
        else
            tag := RC_NiceName(c.vinModel)
        if (c.mkX != "")
            tag .= (tag != "" ? ", " : "") . c.mkX
        ; The state's own body word is deliberately NOT in here. A cab chassis
        ; is registered as a UTILITY the same as a tub is, so handing that
        ; word to the tail had every Isuzu ute called a tub on the strength of
        ; it. Only what a shop or the dealer system said gets a say - and when
        ; none of them said, the line stops at the driveline rather than
        ; guessing.
        tag := RC_TagTail(tag, c.badge, c.bodyHint . " " . c.mkX . " " . c.trm)
    }
    RC_SetMake(c.badge, tag, c.st)

    ; The state only ever says "UTIL"; whichever shop answered knows whether
    ; that is a tub or a cab chassis, so its words are handed over as the hint.
    RC_PrettyRows(c.bodyHint, c.badge)
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
        RC_Use()
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
    global RC_VinVal, RC_QUIET
    if (RC_QUIET)
        return
    RC_VinVal := vin
    GuiControl, RC:, RC_VinTxt, % (vin != "") ? vin : Chr(0x2014)
    ; The VIN on the band is what the EPC jump needs, and all it needs. So
    ; this is where the ring goes up - while the register is still writing
    ; its rows and the later legs have not started - for a make one of the
    ; four catalogs covers. A partial VIN, or a make with no catalog, arms
    ; nothing, and RC_Done takes the waiting word down instead.
    if (vin != "")
        RC_EpcHot(RC_BrandOfVin(vin) != "")
}

; Double-click on the VIN value itself - same as pressing the copy button,
; except the window stays up. The button is aimed at, the VIN value is landed
; on while reading the band, and closing the window out from under a reader is
; not what was wanted.
RC_OnVinDbl() {
    if (A_GuiEvent = "DoubleClick")
        RC_OnCopy(false)
}

; The Copy button. The tooltip at the cursor is the whole of the feedback -
; it shows exactly what landed on the clipboard, including the short end ACT
; hands back.
;
; With the VIN on the clipboard the window has done its job and is only in the
; way of wherever the VIN is about to be pasted, so it goes away to the tray -
; the same way Escape puts it away, and back the same ways. The tip is put up
; first: it is a window of its own and outlives the one it was called from, so
; it stays on screen its two seconds over whatever is underneath.
RC_OnCopy(hide := true) {
    global RC_VinVal, RC_HIDEAFTER
    if (RC_VinVal = "")
        return
    Clipboard := RC_VinVal
    RC_TipAtMouse(RC_VinVal)
    if (hide && RC_HIDEAFTER)
        Gui, RC:Hide
}

; Hovering the copy button says what it does. WM_MOUSEMOVE arrives here for
; the whole window; the tooltip goes up when the pointer lands on the button
; and is put away when it leaves - and only then, so it cannot swat the
; two-second VIN tip shown anywhere else.
RC_MouseTip(wParam, lParam, msg, hwnd) {
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
    RC_BtnHover(hwnd)
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
    global RC_QUIET
    if (RC_QUIET)
        return
    ; Both have to be screen coordinates. Left on the default, MouseGetPos
    ; answers relative to the active window and the tip lands nowhere near the
    ; cursor.
    CoordMode, Mouse, Screen
    CoordMode, ToolTip, Screen
    MouseGetPos, mx, my
    ToolTip, %vin%, mx + RC_S(16), my + RC_S(16)
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
    RC_Use()
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
    SetTimer, RC_BtnsUp, -1
    RC_SelectPlate()
return

; Page Down brings the window to the top from anywhere - or back up from the
; tray if it was closed away - with the old plate selected, ready to be typed
; straight over. Closing the window only hides it, so this keeps working.
; PgDn is bound to RC_TrayShow by the Hotkey command up top, window mode only.
RC_TrayShow:
    Gui, RC:Show
    SetTimer, RC_BtnsUp, -1
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
    global RC_EzyS, RC_EzyC, RC_EzyErr, RC_UA, RC_GEN
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

    ; A newer search can start while the portal is asked and log in itself
    ; before this one resumes. Then this session is the newer one's, not to be
    ; dropped on the strength of a page this one never got.
    gen := RC_GEN

    ; The login page deals the CSRF token along with the session cookie.
    page := RC_Send("GET", RC_EZY_BASE . "/login", "", "", "", "", RC_EzyC)
    if (RC_GEN != gen)
        return false
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
    if (RC_GEN != gen)
        return false

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

; The cab, asked of EzyParts, when neither tyre shop had the plate. The trade
; register behind Burson keeps its own copy of the build - "D-MAX LS-U, SX
; SPACECAB" sits in the details line - and it holds plates the fitment shops
; have long since let go: a rego cancelled years ago is out of a tyre shop's
; book while the parts trade still knows exactly what the truck was. Only the
; one state is asked, the one the register already named, so this is a single
; request on top of a login that is usually already open.
RC_EzyCab(plate, state) {
    global RC_EZY_HOST, RC_EZY_BASE
    if (plate = "" || state = "")
        return ""
    if !RC_EzyOpen()
        return ""
    ref := "https://" . RC_EZY_HOST . RC_EZY_BASE . "/workbench"
    page := RC_EzyGet(RC_EZY_BASE . "/vehicle/rego/search?state=" . RC_Enc(state)
        . "&rego=" . RC_Enc(plate) . "&ac=3", ref)
    eMake := ""
    eModel := ""
    eYear := ""
    eEngine := ""
    eCab := ""
    eCount := 0
    if !RC_EzyFirst(page, eMake, eModel, eYear, eEngine, eCab, eCount)
        return ""

    ; More than one build fits the plate and the register does not say which.
    ; On a D-MAX those builds are the three cabs - the single, the space and
    ; the crew all answer to the one rego - so taking the first of them is not
    ; reading the cab, it is picking one, and a wrong cab is worse than none.
    if (eCount > 1)
        return ""

    ; The cab is named in the details line on some builds, in the model name on
    ; others - "SX SPACECAB" is the model - and in the long description on the
    ; rest, so all three are read.
    words := RC_CabWords(eModel . " " . eCab . " " . RC_EzyLong(page))

    ; Only a cab leaves here. The details line is mostly doors and driveline,
    ; and "2D" is no answer to which cab it is.
    return (RC_CabType(words) != "") ? words : ""
}

; EzyParts writes the cab into its long description as a shorthand between
; dashes - "2 Door Ute - SC - Utility" - which no other shop uses. It is spelt
; out here so everything downstream reads the one set of words. Only SC is
; translated: it is the one seen in the register's own answers, and inventing
; the other two would be guessing at a cab rather than reading one. Anything
; the register spells out in full is already understood.
RC_EzyLong(page) {
    if !RegExMatch(page, """lngDsc"":""([^""]*)""", m)
        return ""
    return RegExReplace(m1, "i)\s-\s*SC\s*-\s", " Single Cab ")
}

; A plate VicRoads does not hold, asked of EzyParts state by state - one
; login, one GET each, and the register answers with the VIN, the build and
; the year. JAX is only rung afterwards, and only for an Isuzu, whose trim
; the register never quite pins down. True once the list is filled.
RC_FillEzyPlate(plate) {
    global RC_PROBE, RC_EZY_HOST, RC_EZY_BASE, RC_RedRow, RC_WipeRow, RC_ModelPick
    global RC_EzyErr, RC_CTX, RC_GEN, RC_LastKey, RC_SPEED
    RC_Use()
    if !RC_EzyOpen()
        return false

    ref := "https://" . RC_EZY_HOST . RC_EZY_BASE . "/workbench"
    hit := ""
    hitSt := ""
    answered := 0
    gen := RC_GEN
    for i, st in RC_PROBE {
        RC_BarBusy()
        Sleep, 10
        page := RC_EzyGet(RC_EZY_BASE . "/vehicle/rego/search?state=" . RC_Enc(st) . "&rego=" . RC_Enc(plate) . "&ac=3", ref)
        ; Overtaken by a newer search while the portal was asked: this one
        ; is about the wrong car now and paints nothing.
        if (RC_GEN != gen)
            return false
        if (page != "")
            answered += 1
        ; The wrong state answers "results":"0" with an apology; the right
        ; one carries a car, or at the least the VIN.
        if (InStr(page, """vehicles"":[{") || RegExMatch(page, """vin"":""[A-Z0-9]")) {
            hit := page
            hitSt := st
            break
        }
        ; That state has not got it. On to the next one, and the bar with it.
        RC_BarLeg()
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
        if (RC_GEN != gen)
            return false
        RC_EzyFirst(page, make, model, yrRange, eng, cab, cnt)
    }

    ; The fuller answer carries the expiry date, when the state shares it.
    expiry := ""
    page := RC_EzyGet(RC_EZY_BASE . "/vehicle/rego/search/more?state=" . RC_Enc(hitSt) . "&rego=" . RC_Enc(plate) . "&ac=3", ref)
    if (RC_GEN != gen)
        return false
    if RegExMatch(page, """registrationStatusExpiry"":""([^""]+)""", m)
        expiry := Trim(m1)

    ; The states register a Genesis as a HYUNDAI; the VIN tells them apart.
    if (InStr(make, "HYUNDAI") && (SubStr(vin, 1, 3) = "KMT" || SubStr(vin, 1, 3) = "KMU"))
        make := "GENESIS"

    sX := RC_EzyEngine(eng)
    RC_Tick("ezy")

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
    if RC_WipesWanted(make) {
        RC_WipeRow := LV_Add("", "Wiper driver", "")
        LV_Add("", "Wiper passenger", "")
        LV_Add("", "Wiper rear", "")
    } else
        RC_WipeRow := LV_GetCount() + 1

    ; That is everything the register itself knows, and it is worth putting up
    ; now. Hyundai's own VIN answer, the Isuzu VIN sheet and the tyre shops are
    ; all somebody else's website; they are left to RC_Rest, which runs once
    ; this much is on screen. What those legs need goes into RC_CTX.
    RC_CTX := { gen: RC_GEN, key: RC_LastKey, rego: plate, st: hitSt, src: "ezy"
        , make: make, badge: make, vin: vin, year: year, body: cab
        , bodyHint: cab, vinModel: model, vinYear: (year != "") ? year : ""
        , genTag: "", mkX: sX, trm: "", yearWeak: false
        , note: "", stage: 1, full: RC_WipesWanted(make), cabDone: false }
    ; An Isuzu's VIN names the rest of the line straight away.
    if InStr(make, "ISUZU")
        RC_IsuSeed(RC_CTX)
    ; RC_TagShow fits the list itself, and on Ultra the list is one line away
    ; from losing most of its rows - so the fitting is held off until after
    ; the cut and the window grows once instead of growing and shrinking.
    RC_NOFIT := (RC_SPEED = 0)
    RC_TagShow()
    RC_NOFIT := 0
    if (RC_SPEED = 0)
        RC_QSeed()
    RC_FitList()
    RC_Tick("rows")

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
    RC_CTX.note := note
    RC_CacheSave(plate, note, 0)
    SetTimer, RC_Rest, -60
    return true
}

; Leg two for a car that came out of EzyParts. The register has already named
; the make, the model and the engine, so this is only the two sources that
; know better: Hyundai's own VIN answer, which covers Genesis as well, and the
; Isuzu VIN sheet.
RC_EzyStage2() {
    global RC_CTX
    RC_Use()
    c := RC_CTX
    vin := c.vin
    make := c.make

    if (vin != "" && (InStr(make, "HYUNDAI") || InStr(make, "GENESIS"))) {
        RC_RestBar(45)
        hX := ""
        hTrim := ""
        hYear := ""
        gen := ""
        hModel := RC_HmcVin(vin, gen, hX, hTrim, hYear)
        if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
            return
        if (hModel != "") {
            c.vinModel := hModel
            c.trm := hTrim
            if (hX != "")
                c.mkX := hX
            if (gen != "")
                c.genTag := gen
            ; A year read off a model-year range is a guess; Hyundai's is not,
            ; so that one is allowed to replace it.
            if (hYear != "" && (c.vinYear = "" || c.yearWeak))
                c.vinYear := hYear
        }
    }

    ; Isuzu's own VIN sheet settles what EzyParts left open - the exact build
    ; year, the generation, the engine and the driveline are all in the VIN
    ; itself. Only the trim is not, and that stays the fitment shops'.
    if (vin != "" && InStr(make, "ISUZU")) {
        ; The dealer system first, for the same reason as on the state path:
        ; the model code, the words behind it, the group and the paint come
        ; from nowhere else, and the words name the cab as well.
        RC_RestBar(50)
        ids := RC_IdsVin(vin)
        RC_Tick("ids")
        if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
            return
        if (IsObject(ids)) {
            RC_IdsRows(ids, vin)
            iW := RC_IsuFromIds(c, ids, vin)
            c.bodyHint := Trim(c.bodyHint . " " . iW)
            if (c.vinYear = "" && ids.year != "")
                c.vinYear := ids.year
            if (RC_CabType(iW) != "" && RC_BodyStyle(iW) != "")
                RC_CTX.cabDone := true
        }
        RC_RestBar(60)
        iEng := ""
        iDrive := ""
        iYr := ""
        iGen := ""
        iModel := RC_IsuzuVin(vin, iEng, iDrive, iYr, iGen)
        if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
            return
        if (iModel != "") {
            if (c.vinModel = "")
                c.vinModel := iModel
            if (iYr != "")
                c.vinYear := iYr
            if (iGen != "")
                c.genTag := "(" . iGen
            if (c.mkX = "" && iEng != "")
                c.mkX := iEng
            if (iDrive != "" && !InStr(c.mkX . " " . c.vinModel . " " . c.trm, iDrive))
                c.mkX .= (c.mkX != "" ? ", " : "") . iDrive
        }
    }
    RC_Tick("build")

    ; An Isuzu's year goes in its own block of rows, in its own place.
    if (c.isu)
        RC_RowPut("Year", c.vinYear)
    else
        RC_SetRow("Year", c.vinYear)
    RC_TagShow()
    RC_CacheSave(c.key, c.note, 1)
}

; Leg three for an EzyParts car, Full only: the tyre shops, then the wiper
; sizes. The shops are asked on every plate, not only when EzyParts came up
; short - the chassis code, the model-year range, the gearbox and the tyre
; sizes come from nowhere else, so even a car EzyParts has fully named has
; more to learn. Mobile Tyre Shop first, JAX second.
;
; Isuzu is the one make whose model and trim they overrule: EzyParts sells
; three trims on one build line and only a fitment database says which one the
; plate wears. For everything else the shops fill blanks and no more.
;
; A VIN search has no plate of its own, so it has no shops to ask - it comes
; here for the wiper sizes alone.
RC_EzyStage3() {
    global RC_CTX, RC_WipeRow
    RC_Use()
    c := RC_CTX
    if (c.rego != "" && c.st != "") {
        RC_RestBar(72)
        jX := ""
        jTrim := ""
        jYear := ""
        jCab := ""
        jMake := ""
        jInfo := ""
        jModel := RC_MtsRego(c.rego, c.st, jX, jTrim, jYear, jCab, jMake, jInfo)
        if (jModel = "") {
            RC_RestBar(78)
            jInfo := ""
            jModel := RC_JaxRego(c.rego, c.st, jX, jTrim, jYear, jCab, jMake)
        }
        RC_Tick("fitment")
        if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
            return
        if (jModel != "") {
            beats := (InStr(c.make, "ISUZU") || c.vinModel = "")
            if (beats)
                c.vinModel := jModel
            if (beats || c.trm = "")
                c.trm := jTrim
            if (c.make = "") {
                c.make := jMake
                c.badge := jMake
            }
            ; The cab words already have a Body type row of their own here,
            ; so the shop's own copy of them is dropped before its rows go in.
            if (jCab != "") {
                c.body := jCab
                c.bodyHint := jCab
                RC_SetRow("Body type", jCab)
                if IsObject(jInfo)
                    jInfo.cab := ""
            }
            if (jX != "" && c.mkX = "")
                c.mkX := jX
            if (c.vinYear = "")
                c.vinYear := jYear
        }
        if IsObject(jInfo) {
            RC_MtsRows(jInfo)
            c.bodyHint := jInfo.name . " " . c.body
        }
        RC_SetRow("Year", c.vinYear)
        RC_TagShow()
    }

    RC_RestBar(92)
    if (c.badge != "")
        RC_WipeFind(c.badge, c.vinYear, c.body, c.vinModel, c.vinYear, c.genTag, c.trm)
    RC_WipeShow()
    if (c.rego != "")
        RC_WipeOnline(c.rego, c.st, c.badge)
    RC_Tick("wipers")
    if (!IsObject(RC_CTX) || RC_CTX.gen != c.gen)
        return
    RC_FitList()
    RC_CacheSave(c.key, c.note, 2)
}

; A VIN VicRoads does not hold, asked of EzyParts' fitment search, which
; reads the build straight off the VIN for any make. The register never
; hands a plate back for a VIN, so there is no rego row and no expiry -
; and more than one build can fit the one code, so the count is said when
; it is more than one. True once the list is filled.
RC_FillEzyVin(vin) {
    global RC_EZY_HOST, RC_EZY_BASE, RC_RedRow, RC_WipeRow, RC_ModelPick
    global RC_EzyErr, RC_CTX, RC_GEN, RC_LastKey, RC_SPEED
    RC_Use()
    gen := RC_GEN
    if !RC_EzyOpen()
        return false
    RC_BarBusy()
    Sleep, 10
    page := RC_EzyGet(RC_EZY_BASE . "/vehicle/t/search?text=" . RC_Enc(vin)
        , "https://" . RC_EZY_HOST . RC_EZY_BASE . "/workbench")
    ; Overtaken by a newer search while the portal was asked: this one is
    ; about the wrong car now and paints nothing.
    if (RC_GEN != gen)
        return false
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

    ; A year read off a model-year range is only near enough - Hyundai's own
    ; answer or an Isuzu VIN will say it exactly, in the leg after this one.
    year := ""
    if RegExMatch(yrRange, "(\d{4})", m)
        year := m1
    sX := RC_EzyEngine(eng)
    RC_Tick("ezy")

    RC_RedRow := 0
    RC_WipeRow := 0
    RC_ModelPick := 0
    RC_SetVin(vin)
    if (yrRange != "")
        LV_Add("", "Year", yrRange)
    if (cab != "")
        LV_Add("", "Body type", cab)
    if RC_WipesWanted(make) {
        RC_WipeRow := LV_Add("", "Wiper driver", "")
        LV_Add("", "Wiper passenger", "")
        LV_Add("", "Wiper rear", "")
    } else
        RC_WipeRow := LV_GetCount() + 1

    ; The register's own answer goes up now; the maker's VIN decode and the
    ; wiper sizes are left to RC_Rest. There is no plate here, so no shop can
    ; be asked about this car - the third leg is the wipers alone.
    RC_CTX := { gen: RC_GEN, key: RC_LastKey, rego: "", st: "", src: "ezy"
        , make: make, badge: make, vin: vin, year: year, body: cab
        , bodyHint: cab, vinModel: model, vinYear: year
        , genTag: "", mkX: sX, trm: "", yearWeak: true
        , note: "", stage: 1, full: RC_WipesWanted(make), cabDone: false }
    ; An Isuzu's VIN names the rest of the line straight away.
    if InStr(make, "ISUZU")
        RC_IsuSeed(RC_CTX)
    ; RC_TagShow fits the list itself, and on Ultra the list is one line away
    ; from losing most of its rows - so the fitting is held off until after
    ; the cut and the window grows once instead of growing and shrinking.
    RC_NOFIT := (RC_SPEED = 0)
    RC_TagShow()
    RC_NOFIT := 0
    if (RC_SPEED = 0)
        RC_QSeed()
    RC_FitList()
    RC_Tick("rows")

    note := "EzyParts knows the VIN."
    if (cnt > 1)
        note := "EzyParts knows the VIN - " . cnt . " builds fit it, the first is shown."
    note .= " No plate: the register gives none back for a VIN."
    RC_Done(true, "Success")
    RC_SelectPlate()
    RC_CTX.note := note
    RC_CacheSave(vin, note, 0)
    SetTimer, RC_Rest, -60
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
; state only said "UTIL". For an Isuzu the make is passed as well, because an
; Isuzu also gets its cab named: "Utility / Crew cab / Tub".
RC_BodyText(text, hint := "", make := "") {
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

    ; This pass runs again every time a later leg learns something, and what it
    ; wrote last time is what comes back in - "Utility / Crew cab" - so the cab
    ; collects another capital on every trip and ends up reading "Crew Cab".
    ; Put it back the way RC_CabType writes it, which is also what turns the
    ; dealer system's shouted "SINGLE CAB" into words.
    cw := RC_CabType(out)
    if (cw != "")
        out := RegExReplace(out, "i)\b(crew|dual|double|space|extra|xtra|king|extended|super|freestyle|single|regular|standard)\s+cabs?\b", cw)

    ; The build line is the one that really knows - "UTIL" on its own says
    ; nothing about the back of the car, so it is only allowed to answer when
    ; it uses a word that settles it. A ute nobody has described stays a plain
    ; "Utility" rather than being called a tub on a guess.
    ;
    ; And only for a body that could have one. A wagon has no tub and no cab
    ; chassis behind it, so whatever the hint says about the back of a truck
    ; is about some other truck - the row is the register's own word for the
    ; body and it is the one that decides. This is what had "Wagon / Tub" on
    ; an MU-X.
    style := ""
    if (RC_HasCab(out)) {
        style := RC_BodyStyle(hint)
        if (style = "")
            style := RC_BodyStyle(out, true)
    }

    ; The cab goes in for an Isuzu and nobody else: on a D-MAX it decides the
    ; doors, the glass, the seats and half the panels, so a single cab chassis
    ; and a crew cab tub are two different trucks wearing one body word. It is
    ; written before the back of the truck, the way the yards say it.
    cab := InStr(make, "ISUZU") ? RC_CabType(hint . " " . out) : ""
    if (cab != "" && !InStr(RC_Squash(out), RC_Squash(cab)))
        out .= " / " . cab
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
    ; Same rule as the body row: a wagon has no back-of-truck to name, and the
    ; source here is everything known about the car at once, so an MU-X whose
    ; line says SUV is not asked the question at all.
    if (InStr(make, "ISUZU") && RC_HasCab(source)) {
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
    RC_Use()
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
    RC_Use()
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
;
; The marque comes off the front first. The company that builds these is
; Isuzu UTE Australia and the tyre shop writes its make out in full, so the
; build line for a MU-X reads "Isuzu UTE RJ MU-X LS-T 4D SUV" - and the word
; Ute in the MAKE was being read as the body. Every Isuzu came back a tub on
; the strength of it: the wagon, and the cab chassis whose own words had not
; settled it either way.
RC_BodyStyle(text, strict := false) {
    text := RC_NoMarque(text)
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

; The make with the body word taken out of it. "Isuzu UTE" is a company name,
; not a body - the same two words the shops use for the marque are the ones
; the body pass reads - so the pair is put back to plain "Isuzu" before
; anything looks for a ute in the line. Only the pair is touched: a line that
; says Isuzu and separately says Ute still says Ute.
RC_NoMarque(text) {
    return RegExReplace(text, "i)\bisuzu\s+ute\b", "Isuzu")
}

; The cab, door and ride-height words out of a build line, in the order they
; were printed - "Space Cab Chassis 2D", "Crew Cab Utility Hi-Ride". These are
; the same words the trim peeling throws away, kept for their own row.
RC_CabWords(text) {
    text := RC_CabSplit(text)
    out := ""
    pos := 1
    while (pos := RegExMatch(text, "i)\b(Crew|Space|Dual|Single|Extended|Extra|King|Super|Cab|Chassis|Pick.?Up|Tray|Utility|Ute|Wagon|Van|SUV|Sedan|Hatch|Coupe|Hi.?Rider?|Low.?Rider?|\d+D|\d+dr)\b", c, pos)) {
        pos += StrLen(c)
        out .= (out = "" ? "" : " ") . c1
    }
    return out
}

; Not every shop puts a space in the cab. EzyParts writes "D-MAX LS-U, SX
; SPACECAB" as one word, and a word boundary can no more find "Cab" inside
; "SPACECAB" than inside "Cabinet" - so the joins are opened up first and
; every reader downstream sees the same two words.
RC_CabSplit(text) {
    text := RegExReplace(text, "i)\b(crew|space|dual|double|single|regular|extended|extra|xtra|king|super|freestyle)(cabs?)\b", "$1 $2")
    return RegExReplace(text, "i)\b(cab)(chassis)\b", "$1 $2")
}

; Which cab an Isuzu was built with, out of whatever line names it. Isuzu sells
; three and calls them Single, Space and Crew; everyone else's words for the
; same three cabs are answered with Isuzu's, so the row reads the same however
; the shop that answered happened to spell it.
RC_CabType(text) {
    t := RC_Squash(RC_CabSplit(text))
    if RegExMatch(t, "\b(crew|dual|double)\s+cabs?\b")
        return "Crew cab"
    if RegExMatch(t, "\b(space|extra|xtra|king|extended|super|freestyle)\s+cabs?\b")
        return "Space cab"
    if RegExMatch(t, "\b(single|regular|standard)\s+cabs?\b")
        return "Single cab"
    return ""
}

; Whether a cab is a thing this body could even have. Isuzu sells the D-MAX and
; the MU-X and only one of them has a cab to name - a wagon is a wagon however
; many doors it has - so without this the cab leg spent three requests on every
; MU-X proving a wagon is not a ute, and the search took thirteen seconds to
; learn nothing. A body the register did not name is asked about all the same:
; unknown is not the same as wagon, and a ute must not stop being asked.
RC_HasCab(body) {
    b := RC_Squash(body)
    if (b = "")
        return true
    return !RegExMatch(b, "\b(wagon|suv|sedan|hatch|coupe|convertible|van|bus)\b")
}

; The make sits in bold with the car spelled out in ordinary weight on its
; own line beneath. The state the car is registered in shows only in the
; status bar's "Found in" - the little tag that used to sit on the make's
; line is gone.
RC_SetMake(bold, bracket, state := "") {
    global RC_FoundIn, RC_QUIET, RC_QMake, RC_QMakeX, RC_QSt
    bracket := RC_TrimCase(RC_NoEcho(bracket))
    ; The case pass folds five capitals to a word, and D-MAX is five. It is
    ; the badge on the tailgate, and it is written the way the tailgate is.
    bracket := RegExReplace(bracket, "i)\bD-Max\b", "D-MAX")
    ; Kept aside as well as written: RC_CacheSave reads the words back from
    ; here while the hidden list is the one being filled, and so does the
    ; reveal.
    RC_QMake  := bold
    RC_QMakeX := bracket
    RC_QSt    := state
    ; This line is written even behind Ultra, and it is the only thing that
    ; is. The model and the trim - a D-MAX, an MU-X, an LS-U - are what
    ; somebody has the window open to find out, they cost nothing to show, and
    ; they land a second or two after the register's answer rather than at the
    ; end. The list is another matter: those rows are what Ultra is for
    ; leaving out, and they wait to be asked for.
    ;
    ; Always the real window, whichever list the legs are filling - the font
    ; lines below set the default Gui's font, and pointed at the hidden one
    ; they would size the make line off somebody else's setting.
    Gui, RC:Default
    ; A long make - MERCEDES-BENZ - drops a size instead of being cut off.
    Gui, Font, % "s" . (StrLen(bold) > 16 ? 11 : 13) . " w600", Segoe UI
    GuiControl, RC:Font, RC_Make
    GuiControl, RC:, RC_Make, % (bold != "") ? bold : A_Space
    GuiControl, RC:, RC_MakeX, %bracket%
    GuiControl, % (bracket != "") ? "RC:Show" : "RC:Hide", RC_MakeX
    RC_FoundIn := state
    ; The default handed back to whichever list the caller was working in.
    RC_Use()
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
    RC_Use()
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
    RC_Use()
    ; Fast never leaves the register - the workbook still answers whatever it
    ; holds, but nothing is asked for over the wire. Ultra does ask: it is
    ; walking the whole chain out of sight so the sizes are already there if
    ; the setting is turned up.
    if (RC_SPEED = 1)
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
    ; The last thing anything is asked for, and it comes after the 92 the leg
    ; above set - so this is the bar's final move before it fills.
    RC_RestBar(95)

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

; --- Ultra: the answer that is fetched but not shown -----------------------
;
; Ultra shows three things - the make above the list, the VIN on the band, and
; the rego and expiry rows - because that is what nearly every asking is for.
; It does not fetch three things. The whole chain runs exactly as it does on
; Full, only into a ListView on a Gui that is never shown, so that changing
; the setting afterwards is a repaint rather than another two to five seconds
; on somebody else's website.
;
; The seam is here and nowhere else: the register's answer is built into the
; real list the way it always was, copied across to the hidden one, and then
; cut back on screen to the rows Ultra keeps. The copying and the cutting
; happen in the one thread, with no sleep between them, so the rows that are
; about to go are never painted in the first place - there is no flicker to
; see because there is nothing on screen to flick.

; What Ultra leaves in the window. The rego, the expiry and the year - the
; make and the model are not rows, they are the line above the list, and the
; VIN has its own band above that.
RC_QKeep(field) {
    ; An Isuzu's year is in the line under the make, so its Ultra is two rows.
    if RC_IsIsu()
        return RC_IsuRowOk(field, 0)
    return (field = "Registration" || field = "Expiry" || field = "Year")
}

; A row Ultra shows, written again in the window as well as in the hidden
; list. The year is the one that matters: the register often gives a build
; year, and the maker's VIN answer or the Isuzu sheet gives a better one a
; second or two later - which should land on screen when it lands, not sit
; behind the setting waiting to be asked for.
;
; The quiet flag comes down for the length of it, because everything this
; calls is written to do nothing while it is up.
RC_QMirror(field, value) {
    global RC_QUIET
    was := RC_QUIET
    RC_QUIET := 0
    Gui, RC:Default
    found := 0
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        if (f == field) {
            found := A_Index
            break
        }
    }
    if (found)
        LV_Modify(found, "Col2", value)
    else {
        ; In its place, not on the end: an Isuzu's block of rows has an
        ; order, and the window's cut of the list keeps it.
        LV_Insert(RC_RowSlot(field), "", field, value)
        RC_FitList()
    }
    RC_QUIET := was
    RC_Use()
}

; Hand the register's whole answer over to the hidden list and cut the visible
; one back. After this the legs write to the hidden list and the window sits
; still.
RC_QSeed() {
    global RC_QOn, RC_QRed, RC_RedRow, RC_QMake, RC_QMakeX, RC_QSt, RC_FoundIn
    Gui, RC:Default
    rows := []
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        LV_GetText(v, A_Index, 2)
        rows.Push([f, v])
    }
    ; The make line as it stands, so a leg that never learns anything new
    ; still has the right words to put back at the reveal.
    GuiControlGet, mk, RC:, RC_Make
    GuiControlGet, mx, RC:, RC_MakeX
    RC_QMake  := Trim(mk)
    RC_QMakeX := Trim(mx)
    RC_QSt    := RC_FoundIn
    ; Which row is red, counted in the full list. The visible list is about to
    ; be renumbered and the two answers stop agreeing from here on.
    RC_QRed := RC_RedRow

    Gui, RCQ:Default
    LV_Delete()
    for i, r in rows
        LV_Add("", r[1], r[2])

    Gui, RC:Default
    ; Backwards, so deleting a row does not renumber the ones still to check.
    n := LV_GetCount()
    Loop, %n%
    {
        i := n + 1 - A_Index
        LV_GetText(f, i, 1)
        if !RC_QKeep(f)
            LV_Delete(i)
    }
    ; The red row again, in the numbering the window is now using. A search
    ; whose expiry row was not the red one leaves this at nothing.
    if (RC_RedRow) {
        RC_RedRow := 0
        Loop, % LV_GetCount()
        {
            LV_GetText(f, A_Index, 1)
            if (f = "Expiry") {
                RC_RedRow := A_Index
                break
            }
        }
    }
    RC_QOn := 1
}

; Put the hidden answer up. Everything the legs found goes in at once - rows,
; make line, wiper sizes, the red expiry - and the hidden copy is done with.
RC_QReveal() {
    global RC_QUIET, RC_QOn, RC_QMake, RC_QMakeX, RC_QSt, RC_QRed, RC_RedRow
    if (!RC_QOn)
        return false
    Gui, RCQ:Default
    rows := []
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        LV_GetText(v, A_Index, 2)
        rows.Push([f, v])
    }
    ; Down before anything is drawn. A leg still in the air carries on from
    ; here into the real list, which now holds exactly what the hidden one
    ; did, so every row number it is working to still points where it did.
    RC_QUIET := 0
    RC_QOn   := 0
    Gui, RC:Default
    LV_Delete()
    ; An Isuzu revealed onto Fast shows Fast's cut of the whole answer; Full
    ; shows the lot. The rows left out are still in the day's kept copy, and
    ; RC_ModePick paints from there when Full is asked for next.
    isuCut := (RC_IsIsu() && RC_SPEED = 1)
    for i, r in rows {
        if (isuCut && !RC_IsuRowOk(r[1], RC_SPEED))
            continue
        LV_Add("", r[1], r[2])
    }
    RC_RedRow := RC_QRed
    if (isuCut) {
        ; The red row again, in the cut list's numbering; and no wiper rows
        ; to paint sizes into, so the anchor points past the end.
        RC_RedRow := 0
        Loop, % LV_GetCount()
        {
            LV_GetText(f, A_Index, 1)
            if (f = "Expiry") {
                RC_RedRow := A_Index
                break
            }
        }
        RC_WipeRow := LV_GetCount() + 1
    }
    RC_SetMake(RC_QMake, RC_QMakeX, RC_QSt)
    if (!isuCut)
        RC_WipeShow()
    RC_FitList()
    return true
}

; A new search: whatever Ultra was holding for the last one is no longer
; anybody's answer.
RC_QClear() {
    global RC_QUIET, RC_QOn, RC_QMake, RC_QMakeX, RC_QSt, RC_QRed
    RC_QUIET := 0
    RC_QOn   := 0
    RC_QMake := "", RC_QMakeX := "", RC_QSt := "", RC_QRed := 0
    Gui, RCQ:Default
    LV_Delete()
    Gui, RC:Default
}

; --- the day's answers, kept -----------------------------------------------

; Put away everything the window is showing, under the plate or VIN that was
; asked, so the same asking later in the day is answered from here.
RC_CacheSave(key, note, speed := -1) {
    global RC_CACHE, RC_RedRow, RC_WipeRow, RC_ModelPick, RC_Cands, RC_SPEED
    global RC_VinVal, RC_FoundIn
    global RC_QUIET, RC_QMake, RC_QMakeX, RC_QSt, RC_QRed
    ; How far the chain was walked to get this, so a later Full search knows
    ; not to settle for a copy taken on Fast. A re-save that is only a model
    ; pick says which setting the rows came from; everything else is now.
    if (speed < 0)
        speed := RC_SPEED
    if (key = "")
        return
    RC_Use()
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
    ; Behind Ultra the window is showing somebody else's two rows, so the make
    ; line is not the one this answer belongs to. RC_SetMake put the right
    ; words aside; the red row is the number it had in the full list, not in
    ; the cut-down one on screen.
    if (RC_QUIET) {
        mk  := RC_QMake
        mx  := RC_QMakeX
        st  := RC_QSt
        red := RC_QRed
    } else {
        GuiControlGet, mk, RC:, RC_Make
        GuiControlGet, mx, RC:, RC_MakeX
        st  := RC_FoundIn
        red := RC_RedRow
    }
    ; A first sighting goes in the day book; a model pick on a car already
    ; kept is only an update, not another lookup.
    if !RC_CACHE.HasKey(key)
        RC_LogLine(key, Trim(mk))
    RC_CACHE[key] := { when: A_Now, rows: rows, red: red, wipe: RC_WipeRow
        , pick: RC_ModelPick, cands: cands, make: Trim(mk), makeX: Trim(mx), note: note
        , speed: speed, vin: RC_VinVal, st: st }
    RC_RecentAdd(key, Trim(mk))
}

; Paint a kept answer back into the window - list, make, dropdown, red row,
; VIN on the clipboard - without one request going out. The caller has
; already emptied the window the way a fresh search does.
RC_CacheShow(key) {
    global RC_CACHE
    RC_CachePaint(key)
    c := RC_CACHE[key]

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

; The rows, the make line and the wiper sizes of a kept answer, painted back
; into the window. RC_CacheShow's first half, on its own for RC_ModePick,
; which wants the rows and none of the toast, the log line or the day book.
RC_CachePaint(key) {
    global RC_CACHE, RC_RedRow, RC_WipeRow, RC_ModelPick, RC_Cands, RC_WIPE
    RC_Use()
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
    RC_NOFIT := (RC_SPEED = 0)
    RC_WipeShow()
    RC_NOFIT := 0
    ; A kept answer is the whole car, however thin the setting is. On Ultra it
    ; goes straight into the hidden list and the window keeps its two rows -
    ; there is nothing left to fetch, so turning the speed up shows it at once.
    if (RC_SPEED = 0)
        RC_QSeed()
    RC_FitList()
}

; Whether a search puts the three wiper rows in and walks the shops for
; them. Full always; Ultra too, since its legs run behind the window into
; the hidden list - except for an Isuzu, whose Ultra is the two rows and the
; line under the make, and stops there. The shops are two or three seconds
; of the window's own thread, and Ultra on an Isuzu is asked for exactly so
; that it does not pay them. Full fetches them when Full is asked for.
RC_WipesWanted(make) {
    global RC_SPEED
    if (RC_SPEED = 1)
        return false
    if (RC_SPEED = 0 && InStr(make, "ISUZU"))
        return false
    return true
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
    RC_Use()
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
    global RC_VinVal, RC_HIDEAFTER
    static LABEL := { kia: "Kia", hyundai: "Hyundai", isuzu: "Isuzu", byd: "BYD" }
    ; The jump is what the ring was there to offer, so it comes down whether
    ; the button was pressed or Enter took it.
    RC_EpcHot(false)
    if (RC_VinVal = "") {
        RC_Say("  " . Chr(0x2715) . "  No VIN to look up - run a search first")
        return
    }
    brand := RC_BrandOfVin(RC_VinVal)
    if (brand = "") {
        RC_Say("  " . Chr(0x2715) . "  No catalog here for a " . SubStr(RC_VinVal, 1, 3) . " VIN")
        return
    }
    ; A mark in the timing line, so the day book shows where in the search
    ; the jump landed - the point of taking it early is that it need not wait
    ; for the legs, and this is the proof.
    RC_Tick("epc")
    ; The catalog is now in front and being searched, so the window goes away to
    ; the tray rather than sitting over the top of it. Only on a jump that
    ; actually happened: the paths above and the no-catalog-open path inside
    ; RC_CatJump each leave a line in the status bar saying why nothing did, and
    ; hiding the window would take the answer away with it.
    if (RC_CatJump(brand, LABEL[brand]) && RC_HIDEAFTER)
        Gui, RC:Hide
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
; ready to paste into whatever the catalog asks for. Answers whether the jump
; was made, so a caller that wants to get out of the catalog's way can tell a
; jump from a line in the status bar explaining why there was not one.
RC_CatJump(brand, label) {
    global RC_CAT, RC_VinVal, RC_BAR_ON
    RC_Use()
    RC_CatPaint()
    ; The status bar is written straight here rather than through RC_Done -
    ; that would put the time since the last SEARCH started in the middle
    ; cell, which has nothing to do with a catalog jump and only grows.
    if (!RC_CAT.HasKey(brand)) {
        ; Short on purpose, like the line further down. Naming the three
        ; browsers it looked in ran the cell over and got cut off mid-word,
        ; which told the reader less than the four words that fit.
        RC_Say("  " . Chr(0x2715) . "  No " . label . " catalog open")
        ; The jump can be asked for while the search is still loading, and
        ; then the bar is sitting on the status cell and the line above is
        ; held back until it comes down. A press that does nothing and says
        ; nothing is what this whole button is meant to be rid of, so the
        ; same words go up at the cursor for the two seconds the bar hides
        ; them.
        if (RC_BAR_ON)
            RC_TipAtMouse("No " . label . " catalog open")
        return false
    }
    ; The VIN goes on the clipboard either way, so it is there to paste if the
    ; catalog asks for something the search could not fill in.
    if (RC_VinVal != "")
        Clipboard := RC_VinVal
    ; With a VIN in hand the catalog is not just opened, it is searched.
    RC_CatSpawn((RC_VinVal != "" ? "search " . brand . " " . RC_VinVal
                                 : "select " . brand))
    ; The VIN used to be named here - "searching MPATFR85JKT003256", and the
    ; VIN the catalog already had before that. The cell is not wide enough for
    ; either: the line came out as "Opened the Isuzu catalog - searching M" and
    ; stopped. The half that got cut was the half already on screen, in the band
    ; above, in bigger type - so the line says what happened and leaves the VIN
    ; to the band that was showing it all along.
    RC_Say("  " . Chr(0x2713) . "  Opened the " . label . " catalog")
    return true
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


;==============================================================================
; Isuzu IDS  (Pentana XT client -> DC611 Warranty Unit Enquiry)
;
; The factory's own record of the truck. It is the only source anywhere that
; names the model code it was built to, what that code spells out in words,
; the group and the paint code - everything else in this script is a guess off
; a VIN or a tyre shop's fitment line. So for an Isuzu this is asked first and
; the older sources only fill what it left blank.
;
; The transport is IsuzuVIN.ahk's, copied here rather than shelled out to: a
; headless Chrome driven over the DevTools protocol through a raw Winsock
; WebSocket, signed in to IDS and left signed in. Both apps share ONE Chrome -
; same port, same profile folder, same pid file, same named mutex - because IDS
; hands out one session at a time and a second sign-in would knock the first
; one out from under whoever was using it. That is also why nothing here ever
; kills Chrome: the other app may be in it, and the signed-in session is the
; expensive thing in the whole arrangement.
;==============================================================================

; The one way in. Hands back the DC611 record as a field/value object, or ""
; when IDS could not be reached or does not hold the VIN - and "" is always
; survivable: every caller carries on into the sources it used before this
; existed.
RC_IdsVin(vin) {
    global RC_IdsSeen, RC_IdsCold, RC_IdsBusy
    vin := Trim(vin)
    if (StrLen(vin) < 11)
        return ""
    key := vin
    StringUpper, key, key
    if RC_IdsSeen.HasKey(key)
        return RC_IdsSeen[key]

    ; Asked on some earlier day. The record was written to disk then, and a
    ; truck is built once, so the file is the answer - no Chrome, no wait.
    ; FileExist first: FileRead on a missing file throws rather than failing.
    path := RC_IdsCachePath(key)
    if (path != "" && FileExist(path)) {
        FileRead, res, %path%
        if RegExMatch(res, "m)^vin=[^\r\n]+") {
            map := RC_IdsParse(res)
            RC_IdsSeen[key] := map
            RC_Tick("ids.disk")
            return map
        }
    }

    ; It would not come up a minute ago. Asking again on every search costs
    ; twenty seconds each time for the same refusal, so it is left alone for
    ; two minutes and the tyre shops answer meanwhile.
    if (RC_IdsCold && A_TickCount - RC_IdsCold < 120000)
        return ""

    ; Somebody in this process is already in the Chrome - a search that was
    ; overtaken mid-lookup, most likely. Two hands on one form is how a VIN
    ; ends up half in each field, so this one goes without IDS.
    if (RC_IdsBusy)
        return ""

    ; Twenty seconds to get in: IsuzuVIN itself may be mid-lookup on the one
    ; tab, and waiting for it is far cheaper than a second session.
    if !RC_IdsLock(20000) {
        RC_IdsCold := A_TickCount
        return ""
    }
    RC_IdsBusy := 1
    res := ""
    try {
        if RC_IdsReady() {
            RC_Tick("ids.ready")
            res := RC_IdsLookup(vin)
            RC_Tick("ids.lookup")
            RC_IdsForms()
        }
    } catch e {
        res := ""
    }
    RC_IdsBusy := 0
    RC_IdsUnlock()

    if (res = "NOTFOUND") {
        ; IDS holds every Isuzu sold here, so a VIN it does not know is not an
        ; Isuzu record - a true answer, and one worth remembering so the same
        ; plate is not asked twice. Remembered for the day only: a not-found
        ; is read off a screen that went blank, and a blank screen is not
        ; something to keep forever.
        RC_IdsSeen[key] := ""
        return ""
    }
    if (res = "") {
        RC_IdsCold := A_TickCount
        return ""
    }
    map := RC_IdsParse(res)
    RC_IdsSeen[key] := map
    ; And onto the disk, for every later day.
    if (path != "" && !FileExist(path)) {
        SplitPath, path, , dir
        FileCreateDir, %dir%
        FileAppend, %res%, %path%
    }
    return map
}

; Where a VIN's record is kept: one file per VIN, in the Isuzu tool's own
; folder so the two apps can share it. Blank for a VIN that is not a plain
; run of letters and digits - nothing that could be a path is written.
RC_IdsCachePath(key) {
    if !RegExMatch(key, "^[A-Z0-9]{11,17}$")
        return ""
    return RC_IdsDir() . "\ids-cache\" . key . ".txt"
}

; Get the dealer system ready before anyone asks for it, from a timer shortly
; after the window is up. Critical: a plate typed while this is under way
; waits the second or so the attach takes, rather than starting a search that
; would find the Chrome half set up.
RC_IdsWarm() {
    global RC_IdsBusy, RC_IdsCold, RC_TIMING, RC_LOG
    Critical
    if (RC_IdsBusy || !RC_IdsLock(0))
        return
    RC_IdsBusy := 1
    t0 := A_TickCount
    ok := false
    try {
        ok := RC_IdsReady()
        if (!ok)
            RC_IdsCold := A_TickCount
    } catch e {
    }
    RC_IdsBusy := 0
    RC_IdsUnlock()
    ; Its own line in the day book, not a tick: a search may be half way
    ; through its own ticks when this runs, and they are not to be mixed.
    if (RC_TIMING) {
        line := A_YYYY . "-" . A_MM . "-" . A_DD . " " . A_Hour . ":" . A_Min
              . "  timing warm " . (ok ? "ready" : "failed") . " ms=" . (A_TickCount - t0) . "`n"
        FileAppend, %line%, %RC_LOG%
    }
}

; Once a minute, a word to the session so it is still there at the next
; search. Nothing is started here - a Chrome that has gone stays gone until a
; search needs it - and a socket that no longer answers is closed so the next
; search reconnects instead of waiting on it.
RC_IdsKeep() {
    global RC_IdsBusy, RC_IdsSock
    Critical
    if (RC_IdsBusy || !RC_IdsSock || !RC_IdsLock(0))
        return
    RC_IdsBusy := 1
    try {
        if (RC_IdsEval("'pong'") = "pong")
            RC_IdsPoke()
        else if (RC_IdsSock) {
            RCS_Close(RC_IdsSock)
            RC_IdsSock := 0
        }
    } catch e {
    }
    RC_IdsBusy := 0
    RC_IdsUnlock()
}

; --- an Isuzu, read off the VIN and the dealer record ------------------------
;
; Isuzu is the one make the window can name almost entirely by itself. Thai
; built D-MAXes and MU-Xes - every one sold here - carry the model, the
; drive, the engine and the build year in the VIN, and the dealer system adds
; the model code, the words behind it, the paint and the dates. So an Isuzu
; gets its own line under the make, built here and nowhere else:
;
;   D-MAX RT66 2019, 4x2 Crew Cab Tub LSU Auto, 4JJ1 3.0L Diesel, High Ride
;
; The first half of that is up with the register's answer; the dealer record
; fills the rest in a few seconds later.

; Read the VIN into the search's context. True when it was an Isuzu VIN.
RC_IsuSeed(c) {
    vin := c.vin
    eng := ""
    drive := ""
    yr := ""
    gen := ""
    model := RC_IsuzuVin(vin, eng, drive, yr, gen)
    if (model = "")
        return false
    c.isu := true
    if (c.vinModel = "")
        c.vinModel := model
    if (yr != "")
        c.vinYear := yr
    if (gen != "" && c.genTag = "")
        c.genTag := "(" . gen
    c.isuDrive := drive
    c.isuEng := StrReplace(eng, "T/Diesel", "Diesel")
    if (c.mkX = "") {
        c.mkX := eng
        if (drive != "")
            c.mkX .= (c.mkX != "" ? ", " : "") . drive
    }
    return true
}

; What the dealer record adds: the model name off the code, the words in
; their proper case, and the ride height. Hands back the words the body pass
; reads, the same as RC_IdsWords did before.
RC_IsuFromIds(c, ids, vin) {
    iW := RC_IdsWords(ids.model_desc)
    c.isuName := RC_IsuName(ids.model)
    c.isuWords := RC_IsuNice(iW)
    c.isuRide := RC_IdsRide(vin, ids.model, ids.model_desc)
    return iW
}

; The line under the make: the model, and only the model. Everything else
; about the truck is a row of its own, so nothing is said twice.
RC_IsuLine(c) {
    return c.vinModel
}

; The block of rows an Isuzu gets, written wherever the search has got to:
; the year, the build and the engine are in the VIN and go up with the
; register's answer; the build fills out into the dealer system's words when
; those arrive. Every row is put in its place - see RC_RowPut - so the block
; reads the same whichever leg wrote which row.
RC_IsuRows(c) {
    RC_RowPut("Year", c.vinYear)
    RC_RowPut("Build", RC_IsuBuild(c))
    RC_RowPut("Engine", c.isuEng)
}

; The build in words. The dealer system's own, once it has answered - "4x2
; Crew Cab Tub LSU Auto" - and until then the drive off the VIN, plus
; whatever a shop has said about the cab and the back, plus the trim.
RC_IsuBuild(c) {
    words := c.isuWords
    if (words != "")
        return words
    words := c.isuDrive
    if (c.bodyHint != "") {
        cab := RC_CabType(c.bodyHint)
        style := RC_BodyStyle(c.bodyHint)
        if (cab != "")
            words .= (words != "" ? " " : "") . cab
        if (style != "")
            words .= (words != "" ? " " : "") . style
    }
    if (c.trm != "")
        words .= (words != "" ? " " : "") . c.trm
    return Trim(words)
}

; --- rows with a place of their own --------------------------------------
;
; RC_SetRow puts a new row above the wipers, which is the end of the list for
; every purpose but one: the Isuzu block, whose rows come from three legs in
; whatever order the legs finish, and which should still read code, year,
; build, engine, ride height, colour, dates. So these are put in by name.

; Where a row sits in the block. Anything not in the block sits after it.
RC_RowPos(field) {
    static ORDER := ",Registration,Expiry,Model code,Year,Build,Engine,Ride height,Colour,Build date,Warranty start,Warranty expiry,"
    p := InStr(ORDER, "," . field . ",")
    return p ? p : 9999
}

; The row a new field goes in above: the first row that belongs after it, or
; the wipers - which is where RC_SetRow puts everything.
RC_RowSlot(field) {
    global RC_WipeRow
    mine := RC_RowPos(field)
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        if (RC_RowPos(f) > mine)
            return A_Index
    }
    return RC_WipeRow
}

; Write a row in its place - over the row of that name if there is one, and
; slid in where it belongs if there is not. Behind Ultra the window's own cut
; of the list gets the same row, in the same place, when it is one Ultra
; shows.
RC_RowPut(field, value) {
    global RC_WipeRow, RC_RedRow, RC_QUIET
    if (value = "")
        return
    RC_Use()
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        if (f == field) {
            LV_Modify(A_Index, "Col2", value)
            if (RC_QUIET && RC_QKeep(field))
                RC_QMirror(field, value)
            return
        }
    }
    at := RC_RowSlot(field)
    LV_Insert(at, "", field, value)
    if (at <= RC_WipeRow)
        RC_WipeRow += 1
    if (RC_RedRow && at <= RC_RedRow)
        RC_RedRow += 1
    if (RC_QUIET && RC_QKeep(field))
        RC_QMirror(field, value)
}

; The dealer system's words in their proper case: "4X2 CREW CAB LSU AUTO"
; reads "4x2 Crew Cab LSU Auto". The trims are initials and stay capitals -
; RC_TitleWord knows LSU, LST and LSM, and SX and EX are two letters, which it
; leaves alone by itself. A cab chassis came through RC_IdsWords as "CAB Cab
; Chassis", and the doubled cab is folded here.
RC_IsuNice(words) {
    s := RC_TitleCase(words)
    s := RegExReplace(s, "i)\bCab Cab Chassis\b", "Cab Chassis")
    s := RegExReplace(s, "i)\b4X(2|4)\b", "4x$1")
    return s
}

; The model name Isuzu gives a build, off the front of its model code - the
; IUA "Model Designation Code Breakdown": IOR9 is the RT66, TOR5 the RG16,
; UJOR5 the RJ08. Longest prefix first, so UIOR7Z is tried before UIOR7.
RC_IsuName(code) {
    static MAP := [ ["UJOR5XXD", "RJ08"], ["UIOR7Z", "RF20"]
                  , ["UIOR4", "RF10"], ["UIOR5", "RF15"], ["UIOR6", "RF16"]
                  , ["UIOR7", "RF17"], ["UIOR8", "RF28"], ["UIOR9", "RF35"]
                  , ["UJOR1", "RJ01"], ["UJOR2", "RJ05"], ["UJOR3", "RJ06"]
                  , ["UJOR4", "RJ07"], ["UJOR5", "RJ08"]
                  , ["GORB", "TF190"], ["IOR2", "RT50"], ["IOR3", "RT70"]
                  , ["IOR4", "RT75"], ["IOR5", "RT80"], ["IOR6", "RT85"]
                  , ["IOR7", "RT87"], ["IOR8", "RT93"], ["IOR9", "RT66"]
                  , ["TOR0", "RG01"], ["TOR2", "RG10"], ["TOR3", "RG12"]
                  , ["TOR4", "RG14"], ["TOR5", "RG16"] ]
    code := StrReplace(Trim(code), " ", "")
    StringUpper, code, code
    for i, p in MAP {
        if (SubStr(code, 1, StrLen(p[1])) == p[1])
            return p[2]
    }
    return ""
}

; Which rows an Isuzu shows at each setting. Ultra is the plate, the expiry
; and the block that says what the truck is: code, year, build, engine, ride
; height, and the paint with its code. Fast adds the dates. Full is everything.
RC_IsuRowOk(field, speed) {
    static ULTRA := ",Registration,Expiry,Model code,Year,Build,Engine,Ride height,Colour,"
    static FAST  := ",Build date,Warranty start,Warranty expiry,"
    if (speed >= 2)
        return true
    if InStr(ULTRA, "," . field . ",")
        return true
    return (speed = 1 && InStr(FAST, "," . field . ","))
}

; Whether the car on screen is an Isuzu. The search's context says so while
; there is one; a kept answer never builds one, and for that the make line
; is asked instead - RC_SetMake keeps a copy in RC_QMake.
RC_IsIsu() {
    global RC_CTX, RC_QMake
    if (IsObject(RC_CTX) && RC_CTX.badge != "")
        return InStr(RC_CTX.badge, "ISUZU") ? true : false
    return InStr(RC_QMake, "ISUZU") ? true : false
}

; ------------------------------------------------ rows out of the record ----
; The four the warehouse asks for, on the end of the list, in the order the
; Isuzu tool prints them. Whatever IDS left blank simply is not written - a
; blank row says nothing a missing one does not.
RC_IdsRows(ids, vin) {
    global RC_SPEED
    ; The code, the ride height and the paint go in the Isuzu block at every
    ; setting; the model words go in the Build row there, written by
    ; RC_IsuRows once RC_IsuFromIds has put them in their proper case. The
    ; three dates are Fast's and Full's.
    RC_RowPut("Model code", ids.model)
    RC_RowPut("Ride height", RC_IdsRide(vin, ids.model, ids.model_desc))
    ; The group is read off the record and deliberately not written: it is the
    ; parts catalogue's own filing word - "TF*" - and it means nothing to
    ; anyone reading this window.
    RC_IdsPaint(ids.colour, ids.colour_code)
    RC_RowPut("Build date", RC_IdsDate(ids.build_date))
    RC_RowPut("Warranty start", RC_IdsDate(ids.warranty_start))
    RC_RowPut("Warranty expiry", RC_IdsDate(ids.warranty_expiry))

    ; The description names the cab, which is the one thing the register never
    ; says and the VIN does not carry. Full's body row; the block's Build row
    ; carries the same words at every setting.
    if (RC_SPEED != 1) {
        cab := RC_CabType(RC_IdsWords(ids.model_desc))
        if (cab != "" && !RC_HasRow("Body type"))
            RC_SetRow("Body type", cab)
    }
}

; IDS writes its dates short - 12/08/19 - and the window writes the year out.
RC_IdsDate(s) {
    s := Trim(s)
    if RegExMatch(s, "^(\d{1,2})/(\d{1,2})/(\d{2})$", m)
        return m1 . "/" . m2 . "/" . ((m3 + 0 < 50) ? "20" : "19") . m3
    return s
}

; The dealer system's description written out in words the rest of this script
; reads. It is the factory's own shorthand - "4X2 SINGLE CAB C/C SX AUTO" - and
; C/C is a cab chassis, which nothing here would otherwise recognise: the body
; pass answers to "cab chassis", "c/chas" and "chassis", and to none of those.
; The row itself keeps the shorthand, because that is what the record says and
; what the parts desk will be reading back over the phone.
RC_IdsWords(desc) {
    w := Trim(RegExReplace(desc, "i)\bC/C\b", " Cab Chassis "))
    w := RegExReplace(w, "\s+", " ")
    ; And no C/C on a truck that has a cab is a tub - IDS says nothing for
    ; the tub, so the nothing is spelt out, once, after the cab words. The
    ; body pass answers to "tub", and so does the line under the make.
    if (!InStr(w, "Chassis") && RC_CabType(w) != "")
        w := RegExReplace(w, "i)\bCAB\b", "Cab Tub", , 1)
    return w
}

; The paint code goes on the end of the colour row rather than in a row of its
; own - it is the same fact said twice, and the code is the half that gets
; ordered. A digit anywhere in a word is what stops the title-case pass from
; touching it, so "(527)" survives being tidied.
RC_IdsPaint(colour, code) {
    if (code = "")
        return
    RC_Use()
    Loop, % LV_GetCount()
    {
        LV_GetText(f, A_Index, 1)
        ; "==" and not "=": row names are compared as written.
        if (f == "Colour") {
            LV_GetText(v, A_Index, 2)
            if InStr(v, code)
                return
            ; The factory's own name for the paint beats the register's
            ; one-word guess at it - "Titanium Silver Metallic", not "SILVER".
            if (colour != "")
                v := colour
            ; Through RC_RowPut, not LV_Modify: behind Ultra the row is in
            ; the window as well as the hidden list, and both get the code.
            RC_RowPut("Colour", Trim(Trim(v) . " (" . code . ")"))
            return
        }
    }
    ; No colour row at all - the state kept it to itself - so IDS writes one,
    ; in the block's place for it.
    RC_RowPut("Colour", (colour != "") ? colour . " (" . code . ")" : code)
}

; ------------------------------------------------------ high ride / low ride
; Isuzu does not put ride height in the VIN and does not put it in the DC611
; record either. It lives in the model code, and only by convention: the last
; three digits are the variant, and the low-ride variants have always been
; 002, 004, 024 and 025.
;
; Where that comes from: the IUA "VIN ID Breakdown" sheet lists the pre-18MY
; low-ride model codes outright - eighteen codes across nine prefixes, and
; every one of them ends in one of those four numbers. No list has been issued
; for 18MY on, so the same four are carried forward, and two records years
; apart say the carry-forward holds: TOR0002 = 4X2 SINGLE CAB C/C SX AUTO,
; TOR3025 = 4X2 SPACE CAB C/C SX AUTO.
;
; Two gates come BEFORE the suffix, because the suffix on its own lies:
;   - 4x4 is high ride by construction. TOR3004 is a 4X4 SINGLE CAB C/C and
;     ends 004; without the gate it would read Low Ride.
;   - the MU-X is a wagon on the high-ride chassis, 4x2 or 4x4 alike.
; Both are read off the VIN, which the sheet does define: character 4 is the
; model line (T pickup, U light-duty MPV) and character 6 is the drive system
; (R 4x2, S 4x4). With no usable VIN the model description carries the same
; two facts in words, so it is the fallback.
;
; Returns "High Ride", "Low Ride", or "" when there is not enough to say - and
; "" is the honest answer, not a default of High Ride.
RC_IdsRide(vin, model, desc) {
    ; no case folding anywhere below: AHK compares strings case-blind, InStr is
    ; case-blind by default, and the one regex carries the i) flag
    vin := StrReplace(Trim(vin), " ", "")
    model := StrReplace(Trim(model), " ", "")
    desc := Trim(desc)

    line := ""
    drive := ""
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
    return InStr("|002|004|024|025|", "|" . m1 . "|") ? "Low Ride" : "High Ride"
}

RC_IdsParse(res) {
    map := {}
    Loop, Parse, res, `n, `r
    {
        eq := InStr(A_LoopField, "=")
        if (eq)
            map[SubStr(A_LoopField, 1, eq - 1)] := SubStr(A_LoopField, eq + 1)
    }
    return map
}

; ---------------------------------------------- one tab, two applications ----
; The mutex is named the same as IsuzuVIN's on purpose. Two apps typing into
; one form at once is how a VIN ends up half in one field and half in another.
RC_IdsLock(timeoutMs) {
    global RC_IdsMx
    if (!RC_IdsMx)
        RC_IdsMx := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", "Local\IsuzuVIN_CDP", "Ptr")
    if (!RC_IdsMx)
        return false
    ; Asked without waiting, over and over with a sleep between, rather than
    ; one wait for the whole timeoutMs: IsuzuVIN may hold the tab for twenty
    ; seconds, and a window frozen for twenty seconds takes no clicks. The
    ; sleep is what hands the window its messages.
    t0 := A_TickCount
    Loop {
        r := DllCall("WaitForSingleObject", "Ptr", RC_IdsMx, "UInt", 0, "UInt")
        if (r = 0 || r = 0x80)     ; WAIT_OBJECT_0 or WAIT_ABANDONED
            return true
        if (A_TickCount - t0 >= timeoutMs)
            return false
        Sleep, 50
    }
}

RC_IdsUnlock() {
    global RC_IdsMx
    if (RC_IdsMx)
        DllCall("ReleaseMutex", "Ptr", RC_IdsMx)
}

; A tab we can type into, signed in, with a server that is answering. The
; cheap checks first: a socket that evals, and a session confirmed alive
; within the minute, is taken at its word - proving liveness costs a server
; round trip and this runs on every Isuzu.
RC_IdsReady() {
    global RC_IdsSock, RC_IdsOk
    if (RC_IdsEval("'pong'") = "pong") {
        if (RC_IdsOk && A_TickCount - RC_IdsOk < 60000 && RC_IdsIn())
            return true
        if (RC_IdsIn() && RC_IdsAlive()) {
            RC_IdsPoke()
            RC_IdsOk := A_TickCount
            return true
        }
        if (RC_IdsRecover()) {
            RC_IdsForms()
            RC_IdsOk := A_TickCount
            return true
        }
    }
    ; transport itself is gone - socket, then Chrome, then page, then login
    if (RC_IdsSock) {
        RCS_Close(RC_IdsSock)
        RC_IdsSock := 0
    }
    if !RC_IdsChrome()
        return false
    if !RC_IdsPage()
        return false
    if !RC_IdsRecover()
        return false
    RC_IdsForms()
    RC_IdsOk := A_TickCount
    return true
}

; ------------------------------------------------------- Chrome management ---
RC_IdsDir() {
    ; The Isuzu tool's own folder, beside this one. Its profile is where the
    ; signed-in session lives, so this is not a copy of that setup - it is
    ; that setup.
    return A_ScriptDir . "\..\IsuzuVIN"
}

RC_IdsExe() {
    for i, p in ["C:\Program Files\Google\Chrome\Application\chrome.exe"
                , "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
                , A_AppData "\..\Local\Google\Chrome\Application\chrome.exe"] {
        if FileExist(p)
            return p
    }
    return ""
}

RC_IdsHttp(path) {
    try {
        whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://127.0.0.1:9412" . path, true)
        whr.Send()
        whr.WaitForResponse(5)
        return whr.ResponseText
    } catch e {
        return ""
    }
}

; FileDelete on a file that is not there raises exception "1" inside a try, so
; every delete goes through here.
RC_IdsDel(f) {
    try {
        if FileExist(f)
            FileDelete, %f%
    } catch e {
    }
}

RC_IdsChrome() {
    if (InStr(RC_IdsHttp("/json/version"), "webSocketDebuggerUrl"))
        return true
    exe := RC_IdsExe()
    if (exe = "")
        return false
    dir := RC_IdsDir()
    args := " --headless=new --disable-gpu"
          . " --remote-debugging-port=9412"
          . " --user-data-dir=""" . dir . "\chrome-profile"""
          . " --remote-allow-origins=*"
          . " --window-size=1280,1024"
          . " --no-first-run --no-default-browser-check"
          . " --disable-features=Translate,MediaRouter"
          . " --disable-background-timer-throttling"
          . " --disable-renderer-backgrounding"
          . " --disable-backgrounding-occluded-windows"
    pid := 0
    Run, %exe%%args%, , Hide, pid
    ; The pid file is the Isuzu tool's, and it is written here for its sake:
    ; whichever app started Chrome, the other one has to be able to find it.
    RC_IdsDel(dir . "\chrome.pid")
    FileAppend, %pid%, % dir . "\chrome.pid"
    Loop, 40 {
        Sleep, 300
        if (InStr(RC_IdsHttp("/json/version"), "webSocketDebuggerUrl"))
            return true
    }
    return false
}

; attach to a live IDS tab (warm) or make a fresh one (cold)
RC_IdsPage() {
    global RC_IdsSock, RC_IdsId
    list := RC_IdsHttp("/json/list")
    pos := 1
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (!InStr(blk, "idserp.iua.net.au") || !InStr(blk, """page"""))
            continue
        if !RegExMatch(blk, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/page/[^""]+)""", wm)
            continue
        s := RCS_Connect("127.0.0.1", 9412, wm1)
        if (!s)
            continue
        RC_IdsSock := s
        if (RC_IdsEval("'pong'") = "pong") {
            RC_IdsCmd("Emulation.setDeviceMetricsOverride", "{""width"":1280,""height"":1024,""deviceScaleFactor"":1,""mobile"":false}")
            return true
        }
        ; a tab that answers no evals is a wedged renderer - close it over HTTP,
        ; which still works when evals do not, or it lingers forever eating
        ; memory
        if (RC_IdsSock) {
            RCS_Close(RC_IdsSock)
            RC_IdsSock := 0
        }
        if RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im)
            RC_IdsHttp("/json/close/" . im1)
    }
    ; ---- cold path: create a fresh target ----
    ver := RC_IdsHttp("/json/version")
    if !RegExMatch(ver, "webSocketDebuggerUrl""\s*:\s*""ws://[^/]+(/devtools/[^""]+)""", bm)
        return false
    bsock := RCS_Connect("127.0.0.1", 9412, bm1)
    if (!bsock)
        return false
    id := ++RC_IdsId
    RCS_SendText(bsock, "{""id"":" . id . ",""method"":""Target.createTarget"",""params"":{""url"":""https://idserp.iua.net.au/app?open=xtapp"",""newWindow"":true,""width"":1280,""height"":1024}}")
    tid := ""
    Loop, 30 {
        r := RCS_Recv(bsock)
        if (r = "")
            break
        if (InStr(r, """id"":" . id) && RegExMatch(r, """targetId""\s*:\s*""([0-9A-Fa-f]+)""", tm)) {
            tid := tm1
            break
        }
    }
    RCS_Close(bsock)
    if (tid = "")
        return false
    RC_IdsSock := RCS_Connect("127.0.0.1", 9412, "/devtools/page/" . tid)
    if (!RC_IdsSock)
        return false
    RC_IdsCmd("Emulation.setDeviceMetricsOverride", "{""width"":1280,""height"":1024,""deviceScaleFactor"":1,""mobile"":false}")
    return true
}

; alive check -> sign in on the page -> fresh tab and sign in.
; TRAP 1: the page title keeps saying "Active user" long after the server has
; killed the session, so the title alone is never enough.
; TRAP 2: NEVER navigate a zombie RAP page - its unload handler fires a sync
; XHR into the dead session and blocks the renderer main thread forever, after
; which every eval hangs. Close the tab and open a fresh one instead.
RC_IdsRecover() {
    global RC_IdsSock
    if (RC_IdsSock && RC_IdsIn() && RC_IdsAlive()) {
        RC_IdsPoke()
        return true
    }
    if (RC_IdsSock && !RC_IdsIn() && RC_IdsLogin()) {
        RC_IdsPoke()
        return true
    }
    if !RC_IdsTab()
        return false
    if !RC_IdsLogin()
        return false
    RC_IdsPoke()
    return true
}

; drop every IDS tab, wedged ones included, and open a brand-new xtapp target
RC_IdsTab() {
    global RC_IdsSock
    if (RC_IdsSock) {
        RCS_Close(RC_IdsSock)
        RC_IdsSock := 0
    }
    list := RC_IdsHttp("/json/list")
    pos := 1
    while (pos := RegExMatch(list, "\{[^{}]+\}", blk, pos)) {
        pos += StrLen(blk)
        if (InStr(blk, "idserp.iua.net.au") && InStr(blk, """page""")
            && RegExMatch(blk, """id""\s*:\s*""([0-9A-Fa-f]+)""", im))
            RC_IdsHttp("/json/close/" . im1)
    }
    Sleep, 500
    return RC_IdsPage()
}

; ------------------------------------------------------------- CDP layer -----
RC_IdsEsc(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, """", "\""")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

RC_IdsCmd(method, paramsJson) {
    global RC_IdsSock, RC_IdsId
    if (!RC_IdsSock)
        return ""
    id := ++RC_IdsId
    if !RCS_SendText(RC_IdsSock, "{""id"":" . id . ",""method"":""" . method . """,""params"":" . paramsJson . "}")
        return ""
    Loop, 500 {
        r := RCS_Recv(RC_IdsSock)
        if (r = "") {
            ; transport dead, or the page's main thread is wedged. Kill the
            ; socket so every later call fails INSTANTLY instead of burning a
            ; full receive timeout each - a wedged page turns a poll loop into
            ; a twenty-minute hang otherwise.
            RCS_Close(RC_IdsSock)
            RC_IdsSock := 0
            return ""
        }
        if (RegExMatch(r, """id""\s*:\s*" . id . "\b"))
            return r
        ; else an event, or another id - keep reading
    }
    return ""
}

RC_IdsEval(js) {
    r := RC_IdsCmd("Runtime.evaluate", "{""expression"":""" . RC_IdsEsc(js) . """,""returnByValue"":true}")
    if (r = "")
        return ""
    if RegExMatch(r, """value""\s*:\s*""([^""]*)""", m)
        return m1
    if RegExMatch(r, """value""\s*:\s*([0-9]+)", m)
        return m1
    return ""
}

RC_IdsB64(b64) {
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

RC_IdsClick(x, y) {
    RC_IdsCmd("Input.dispatchMouseEvent", "{""type"":""mousePressed"",""x"":" . x . ",""y"":" . y . ",""button"":""left"",""clickCount"":1}")
    RC_IdsCmd("Input.dispatchMouseEvent", "{""type"":""mouseReleased"",""x"":" . x . ",""y"":" . y . ",""button"":""left"",""clickCount"":1}")
}

; the whole string in ONE call, and it still fires proper input events
RC_IdsIns(s) {
    RC_IdsCmd("Input.insertText", "{""text"":""" . RC_IdsEsc(s) . """}")
}

; the slow fallback, one key at a time, for forms that ignore the fast way
RC_IdsType(s) {
    Loop, Parse, s
    {
        ch := RC_IdsEsc(A_LoopField)
        RC_IdsCmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""text"":""" . ch . """}")
        RC_IdsCmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""text"":""" . ch . """}")
    }
}

RC_IdsKey(key, vk) {
    RC_IdsCmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""key"":""" . key . """,""code"":""" . key . """,""windowsVirtualKeyCode"":" . vk . "}")
    RC_IdsCmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""key"":""" . key . """,""code"":""" . key . """,""windowsVirtualKeyCode"":" . vk . "}")
}

RC_IdsWipe() {
    RC_IdsCmd("Input.dispatchKeyEvent", "{""type"":""keyDown"",""modifiers"":2,""key"":""a"",""code"":""KeyA"",""windowsVirtualKeyCode"":65}")
    RC_IdsCmd("Input.dispatchKeyEvent", "{""type"":""keyUp"",""modifiers"":2,""key"":""a"",""code"":""KeyA"",""windowsVirtualKeyCode"":65}")
    RC_IdsKey("Delete", 46)
}

RC_IdsXY(js, ByRef x, ByRef y) {
    v := RC_IdsEval(js)
    if RegExMatch(v, "^(-?[0-9]+),(-?[0-9]+)$", m) {
        x := m1
        y := m2
        return true
    }
    return false
}

; poll a coordinate-returning script until it resolves, instead of sleeping a
; fixed guess and hoping the form arrived
RC_IdsWait(js, ByRef x, ByRef y, timeoutMs := 6000, stepMs := 200) {
    start := A_TickCount
    Loop {
        if RC_IdsXY(js, x, y)
            return true
        if (A_TickCount - start > timeoutMs)
            return false
        Sleep, %stepMs%
    }
}

RC_IdsQ(s) {
    return "'" . StrReplace(s, "'", "\'") . "'"
}

; ---------------------------------------------------------------- login ------
; The title alone LIES: it keeps saying "Active user" even after the server has
; thrown a re-auth panel back up - the session was challenged, not killed, so
; RAP still answers and the liveness check passes too. The only honest tell is
; a VISIBLE password box on screen. The width filter matters: RAP leaves stale
; hidden password inputs lying about in the DOM.
RC_IdsIn() {
    if !InStr(RC_IdsEval("document.title"), "Active user")
        return false
    pw := RC_IdsEval("''+Array.from(document.querySelectorAll('input[type=password]')).filter(function(x){return x.getBoundingClientRect().width>0;}).length")
    return (pw = "0")
}

; Find the login fields RELATIVE TO THE VISIBLE PASSWORD BOX, never by input
; index. On the cold login page the username and password happen to be inputs
; 0 and 1, but on the mid-session re-auth panel the MENU SEARCH BOX is input 0
; - so index 1 is the username, and typing the password into it fails three
; times and falls back to a slow fresh-tab login for no reason. Anchor on the
; one visible password input; the username is the nearest visible, editable,
; non-password input above it and left-aligned with it.
RC_IdsLoginJs(which, what) {
    return "(function(){"
        . "var vis=function(x){var r=x.getBoundingClientRect();return r.width>0&&r.height>0;};"
        . "var pw=Array.from(document.querySelectorAll('input[type=password]')).filter(vis)[0];"
        . "if(!pw)return '';"
        . "var pr=pw.getBoundingClientRect();"
        . "var e=pw;"
        . "if('" . which . "'==='u'){"
        .   "var ok=function(x){return x!==pw&&x.type!=='password'&&!x.readOnly&&!x.disabled&&vis(x)&&x.getBoundingClientRect().top<pr.top;};"
        .   "var all=Array.from(document.querySelectorAll('input')).filter(ok);"
        .   "var aligned=all.filter(function(x){return Math.abs(x.getBoundingClientRect().left-pr.left)<40;});"
        .   "var pick=(aligned.length?aligned:all);"
        .   "pick.sort(function(a,b){return b.getBoundingClientRect().top-a.getBoundingClientRect().top;});"
        .   "e=pick[0];"
        . "}"
        . "if(!e)return '';"
        . ((what = "xy")
            ? "var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);"
            : "return e.value||'';")
        . "})()"
}

; click the field, clear it, type, read it back; three goes, the last one
; typing key by key
RC_IdsSetField(which, text) {
    jsCoord := RC_IdsLoginJs(which, "xy")
    jsVal   := RC_IdsLoginJs(which, "val")
    Loop, 3 {
        if !RC_IdsXY(jsCoord, cx, cy)
            return false
        RC_IdsClick(cx, cy)
        Sleep, 100
        RC_IdsWipe()
        Sleep, 60
        if (A_Index < 3)
            RC_IdsIns(text)
        else
            RC_IdsType(text)
        Sleep, 120
        ; "==" and not "=": a password is compared as written, case and all
        if (RC_IdsEval(jsVal) == text)
            return true
    }
    return false
}

RC_IdsLogin() {
    global RC_IDS_USER, RC_IDS_PW
    if RC_IdsIn()
        return true
    ; wait for the form - a VISIBLE password box, for the reason above
    n := 0
    Loop, 60 {
        n := RC_IdsEval("''+Array.from(document.querySelectorAll('input[type=password]')).filter(function(x){return x.getBoundingClientRect().width>0;}).length")
        if (n >= 1)
            break
        Sleep, 250
    }
    if (n < 1)
        return RC_IdsIn()
    Sleep, 700   ; let the RAP login form settle before typing into it
    if !RC_IdsSetField("u", RC_IDS_USER)
        return false
    if !RC_IdsSetField("p", RC_IDS_PW)
        return false
    jsS := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){return x.children.length<=1&&(x.innerText||'').trim()==='Sign in'&&x.getBoundingClientRect().width>0;});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !RC_IdsXY(jsS, sx, sy)
        return false
    RC_IdsClick(sx, sy)
    Loop, 50 {
        Sleep, 300
        if RC_IdsIn()
            return true
        ; the server's own refusal, rather than a blind timeout
        err := RC_IdsEval("(function(){var e=Array.from(document.querySelectorAll('div,span')).find(function(x){var r=x.getBoundingClientRect();return r.width>0&&x.children.length===0&&/incorrect|invalid|locked|no company|denied/i.test(x.innerText||'');});return e?(e.innerText||'').trim().substring(0,80):'';})()")
        if (err != "")
            return false
    }
    return RC_IdsIn()
}

; TRUE server liveness. A zombie page still answers JS and still shows a
; logged-in title, but RAP's request counter only moves when the SERVER answers
; a send(). A frozen counter after a real send is a dead session.
RC_IdsAlive() {
    jsCnt := "(function(){try{return ''+rwt.remote.Connection.getInstance()._requestCounter;}catch(e){return 'NA';}})()"
    c0 := RC_IdsEval(jsCnt)
    if (c0 = "NA" || c0 = "")
        return RC_IdsIn()   ; counter not exposed - the title is all there is
    RC_IdsEval(RC_IdsSendJs())
    Loop, 12 {
        Sleep, 250
        c1 := RC_IdsEval(jsCnt)
        if (c1 != "" && c1 != "NA" && c1 != c0)
            return true
    }
    return false
}

; A real RAP request, plus an in-page interval that keeps making them after
; this script has gone. That interval is what holds the session open overnight.
RC_IdsSendJs() {
    return "(function(){if(!window.__ivSend){window.__ivSend=function(){try{if(window.rwt&&rwt.remote&&rwt.remote.Connection&&rwt.remote.Connection.getInstance){rwt.remote.Connection.getInstance().send();return 'sent-conn';}}catch(e){}try{if(window.rwt&&rwt.remote&&rwt.remote.Server&&rwt.remote.Server.getInstance){rwt.remote.Server.getInstance().send();return 'sent-server';}}catch(e){}try{if(window.org&&org.eclipse&&org.eclipse.swt&&org.eclipse.swt.Request&&org.eclipse.swt.Request.getInstance){org.eclipse.swt.Request.getInstance().send();return 'sent-legacy';}}catch(e){}return 'no';};}if(!window.__ivKA){window.__ivKA=setInterval(function(){try{window.__ivSend();}catch(e){}},240000);}return window.__ivSend();})()"
}

RC_IdsPoke() {
    RC_IdsEval(RC_IdsSendJs())
}

; ----------------------------------------------------------- housekeeping ----
; When a server-side program instance dies - DC611 hit with something it hates
; - IDS replaces the whole tab's content with "Program terminated". The tab is
; then dead: no buttons, keys do nothing. The only way out is the X on the tab
; header, a ~16px child at the right of the label.
RC_IdsDead() {
    jsT := "(function(){return Array.from(document.querySelectorAll('div,span,td,input')).some(function(x){var r=x.getBoundingClientRect();if(r.width<=0||r.height<=0)return false;var v=(x.tagName==='INPUT'?(x.value||''):(x.children.length===0?(x.innerText||''):'')).trim();return /program terminated/i.test(v);})?'1':'0';})()"
    jsX := "(function(){var tabs=Array.from(document.querySelectorAll('div')).filter(function(e){var r=e.getBoundingClientRect();return r.height>18&&r.height<30&&r.top<80&&r.width>80&&r.width<420&&/^DC\d+/.test((e.innerText||'').trim())&&e.children.length>=2;});if(!tabs.length)return'';var t=tabs[0];var kids=Array.from(t.children).map(function(c){return c.getBoundingClientRect();}).filter(function(r){return r.width>=10&&r.width<=20;});if(!kids.length)return'';var r=kids[kids.length-1];return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    Loop, 3 {
        if (RC_IdsEval(jsT) != "1")
            return true
        if RC_IdsXY(jsX, tx, ty) {
            RC_IdsClick(tx, ty)
            Sleep, 600
            continue
        }
        RC_IdsKey("Enter", 13)
        Sleep, 400
        RC_IdsKey("Escape", 27)
        Sleep, 400
    }
    return (RC_IdsEval(jsT) != "1")
}

; close any DC611 screen still open, so the next lookup starts from the menu
RC_IdsForms() {
    RC_IdsDead()
    ; closing a dead tab - or the death itself - can throw up the mid-session
    ; re-auth challenge, so sign back in before touching anything else
    if (!RC_IdsIn())
        RC_IdsLogin()
    jsExit := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='Exit F3';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    Loop, 3 {
        if !RC_IdsXY(jsExit, ex, ey)
            break
        RC_IdsClick(ex, ey)
        Sleep, 500
    }
}

; The DC611 record read off the screen by where the cells sit. Every value is
; an input, and the form's layout does not move, so each field is whichever
; non-empty input lands nearest its known corner.
RC_IdsReadJs() {
    return "(function(){var cells={vin:[419,140],year:[697,140],group:[847,140],model:[419,164],model_desc:[605,164],colour_code:[419,188],colour:[475,188],trim_code:[761,188],trim:[817,188],engine:[467,210],activity:[973,231],key_number:[500,276],status_code:[811,299],status:[835,299],rego:[500,322],selling_dealer:[811,345],build_date:[499,368],retail_sale:[810,368],purpose_code:[1008,368],warranty_start:[810,414],sold_to_dealer:[500,437],warranty_expiry:[810,437],kms:[965,437],date_to_dealer:[499,483],comments:[500,512]};var items=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),x:Math.round(r.left),y:Math.round(r.top),w:Math.round(r.width)};}).filter(function(i){return i.w>0&&i.v!=='';});var out=[];var tol=28;Object.keys(cells).forEach(function(k){var cx=cells[k][0],cy=cells[k][1],best='',bd=tol+1;items.forEach(function(i){var d=Math.abs(i.x-cx)+Math.abs(i.y-cy);if(d<bd){bd=d;best=i.v;}});out.push(k+'='+best);});return btoa(unescape(encodeURIComponent(out.join('\n'))));})()"
}

; DC611 itself: open it from the menu box, type the VIN, click OK, wait for
; the record. Returns key=value lines, "NOTFOUND", or "" when something broke.
RC_IdsLookup(vin) {
    jsMenu := "(function(){var e=Array.from(document.querySelectorAll('input')).filter(function(x){var r=x.getBoundingClientRect();return !x.readOnly&&r.width>0&&r.top<140&&r.left<400;})[0];if(!e)return'';var r=e.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !RC_IdsXY(jsMenu, mx, my)
        return ""
    RC_IdsClick(mx, my)
    RC_IdsWipe()
    RC_IdsIns("DC611")
    Sleep, 250
    RC_IdsKey("Enter", 13)

    lbl := "Vin Number"
    jsField := "(function(){var ins=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),x:r.left,cx:r.left+r.width/2,cy:r.top+r.height/2,w:r.width,ro:e.readOnly};}).filter(function(i){return i.w>0;});var lab=ins.find(function(i){return i.v===" . RC_IdsQ(lbl) . ";});if(!lab)return'';var c=ins.filter(function(i){return !i.ro&&Math.abs(i.cy-lab.cy)<12&&i.x>lab.x;});c.sort(function(a,b){return a.x-b.x;});if(!c.length)return'';return Math.round(c[0].cx)+','+Math.round(c[0].cy);})()"
    if !RC_IdsWait(jsField, fx, fy, 6000, 200) {
        ; the menu did not take - try again typing key by key
        if !RC_IdsXY(jsMenu, mx, my)
            return ""
        RC_IdsClick(mx, my)
        RC_IdsWipe()
        RC_IdsType("DC611")
        Sleep, 300
        RC_IdsKey("Enter", 13)
        if !RC_IdsWait(jsField, fx, fy, 8000, 250)
            return ""
    }

    ; type the VIN and check it landed - three goes, the last key by key
    entered := false
    Loop, 3 {
        RC_IdsClick(fx, fy)
        RC_IdsWipe()
        Sleep, 60
        if (A_Index < 3)
            RC_IdsIns(vin)
        else
            RC_IdsType(vin)
        Sleep, 120
        jsRead := "(function(){var ins=Array.from(document.querySelectorAll('input')).map(function(e){var r=e.getBoundingClientRect();return{v:(e.value||'').trim(),cy:r.top+r.height/2,cx:r.left+r.width/2,w:r.width};}).filter(function(i){return i.w>0;});var m=ins.find(function(i){return Math.abs(i.cx-" . fx . ")<3&&Math.abs(i.cy-" . fy . ")<3;});return m?m.v:'';})()"
        if (RC_IdsEval(jsRead) = vin) {
            entered := true
            break
        }
    }
    if (!entered)
        return ""

    jsOK := "(function(){var b=Array.from(document.querySelectorAll('*')).find(function(x){var r=x.getBoundingClientRect();return x.children.length<=1&&r.width>0&&r.height>0&&(x.innerText||'').trim()==='OK';});if(!b)return'';var r=b.getBoundingClientRect();return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"
    if !RC_IdsXY(jsOK, ox, oy)
        return ""
    RC_IdsClick(ox, oy)

    ; Wait for the record, up to about twelve seconds.
    ; IDS shows NO "not found" text for a VIN it does not hold - it just bounces
    ; back to the entry screen with the field CLEARED. A visible editable empty
    ; field where the query used to be, with no record rendered, is what "no
    ; record" looks like.
    jsReady := "(function(){var vin=Array.from(document.querySelectorAll('input')).some(function(e){var r=e.getBoundingClientRect();if(r.width<=0)return false;var v=(e.value||'').trim();return v.length===17&&/^[A-Za-z0-9]+$/.test(v);});var msg=Array.from(document.querySelectorAll('*')).some(function(x){return x.children.length<=1&&/not found|no record|does not exist|invalid/i.test((x.innerText||''));});return vin?'ok':(msg?'none':'wait');})()"
    jsCamp := "(function(){return Array.from(document.querySelectorAll('input')).some(function(e){var r=e.getBoundingClientRect();return r.width>0&&/unit is part of an outstanding campaign/i.test(e.value||'');})?'1':'0';})()"
    jsCleared := "(function(){var ins=Array.from(document.querySelectorAll('input')).filter(function(e){var r=e.getBoundingClientRect();return r.width>0;});var lab=ins.find(function(e){return (e.value||'').trim()===" . RC_IdsQ(lbl) . ";});if(!lab)return'0';var lr=lab.getBoundingClientRect();var c=ins.filter(function(e){var r=e.getBoundingClientRect();return !e.readOnly&&Math.abs((r.top+r.height/2)-(lr.top+lr.height/2))<12&&r.left>lr.left;});return (c.length&&(c[0].value||'').trim()==='')?'1':'0';})()"
    txt := ""
    clearedHits := 0
    campHits := 0
    Loop, 40 {
        Sleep, 300
        st := RC_IdsEval(jsReady)
        if (st = "ok") {
            ; the typed entry field is ALSO seventeen characters, so "ok" can
            ; fire while the entry screen is still up - only a read whose vin
            ; cell actually resolved is accepted
            Sleep, 250
            ; a campaign warning screen, checked only after the paint or it can
            ; slip past: acknowledge it and keep polling for the real record
            if (RC_IdsEval(jsCamp) = "1" && campHits < 5) {
                campHits += 1
                RC_IdsKey("Enter", 13)
                Sleep, 400
                continue
            }
            t := RC_IdsB64(RC_IdsEval(RC_IdsReadJs()))
            ; [^\r\n]+ and not .+ : AHK v1 treats only \r\n as a newline, so
            ; with m) a dot walks straight across these \n-separated lines
            if RegExMatch(t, "m)^vin=[^\r\n]+") {
                txt := t
                break
            }
        } else if (st = "none") {
            txt := "NOTFOUND"
            break
        } else if (RC_IdsEval(jsCleared) = "1") {
            ; three sightings in a row, about a second, so a mid-render blank
            ; cannot fake a not-found
            clearedHits += 1
            if (clearedHits >= 3) {
                txt := "NOTFOUND"
                break
            }
        } else {
            clearedHits := 0
        }
    }
    return txt
}

;==============================================================================
; RCS_ - a minimal WebSocket client over raw Winsock, for the CDP conversation
; above. No compression, no extensions; client frames are masked because the
; protocol says they must be. Localhost only.
;==============================================================================
RCS_Startup() {
    static done := 0
    if (done)
        return
    VarSetCapacity(wsadata, 408, 0)
    DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", &wsadata)
    done := 1
}

; TCP connect plus the upgrade handshake for `path`. Socket handle, or 0.
RCS_Connect(host, port, path) {
    RCS_Startup()
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
        RCS_Close(sock)
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
    if !RCS_SendRaw(sock, req) {
        RCS_Close(sock)
        return 0
    }
    resp := ""
    Loop {
        chunk := RCS_RecvSome(sock, 1)
        if (chunk = "")
            break
        resp .= chunk
        if (InStr(resp, "`r`n`r`n") || StrLen(resp) > 8192)
            break
    }
    if !InStr(resp, " 101 ") {
        RCS_Close(sock)
        return 0
    }
    return sock
}

RCS_SendRaw(sock, str) {
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

RCS_SendBuf(sock, ptr, len) {
    sent := 0
    while (sent < len) {
        n := DllCall("ws2_32\send", "Ptr", sock, "Ptr", ptr + sent, "Int", len - sent, "Int", 0, "Int")
        if (n <= 0)
            return false
        sent += n
    }
    return true
}

; Whether the socket has bytes waiting (or has closed, which reads the same
; and lets recv say so) within ms. A select on the one socket.
RCS_Readable(sock, ms) {
    VarSetCapacity(fds, 8 + 64 * A_PtrSize, 0)          ; fd_set: count, then the sockets
    NumPut(1, fds, 0, "UInt")
    NumPut(sock, fds, (A_PtrSize = 8) ? 8 : 4, "Ptr")
    VarSetCapacity(tv, 8, 0)                             ; timeval: seconds, microseconds
    NumPut(ms // 1000, tv, 0, "Int")
    NumPut(Mod(ms, 1000) * 1000, tv, 4, "Int")
    return DllCall("ws2_32\select", "Int", 0, "Ptr", &fds, "Ptr", 0, "Ptr", 0, "Ptr", &tv, "Int") > 0
}

; Wait for something to read, in short looks with a sleep between, so the
; window keeps taking clicks while the page thinks. recv itself used to do
; this waiting, and it froze the window for as long as it took - up to the
; socket's ten second timeout, which is kept here as the same limit.
RCS_Wait(sock) {
    static LIMIT := 10000
    t0 := A_TickCount
    Loop {
        if RCS_Readable(sock, 50)
            return true
        if (A_TickCount - t0 >= LIMIT)
            return false
        Sleep, 10
    }
}

; up to `max` bytes back as one char per byte, for reading the handshake
RCS_RecvSome(sock, max) {
    if !RCS_Wait(sock)
        return ""
    VarSetCapacity(b, max, 0)
    n := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", &b, "Int", max, "Int", 0, "Int")
    if (n <= 0)
        return ""
    return StrGet(&b, n, "CP0")
}

RCS_RecvN(sock, n, ByRef outbuf) {
    VarSetCapacity(outbuf, n, 0)
    got := 0
    while (got < n) {
        if !RCS_Wait(sock)
            return false
        r := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", &outbuf + got, "Int", n - got, "Int", 0, "Int")
        if (r <= 0)
            return false
        got += r
    }
    return true
}

RCS_SendText(sock, text) {
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
    return RCS_SendBuf(sock, &frame, total)
}

; one whole application message, handling fragments, pings and close
RCS_Recv(sock) {
    latin1 := ""
    frames := 0
    Loop {
        if !RCS_RecvN(sock, 2, h)
            return ""
        b0 := NumGet(h, 0, "UChar")
        b1 := NumGet(h, 1, "UChar")
        fin := (b0 & 0x80) != 0
        opcode := b0 & 0x0F
        masked := (b1 & 0x80) != 0
        len := b1 & 0x7F
        if (len = 126) {
            if !RCS_RecvN(sock, 2, e)
                return ""
            len := (NumGet(e, 0, "UChar") << 8) | NumGet(e, 1, "UChar")
        } else if (len = 127) {
            if !RCS_RecvN(sock, 8, e)
                return ""
            len := 0
            Loop 8
                len := (len * 256) + NumGet(e, A_Index - 1, "UChar")
        }
        if (masked) {
            if !RCS_RecvN(sock, 4, mk)
                return ""
        }
        if (len > 0) {
            if !RCS_RecvN(sock, len, pb)
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
                RCS_Pong(sock, &pb, len)
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

RCS_Pong(sock, ptr, len) {
    total := 2 + 4 + len
    VarSetCapacity(f, total, 0)
    NumPut(0x8A, f, 0, "UChar")
    NumPut(0x80 | (len < 126 ? len : 0), f, 1, "UChar")
    NumPut(0,f,2,"UChar"), NumPut(0,f,3,"UChar"), NumPut(0,f,4,"UChar"), NumPut(0,f,5,"UChar")
    Loop %len%
        NumPut(NumGet(ptr, A_Index - 1, "UChar") ^ 0, f, 6 + A_Index - 1, "UChar")
    RCS_SendBuf(sock, &f, total)
}

RCS_Close(sock) {
    DllCall("ws2_32\closesocket", "Ptr", sock)
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
; A session is also a cookie jar, so one session per site keeps the sites'
; sessions apart. The session is a WinHttpRequest object kept for the life of
; the site: the object owns one WinHTTP session handle underneath, and that is
; where WinHTTP keeps the cookies from one request to the next - the same
; core, the same jar, as the raw handle this used to hold.
;
; Why an object and not the raw DllCalls any more: the raw WinHttpSendRequest
; and WinHttpReceiveResponse pair BLOCKS. While a website thinks, the calling
; script pumps no messages - a button pressed then sits in the queue until the
; site answers, and every timer with it. The object is opened in async mode
; and this file polls it: WaitForResponse(0) asks "done yet?" and Sleep gives
; the script's window its messages back between askings. A click during a
; request now runs during the request, which is the whole point.
;
; A request is the session's only one at a time. A second request on a
; session with one still in the air aborts the first: the caller that is
; still polling for it gets "" and status 0, as it would for a dead server.
; That is the newer search winning, which is what a newer search should do.
;==============================================================================

; Fresh session (= fresh cookie jar). Timeouts are ms: resolve, connect, send,
; receive. Returns 0 on failure.
AH_Open(ua, tResolve := 10000, tConnect := 10000, tSend := 20000, tRecv := 30000) {
    try {
        whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        whr.SetTimeouts(tResolve, tConnect, tSend, tRecv)
    } catch e {
        return 0
    }
    ; seq numbers the requests so a poll can tell its own from a newer one;
    ; wait is the longest a poll is allowed to go on before giving up on its
    ; own, over and above the object's own timeouts.
    return { whr: whr, ua: ua, seq: 0, wait: tSend + tRecv, dead: false }
}

; A connection is a host and a port on a session - the URL is built from it
; at request time. Returns 0 without a session.
AH_Connect(hSess, host, port := 443) {
    if !IsObject(hSess)
        return 0
    return { sess: hSess, host: host, port: port }
}

; Closing a session aborts whatever it still has in the air and marks it dead,
; so a poll still waiting on it comes back empty rather than with a page meant
; for the session that replaced it. Closing a connection is nothing - it owns
; no handle of its own.
AH_Close(h) {
    if !IsObject(h)
        return
    if h.HasKey("whr") {
        h.dead := true
        h.seq += 1
        try h.whr.Abort()
    }
}

; Fire one request on an existing connection and return the body as UTF-8
; text ("" on any transport failure). `hdrs` is the caller's complete header
; block, CRLF-separated, no trailing CRLF. `status` comes back with the HTTP
; status code (0 = never got a reply), which is how an expired session
; (401/403) is told apart from a dead server (500) or a dead connection (0).
;
; The request goes out async and is polled: 10 ms asleep between askings, so
; the window behind this stays a window. The poll gives up on its own after
; the session's send plus receive timeouts, and at once when a newer request
; has taken the session over.
AH_Request(hConn, method, path, hdrs, body, ByRef status) {
    static MAXLEN := 4194304       ; 4 MB - far more than these pages need

    status := 0
    if (!IsObject(hConn) || !IsObject(hConn.sess) || hConn.sess.dead)
        return ""
    sess := hConn.sess
    whr  := sess.whr
    url  := "https://" . hConn.host . ((hConn.port = 443) ? "" : ":" . hConn.port) . path

    ; Take the session over. Anything still in the air is the last caller's,
    ; and its poll sees the number move and stops.
    sess.seq += 1
    mine := sess.seq
    try whr.Abort()

    try {
        whr.Open(method, url, true)
        whr.Option(0) := sess.ua                 ; WinHttpRequestOption_UserAgentString
        Loop, Parse, hdrs, `n, `r
        {
            p := InStr(A_LoopField, ":")
            if (p < 2)
                continue
            whr.SetRequestHeader(Trim(SubStr(A_LoopField, 1, p - 1)), Trim(SubStr(A_LoopField, p + 1)))
        }

        if (body != "") {
            ; Sent as bytes, UTF-8, so what goes down the wire is exactly what
            ; the raw handle used to send - not the object's own idea of the
            ; encoding.
            len := StrPut(body, "UTF-8") - 1
            VarSetCapacity(raw, len + 1, 0)
            StrPut(body, &raw, "UTF-8")
            bytes := ComObjArray(0x11, len)      ; VT_UI1
            pData := NumGet(ComObjValue(bytes) + 8 + A_PtrSize, "Ptr")
            DllCall("RtlMoveMemory", "Ptr", pData, "Ptr", &raw, "Ptr", len)
            whr.Send(bytes)
        } else {
            whr.Send()
        }

        t0 := A_TickCount
        Loop {
            if whr.WaitForResponse(0)
                break
            if (sess.seq != mine || sess.dead)
                return ""
            if (A_TickCount - t0 > sess.wait) {
                try whr.Abort()
                return ""
            }
            Sleep, 10
        }
        if (sess.seq != mine || sess.dead)
            return ""

        status := whr.Status
        arr := whr.ResponseBody
        n := arr.MaxIndex() + 1
        if (n <= 0)
            return ""
        if (n > MAXLEN - 1)
            n := MAXLEN - 1
        pData := NumGet(ComObjValue(arr) + 8 + A_PtrSize, "Ptr")
        return StrGet(pData, n, "UTF-8")
    } catch e {
        ; A timeout, a refused connection, a certificate the machine will not
        ; take, or the abort above landing in the middle of the wait - all of
        ; them are "no reply", status 0, the same as the raw handle answered.
        try whr.Abort()
        return ""
    }
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
        for i, w in CP_Windows() {
            h := w.h
            if CP_SelectOf(h, brand, loose) {
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
    return false
}


; Every visible browser window, best browser first - see CP_EXES for what
; "best" means and why it matters.
CP_Windows() {
    global CP_EXES
    out := []
    for i, exe in CP_EXES {
        WinGet, list, List, % "ahk_exe " . exe
        Loop, %list%
        {
            h := list%A_Index%
            if (h = "" || !DllCall("IsWindowVisible", "ptr", h))
                continue
            out.Push({ h: h, exe: exe })
        }
    }
    return out
}


; The tab titles of one window, from wherever this process is up to.
;
; Chrome hands its tab strip to a UI Automation client exactly ONCE per client
; process - and Edge is the same browser underneath, so it does too. Every
; window read after the first comes back with an empty strip, whichever window
; it is, and a fresh IUIAutomation does not lift it: the shutter is on the
; process. So the first window asked for is read here and every window after it
; is read by a process of its own, which starts with its read unspent.
;
; This is what had the lights going out. Edge used to be looked in first, so an
; Edge window open for something else - a New tab page is enough - spent the
; read, and Chrome, holding every catalog, then answered with nothing at all
; and every tick went off.
CP_TabsOf(hwnd) {
    global CP_READ
    if (!CP_READ) {
        CP_READ := true
        return CP_TabTitles(hwnd)
    }
    names := []
    f := A_Temp . "\AudosTabs" . hwnd . ".txt"
    CP_Del(f)
    RunWait, % CP_Worker("tabs " . hwnd . " """ . f . """"), , Hide UseErrorLevel
    txt := ""
    if FileExist(f)
        try FileRead, txt, %f%
    CP_Del(f)
    Loop, Parse, txt, `n, `r
    {
        if (A_LoopField != "")
            names.Push(A_LoopField)
    }
    return names
}


; CP_SelectIn under the same one-read-per-process rule as CP_TabsOf: picking a
; tab means walking the strip, so a second window has to be handled by a second
; process. The child does the picking; bringing the window forward is left to
; the caller, which is where it was already done.
CP_SelectOf(hwnd, brand, loose) {
    global CP_READ
    if (!CP_READ) {
        CP_READ := true
        return CP_SelectIn(hwnd, brand, loose)
    }
    RunWait, % CP_Worker("selectin " . hwnd . " " . brand . " " . (loose ? 1 : 0))
             , , Hide UseErrorLevel
    return (ErrorLevel = 0)
}


; The command line that runs this same script again with a mode word. In the
; one-file build the script IS RegoCheck, which is why A_ScriptFullPath is used
; rather than a name - the worker is whatever this file happens to be.
CP_Worker(args) {
    return """" . A_AhkPath . """ """ . A_ScriptFullPath . """ " . args
}


; The "tabs" worker: one window's tab titles, one per line, and out.
CP_TabsOut(hwnd, file) {
    CP_Del(file)
    out := ""
    for i, nm in CP_TabTitles(hwnd)
        out .= nm . "`n"
    FileAppend, %out%, %file%, UTF-8
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
    ; 0. Isuzu's EQ-HIT drops back to its login page whenever the session
    ;    lapses, and that page has no VIN box on it at all - the wait below
    ;    would spend its ten seconds looking for one that is never coming and
    ;    the whole sequence would be tried three times over. The browser is
    ;    already holding the username and password, so the page wants nothing
    ;    but its own Login button pressed.
    ;
    ;    Nothing is typed here and no credential is read: the button is
    ;    pressed, and whatever the browser has saved for the site is what goes
    ;    in. A page with a live session carries no Login button - it says
    ;    Logout, which the exact-name match will not touch - so finding
    ;    nothing is the ordinary case rather than a failure.
    ;    The button is asked for ahead of anything else wearing the same word:
    ;    the first version of this went through whatever came first and pressed
    ;    a wrapper that swallowed the click, so the page sat on the login screen
    ;    and the whole attempt ran out looking for a VIN box.
    ;
    ;    Pressed with the real mouse, and pressed again until the button is
    ;    gone. Invoke on its own drew the frame round the button, reported
    ;    success and left the page exactly where it was - the form listens for a
    ;    genuine click and not for the accessibility event - and since Invoke
    ;    cannot say whether the page acted, the button still being there is what
    ;    is checked instead. Three goes: the first click also brings Chrome
    ;    forward if something had stolen focus, and that one is sometimes spent.
    static BUTTON := 50000, HYPERLINK := 50005, TEXT := 50020
    static LOGIN := [BUTTON, HYPERLINK, TEXT]
    wait := 40
    if (brand = "isuzu" && CP_Has(hwnd, "Login", LOGIN)) {
        gone := false
        Loop, 3
        {
            if (!CP_Invoke(hwnd, "Login", LOGIN, true)) {
                gone := true            ; someone else got there first
                break
            }
            ; The page tears the login form down as it goes; give it long
            ; enough to have done so before reading the button back.
            Sleep, 1500
            if (!CP_Has(hwnd, "Login", LOGIN)) {
                gone := true
                break
            }
            CP_Trace("Login button still there - pressing again")
        }
        CP_Trace(gone ? "EQ-HIT login page - pressed Login" : "Login would not take")
        ; Coming up off a cold session it can be a minute before the catalog
        ; has drawn anything, so the wait below is stretched rather than the
        ; usual ten seconds spent on a page that was never going to be ready.
        wait := 90
    }

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
    ;    Looked for every 100 ms rather than every 250. The ceilings below are
    ;    the same ten and twenty-two seconds they were - the counts were scaled
    ;    with the step - but a box drawn 40 ms after the nav click used to sit
    ;    there unnoticed for the rest of its 250, and that happened on every
    ;    catalog, every search.
    box := 0
    wait := Round(wait * 2.5)          ; Round, not the bare product: 40 * 2.5
                                       ; is the float 100.000000 in AHK v1.
    Loop, %wait%
    {
        box := CP_VinBox(hwnd)
        if (box)
            break
        Sleep, 100
    }
    if (!box) {
        CP_Trace("VIN box NEVER APPEARED")
        return false
    }
    CP_Trace("VIN box found")
    ; The frame stays round the box for the whole of the next two steps, so
    ; there is something to look at while the VIN is going in rather than a
    ; blink half a second before it does.
    CP_HoldOn(box)

    ; 3. Focus, then fill. Focus first every time: the value goes in through
    ;    the box that holds the keyboard, and the Enter below has to land
    ;    there too rather than on whatever the page had selected.
    ok := CP_Fill(box, vin)
    CP_Rel(box)
    if (!ok) {
        CP_HoldOff()
        return false
    }

    ; 4. BYD's form does not submit on Enter - it has its own Search button.
    ;    Everyone else takes Enter in the box, and BYD gets it too if the
    ;    button cannot be found, since it is the only move left.
    if (brand = "byd" && CP_Invoke(hwnd, "Search"))
        CP_Trace("clicked Search")
    else {
        SendInput, {Enter}
        CP_Trace("entered")
    }
    ; The VIN is in and submitted - what the frame was there to show is done.
    CP_HoldOff()

    ; 5. BYD does not go straight into the catalog. It answers with a summary
    ;    panel - series, model, colour, build date - and an "Enter EPC" button,
    ;    and the parts are behind that button. Nobody stops to read the summary,
    ;    so the button gets clicked as soon as it turns up.
    ;
    ;    Waited for rather than clicked straight off: the panel is only drawn
    ;    once the lookup comes back, a second or two after the click above. A
    ;    VIN the catalog does not know brings up no panel at all, so the wait
    ;    running out is an answer rather than a fault - whatever the page did
    ;    put up is left alone for someone to read.
    if (brand = "byd") {
        if CP_InvokeWait(hwnd, "Enter EPC", 24, 250)
            CP_Trace("clicked Enter EPC")
        else
            CP_Trace("no Enter EPC button came up")
    }

    ; 6. Prove the catalog actually took it. The tab renames itself to the
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
        CP_WaitVal(box, "", 150)
        if (CP_Val(box) != "") {
            SendInput, ^a
            Sleep, 40
            SendInput, {Delete}
            CP_WaitVal(box, "", 150)
        }
        CP_Trace(CP_Val(box) = "" ? "cleared the box" : "box would not empty")
    }

    if (CP_SetVal(box, vin)) {
        CP_WaitVal(box, vin, 200)
        if (CP_Val(box) = vin) {
            CP_Trace("set through the ValuePattern")
            return true
        }
        CP_Trace("ValuePattern said yes but the box did not keep it")
    } else
        CP_Trace("box has no settable ValuePattern")

    SendInput, ^a
    Sleep, 40
    SendInput, % "{Raw}" . vin
    ; The old flat 400 was the slowest page's worst case charged to every page.
    ; Same ceiling, read every 50 ms, and a box that has the VIN in it after
    ; 60 ms is done at 60 ms.
    CP_WaitVal(box, vin, 400)
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
    ; 80 at 150 ms is the same twelve seconds 30 at 400 was. This is the last
    ; step of the search and the one the person is watching for: the tab renames
    ; itself the moment the car is up, and the old grain could sit on a finished
    ; lookup for another third of a second before noticing.
    Loop, 80
    {
        WinGetTitle, t, ahk_id %hwnd%
        if InStr(t, vin)
            return true
        Sleep, 150
    }
    return false
}


; Wait until the page has something on it. A tab just switched to may not have
; rendered, and an empty tree looks the same as a page missing what we want.
CP_PageReady(hwnd) {
    ; 63 at 80 ms, five seconds, as before. A tab that was already open and
    ; drawn - which is every tab, once the catalog has been used once - answers
    ; on the first look, so this only ever cost the grain.
    Loop, 63
    {
        if (CP_ActiveUrl(hwnd) != "")
            return true
        Sleep, 80
    }
    return false
}


; CP_Invoke for something the page has not drawn yet: the same click, tried
; again every so often until it is there or the tries run out. Nothing waits on
; a timer here - a slow lookup is found late rather than missed, and a lookup
; that never produces the thing costs the full wait and no more.
CP_InvokeWait(hwnd, name, tries, wait) {
    Loop, %tries%
    {
        if CP_Invoke(hwnd, name)
            return true
        Sleep, %wait%
    }
    return false
}


; Click a named thing on the page. Through UI Automation's Invoke where the
; element has one - no mouse, no keystrokes, works on a window that is not
; even in front. Plenty of clickable things expose no InvokePattern at all -
; BYD's EPC nav is a plain Text - and those get the real mouse, pointer put
; back after. Flashes a frame round it first so it is plain what was clicked.
;
; The control types are tried in the order given, first match wins, and the
; default order suits a nav link. Pass an order when the page has the same word
; on more than one kind of thing: EQ-HIT's login page answers "Login" with both
; a real button and some scenery, and only the button submits the form.
;
; Pass mouse := true for a page that answers Invoke by doing nothing. Invoke
; raises the accessibility event and reports success whether or not the page
; acted on it, so a form that only listens for a real mousedown/mouseup pair -
; EQ-HIT's login form is one - sits there while this reports a click. Nothing
; can be read back to tell the two apart, so where it matters the mouse goes
; first and the patterns are the fallback rather than the other way about.
CP_Invoke(hwnd, name, order := "", mouse := false) {
    static INVOKE := 10000
    uia := CP_Uia()
    if (!uia)
        return false
    ; The control types are walked here, not inside the finder, so that a page
    ; carrying the word on a Button and again on some scenery gets the Button
    ; pressed and is not left half-clicked on the scenery.
    for i, ctype in CP_Order(order) {
        found := CP_FindNamed(uia, hwnd, name, ctype)
        if (!found)
            continue
        CP_Flash(found)
        ok := false
        ; The real pointer, for a page that ignores Invoke.
        if (mouse) {
            ok := CP_ClickEl(found, hwnd)
            if (ok)
                CP_Trace("invoke: mouse (asked for)")
        }
        pat := 0
        if (!ok && DllCall(CP_Vt(found, 16), "ptr", found, "int", INVOKE, "ptr*", pat) = 0 && pat) {
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
            ok := CP_ClickEl(found, hwnd)
            if (ok)
                CP_Trace("invoke: mouse")
        }
        CP_Rel(found)
        if (ok)
            return true
    }
    return false
}


; Is a named, visible thing on the page? The question CP_Invoke cannot answer
; about its own work: Invoke reports whether the click was delivered, never
; whether the page did anything with it, and a button that is still sitting
; there is the plain proof that it did not.
CP_Has(hwnd, name, order := "") {
    uia := CP_Uia()
    if (!uia)
        return false
    for i, ctype in CP_Order(order) {
        found := CP_FindNamed(uia, hwnd, name, ctype)
        if (found) {
            CP_Rel(found)
            return true
        }
    }
    return false
}


; The control types to look through, in order. The default suits a nav link.
CP_Order(order) {
    static HYPERLINK := 50005, BUTTON := 50000, TEXT := 50020
    return IsObject(order) ? order : [HYPERLINK, BUTTON, TEXT]
}


; First visible element of one control type whose name matches exactly.
; Caller releases what comes back; 0 when there is no such thing.
CP_FindNamed(uia, hwnd, name, ctype) {
    ; NAMEPROP, not NAME - AHK variable names ignore case, and NAME would BE
    ; the name parameter.
    static CONTROLTYPE := 30003, SUBTREE := 7, NAMEPROP := 30005
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
            w := 0, hh := 0
            CP_Rect(e, w, hh)
            ; Hidden leftovers stay in a web app's tree, and one of those
            ; can be invoked all day without anything happening.
            if (!found && w > 0 && hh > 0 && CP_Str(e, NAMEPROP) = name) {
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


; Click the middle of an element - the last-resort fallback for clickable
; things with no InvokePattern anywhere near them.
;
; A posted click is tried first, the same one the VIN box gets: it moves no
; pointer, and this runs while somebody is working. Nothing here can be read
; back to say the page took it, so the page is watched for a moment instead -
; see CP_Stirred - and the real pointer goes in if it stayed still.
;
; The one thing that costs: a page that DID take the posted click and left the
; clicked thing sitting there unchanged looks the same from out here as a page
; that ignored it, and gets clicked a second time. These are nav links and
; login buttons - the things that do leave, which is what CP_Stirred is reading
; - so it is the unusual shape rather than the usual one, and a nav link
; followed twice lands in the same place as a nav link followed once.
CP_ClickEl(el, hwnd := 0) {
    VarSetCapacity(rc, 16, 0)
    if (DllCall(CP_Vt(el, 43), "ptr", el, "ptr", &rc) != 0)
        return false
    l := NumGet(rc, 0, "int"), t := NumGet(rc, 4, "int")
    r := NumGet(rc, 8, "int"), b := NumGet(rc, 12, "int")
    if (r - l < 4 || b - t < 4)
        return false
    cx := (l + r) // 2
    cy := (t + b) // 2

    ; Read before the click, so there is something to compare the address to.
    url0 := hwnd ? CP_ActiveUrl(hwnd) : ""
    if (CP_QuietClick(cx, cy) && CP_Stirred(el, hwnd, url0)) {
        CP_Trace("click: posted, pointer never moved")
        return true
    }

    prev := A_CoordModeMouse
    CoordMode, Mouse, Screen
    MouseGetPos, ox, oy
    Click, %cx%, %cy%
    ; Only so the button goes down and up somewhere the page can see both. What
    ; the page then DOES about it is waited for by whoever asked for the click,
    ; and they all wait by looking rather than by the clock.
    Sleep, 110
    MouseMove, ox, oy, 0
    CoordMode, Mouse, %prev%
    CP_Trace("click: real pointer")
    return true
}


; Did the page do anything about the click just posted at it?
;
; Two ways of asking, because one alone answers too narrowly. The thing that
; was clicked is looked at first - a nav link that has been followed is gone
; from the tree, or drawn at no size, and either reads as a page that moved.
; That is the cheap question, so it is the one asked every time round.
;
; The address is the second, for a click that swapped the page under the same
; link - and it costs a walk of the whole document tree to answer, so it is
; asked twice in the half second rather than eight times.
;
; Half a second because this is a wager, not a wait: the whole point of the
; posted click is that it costs less than the pointer jumping across the
; screen, and a page still sitting there after half a second has almost
; certainly ignored it. A page that was merely slow gets clicked again by the
; fallback, which is where it would have been anyway.
CP_Stirred(el, hwnd, url0) {
    Loop, 8
    {
        Sleep, 60
        w := 0, h := 0
        CP_Rect(el, w, h)
        if (w <= 0 || h <= 0)
            return true
        if (hwnd && Mod(A_Index, 4) = 0) {
            u := CP_ActiveUrl(hwnd)
            if (u != "" && u != url0)
                return true
        }
    }
    return false
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
; Half a second was long enough to read a word beside it, but nobody is reading
; anything - it is there so the thing being clicked is visibly the thing that
; was meant. A fifth of a second still registers, and it is spent on every
; invoke in the sequence.
CP_Flash(el, ms := 200) {
    if (!CP_FrameOn(el, "CPHL"))
        return
    Sleep, %ms%
    CP_FrameOff("CPHL")
}


; The same frame, but left standing until it is taken down by hand. The VIN box
; wears this one: a frame that blinked out before the VIN went in would be
; pointing at the box during the wait and gone by the time anything happened in
; it. Its own window - the momentary flashes above keep coming while it stands.
CP_HoldOn(el) {
    return CP_FrameOn(el, "CPHOLD")
}

CP_HoldOff() {
    CP_FrameOff("CPHOLD")
}


; The frame itself, in the named window. Returns false when the element has no
; rectangle worth drawing round.
CP_FrameOn(el, g) {
    static TH := 3, PAD := 2
    VarSetCapacity(rc, 16, 0)
    if (DllCall(CP_Vt(el, 43), "ptr", el, "ptr", &rc) != 0)
        return false
    l := NumGet(rc, 0, "int") - PAD, t := NumGet(rc, 4, "int") - PAD
    r := NumGet(rc, 8, "int") + PAD, b := NumGet(rc, 12, "int") + PAD
    w := r - l, h := b - t
    if (w < 6 || h < 6)
        return false

    ; -DPIScale: the rectangle came from UI Automation in real screen pixels,
    ; and AHK's scaling would blow the frame up past the element at 125%.
    Gui, %g%:New, +AlwaysOnTop -Caption +ToolWindow +E0x8000020 -DPIScale +HwndhHL
    Gui, %g%:Color, FF3B30
    Gui, %g%:Show, NoActivate x%l% y%t% w%w% h%h%
    ; The middle is cut out of the window, leaving just the border - so the
    ; page underneath stays readable.
    outer := DllCall("CreateRectRgn", "int", 0, "int", 0, "int", w, "int", h, "ptr")
    inner := DllCall("CreateRectRgn", "int", TH, "int", TH, "int", w - TH, "int", h - TH, "ptr")
    DllCall("CombineRgn", "ptr", outer, "ptr", outer, "ptr", inner, "int", 4)   ; RGN_DIFF
    DllCall("DeleteObject", "ptr", inner)
    DllCall("SetWindowRgn", "ptr", hHL, "ptr", outer, "int", true)
    return true
}

CP_FrameOff(g) {
    Gui, %g%:Destroy
}


; Put the keyboard in a box and prove it landed.
;
; Asking UI Automation for focus is tried first because it moves no mouse, but
; on a framework-bound web input it often reports success while the keyboard
; stays where it was. A real click in the middle of the box is what a person
; does and is what these pages actually listen for, so that is the fallback.
CP_FocusBox(box) {
    ; Asked once each, not waited on - see CP_HasFocus. Either the box already
    ; holds the keyboard or SetFocus took, and both are true the instant they
    ; are true; there is nothing in flight here to give time to.
    ; Traced because the four catalogs take four different ways through here and
    ; the line in the trace is the only way to tell afterwards which one a page
    ; used - and so whether a page that moved the pointer needed to.
    if (CP_HasFocus(box, 1)) {
        CP_Trace("focus: box already had it")
        return true
    }
    DllCall(CP_Vt(box, 3), "ptr", box)                  ; SetFocus
    if (CP_HasFocus(box, 1)) {
        CP_Trace("focus: SetFocus took")
        return true
    }

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

    ; A posted click first - it goes straight to the window at that point and
    ; the pointer never moves, so nothing is taken away from whoever is working
    ; while this runs. Chrome's renderer is the usual thing that ignores a
    ; posted mouse message, and an ignored one is silent, so the box is asked
    ; whether it actually took the keyboard rather than the posting being
    ; believed. Six tries, not sixteen: this is the attempt that might have
    ; done nothing at all, and every millisecond spent finding that out is
    ; spent again on the real click below.
    if (CP_QuietClick(cx, cy) && CP_HasFocus(box, 6)) {
        CP_Trace("focus: posted click, pointer never moved")
        return true
    }

    prev := A_CoordModeMouse
    CoordMode, Mouse, Screen
    MouseGetPos, ox, oy
    Click, %cx%, %cy%
    ; Long enough for the click to have been dispatched. The waiting for the
    ; page to act on it is done below, where it can stop early.
    Sleep, 110
    ; Put the pointer back where it was - this runs while somebody is working.
    MouseMove, ox, oy, 0
    CoordMode, Mouse, %prev%
    CP_Trace("focus: real pointer")
    ; This one IS waiting on something - the page taking the click - so it gets
    ; the tries. Sixteen at 60 ms, about the second the old ten at 100 ms had.
    return CP_HasFocus(box, 16)
}


; Click a screen point without moving the pointer.
;
; The message is posted to whatever window is under the point - for a browser
; that is the render widget's own child window, not the frame - with the
; coordinates put back into that window's client space, which is what
; ControlClick reads them as. NA keeps it from activating or attaching to the
; target's thread: this runs behind whatever the person is actually doing and
; must not pull the focus over to the browser to do its work.
;
; Answers only whether the message went out. Whether anything came of it is
; not knowable from here and is the caller's job to check.
CP_QuietClick(cx, cy) {
    hw := DllCall("WindowFromPoint", "Int64", (cy << 32) | (cx & 0xFFFFFFFF), "Ptr")
    if (!hw)
        return false
    VarSetCapacity(pt, 8, 0)
    NumPut(cx, pt, 0, "Int")
    NumPut(cy, pt, 4, "Int")
    if (!DllCall("ScreenToClient", "Ptr", hw, "Ptr", &pt))
        return false
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")
    ControlClick, , ahk_id %hw%, , Left, 1, % "NA x" . x . " y" . y
    return !ErrorLevel
}


; Has the box got the keyboard? Waits by default, because after a click the
; answer is worth waiting for - but the two callers above ASK it, they are not
; waiting on it, and a question asked with tries left over is a second spent
; standing still. Both of them pass 1.
;
; That was two seconds of the search, every search: the box has not got the
; keyboard when we walk up to it, so the opening check polled its full ten
; times for an answer it was never going to get, SetFocus was tried, and the
; check polled ten more. Then the click - the thing that actually works - went
; in two seconds late.
CP_HasFocus(box, tries := 10) {
    Loop, %tries%
    {
        if CP_Bool(box, 30008)                          ; HasKeyboardFocus
            return true
        if (A_Index < tries)
            Sleep, 60
    }
    return false
}


; Wait up to ms for a box to read back what it was meant to be holding, and
; stop the moment it does.
;
; Every one of these used to be a flat Sleep sized for the slowest page that
; had ever needed one, which meant every fast page paid the slow page's bill.
; The ceiling is unchanged - a page that really does take the whole 400 ms
; still gets it - so this is only ever earlier, never sooner than the page.
CP_WaitVal(el, want, ms) {
    static STEP := 50
    n := Round(ms / STEP)
    if (n < 1)
        n := 1
    Loop, %n%
    {
        if (CP_Val(el) = want)
            return true
        Sleep, %STEP%
    }
    return (CP_Val(el) = want)
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
;
; Two things harden that. The host is checked first for the brands that have
; one listed, and a Kia or Hyundai tab that is not on Microcat is out however
; well its title read. And "strict" turns the whole thing round: the URL has
; to NAME the brand for the tab to count, silence is not consent. The loose
; pass uses strict, because there the title has already failed to say which
; brand it is and the URL is the only thing left that knows.
CP_UrlAgrees(hwnd, brand, strict := false) {
    global CP_HOST
    ; The page needs a moment after the switch before its address is readable.
    ; 24 at 60 ms - the same 1.44 s, checked twice as often. This runs once per
    ; candidate tab while picking which one to use, so its grain is paid before
    ; the search has even started.
    Loop, 24
    {
        url := CP_ActiveUrl(hwnd)
        if (url != "") {
            if (CP_HOST.HasKey(brand) && !InStr(url, CP_HOST[brand]))
                return false
            said := CP_BrandOfUrl(url)
            if (strict)
                return (said = brand)
            return (said = "" || said = brand)
        }
        Sleep, 60
    }
    ; No URL came back at all. Left to stand as before, except under strict,
    ; where an unreadable URL has confirmed nothing.
    return !strict
}


CP_Main() {
    global CP_OUT
    hits := {}          ; brand -> { vin, hwnd, exe, title }
    seen := []

    ; Windows in preference order, so first sighting wins means Chrome wins.
    for i, w in CP_Windows() {
        for j, title in CP_TabsOf(w.h) {
            seen.Push(title)
            brand := CP_BrandOf(title)
            ; First sighting of a brand wins. A second tab of the same
            ; catalog is the same catalog.
            if (brand != "" && !hits.HasKey(brand))
                hits[brand] := { vin: CP_VinIn(title), hwnd: w.h, exe: w.exe, title: title }
        }
        ; All four accounted for. The windows further down can only repeat what
        ; is already here, and each of them costs a process - the usual case,
        ; every catalog in one Chrome window, stops right here and the sweep is
        ; the single process it always was.
        if (CP_AllFound(hits))
            break
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


; Has every brand been found? The sweep's reason to stop looking.
CP_AllFound(hits) {
    global CP_BRANDS
    for i, brand in CP_BRANDS {
        if (!hits.HasKey(brand))
            return false
    }
    return true
}


; Does a stripped-down title carry any one of these words? Used for the
; must-say gate, against the same flattened title the veto lists read.
CP_SaysWord(flat, words) {
    for i, w in words {
        if InStr(flat, w)
            return true
    }
    return false
}


; Which brand a tab title belongs to, or "" for none of them.
CP_BrandOf(title) {
    global CP_BRANDS, CP_WORDS, CP_WMI, CP_VETO, CP_ANTI, CP_MUSTCAT, CP_MUSTSAY
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
        ; A brand's own veto first: the title may name the brand and still not
        ; be its catalog, and saying "not this brand" is more use than saying
        ; "this brand, second choice" - there is no second choice here.
        skip := false
        ; Most brands have no veto list. Indexing a key that is not there hands
        ; back an empty string, and a for-loop over one of those is a run-time
        ; error rather than nought passes.
        for j, bad in (CP_ANTI.HasKey(brand) ? CP_ANTI[brand] : []) {
            if InStr(flat, bad) {
                skip := true
                break
            }
        }
        if (skip)
            continue
        ; Kia and Hyundai carry the shop's other sites under the same word, so
        ; for those two the title has to read like a catalog before the word
        ; is worth anything - see CP_MUSTCAT. Nothing is lost on the titles
        ; the catalog actually wears: "Microcat EPC - KIA" says Microcat, and
        ; a tab with a car loaded is caught by the VIN below instead.
        if (CP_MUSTCAT.HasKey(brand) && !CP_MaybeCatalog(title))
            continue
        ; And for the brands with a word of their own to say - BYD says TIS -
        ; the title has to say it. Same shape as the gate above: fail it and
        ; the title proves nothing, leaving the VIN below as the tab's only
        ; way in.
        if (CP_MUSTSAY.HasKey(brand) && !CP_SaysWord(flat, CP_MUSTSAY[brand]))
            continue
        for j, word in CP_WORDS[brand] {
            if RegExMatch(title, "i)" . word)
                return brand
        }
    }
    ; Otherwise the VIN, which is how a Microcat tab reads once a car is on
    ; screen and the brand has dropped out of the title.
    return CP_BrandOfVin(CP_VinIn(title))
}


; Does this title carry ONE brand's own word? The global veto and the brand's
; own ANTI list still apply, but the catalog-shape gate does not - so a
; Hyundai dealer portal answers yes here where CP_BrandOf answers "".
;
; Only the loose pass uses it, and only as a way of putting a tab forward to
; be judged: what a tab found this way is accepted on is its URL, checked
; strictly, so a title that merely says the brand cannot get a VIN typed into
; it. This is the fallback for the day Microcat renames its pages and the
; shape CP_MaybeCatalog looks for stops being there.
CP_SaysBrand(title, brand) {
    global CP_WORDS, CP_VETO, CP_ANTI
    if (Trim(title) = "")
        return false
    flat := CP_Norm(title)
    for i, bad in CP_VETO {
        if InStr(flat, bad)
            return false
    }
    for j, bad in (CP_ANTI.HasKey(brand) ? CP_ANTI[brand] : []) {
        if InStr(flat, bad)
            return false
    }
    for j, word in CP_WORDS[brand] {
        if RegExMatch(title, "i)" . word)
            return true
    }
    return false
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

    ; Where the page starts. Everything the BROWSER draws - the tab strip, the
    ; address bar - is above this line and everything a PAGE draws is below it,
    ; which is the one test that does not care whose browser it is.
    pageTop := CP_PageTop(uia, el)

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
            ; A tab strip sitting inside the page is the page's own. Edge's new
            ; tab page carries one - a news carousel, seventeen headlines wide,
            ; class "tablist", every headline a TabItem of class "tab". A bare
            ; lowercase word gets past the class test below, so those headlines
            ; read as browser tabs, and one naming a make - "Mitsubishi Pajero,
            ; Triton hybrids coming" was in there - would light that make's box
            ; off a news story.
            if (!CP_AbovePage(strip, pageTop)) {
                CP_Rel(strip)
                continue
            }
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
    pageTop := CP_PageTop(uia, el)
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
            ; Same guard as the sweep: a strip inside the page belongs to the
            ; page, and picking one of its tabs would be a click in the middle
            ; of whatever is on screen.
            if (!CP_AbovePage(strip, pageTop)) {
                CP_Rel(strip)
                continue
            }
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
                    ; Tight pass: the title has settled on this brand, which
                    ; for Kia and Hyundai means it looked like a catalog too.
                    ; Loose pass: anything the title could not settle - a
                    ; catalog-shaped title of unknown brand, or a tab that
                    ; merely says the brand - put forward for the URL to judge.
                    want := loose ? (CP_SaysBrand(name, brand)
                                     || (CP_BrandOf(name) = "" && CP_MaybeCatalog(name)))
                                  : (CP_BrandOf(name) = brand)
                    ; The tab already showing is a candidate like any other.
                    ; Skipping it - which is what holding it aside for the
                    ; restore used to do - meant asking for the catalog you
                    ; were already looking at answered "no such tab".
                    if (want && (isSel || CP_Pick(tab))) {
                        ; Strict on the loose pass: the title did not settle
                        ; the brand, so the URL has to, and saying nothing is
                        ; not the same as saying yes.
                        if CP_UrlAgrees(hwnd, brand, loose)
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
; The top edge of the page area, or -1 when the window is not showing a page.
;
; A browser window is in two halves: its own furniture along the top - tab
; strip, address bar - and the page underneath. The line between them is the
; top of the Document, and it is the only way of telling the browser's tabs
; from a page's that does not depend on knowing which browser this is or what
; the site calls its classes.
;
; The smallest top wins. A window can hold more than one Document at once -
; a PDF viewer, an embedded frame - and the page area starts at the highest
; of them.
CP_PageTop(uia, root) {
    static DOCUMENT := 50030, CONTROLTYPE := 30003, SUBTREE := 7
    top := -1
    arr := CP_Find(uia, root, CONTROLTYPE, DOCUMENT, SUBTREE)
    if (!arr)
        return top
    n := 0
    DllCall(CP_Vt(arr, 3), "ptr", arr, "int*", n)
    Loop, %n%
    {
        d := 0
        DllCall(CP_Vt(arr, 4), "ptr", arr, "int", A_Index - 1, "ptr*", d)
        if (!d)
            continue
        ; A hidden Document reports an empty rectangle at the origin, which
        ; would put the line above the tab strip and throw every tab away.
        if (CP_RectOf(d, l, t, r, b) && r > l && b > t && (top < 0 || t < top))
            top := t
        CP_Rel(d)
    }
    CP_Rel(arr)
    return top
}


; Is this element in the browser's own furniture rather than inside the page?
; True when there is no page to be inside, which leaves an unfamiliar browser
; no worse off than it was.
CP_AbovePage(el, pageTop) {
    if (pageTop < 0)
        return true
    if (!CP_RectOf(el, l, t, r, b))
        return true
    return (t < pageTop)
}


; An element's rectangle, all four edges. False when it has not got one.
CP_RectOf(el, ByRef l, ByRef t, ByRef r, ByRef b) {
    VarSetCapacity(rc, 16, 0)
    l := 0, t := 0, r := 0, b := 0
    if (DllCall(CP_Vt(el, 43), "ptr", el, "ptr", &rc) != 0)
        return false
    l := NumGet(rc, 0, "int"), t := NumGet(rc, 4, "int")
    r := NumGet(rc, 8, "int"), b := NumGet(rc, 12, "int")
    return true
}


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