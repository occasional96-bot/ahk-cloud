;=============================================================================
;
;   AUDOS_Switch.ahk        AutoHotkey v1
;
;   Tells the two AUDOS windows apart and gives you one hotkey per brand.
;
;   PART NUMBER LOOKUP - copy a part number, then:
;
;       Ctrl + Left click    work out the brand and look it up there
;       Ctrl + Shift + Left  force Isuzu, for the odd lettered number
;       Ctrl + Right click   look it up in the HYUNDAI window
;
;   Ctrl+Left click reads the number and decides where it belongs, in this
;   order: BYD (ends -00), then Isuzu, then Kia for everything else. BYD and
;   Kia open the AUDOS window; Isuzu goes to the separate Isuzu Parts & VIN
;   Lookup tool, starting it if it is not up.
;
;   Isuzu is decided two ways. Ten-digit numbers go by their family prefix,
;   two digits deep, then three, then four for the last two groups Kia also
;   uses. The 89 numbers no prefix can reach - accessories, service kits,
;   oils, workwear, tow mirrors - are listed by name in AUDOS_ISUZU_EXACT
;   and matched exactly.
;
;   Together those read every one of the 1627 Isuzu numbers in the Werribee
;   pad correctly, and send none of the 5839 Kia numbers to Isuzu.
;
;   Anything unrecognised still reads as Kia, so a wrong guess opens the
;   wrong window - it never looks up the wrong number. And if the AUDOS
;   window is not open at all, a guessed Kia goes to the Isuzu tool rather
;   than stopping on "Kia window not found".
;
;   JUST BRING A WINDOW UP
;
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

    ;--- telling the three brands apart -------------------------------------
    ; Ctrl+Left click reads the clipboard and decides for itself where the
    ; part number belongs. The order is fixed and deliberate:
    ;
    ;     1. BYD    ends in -00
    ;     2. Isuzu  ten digits with an Isuzu family prefix
    ;     3. Kia    everything else
    ;
    ; Kia is last on purpose. It is the catch-all, so anything the first two
    ; rules do not claim ends up there.
    ;
    ; Where the Isuzu prefixes come from: the 465-page Werribee inventory pad
    ; (list 653, 24/06/26) holds 1538 Isuzu and 150 Kia part numbers that are
    ; ten plain digits, which is the only place the two brands genuinely
    ; collide. Grouping those by leading digits gives the two tables below.
    ; Measured five-fold cross-validated - so scored only on numbers the
    ; tables had not seen - this gets 99.11% right: 12 Isuzu sent to Kia and
    ; 3 Kia sent to Isuzu out of 1688.
    ;
    ; Suffixes were tested and deliberately left out. They carry almost no
    ; signal (a rule built on the last two digits scores 28.85%), and bolting
    ; one on as a tie-breaker made things worse, not better - it decided 11
    ; numbers and got 6 of them wrong.

    ; Leading TWO digits that only ever belong to Isuzu. Covers 1493 of the
    ; 1538, with no Kia number anywhere near them.
    AUDOS_ISUZU_P2 := "|"
    AUDOS_ISUZU_P2 .= "03|05|08|09|10|55|56|57|58|59|60|61|"
    AUDOS_ISUZU_P2 .= "74|75|89|90|"

    ; The seven leading pairs both brands use - 02 04 11 18 53 54 94 - split
    ; apart at three digits. These are the Isuzu side of that split; anything
    ; else falls through to Kia. Going deeper than three digits was tested and
    ; changes nothing, which is the sign there is no more signal to find.
    AUDOS_ISUZU_P3 := "|"
    AUDOS_ISUZU_P3 .= "028|040|115|182|534|541|542|544|546|941|"

    ; Four digits is where Isuzu and Kia finally come apart. 187 and 545 are
    ; still mixed at three - Isuzu holds 1876, 5452 and 5453 there, Kia holds
    ; 1879 and 5455. The rest of this table is whole Isuzu families the pad
    ; never showed, picked up from the IUA accessory file: the 5431 and 5432
    ; roof and tray series, 6322 and 6341, and a few smaller ones.
    ;
    ; Every one was checked against all 5839 Kia, 8709 Hyundai, 5774 Genesis,
    ; 1352 BYD and 41 Nissan numbers in the pad - not one four-digit prefix
    ; here belongs to another brand. Prefixes are worth more than stored
    ; numbers because they catch parts nobody has seen yet.
    ;
    ; This is deeper than the cascade used to go. An earlier note here said
    ; going past three digits changed nothing - that was measured by holding
    ; part of the pad back, where a prefix the table has never seen cannot
    ; help by definition. It was wrong about the rule itself. 1876101070 is
    ; a real Isuzu number that the three-digit cascade sent to Kia.
    AUDOS_ISUZU_P4 := "|"
    AUDOS_ISUZU_P4 .= "1876|5452|5453|5123|5143|5222|5431|5432|6243|6322|6341|6441|"

    ; Named Isuzu numbers the rules above cannot reach.
    ;
    ; Two kinds of number end up here. A handful of ordinary parts sit in the
    ; 187 and 545 groups both brands share, so the prefix cascade cannot call
    ; them. The rest are not shaped like parts at all - accessories, service
    ; kits, oils, workwear, tow mirrors - and they carry letters where the
    ; cascade wants ten digits.
    ;
    ; Every one is listed under make code IA in the pad, none of them is also
    ; a Kia, Hyundai, Genesis, BYD or Nissan number, and the list is checked
    ; by exact match, so it can only ever add an Isuzu answer - it can never
    ; take one away from another brand. That makes it a safe stopgap until a
    ; real rule turns up for them.
    ;
    ; The list is built from three sources, all of them Isuzu's own: the
    ; Werribee inventory pad, the Best Value Parts quick reference, and the
    ; IUA accessory price file. Only the PART NUMBER columns were read, so
    ; model years, engine codes and sizes never got in.
    ;
    ; None of the 546 is also a Kia, Hyundai, Genesis, BYD or Nissan number.
    ; Four notation entries were left out - 2X8973014930 and friends, which
    ; are a quantity written in front of a part number, not a part number.
    AUDOS_ISUZU_EXACT := "|08A0HRTB01|08A0HRTB02|08A0HRTB03|08A0HRTB04|08A0LMIN01|08A0LMTB01|"
    AUDOS_ISUZU_EXACT .= "|08A0RSPB01|08A0RSPB02|08A0RSPB03|08A0RSPB05|08A0TMAT02|08A0TMAT03|"
    AUDOS_ISUZU_EXACT .= "|08A0TMAT04|08A0TMAT05|08A0TMAT07|08A0TMAT08|08A0TMAT09|08A0TMAT11|"
    AUDOS_ISUZU_EXACT .= "|08A0TMP504|08A0TMP520|08A0TMP877|08A0TMP936|08C0EGPA01|08C0EGPA02|"
    AUDOS_ISUZU_EXACT .= "|08C0EGPA03|08C0EGPA04|08C0EGPA05|08C0EGPA06|08C0EGPA07|08C0EGPA08|"
    AUDOS_ISUZU_EXACT .= "|08C0TMAT41|08C0TMAT42|08C0TMAT43|08C0TMAT51|08C0TMAT52|08C0TMAT53|"
    AUDOS_ISUZU_EXACT .= "|08C0TMAT61|08C0TMAT62|08C0TMAT63|08C0TTST01|08D0ARCN01|08D0EGSB01|"
    AUDOS_ISUZU_EXACT .= "|08D0THRR03|08D0THRR04|08D0THRR05|08D0THRR06|08D0TTBL01|08D0TTBL02|"
    AUDOS_ISUZU_EXACT .= "|08D0TTST01|08D0TTST02|08D0TTST03|08D0ZTLE01|08D1ARCN01|08D1ARCN02|"
    AUDOS_ISUZU_EXACT .= "|08D1ARCN03|08D1ARCN04|08D1ARCN05|08D1ARCN06|08D1ARCN07|08D1ARCN08|"
    AUDOS_ISUZU_EXACT .= "|08D1ARCN09|08D1ARCN10|08D1ARCN11|08D1ARCN12|08D1EGHT01|08D1EGHT02|"
    AUDOS_ISUZU_EXACT .= "|08D2ARCN01|08D2ARCN02|08D2ARCN03|08D2ARCN04|08D2ARCN05|08D2ARCN06|"
    AUDOS_ISUZU_EXACT .= "|08D2ARCN07|08D2ARCN08|08D2ARCN09|08D2ARCN10|08D2ARCN11|08D2ARCN12|"
    AUDOS_ISUZU_EXACT .= "|08D2EGHT01|08D2EGHT02|08D3ARCN01|08D3ARCN02|08D3ARCN03|08D3ARCN04|"
    AUDOS_ISUZU_EXACT .= "|08D3ARCN05|08D3ARCN06|08D3ARCN07|08D3ARCN08|08D3ARCN09|08D3ARCN10|"
    AUDOS_ISUZU_EXACT .= "|08D3ARCN11|08D3ARCN12|08D3EGHT01|08D3EGHT02|08D4ARCN01|08D4ARCN02|"
    AUDOS_ISUZU_EXACT .= "|08D4ARCN03|08D4ARCN04|08D4ARCN05|08D4ARCN06|08D4ARCN07|08D4ARCN08|"
    AUDOS_ISUZU_EXACT .= "|08D4ARCN09|08D4ARCN10|08D4ARCN11|08D4ARCN12|08D4EGHT01|08D4EGHT02|"
    AUDOS_ISUZU_EXACT .= "|08D5ARCN01|08D5ARCN02|08D5ARCN03|08D5ARCN04|08D5ARCN05|08D5ARCN06|"
    AUDOS_ISUZU_EXACT .= "|08D5ARCN07|08D5ARCN08|08D5ARCN09|08D5ARCN10|08D5ARCN11|08D5ARCN12|"
    AUDOS_ISUZU_EXACT .= "|08D5EGHT01|08D5EGHT02|08D6EGHT02|08D7ARCN01|08D7ARCN02|08D7ARCN03|"
    AUDOS_ISUZU_EXACT .= "|08D7ARCN04|08D7ARCN05|08D7ARCN06|08D7ARCN07|08D7ARCN08|08D7ARCN09|"
    AUDOS_ISUZU_EXACT .= "|08D7ARCN10|08D7ARCN11|08D7ARCN12|08D7EGHT01|08D7EGHT02|08D8EGHT02|"
    AUDOS_ISUZU_EXACT .= "|08D9ARCN01|08D9ARCN02|08D9ARCN03|08D9ARCN04|08D9ARCN05|08D9ARCN06|"
    AUDOS_ISUZU_EXACT .= "|08D9ARCN07|08D9ARCN08|08D9EGHT02|08DSP01BL|08DSP01GS|08DSP01HB|"
    AUDOS_ISUZU_EXACT .= "|08DSP01LULS|08DSP01RWA|08DSP01RWB|08DSP01SD|08E0TMAT41|08E0TMAT42|"
    AUDOS_ISUZU_EXACT .= "|08E0TMAT43|08E0TMAT51|08E0TMAT52|08E0TMAT53|08E0TMAT61|08E0TMAT62|"
    AUDOS_ISUZU_EXACT .= "|08E0TMAT63|08S0TMAT41|08S0TMAT42|08S0TMAT43|08S0TMAT51|08S0TMAT52|"
    AUDOS_ISUZU_EXACT .= "|08S0TMAT53|08S0TMAT61|08S0TMAT62|08S0TMAT63|08S0TTST01|106928|"
    AUDOS_ISUZU_EXACT .= "|115149|116113|12010|123121|123127|1410-LB2-RC|32133|32140|32144|"
    AUDOS_ISUZU_EXACT .= "|32145|32147|32148|33100|33114|33118|33119|5123726001|5123726002|"
    AUDOS_ISUZU_EXACT .= "|5123726003|5143626001|5143626002|52110|52111|52113|5222618001|"
    AUDOS_ISUZU_EXACT .= "|5411689001D|5411689011D|5411689021D|5411689031D|5411689041D|"
    AUDOS_ISUZU_EXACT .= "|5411689051D|5411689061D|5411689071D|5421689001D|5421689011D|"
    AUDOS_ISUZU_EXACT .= "|5421689021D|5421689031D|5421689041D|5421689051D|5421689061D|"
    AUDOS_ISUZU_EXACT .= "|5421689071D|5431686210|5431686220|5431686230|5431686240|5431686260|"
    AUDOS_ISUZU_EXACT .= "|5431686270|5431686280|5431686290|5431686310|5431686320|5431686330|"
    AUDOS_ISUZU_EXACT .= "|5431686340|5431686350|5431689000|5431689001|5431689001D|5431689010|"
    AUDOS_ISUZU_EXACT .= "|5431689011|5431689011D|5431689020|5431689021|5431689021D|"
    AUDOS_ISUZU_EXACT .= "|5431689030|5431689031|5431689031D|5431689040|5431689041|"
    AUDOS_ISUZU_EXACT .= "|5431689041D|5431689050|5431689051|5431689051D|5431689060|"
    AUDOS_ISUZU_EXACT .= "|5431689061|5431689061D|5431689070|5431689071|5431689071D|"
    AUDOS_ISUZU_EXACT .= "|5432606000|5432606001|5432606010|5432606011|5432606020|5432606021|"
    AUDOS_ISUZU_EXACT .= "|5432606030|5432606031|5432606040|5432606041|5432606050|5432606051|"
    AUDOS_ISUZU_EXACT .= "|5432606070|5432606071|5432912010|5432915010|5432916530|570|572|576|"
    AUDOS_ISUZU_EXACT .= "|6111686110D|6111686120D|6111686130D|6111686140D|6111686150D|"
    AUDOS_ISUZU_EXACT .= "|6111686210D|6111686220D|6111686230D|6111686240D|6111686250D|"
    AUDOS_ISUZU_EXACT .= "|6121686110D|6121686120D|6121686130D|6121686140D|6121686150D|"
    AUDOS_ISUZU_EXACT .= "|6121686210D|6121686220D|6121686230D|6121686240D|6121686250D|"
    AUDOS_ISUZU_EXACT .= "|6131686110D|6131686120D|6131686130D|6131686140D|6131686150D|"
    AUDOS_ISUZU_EXACT .= "|6131686210D|6131686220D|6131686230D|6131686240D|6131686250D|62110|"
    AUDOS_ISUZU_EXACT .= "|62111|62113|6243636010|6322621260|6322623360|6322624460|6341621250|"
    AUDOS_ISUZU_EXACT .= "|6341624450|6341681210|6341684410|6441683310|9PMFDMAX4|A0556M0010|"
    AUDOS_ISUZU_EXACT .= "|A0556M0020|A0556M0021|A0556M0030|A0556M0031|A0556M0040|A0556M0041|"
    AUDOS_ISUZU_EXACT .= "|A0556M0080|A0556M0081|A0556M0090|A0556M0120|A0556M0150|A0556M0170|"
    AUDOS_ISUZU_EXACT .= "|A0556R0030|A0556R0031|A0556R0040|A0556R0041|A0556R0050|A0556R0051|"
    AUDOS_ISUZU_EXACT .= "|A0556R0150|A0556S0050|A0556S0060|A0562R0100-000|A0562R0100-527|"
    AUDOS_ISUZU_EXACT .= "|A0562R0100-554|A0562R0100-564|A0562R0100-568|A0562R0100-569|"
    AUDOS_ISUZU_EXACT .= "|A0562R0100-575|A0562R0100-587|A0562R0100-588|A0562R0110-000|"
    AUDOS_ISUZU_EXACT .= "|A0562R0110-527|A0562R0110-554|A0562R0110-564|A0562R0110-568|"
    AUDOS_ISUZU_EXACT .= "|A0562R0110-569|A0562R0110-575|A0562R0110-587|A0562R0110-588|"
    AUDOS_ISUZU_EXACT .= "|A0562R0300|A0562R0310|A0562R0320|A0562S0100-401|A0562S0110-401|"
    AUDOS_ISUZU_EXACT .= "|A0562S0350|A0575S0200-401|A0586R0010|A1390M0050|A1390M0080|"
    AUDOS_ISUZU_EXACT .= "|A1390M0100|A1924M0010|A1924M0020|CVC-IU-DX20-FSIEB|"
    AUDOS_ISUZU_EXACT .= "|CVC-IU-DX20-FSIEC|CVC-IU-DX20-HFSIE|CVC-IU-DX20-HFSIEB|"
    AUDOS_ISUZU_EXACT .= "|CVC-IU-DX20-HFSIEC|CVC-IU-DX20-SIEB|CVC-IU-DX20-SIEC|"
    AUDOS_ISUZU_EXACT .= "|CVC-IU-DX2020-FSIEB|CVC-IU-DX2020-FSIEC|CVC-IU-DX2020-SIEB|"
    AUDOS_ISUZU_EXACT .= "|CVC-IU-DX2020-SIEC|CVC-IU-MX25-HVFSI|CVC-IU-MX25-HVFSIEB|"
    AUDOS_ISUZU_EXACT .= "|CVC-IU-MX25-HVFSIEC|CVNG-HI-DC2012-FI|CVNG-HI-DC2012-FIEB|"
    AUDOS_ISUZU_EXACT .= "|CVNG-HI-DC2012-FIEC|CVNG-HI-DC2012-IEB|CVNG-HI-DC2012-IEC|"
    AUDOS_ISUZU_EXACT .= "|CVNG-IU-DX20-FSIE|CVNG-IU-DX20-FSIEB|CVNG-IU-DX20-FSIEC|"
    AUDOS_ISUZU_EXACT .= "|CVNG-IU-DX20-HFSI|CVNG-IU-DX20-HFSIEB|CVNG-IU-DX20-HFSIEC|"
    AUDOS_ISUZU_EXACT .= "|CVNG-IU-DX20-SIEB|CVNG-IU-DX20-SIEC|CVNG-IU-DX2020-FSIEB|"
    AUDOS_ISUZU_EXACT .= "|CVNG-IU-DX2020-FSIEC|CVNG-IU-DX2020-SIEB|CVNG-IU-DX2020-SIEC|"
    AUDOS_ISUZU_EXACT .= "|CVNG-IU-MX25-HVFS|CVNG-IU-MX25-HVFSIEB|CVNG-IU-MX25-HVFSIEC|"
    AUDOS_ISUZU_EXACT .= "|DNX9190DABS|E1345R0010|E1345R0020|E1345S0020|EVO-10-S-103253|"
    AUDOS_ISUZU_EXACT .= "|F0557M0010|F0557M0020|IUA1410-LB2-RC|IUA43RS3.5|IUA44RS3.5|"
    AUDOS_ISUZU_EXACT .= "|IULAT00010-1L|IULAT00010-5L|IULBK00010-500M|IULEN00010-1L|"
    AUDOS_ISUZU_EXACT .= "|IULEN00010-5L|IULGE00010-1L|IULGE00010-5L|IULLC00010-1L|"
    AUDOS_ISUZU_EXACT .= "|IULLC00010-5L|IUSP10000|IUSP105000|IUSP15000|IUSP20000|IUSP30000|"
    AUDOS_ISUZU_EXACT .= "|IUSP40000|IUSP45000|IUSP50000|IUSP60000|IUSP75000|IUSP90000|"
    AUDOS_ISUZU_EXACT .= "|IUWB161201|IUWB240101|JA9671|JB0019|JB1253|JB1379|JC-01256|"
    AUDOS_ISUZU_EXACT .= "|JC-01257|JC-01335|JC-01518|JC-01519|JC-01690|JC-01695N|JC-01806|"
    AUDOS_ISUZU_EXACT .= "|JC-02183|JC-02188|JC-02309|JC-04622|LB350|M063150100M|M063150100S|"
    AUDOS_ISUZU_EXACT .= "|M063210010M|M06321002008|M06321002012|M0632300102XL|M063230010L|"
    AUDOS_ISUZU_EXACT .= "|M063230010M|M063230010XL|M06323002008|M06323002012|M1063P0060-M|"
    AUDOS_ISUZU_EXACT .= "|M1063P0060-XL|M110150041|M110160050|M110160060|M110170020|"
    AUDOS_ISUZU_EXACT .= "|M142230100|M290170010|M850180010|M850210020|M850210030|M850210070|"
    AUDOS_ISUZU_EXACT .= "|M850220020|NAVIDVDAUDIE2001A|RBC050|S000000020|S103790010|"
    AUDOS_ISUZU_EXACT .= "|SPECACT50|SVC-03F-0003717|SVC-04D-0002266|SVC-04E-0003718|"
    AUDOS_ISUZU_EXACT .= "|SVC-10B-0002052AF|SVC-11A-0003609|SVC-11A-0003610|SVC-11B-0003611|"
    AUDOS_ISUZU_EXACT .= "|SVC-11B-0003612|SVC-12C-0001999|SVC-12H-0003716|SVC-12H-0003719|"
    AUDOS_ISUZU_EXACT .= "|SVC-12L-0003715|SVC-14A10003607|SVC-14A10003608|SVC-14A10004770|"
    AUDOS_ISUZU_EXACT .= "|SVC-14A10004775|SVC-14A10004776|SVC-14A10004777|SVC-14A10004778|"
    AUDOS_ISUZU_EXACT .= "|SVC-14A10004867|SVC-14A10004896|SVC-14A10005121|SVC-14A10005122|"
    AUDOS_ISUZU_EXACT .= "|SVC-14N-0004865|SVC-14N-0004866|SVC-14S-0004864|SVC-78G-0005041|"
    AUDOS_ISUZU_EXACT .= "|SVC-A08-0001886|SVC-A08-0001887|SVC-A08-0001888|SVC-A08-0001889|"
    AUDOS_ISUZU_EXACT .= "|SVC-F08-0003602|SVC-F08-0003603|SVC-F08-0003604|SVC-F08-0003605|"
    AUDOS_ISUZU_EXACT .= "|SVC-H08-0003606|SVC-J2160001940|SVC-M08-0004271|T0900R0010|"
    AUDOS_ISUZU_EXACT .= "|T1380S0010|TF-IE-2321AU-1ST|TFIE1542AU|WAG-00A-0002074|"
    AUDOS_ISUZU_EXACT .= "|WAG-00A-0004503|WAG-00A-004503|WAG-10B-0002052AF|WAG-10B-0002054|"
    AUDOS_ISUZU_EXACT .= "|WAG-12G-0002000|WAG-14A10001876|WAG-14A10001877|WAG-14A10003619|"
    AUDOS_ISUZU_EXACT .= "|WAG-14A10003620|WAG-14F-0001895|WAG-14F-0002672|WAG-14N-0001890|"
    AUDOS_ISUZU_EXACT .= "|WAG-14N-0001891|WAG-14N-0004548|WAG-14N-0004681|WAG-14S-0001892|"
    AUDOS_ISUZU_EXACT .= "|WAG-14S-0004335|WAG-H08-0003508|WAG-H08-0003509|WAG-H08-0003510|"
    AUDOS_ISUZU_EXACT .= "|WAG-H08-0003569|WAG-T06-0001939|WAG-T07-0001941|WAG-T07-0003985|"
    AUDOS_ISUZU_EXACT .= "|WAG-T07-0003986|X1345K0010|"

    ;--- the Isuzu lookup window --------------------------------------------
    ; Isuzu does not live in AUDOS at all. It has its own tool, and the part
    ; goes into the Parts tab there.
    ;
    ; Matched on the words only, never the version, so v1.9 becoming v2.0
    ; does not quietly break this. Needs SetTitleMatchMode 2 - the lookup
    ; sets it and puts it back.
    AUDOS_ISUZU_TITLE  := "Isuzu Parts & VIN Lookup"

    ; Where to launch it from if it is not already open.
    ;
    ; Careful: IsuzuVIN.ahk is #SingleInstance Force, which means launching a
    ; second copy KILLS the one already running - and takes its signed-in
    ; session with it, which is the thing that makes lookups sub-second. So
    ; this only ever runs when no window could be found.
    AUDOS_ISUZU_SCRIPT := A_ScriptDir "\IsuzuVIN\IsuzuVIN.ahk"
    AUDOS_ISUZU_EXE    := A_ProgramFiles "\AutoHotkey\AutoHotkeyU64.exe"

    ; How long to wait for that window after launching it. Signing in takes
    ; longer than this, but it does not need to finish - the tool remembers a
    ; lookup typed during warm-up and runs it once sign-in is done.
    AUDOS_ISUZU_WAIT_MS := 15000

    ; How long to keep trying to get the Look up button to actually take.
    ; The usual reason it does not is that the tool is still finishing the
    ; lookup before this one, which it refuses rather than queues, so this
    ; wants to be long enough to outlast a slow lookup.
    AUDOS_ISUZU_PRESS_MS := 20000

    ; What the Isuzu tool says about itself, in its own words. Taken from the
    ; SetStatus calls in IsuzuVIN.ahk. Three groups matter:
    ;
    ;   RUNNING   it took the lookup. "Signing in - your lookup will run"
    ;             counts, that is the queue-it-for-later answer, and so does
    ;             a saved copy going up while it checks for a newer one.
    ;   BUSY      it turned the lookup down because another one is in flight.
    ;             Wait and press again - this is the whole reason this exists.
    ;   BROKEN    no amount of pressing will help. Stop and say so.
    ;
    ; ANY is just all of them, used to pick the status line out of the window
    ; by what it says rather than by a control number that moves per version.
    AUDOS_ISUZU_ST_RUN := "i)looking up|showing your saved copy|no record found"
                        . "|your lookup will run|number was replaced|did not come back"
    AUDOS_ISUZU_ST_BUSY := "i)one moment - finishing|another lookup is already"
                         . "|^busy -|another isuzuvin process"
    AUDOS_ISUZU_ST_BAD := "i)could not open|could not start|sign-in failed"
                        . "|sign-in refused|session is down|something went wrong"
    AUDOS_ISUZU_ST_ANY := "i)looking up|showing your saved copy|no record found"
                        . "|your lookup will run|number was replaced|did not come back"
                        . "|one moment - finishing|another lookup is already|^busy -"
                        . "|another isuzuvin process|could not open|could not start"
                        . "|sign-in failed|sign-in refused|session is down"
                        . "|something went wrong|ready|starting up|signing in"
                        . "|signed in|kept awake"
                        . "|checking the session|session is good"

    ; Which AUDOS window BYD parts belong in.
    ;
    ; UNCONFIRMED - BYD parts share the DMS with Kia and Hyundai (the pad
    ; lists KI, HY, NG, BY and IA side by side), but nobody has said which
    ; window to open for them. Kia is a placeholder. Change the word if it
    ; should be "Hyundai".
    AUDOS_BYD_TARGET := "Kia"

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
                 . "`nCtrl+Left click = part lookup, brand picked for you"
                 . "`nCtrl+Shift+Left click = force Isuzu"
                 . "`nCtrl+Right click = part lookup in Hyundai"
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
; Ctrl+Left click works out the brand from the number itself - BYD, then
; Isuzu, then Kia as the catch-all - and opens whichever one it lands on.
^LButton::AUDOS_SmartPartLookup()

; Ctrl+Shift+Left click forces Isuzu, skipping the deciding entirely.
;
; This is here for the Isuzu numbers that carry letters, like F0557M0020.
; They are rare and they share no shape with each other, so there is nothing
; honest to pattern-match on - left alone they read as Kia. Rather than guess
; at a rule that would start stealing real Kia numbers, this says so outright.
^+LButton::AUDOS_SmartPartLookup("Isuzu")

^RButton::AUDOS_PartLookup("Hyundai")

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
;-----------------------------------------------------------------------------
;   Find a brand's AUDOS window, without complaining if it is not there.
;
;   Nothing found on the first go usually means the remembered answer is
;   stale because AUDOS was closed and reopened, so wipe the memory and look
;   again from scratch before giving up. Returns 0 if the window really is
;   not open. AUDOS_Activate puts a message box on top of this; callers that
;   only want to know whether the window exists should use this instead.
;-----------------------------------------------------------------------------
AUDOS_HwndFresh(brand) {
    hwnd := AUDOS_Hwnd(brand)
    if (!hwnd) {
        AUDOS_ClearCache()
        hwnd := AUDOS_Hwnd(brand)
    }
    return hwnd
}


AUDOS_Activate(brand) {
    hwnd := AUDOS_HwndFresh(brand)
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
;   Work out which brand a part number belongs to.
;
;   Returns "BYD", "Isuzu" or "Kia". Never returns anything else - Kia is the
;   catch-all, so an unrecognised number goes there rather than nowhere.
;
;       AUDOS_BrandOfPart("13964302-00")  ->  "BYD"
;       AUDOS_BrandOfPart("8982924820")   ->  "Isuzu"
;       AUDOS_BrandOfPart("8-98292482-0") ->  "Isuzu"   (scanner form)
;       AUDOS_BrandOfPart("99241M6500")   ->  "Kia"
;-----------------------------------------------------------------------------
AUDOS_BrandOfPart(part) {
    global AUDOS_ISUZU_P2, AUDOS_ISUZU_P3, AUDOS_ISUZU_P4, AUDOS_ISUZU_EXACT
    AUDOS_Init()

    ; Spaces can come along for the ride when a number is copied out of a
    ; document, and barcode scanners put an AIM symbology tag on the front.
    p := RegExReplace(Trim(part), "\s", "")
    StringUpper, p, p
    p := RegExReplace(p, "i)^(\]C1|\]d2|\]Q3|\]e0|\]I0|\]A0)", "")
    if (p = "")
        return "Kia"

    ;--- 1. BYD -------------------------------------------------------------
    ; Eight digits then -00. The -00 is the giveaway: 1332 of the 1336 BYD
    ; numbers in the pad have it and nothing else in any brand does.
    ;
    ; This has to run before Isuzu. Strip the dash out of 13964302-00 and you
    ; are left with ten digits, which is exactly the shape Isuzu claims.
    if (RegExMatch(p, "^[0-9]{6,}-00$"))
        return "BYD"

    ;--- 2. Isuzu -----------------------------------------------------------
    ; Named numbers first. These are Isuzu parts the shape rules below cannot
    ; work out, so they are matched by name and nothing else. The pipes on
    ; both sides keep it an exact match - without them 8973 would match
    ; anything containing 8973.
    d := StrReplace(p, "-", "")
    if (InStr(AUDOS_ISUZU_EXACT, "|" p "|"))
        return "Isuzu"
    if (InStr(AUDOS_ISUZU_EXACT, "|" d "|"))
        return "Isuzu"

    ; The scanner spells Isuzu numbers 8-98292482-0. Written down they lose
    ; the dashes and become 8982924820 - the same number either way.
    if (RegExMatch(p, "^\d-\d{8}-\d$"))
        return "Isuzu"

    if (RegExMatch(d, "^\d{10}$")) {
        ; Leading digits are a real Isuzu family code - 8-9xxxxxxx-x is the
        ; genuine parts series - which is why they separate the two brands so
        ; well. Two digits settles nearly everything; the seven pairs both
        ; brands share get a second look at three.
        if (InStr(AUDOS_ISUZU_P2, "|" SubStr(d, 1, 2) "|"))
            return "Isuzu"
        if (InStr(AUDOS_ISUZU_P3, "|" SubStr(d, 1, 3) "|"))
            return "Isuzu"
        ; 187 and 545 are shared even at three digits. Four settles them.
        if (InStr(AUDOS_ISUZU_P4, "|" SubStr(d, 1, 4) "|"))
            return "Isuzu"
    }

    ;--- 3. Kia -------------------------------------------------------------
    ; Everything left over. Kia numbers nearly always carry a letter
    ; (99241M6500, 81750-3W000WK), and no Isuzu rule above touches those.
    return "Kia"
}


;-----------------------------------------------------------------------------
;   Look a part number up in the Isuzu tool.
;
;   Finds its window, opens it if it is not running, puts the part number in
;   the Parts tab and presses Look up. Returns true if the lookup was fired.
;-----------------------------------------------------------------------------
AUDOS_IsuzuLookup(part) {
    global AUDOS_ISUZU_TITLE, AUDOS_ISUZU_SCRIPT, AUDOS_ISUZU_EXE
    global AUDOS_ISUZU_WAIT_MS
    AUDOS_Init()

    prevMatch := A_TitleMatchMode
    SetTitleMatchMode, 2                 ; match on the words, not the version

    hwnd := WinExist(AUDOS_ISUZU_TITLE)

    ;--- not open? start it -------------------------------------------------
    ; Only ever from here. IsuzuVIN.ahk is #SingleInstance Force, so running
    ; it while a copy is already up would kill the live signed-in session.
    if (!hwnd) {
        if (!FileExist(AUDOS_ISUZU_SCRIPT)) {
            SetTitleMatchMode, %prevMatch%
            MsgBox, 48, AUDOS Switch
                , % "The Isuzu lookup is not running, and it is not where I "
                  . "expected to find it:`n`n" AUDOS_ISUZU_SCRIPT
                  . "`n`nOpen it yourself and try again."
            return false
        }

        ; It reads and writes its cache, chrome profile and session log beside
        ; itself, so it has to start in its own folder.
        SplitPath, AUDOS_ISUZU_SCRIPT, , isuzuDir
        Run, % """" AUDOS_ISUZU_EXE """ """ AUDOS_ISUZU_SCRIPT """"
            , % isuzuDir, UseErrorLevel

        if (ErrorLevel) {
            SetTitleMatchMode, %prevMatch%
            MsgBox, 48, AUDOS Switch
                , % "Could not start the Isuzu lookup:`n`n" AUDOS_ISUZU_SCRIPT
            return false
        }

        WinWait, % AUDOS_ISUZU_TITLE, , % AUDOS_ISUZU_WAIT_MS / 1000
        if (ErrorLevel) {
            SetTitleMatchMode, %prevMatch%
            MsgBox, 48, AUDOS Switch
                , % "The Isuzu lookup did not open within "
                  . Round(AUDOS_ISUZU_WAIT_MS / 1000) " seconds."
            return false
        }
        hwnd := WinExist(AUDOS_ISUZU_TITLE)
    }

    SetTitleMatchMode, %prevMatch%
    if (!hwnd)
        return false

    ; Bring it up first. You want to watch the answer arrive, and it also
    ; means the tab control is in a fit state to take a keystroke.
    WinActivate, ahk_id %hwnd%
    WinWaitActive, ahk_id %hwnd%, , 2

    ;--- make sure the Parts tab is the one showing -------------------------
    ; This matters more than it looks. The tool has one Look up handler for
    ; both tabs and it decides which box to read by asking which tab is
    ; selected - so a part number typed in while the Vehicle tab is up gets
    ; run as a VIN. Edit1 is the part number box, and it is only visible on
    ; the Parts tab, so its visibility is the honest answer to "which tab".
    if (!AUDOS_IsuzuPartsTabUp(hwnd)) {
        ; Home selects the first tab AND tells the tool about it, which a
        ; plain TCM_SETCURSEL would not - that would leave its own idea of
        ; the current tab stale.
        ControlFocus, SysTabControl321, ahk_id %hwnd%
        ControlSend, SysTabControl321, {Home}, ahk_id %hwnd%

        ; Give the tab switch a moment to actually land.
        Loop, 20
        {
            if (AUDOS_IsuzuPartsTabUp(hwnd))
                break
            Sleep, 50
        }
    }

    if (!AUDOS_IsuzuPartsTabUp(hwnd)) {
        MsgBox, 48, AUDOS Switch
            , % "Could not get the Isuzu window onto its Parts tab, so I have "
              . "not typed anything.`n`nClick the Parts tab and try again."
        return false
    }

    ;--- the part number ----------------------------------------------------
    ; ControlSetText replaces whatever was in the box, so this clears the last
    ; part number and puts the new one in as one step.
    ;
    ; Nothing on the clipboard: leave the cursor in the box so you can type it
    ; yourself, the same as the AUDOS lookup does.
    if (part = "") {
        ControlFocus, Edit1, ahk_id %hwnd%
        return false
    }

    ; Put the number in, and check it actually arrived before pressing
    ; anything - a Look up on a half-written box is worse than no Look up.
    Loop, 10
    {
        ControlSetText, Edit1, %part%, ahk_id %hwnd%
        ControlGetText, got, Edit1, ahk_id %hwnd%
        if (Trim(got) = part)
            break
        Sleep, 30
    }

    return AUDOS_IsuzuPress(hwnd, part)
}


;-----------------------------------------------------------------------------
;   Read the Isuzu tool's status line.
;
;   Found by what it says rather than by its control number, because the
;   control numbers move whenever the window gains or loses a label and this
;   has to keep working across versions of the tool.
;-----------------------------------------------------------------------------
AUDOS_IsuzuStatusCtl(hwnd) {
    global AUDOS_ISUZU_ST_ANY
    AUDOS_Init()

    WinGet, list, ControlList, ahk_id %hwnd%
    last := ""
    Loop, Parse, list, `n
    {
        if (SubStr(A_LoopField, 1, 6) != "Static")
            continue
        last := A_LoopField
        ControlGetText, txt, %A_LoopField%, ahk_id %hwnd%
        if (RegExMatch(txt, AUDOS_ISUZU_ST_ANY))
            return A_LoopField
    }

    ; Nothing recognisable - the tool may be saying something new. Its status
    ; line is built last of all, so the last label is the safe guess.
    return last
}


AUDOS_IsuzuStatus(hwnd) {
    ctl := AUDOS_IsuzuStatusCtl(hwnd)
    if (ctl = "")
        return ""
    ControlGetText, txt, %ctl%, ahk_id %hwnd%
    return txt
}


;-----------------------------------------------------------------------------
;   Press Look up, and keep pressing until the tool admits it heard us.
;
;   The click almost always lands. What goes wrong is that the tool turns it
;   down: DoLookup starts with a busy guard, and mid-lookup it answers "One
;   moment - finishing the last lookup..." and drops the request on the
;   floor. Nothing about the window changes except that one line of text, so
;   from the outside it looks exactly like a button press that missed - the
;   new number is sitting in the box and nothing is happening.
;
;   So: press, then read the status line back.
;
;       looking up / signing in   it took it. Signing in means it queued the
;                                 lookup for when warm-up finishes, which is
;                                 as good as running it.
;       one moment                it refused. Wait for the last lookup to
;                                 finish and press again.
;       anything else             the press did not register. Try again by
;                                 another route.
;
;   Three routes, because they fail differently. A posted click is quietest
;   but is the one that goes missing; Enter works because Look up is the
;   default button, so it fires even if the button itself never sees a mouse
;   message; a plain click moves the real cursor and is the last resort.
;-----------------------------------------------------------------------------
AUDOS_IsuzuPress(hwnd, part) {
    global AUDOS_ISUZU_PRESS_MS, AUDOS_ISUZU_ST_RUN
    global AUDOS_ISUZU_ST_BUSY, AUDOS_ISUZU_ST_BAD
    AUDOS_Init()

    ; What it was saying before we touched anything. Some of its running
    ; messages - "Showing your saved copy from ..." - do not name the part,
    ; so on their own they cannot tell our lookup from the one before it.
    ; Keeping the old line means we can insist something actually changed.
    ; Finding the status line means reading every label in the window, which
    ; costs about a third of a second - far too dear to do twenty times a
    ; second. Find it once, then read only that control.
    stCtl  := AUDOS_IsuzuStatusCtl(hwnd)
    before := ""
    if (stCtl != "")
        ControlGetText, before, %stCtl%, ahk_id %hwnd%

    deadline := A_TickCount + AUDOS_ISUZU_PRESS_MS
    attempt  := 0

    Loop
    {
        attempt++
        if (Mod(attempt, 3) = 1)
            ControlClick, Button1, ahk_id %hwnd%, , , , NA
        else if (Mod(attempt, 3) = 2) {
            ControlFocus, Edit1, ahk_id %hwnd%
            ControlSend, Edit1, {Enter}, ahk_id %hwnd%
        } else {
            ControlClick, Button1, ahk_id %hwnd%
        }

        ; Give this attempt a second to show up in the status line.
        Loop, 20
        {
            Sleep, 50
            if (stCtl != "")
                ControlGetText, st, %stCtl%, ahk_id %hwnd%
            else
                st := AUDOS_IsuzuStatus(hwnd)

            ; "Looking up 8982924820 ..." names the part, so it can only be
            ; about ours.
            if (InStr(st, part) && RegExMatch(st, AUDOS_ISUZU_ST_RUN))
                return true

            ; A running message that does not name the part only counts if
            ; the line actually changed - otherwise it is last time's.
            if (st != before && RegExMatch(st, AUDOS_ISUZU_ST_RUN))
                return true

            if (RegExMatch(st, AUDOS_ISUZU_ST_BUSY))
                break            ; busy, not deaf - wait and press again

            ; Signed out, offline, browser gone - pressing will not fix any
            ; of these, so stop rather than hammer it for fifteen seconds.
            if (RegExMatch(st, AUDOS_ISUZU_ST_BAD)) {
                MsgBox, 48, AUDOS Switch
                    , % "The Isuzu tool cannot look anything up right now."
                      . "`n`nIt says: " st
                return false
            }
        }

        ; Reading every label is dear, so this runs once per attempt rather
        ; than on every poll. It catches the case where the answer arrived
        ; without us seeing the status line change on the way past.
        if (AUDOS_IsuzuShowing(hwnd, part))
            return true

        if (A_TickCount > deadline)
            break
        Sleep, 250
    }

    MsgBox, 48, AUDOS Switch
        , % "The Isuzu tool would not start the lookup for " part " within "
          . Round(AUDOS_ISUZU_PRESS_MS / 1000) " seconds.`n`nThe number is in "
          . "the box - press Look up yourself.`n`nLast thing it said: "
          . AUDOS_IsuzuStatus(hwnd)
    return false
}


;-----------------------------------------------------------------------------
;   Is the tool already showing the answer for this part number?
;
;   The result heading is a plain label holding the part number on its own,
;   so a label whose whole text is the number we asked for means the answer
;   is up. The part number box is skipped - we put that there ourselves.
;-----------------------------------------------------------------------------
AUDOS_IsuzuShowing(hwnd, part) {
    WinGet, list, ControlList, ahk_id %hwnd%
    Loop, Parse, list, `n
    {
        if (SubStr(A_LoopField, 1, 6) != "Static")
            continue
        ControlGetText, txt, %A_LoopField%, ahk_id %hwnd%
        if (Trim(txt) = part)
            return true
    }
    return false
}


;-----------------------------------------------------------------------------
;   Is the Isuzu window showing its Parts tab?
;
;   Answered by whether the part number box is visible, not by asking the tab
;   control - a hidden control still exists and still reports a width, which
;   is exactly the trap that makes tab state look right when it is not.
;-----------------------------------------------------------------------------
AUDOS_IsuzuPartsTabUp(hwnd) {
    ControlGet, vis, Visible, , Edit1, ahk_id %hwnd%
    return (!ErrorLevel && vis)
}


;-----------------------------------------------------------------------------
;   Ctrl+Left click. Reads the clipboard, works out the brand, sends it there.
;
;   force: "" to decide from the number, or a brand name to skip the deciding.
;-----------------------------------------------------------------------------
AUDOS_SmartPartLookup(force := "") {
    global AUDOS_BYD_TARGET
    AUDOS_Init()

    part  := Trim(Clipboard, " `t`r`n")
    brand := (force != "") ? force : AUDOS_BrandOfPart(part)

    if (brand = "Isuzu") {
        AUDOS_IsuzuLookup(part)
        return
    }

    ; BYD and Kia are both AUDOS windows, so they go the existing way.
    target := (brand = "BYD") ? AUDOS_BYD_TARGET : "Kia"

    ; Kia is the catch-all, not a positive answer - a number lands there
    ; because nothing else claimed it, not because it looks like a Kia part.
    ; So if the AUDOS window is not even open, "Kia window not found" is the
    ; wrong thing to say: the number is at least as likely to be an Isuzu one
    ; the rules did not recognise. Send it to the Isuzu tool instead, which
    ; will either find it or say it cannot - both more use than a popup.
    ;
    ; Only when the brand was guessed. Ctrl+Shift+Left names the brand
    ; outright, and that answer is left alone.
    if (force = "" && !AUDOS_HwndFresh(target)) {
        AUDOS_IsuzuLookup(part)
        return
    }

    AUDOS_PartLookup(target)
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
    body .= "Ctrl+Left click       part lookup - BYD, Isuzu or Kia,`n"
    body .= "                      picked from the number itself`n"
    body .= "Ctrl+Shift+Left click force Isuzu (for lettered numbers)`n"
    body .= "Ctrl+Right click      part lookup in Hyundai"
    MsgBox, 64, AUDOS Switch, %body%
}
