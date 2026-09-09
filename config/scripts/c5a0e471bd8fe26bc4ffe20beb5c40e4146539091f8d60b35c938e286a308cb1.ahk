;=============================================================================
;
;   AUDOS_Switch.ahk        AutoHotkey v1
;
;   Tells the two AUDOS windows apart and gives you one hotkey per brand.
;
;   PART NUMBER LOOKUP - copy a part number, then:
;
;       Ctrl + Left click    look it up where the number belongs:
;                              looks like BYD    -> BYD Stock Lookup window
;                              looks like Isuzu  -> Isuzu Parts & VIN Lookup
;                              anything else     -> the KIA window
;                            (the BYD and Isuzu tools are opened if closed)
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

    ; Whatever is already open when the script starts gets remembered
    ; quietly - no toast for it. Anything that turns up after this many
    ; milliseconds is genuine news and still toasts as before. Set to 0
    ; if you want the old startup toasts back.
    AUDOS_STARTUP_QUIET_MS := 3000

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

    ;--- BYD Stock Lookup ---------------------------------------------------
    ; Ctrl+Left click hands the part number to the BYD Stock Lookup window
    ; (BydStock.ahk) instead of Kia whenever the number looks like a BYD one.
    ; It is a separate one-shot script, so if its window is not open it is
    ; started with the part number on the command line and looks it up itself.
    AUDOS_BYD_TITLE  := "BYD Stock Lookup"
    AUDOS_BYD_SCRIPT := A_ScriptDir "\BYDStockLookup\BydStock.ahk"

    ; WHAT A BYD PART NUMBER LOOKS LIKE
    ;
    ; Read off the Werribee inventory pad of 24/06/26 (list 653, 465 pages).
    ; Every BYD line there carries the franchise prefix "BY" on the pad, which
    ; is not part of the number you copy. Under that prefix:
    ;
    ;   1336 of 1348 lines   8 digits, a dash, "00"      e.g. 13885898-00
    ;                        every single dashed one ended -00, no other suffix
    ;
    ; The rest are the odd ones out, listed here so they still get routed to
    ; BYD. Two of them (1667736900, 1818926800) are plainly -00 numbers keyed
    ; without the dash. They are accepted only by name: a bare ten-digit
    ; number ending 00 is NOT taken as BYD in general, because Isuzu numbers
    ; are ten digits too and plenty of them end in 00 (5867633300 does).
    ;
    ;   702800, 702816                 towbar / accessory kits
    ;   1667736900, 1818926800         -00 numbers with the dash left out
    ;   AEG24SK18MB, AIM24SK17R,       weather shield, roof racks, tonneau
    ;   AIM24SK05
    ;   D005 D008 D035 D041 D045       mats, boot lip, cargo liner, dish
    ;   D046R D047 D057
    ;   S2191128                       VIN label
    AUDOS_BYD_EXTRA := "702800,702816,1667736900,1818926800"
                     . ",AEG24SK18MB,AIM24SK17R,AIM24SK05"
                     . ",D005,D008,D035,D041,D045,D046R,D047,D057"
                     . ",S2191128"

    ;--- Isuzu Parts & VIN Lookup -------------------------------------------
    ; Same idea for Isuzu numbers: they go to the Isuzu Parts & VIN Lookup
    ; window (IsuzuVIN.ahk), Parts tab. That tool stays running minimised on
    ; the taskbar and signs itself in, so if it is not running it is started
    ; plain (no argument - an argument would put it in headless batch mode)
    ; and the number is pasted in once its window is up. If it is still
    ; signing in, it runs the lookup by itself the moment that finishes.
    AUDOS_ISUZU_TITLE  := "Isuzu Parts & VIN Lookup"
    AUDOS_ISUZU_SCRIPT := A_ScriptDir "\IsuzuVIN\IsuzuVIN.ahk"
    AUDOS_ISUZU_WAIT_MS := 8000     ; how long to wait for its window to appear

    ; WHAT AN ISUZU PART NUMBER LOOKS LIKE
    ;
    ; Three ways a number gets sent to Isuzu, tried in this order:
    ;
    ; 1. It came off the pad with the make on the front. The pad prints
    ;    Isuzu lines as IA and the number run together - IA5867658130,
    ;    IAA0556R0150 - the same way BYD lines get BY. The IA comes off
    ;    and whatever is left goes to Isuzu, no questions asked: the pad
    ;    already said what make it is.
    ;
    ; 2. The genuine shape. One digit, eight digits, one check digit, with
    ;    or without the dashes: 8-98134584-0  1-87830935-0  8981345840.
    ;    1,519 of the 1,607 Isuzu lines on the June 2026 stocktake pad
    ;    (list 647) are this shape.
    ;
    ; 3. The lists below. First the other 88 lines on that pad:
    ;    accessories, oils, merchandise and service kits, with letters in
    ;    them, so they read like Kia numbers and used to be sent to the Kia
    ;    window. Numbers are as the pad prints them, and its column is 17
    ;    wide, so a few long ones are cut short there (CVC-IU-DX20-HFSIE).
    ;    They still match, because that is what gets copied off the screen.
    ;    Then the 359 numbers from the IUA Accessory List V19 (Sep 2026)
    ;    that neither shape takes, one block per family. Add to these when
    ;    a new one turns up; the shape check in AUDOS_IsIsuzuPart already
    ;    takes the A0556R0150 family, with or without a -527 colour code.
    AUDOS_ISUZU_EXTRA := "08A0HRTB03,6131686110D,A0556M0010,A0556M0020,A0556M0030,A0556M0040"
                       . ",A0556R0030,A0556R0040,A0556R0050,A0556R0150,A0556S0050,A0556S0060"
                       . ",A0562R0100-000,A0562R0110-000,A0562R0300,A0562R0310,A0562R0320"
                       . ",A0562S0350,A0586R0010,A1924M0010,CVC-IU-DX20-HFSIE"
                       . ",CVC-IU-MX25-HVFSI,CVNG-HI-DC2012-FI,CVNG-IU-DX20-FSIE"
                       . ",CVNG-IU-DX20-HFSI,CVNG-IU-MX25-HVFS,E1345R0010,E1345R0020"
                       . ",E1345S0020,EVO-10-S-103253,F0557M0010,F0557M0020,IUA1410-LB2-RC"
                       . ",IUA44RS3.5,IULAT00010-1L,IULAT00010-5L,IULBK00010-500M"
                       . ",IULEN00010-1L,IULEN00010-5L,IULGE00010-1L,IULGE00010-5L"
                       . ",IULLC00010-1L,IULLC00010-5L,IUWB161201,IUWB240101,JC-01695N"
                       . ",JC-01806,JC-02183,JC-02309,M063150100M,M063150100S,M063210010M"
                       . ",M06321002008,M06321002012,M0632300102XL,M063230010L,M063230010M"
                       . ",M063230010XL,M06323002008,M06323002012,M1063P0060-M,M1063P0060-XL"
                       . ",M110150041,M110160050,M110160060,M110170020,M142230100,M290170010"
                       . ",M850180010,M850210020,M850210030,M850210070,M850220020"
                       . ",NAVIDVDAUDIE2001A,SVC-14A10004775,SVC-14A10004776,SVC-14A10004778"
                       . ",SVC-14A10004896,SVC-14A10005121,SVC-14N-0004866,SVC-F08-0003605"
                       . ",T0900R0010,TF-IE-2321AU-1ST,TFIE1542AU,WAG-14A10001877"
                       . ",WAG-14A10003619,WAG-14N-0004548,X1345K0010"

    ; IUA Accessory List V19, Sep 2026 - 59 sheets, every part number that
    ; is not the ten digit shape and not the A0556R0150 shape.
    ; 08A0HRTB03 family - tow bars, mats, roof racks, nudge bars, shown on the
    ; TF accessory stock and price sheets
    AUDOS_ISUZU_EXTRA .= ",08A0HRTB01,08A0HRTB02,08A0HRTB04,08A0LMIN01"
    AUDOS_ISUZU_EXTRA .= ",08A0LMTB01,08A0RSPB01,08A0RSPB02,08A0RSPB03"
    AUDOS_ISUZU_EXTRA .= ",08A0RSPB05,08A0TMAT02,08A0TMAT03,08A0TMAT04"
    AUDOS_ISUZU_EXTRA .= ",08A0TMAT05,08A0TMAT07,08A0TMAT08,08A0TMAT09"
    AUDOS_ISUZU_EXTRA .= ",08A0TMAT11,08A0TMP504,08A0TMP520,08A0TMP877"
    AUDOS_ISUZU_EXTRA .= ",08A0TMP936,08C0EGPA01,08C0EGPA02,08C0EGPA03"
    AUDOS_ISUZU_EXTRA .= ",08C0EGPA04,08C0EGPA05,08C0EGPA06,08C0EGPA07"
    AUDOS_ISUZU_EXTRA .= ",08C0EGPA08,08C0TMAT41,08C0TMAT42,08C0TMAT43"
    AUDOS_ISUZU_EXTRA .= ",08C0TMAT51,08C0TMAT52,08C0TMAT53,08C0TMAT61"
    AUDOS_ISUZU_EXTRA .= ",08C0TMAT62,08C0TMAT63,08C0TTST01,08D0ARCN01"
    AUDOS_ISUZU_EXTRA .= ",08D0EGSB01,08D0THRR03,08D0THRR04,08D0THRR05"
    AUDOS_ISUZU_EXTRA .= ",08D0THRR06,08D0TTBL01,08D0TTBL02,08D0TTST01"
    AUDOS_ISUZU_EXTRA .= ",08D0TTST02,08D0TTST03,08D0ZTCP01,08D0ZTLE01"
    AUDOS_ISUZU_EXTRA .= ",08D1ARCN01,08D1ARCN02,08D1ARCN03,08D1ARCN04"
    AUDOS_ISUZU_EXTRA .= ",08D1ARCN05,08D1ARCN06,08D1ARCN07,08D1ARCN08"
    AUDOS_ISUZU_EXTRA .= ",08D1ARCN09,08D1ARCN10,08D1ARCN11,08D1ARCN12"
    AUDOS_ISUZU_EXTRA .= ",08D1EGHT01,08D1EGHT02,08D2ARCN01,08D2ARCN02"
    AUDOS_ISUZU_EXTRA .= ",08D2ARCN03,08D2ARCN04,08D2ARCN05,08D2ARCN06"
    AUDOS_ISUZU_EXTRA .= ",08D2ARCN07,08D2ARCN08,08D2ARCN09,08D2ARCN10"
    AUDOS_ISUZU_EXTRA .= ",08D2ARCN11,08D2ARCN12,08D2EGHT01,08D2EGHT02"
    AUDOS_ISUZU_EXTRA .= ",08D3ARCN01,08D3ARCN02,08D3ARCN03,08D3ARCN04"
    AUDOS_ISUZU_EXTRA .= ",08D3ARCN05,08D3ARCN06,08D3ARCN07,08D3ARCN08"
    AUDOS_ISUZU_EXTRA .= ",08D3ARCN09,08D3ARCN10,08D3ARCN11,08D3ARCN12"
    AUDOS_ISUZU_EXTRA .= ",08D3EGHT01,08D3EGHT02,08D4ARCN01,08D4ARCN02"
    AUDOS_ISUZU_EXTRA .= ",08D4ARCN03,08D4ARCN04,08D4ARCN05,08D4ARCN06"
    AUDOS_ISUZU_EXTRA .= ",08D4ARCN07,08D4ARCN08,08D4ARCN09,08D4ARCN10"
    AUDOS_ISUZU_EXTRA .= ",08D4ARCN11,08D4ARCN12,08D4EGHT01,08D4EGHT02"
    AUDOS_ISUZU_EXTRA .= ",08D5ARCN01,08D5ARCN02,08D5ARCN03,08D5ARCN04"
    AUDOS_ISUZU_EXTRA .= ",08D5ARCN05,08D5ARCN06,08D5ARCN07,08D5ARCN08"
    AUDOS_ISUZU_EXTRA .= ",08D5ARCN09,08D5ARCN10,08D5ARCN11,08D5ARCN12"
    AUDOS_ISUZU_EXTRA .= ",08D5EGHT01,08D5EGHT02,08D6EGHT02,08D7ARCN01"
    AUDOS_ISUZU_EXTRA .= ",08D7ARCN02,08D7ARCN03,08D7ARCN04,08D7ARCN05"
    AUDOS_ISUZU_EXTRA .= ",08D7ARCN06,08D7ARCN07,08D7ARCN08,08D7ARCN09"
    AUDOS_ISUZU_EXTRA .= ",08D7ARCN10,08D7ARCN11,08D7ARCN12,08D7EGHT01"
    AUDOS_ISUZU_EXTRA .= ",08D7EGHT02,08D8EGHT02,08D9ARCN01,08D9ARCN02"
    AUDOS_ISUZU_EXTRA .= ",08D9ARCN03,08D9ARCN04,08D9ARCN05,08D9ARCN06"
    AUDOS_ISUZU_EXTRA .= ",08D9ARCN07,08D9ARCN08,08D9EGHT02,08DSP01BL"
    AUDOS_ISUZU_EXTRA .= ",08DSP01GS,08DSP01HB,08DSP01LULS,08DSP01RWA"
    AUDOS_ISUZU_EXTRA .= ",08DSP01RWB,08DSP01SD,08E0TMAT41,08E0TMAT42"
    AUDOS_ISUZU_EXTRA .= ",08E0TMAT43,08E0TMAT51,08E0TMAT52,08E0TMAT53"
    AUDOS_ISUZU_EXTRA .= ",08E0TMAT61,08E0TMAT62,08E0TMAT63,08S0TMAT41"
    AUDOS_ISUZU_EXTRA .= ",08S0TMAT42,08S0TMAT43,08S0TMAT51,08S0TMAT52"
    AUDOS_ISUZU_EXTRA .= ",08S0TMAT53,08S0TMAT61,08S0TMAT62,08S0TMAT63"
    AUDOS_ISUZU_EXTRA .= ",08S0TTST01"

    ; Tray codes: the genuine ten digits with a D on the end
    AUDOS_ISUZU_EXTRA .= ",5411689001D,5411689011D,5411689021D,5411689031D"
    AUDOS_ISUZU_EXTRA .= ",5411689041D,5411689051D,5411689061D,5411689071D"
    AUDOS_ISUZU_EXTRA .= ",5421689001D,5421689011D,5421689021D,5421689031D"
    AUDOS_ISUZU_EXTRA .= ",5421689041D,5421689051D,5421689061D,5421689071D"
    AUDOS_ISUZU_EXTRA .= ",5431689001D,5431689011D,5431689021D,5431689031D"
    AUDOS_ISUZU_EXTRA .= ",5431689041D,5431689051D,5431689061D,5431689071D"
    AUDOS_ISUZU_EXTRA .= ",6111686110D,6111686120D,6111686130D,6111686140D"
    AUDOS_ISUZU_EXTRA .= ",6111686150D,6111686210D,6111686220D,6111686230D"
    AUDOS_ISUZU_EXTRA .= ",6111686240D,6111686250D,6121686110D,6121686120D"
    AUDOS_ISUZU_EXTRA .= ",6121686130D,6121686140D,6121686150D,6121686210D"
    AUDOS_ISUZU_EXTRA .= ",6121686220D,6121686230D,6121686240D,6121686250D"
    AUDOS_ISUZU_EXTRA .= ",6131686120D,6131686130D,6131686140D,6131686150D"
    AUDOS_ISUZU_EXTRA .= ",6131686210D,6131686220D,6131686230D,6131686240D"
    AUDOS_ISUZU_EXTRA .= ",6131686250D"

    ; A0562R0100-527: the letter shape with a colour code on the end
    AUDOS_ISUZU_EXTRA .= ",A0562R0100-527,A0562R0100-554,A0562R0100-564"
    AUDOS_ISUZU_EXTRA .= ",A0562R0100-568,A0562R0100-569,A0562R0100-575"
    AUDOS_ISUZU_EXTRA .= ",A0562R0100-587,A0562R0100-588,A0562R0110-527"
    AUDOS_ISUZU_EXTRA .= ",A0562R0110-554,A0562R0110-564,A0562R0110-568"
    AUDOS_ISUZU_EXTRA .= ",A0562R0110-569,A0562R0110-575,A0562R0110-587"
    AUDOS_ISUZU_EXTRA .= ",A0562R0110-588,A0562S0100-401,A0562S0110-401"
    AUDOS_ISUZU_EXTRA .= ",A0575S0200-401"

    ; Head units and camera kits
    AUDOS_ISUZU_EXTRA .= ",CVC-IU-DX20-FSIEB,CVC-IU-DX20-FSIEC"
    AUDOS_ISUZU_EXTRA .= ",CVC-IU-DX20-HFSIEB,CVC-IU-DX20-HFSIEC"
    AUDOS_ISUZU_EXTRA .= ",CVC-IU-DX20-SIEB,CVC-IU-DX20-SIEC"
    AUDOS_ISUZU_EXTRA .= ",CVC-IU-DX2020-FSIEB,CVC-IU-DX2020-FSIEC"
    AUDOS_ISUZU_EXTRA .= ",CVC-IU-DX2020-SIEB,CVC-IU-DX2020-SIEC"
    AUDOS_ISUZU_EXTRA .= ",CVC-IU-MX25-HVFSIEB,CVC-IU-MX25-HVFSIEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-HI-DC2012-FIEB,CVNG-HI-DC2012-FIEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-HI-DC2012-IEB,CVNG-HI-DC2012-IEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-IU-DX20-FSIEB,CVNG-IU-DX20-FSIEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-IU-DX20-HFSIEB,CVNG-IU-DX20-HFSIEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-IU-DX20-SIEB,CVNG-IU-DX20-SIEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-IU-DX2020-FSIEB,CVNG-IU-DX2020-FSIEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-IU-DX2020-SIEB,CVNG-IU-DX2020-SIEC"
    AUDOS_ISUZU_EXTRA .= ",CVNG-IU-MX25-HVFSIEB,CVNG-IU-MX25-HVFSIEC"

    ; Service plans and the odd IUA item
    AUDOS_ISUZU_EXTRA .= ",IUA43RS3.5,IUSP10000,IUSP105000,IUSP15000"
    AUDOS_ISUZU_EXTRA .= ",IUSP20000,IUSP30000,IUSP40000,IUSP45000,IUSP50000"
    AUDOS_ISUZU_EXTRA .= ",IUSP60000,IUSP75000,IUSP90000"

    ; Rhino racks
    AUDOS_ISUZU_EXTRA .= ",JA9671,JB0019,JB1253,JB1379,JC-01256,JC-01257"
    AUDOS_ISUZU_EXTRA .= ",JC-01335,JC-01518,JC-01519,JC-01690,JC-02188"
    AUDOS_ISUZU_EXTRA .= ",JC-04622"

    ; Service kits
    AUDOS_ISUZU_EXTRA .= ",SVC-03F-0003717,SVC-04D-0002266,SVC-04E-0003718"
    AUDOS_ISUZU_EXTRA .= ",SVC-10B-0002052AF,SVC-11A-0003609,SVC-11A-0003610"
    AUDOS_ISUZU_EXTRA .= ",SVC-11B-0003611,SVC-11B-0003612,SVC-12C-0001999"
    AUDOS_ISUZU_EXTRA .= ",SVC-12H-0003716,SVC-12H-0003719,SVC-12L-0003715"
    AUDOS_ISUZU_EXTRA .= ",SVC-14A10003607,SVC-14A10003608,SVC-14A10004770"
    AUDOS_ISUZU_EXTRA .= ",SVC-14A10004777,SVC-14A10004867,SVC-14A10005122"
    AUDOS_ISUZU_EXTRA .= ",SVC-14N-0004865,SVC-14S-0004864,SVC-78G-0005041"
    AUDOS_ISUZU_EXTRA .= ",SVC-A08-0001886,SVC-A08-0001887,SVC-A08-0001888"
    AUDOS_ISUZU_EXTRA .= ",SVC-A08-0001889,SVC-F08-0003602,SVC-F08-0003603"
    AUDOS_ISUZU_EXTRA .= ",SVC-F08-0003604,SVC-H08-0003606,SVC-J2160001940"
    AUDOS_ISUZU_EXTRA .= ",SVC-M08-0004271"

    ; WAG kits
    AUDOS_ISUZU_EXTRA .= ",WAG-00A-0002074,WAG-00A-0004503,WAG-00A-004503"
    AUDOS_ISUZU_EXTRA .= ",WAG-10B-0002052AF,WAG-10B-0002054,WAG-12G-0002000"
    AUDOS_ISUZU_EXTRA .= ",WAG-14A10001876,WAG-14A10003620,WAG-14F-0001895"
    AUDOS_ISUZU_EXTRA .= ",WAG-14F-0002672,WAG-14N-0001890,WAG-14N-0001891"
    AUDOS_ISUZU_EXTRA .= ",WAG-14N-0004681,WAG-14S-0001892,WAG-14S-0004335"
    AUDOS_ISUZU_EXTRA .= ",WAG-H08-0003508,WAG-H08-0003509,WAG-H08-0003510"
    AUDOS_ISUZU_EXTRA .= ",WAG-H08-0003569,WAG-T06-0001939,WAG-T07-0001941"
    AUDOS_ISUZU_EXTRA .= ",WAG-T07-0003985,WAG-T07-0003986"

    ; Everything else on the list
    AUDOS_ISUZU_EXTRA .= ",1410-LB2-RC,9PMFDMAX4,DNX9190DABS,LB350,RBC050"
    AUDOS_ISUZU_EXTRA .= ",S000000020,S103790010,SPECACT50"

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
    gAUDOS_QuietUntil := A_TickCount + AUDOS_STARTUP_QUIET_MS  ; silent till then
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
^LButton::AUDOS_LookupByShape()
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

;=============================================================================
;   CTRL+LEFT CLICK  -  send the number where it belongs
;
;   The shape of the number decides the window. A BYD number goes to the BYD
;   Stock Lookup, an Isuzu number to the Isuzu Parts & VIN Lookup, and only
;   what is left goes to Kia. Kia is never even looked for when the number
;   is BYD or Isuzu, so there is no "Kia window not found" box in the way.
;
;   Both tools are AutoHotkey GUIs of their own: one edit box for the part
;   number and one Look up button. Both are found by class, not by number -
;   there is only one Look up button in each, and the part box is the first
;   edit box in each - so Edit1 and Button1 cannot drift. The hand-off itself
;   is AUDOS_ToolLookup: it sets the text straight on the box, reads it back
;   to prove it landed, and presses the button with BM_CLICK, which works
;   whether the window is buried, minimised or halfway up off the taskbar.
;   Every hand-off writes one line to AUDOS_Switch.log next to this script.
;=============================================================================
AUDOS_LookupByShape() {
    part := Trim(Clipboard, " `t`r`n")
    if (AUDOS_IsBydPart(part))
        AUDOS_BydLookup(part)
    else if (AUDOS_IsIsuzuPart(part))
        AUDOS_IsuzuLookup(part)
    else
        AUDOS_PartLookup("Kia")
}

;-----------------------------------------------------------------------------
;   AUDOS_IsBydPart("13885898-00")  ->  true if it looks like a BYD number
;
;   Accepts the pad's "BY" prefix if it was copied along with the number.
;   See AUDOS_BYD_EXTRA in the settings for where the shapes come from.
;-----------------------------------------------------------------------------
AUDOS_IsBydPart(part) {
    global AUDOS_BYD_EXTRA
    AUDOS_Init()
    part := AUDOS_BydNormalise(part)
    if (part = "")
        return false
    if RegExMatch(part, "^\d{8}-\d{2}$")     ; 13885898-00
        return true
    if part in %AUDOS_BYD_EXTRA%
        return true
    return false
}

; Upper case, no spaces, and the pad's "BY" prefix taken off. The prefix
; sits in front of letters as well as digits (BYD005, BYAEG24SK18MB), and
; taking it off a number that is not BYD does no harm - the caller only
; accepts what still matches a BYD shape or the list afterwards.
AUDOS_BydNormalise(part) {
    part := RegExReplace(Trim(part, " `t`r`n"), "\s+")
    StringUpper, part, part
    if RegExMatch(part, "^BY[A-Z0-9]")
        part := SubStr(part, 3)
    return part
}

;-----------------------------------------------------------------------------
;   AUDOS_BydLookup("13885898-00")
;
;   Puts the number in the BYD Stock Lookup window and presses Look up.
;   Starts the window if it is not open. Returns true if it did anything.
;   Numbers that do not look like BYD ones are left alone, quietly.
;-----------------------------------------------------------------------------
AUDOS_BydLookup(part) {
    global AUDOS_BYD_TITLE, AUDOS_BYD_SCRIPT
    AUDOS_Init()
    SetTitleMatchMode, 2        ; per thread: holds even when #Included elsewhere

    if (!AUDOS_IsBydPart(part))
        return false
    part := AUDOS_BydNormalise(part)

    hwnd := WinExist(AUDOS_BYD_TITLE " ahk_class AutoHotkeyGUI")

    ; Not open. BydStock.ahk looks a number up by itself when it is given one
    ; on the command line, so just start it that way.
    if (!hwnd) {
        if (!FileExist(AUDOS_BYD_SCRIPT)) {
            MsgBox, 48, AUDOS Switch
                , % "BYD Stock Lookup is not open and its script was not "
                  . "found at:`n`n" AUDOS_BYD_SCRIPT
            return false
        }
        SplitPath, AUDOS_BYD_SCRIPT, , dir
        Run, "%A_AhkPath%" "%AUDOS_BYD_SCRIPT%" "%part%", %dir%
        AUDOS_HandLog("BYD", part, 0, "started the script with the number")
        return true
    }

    return AUDOS_ToolLookup(hwnd, part, AUDOS_BYD_TITLE)
}

;-----------------------------------------------------------------------------
;   AUDOS_IsIsuzuPart("8-98134584-0")  ->  true if it looks like an Isuzu one
;
;   Three tests, see WHAT AN ISUZU PART NUMBER LOOKS LIKE in the settings:
;   the pad's IA on the front, the genuine digit shape, the accessory
;   shape (A0556R0150: letter, four digits, letter, four digits), and the
;   AUDOS_ISUZU_EXTRA list for everything else the pad carries.
;-----------------------------------------------------------------------------
AUDOS_IsIsuzuPart(part) {
    global AUDOS_ISUZU_EXTRA
    AUDOS_Init()
    if (AUDOS_IsuzuHadMake(part))
        return true
    part := AUDOS_IsuzuNormalise(part)
    if (part = "")
        return false
    if RegExMatch(part, "^\d-?\d{8}-?\d$")           ; 8-98134584-0
        return true
    if RegExMatch(part, "^[A-Z]\d{4}[A-Z]\d{4}(-\d{3})?$")  ; A0556R0150, A0562R0100-527
        return true
    if part in %AUDOS_ISUZU_EXTRA%
        return true
    return false
}

; Did this come off the pad with the IA make code on the front? True only
; when what follows is long enough to be a part number and has a digit in
; it, which is the same test EraWord uses before it strips a make - so a
; word like IADAPTER is left alone.
AUDOS_IsuzuHadMake(part) {
    part := RegExReplace(Trim(part, " `t`r`n"), "\s+")
    StringUpper, part, part
    return RegExMatch(part, "^IA(?=.{5,}$)(?=.*\d)") ? true : false
}

; Upper case, no spaces, and the pad's "IA" prefix taken off.
AUDOS_IsuzuNormalise(part) {
    part := RegExReplace(Trim(part, " `t`r`n"), "\s+")
    StringUpper, part, part
    if (AUDOS_IsuzuHadMake(part))
        part := SubStr(part, 3)
    return part
}

;-----------------------------------------------------------------------------
;   AUDOS_IsuzuLookup("8-98134584-0")
;
;   Puts the number in the Isuzu Parts & VIN Lookup window, on its Parts tab,
;   and presses Look up. Starts the tool if it is not running and waits for
;   its window. Returns true if it did anything.
;-----------------------------------------------------------------------------
AUDOS_IsuzuLookup(part) {
    global AUDOS_ISUZU_TITLE, AUDOS_ISUZU_SCRIPT, AUDOS_ISUZU_WAIT_MS
    AUDOS_Init()
    SetTitleMatchMode, 2        ; per thread: holds even when #Included elsewhere

    part := AUDOS_IsuzuNormalise(part)     ; IA5867658130 -> 5867658130
    if (part = "")
        return false

    title := AUDOS_ISUZU_TITLE " ahk_class AutoHotkeyGUI"
    hwnd  := WinExist(title)

    ; Not running. Start it with no argument - an argument would put it into
    ; its headless batch mode with no window at all - and wait for the window.
    if (!hwnd) {
        if (!FileExist(AUDOS_ISUZU_SCRIPT)) {
            MsgBox, 48, AUDOS Switch
                , % "Isuzu Parts & VIN Lookup is not running and its script "
                  . "was not found at:`n`n" AUDOS_ISUZU_SCRIPT
            return false
        }
        SplitPath, AUDOS_ISUZU_SCRIPT, , dir
        Run, "%A_AhkPath%" "%AUDOS_ISUZU_SCRIPT%", %dir%
        WinWait, %title%, , % AUDOS_ISUZU_WAIT_MS / 1000
        hwnd := WinExist(title)
        if (!hwnd) {
            MsgBox, 48, AUDOS Switch
                , % "Started Isuzu Parts & VIN Lookup but its window did not "
                  . "appear within " Round(AUDOS_ISUZU_WAIT_MS / 1000) " seconds."
            return false
        }
        Sleep, 300                       ; let it finish building its controls
    }

    ; IsuzuVIN v4.0 is one screen: the part box and its Look up button, no
    ; tab strip. (Up to v3.9 there was a Parts/Vehicle tab strip here that had
    ; to be flipped to Parts first; the vehicle screen is its own window now.)
    return AUDOS_ToolLookup(hwnd, part, AUDOS_ISUZU_TITLE)
}

;-----------------------------------------------------------------------------
;   AUDOS_ToolLookup(hwnd, "5867658130", "Isuzu Parts & VIN Lookup")
;
;   The hand-off both tools share. The window is already found; this puts
;   the number in its part box and presses its Look up button, and does not
;   take either on trust:
;
;     1. Restore first if it is parked on the taskbar, and wait until it has
;        actually come up (Restore returns before the window has moved).
;        Then activate. Activation is a courtesy, not a need - the rest works
;        with the window buried.
;     2. Set the box text, read it straight back, and set it once more if it
;        did not land. This is the step that used to go unchecked.
;     3. Focus the button and press it with BM_CLICK. That is the button's
;        own "you were clicked" message, handled on the tool's thread and
;        fired as a normal click, so the tool's Look up code runs exactly as
;        it does for the mouse. A posted mouse click needed the window still
;        and on screen at the moment it landed, which mid-restore it was not.
;        If the tool does not answer the message in time, Enter goes to the
;        box instead - Look up is the default button in both tools.
;
;   Returns true when the number landed and the button was pressed.
;-----------------------------------------------------------------------------
AUDOS_ToolLookup(hwnd, part, toolName) {
    SetTitleMatchMode, 2
    tool := (InStr(toolName, "BYD") ? "BYD" : "Isuzu")

    ControlGet, edit, Hwnd, , Edit1,   ahk_id %hwnd%   ; the part box
    ControlGet, btn,  Hwnd, , Button1, ahk_id %hwnd%   ; the Look up button
    if (!edit || !btn) {
        AUDOS_HandLog(tool, part, hwnd, "no part box or button (edit=" edit " btn=" btn ")")
        MsgBox, 48, AUDOS Switch
            , % "Found the " toolName " window but not its part box "
              . "and Look up button."
        return false
    }

    ; Both tools park themselves minimised on the taskbar, so Restore is what
    ; brings one up - Activate alone would leave it down there. Restore is
    ; asynchronous: give it up to a second to finish before going on.
    WinGet, state, MinMax, ahk_id %hwnd%
    if (state = -1) {
        WinRestore, ahk_id %hwnd%
        Loop, 20 {
            Sleep, 50
            WinGet, state, MinMax, ahk_id %hwnd%
            if (state != -1)
                break
        }
    }
    WinActivate, ahk_id %hwnd%
    WinWaitActive, ahk_id %hwnd%, , 0.5

    ; The number, and proof it landed.
    ControlSetText, , %part%, ahk_id %edit%
    ControlGetText, got, , ahk_id %edit%
    landed := "first try"
    if (got != part) {
        Sleep, 100
        ControlSetText, , %part%, ahk_id %edit%
        ControlGetText, got, , ahk_id %edit%
        landed := "second try"
    }
    if (got != part) {
        AUDOS_HandLog(tool, part, hwnd, "text did not land, box holds [" got "]")
        MsgBox, 48, AUDOS Switch
            , % "Could not put " part " into the " toolName " part box."
        return false
    }

    ; Press the button. BM_CLICK = 0x00F5.
    ControlFocus, , ahk_id %btn%
    SendMessage, 0xF5, 0, 0, , ahk_id %btn%
    press := "BM_CLICK"
    if (ErrorLevel = "FAIL") {
        ControlSend, , {Enter}, ahk_id %edit%
        press := "Enter (BM_CLICK timed out)"
    }
    AUDOS_HandLog(tool, part, hwnd, "ok, text landed " landed ", pressed with " press)
    return true
}

; One line per hand-off in AUDOS_Switch.log beside this script, so a "nothing
; happened" can be read afterwards instead of guessed at.
AUDOS_HandLog(tool, part, hwnd, what) {
    FormatTime, now, , yyyy-MM-dd HH:mm:ss
    FileAppend, % now " " tool " " part " hwnd=" hwnd " " what "`n"
        , % A_ScriptDir "\AUDOS_Switch.log"
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
    global AUDOS_RECHECK_POLLS, gAUDOS_QuietUntil
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

            ; During the startup quiet period we remember the window but
            ; say nothing - it was already open before you ran the script,
            ; so it is not news worth a toast.
            if (A_TickCount < gAUDOS_QuietUntil)
                continue

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
    body .= "Ctrl+Left click   part lookup - BYD / Isuzu / Kia by number shape`n"
    body .= "Ctrl+Right click  part lookup in Hyundai`n"
    body .= "Insert            activate Kia`n"
    body .= "Home              activate Hyundai"
    MsgBox, 64, AUDOS Switch, %body%
}
