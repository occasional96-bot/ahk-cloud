#NoEnv
#SingleInstance, Force
#Persistent
SetBatchLines, -1
SetWorkingDir, %A_ScriptDir%
SetTitleMatchMode, 2
CoordMode, Mouse, Screen
CoordMode, ToolTip, Screen   ; without this a tooltip is placed relative to
                             ; the active window, not the desktop, and lands
                             ; nowhere near the pointer

;=============================================================================
;   EraWord.ahk - double click a part number in ERA and it highlights itself.
;
;   ERA only lets you select by dragging. This makes a double click pick out
;   whatever is under the mouse - a part number, a VIN, an invoice number, a
;   single word out of a description - highlight it the same way a drag would,
;   and put it on the clipboard.
;
;   The click still goes through to ERA untouched, so nothing ERA already does
;   with a double click is taken away from it.
;
;-----------------------------------------------------------------------------
;   HOW A PIXEL BECOMES A CHARACTER
;
;   A terminal screen is a grid. Every character is the same size, so the
;   character under the mouse is just arithmetic - as long as you know how big
;   one cell is, and that is the part worth getting right.
;
;   It is not hardcoded, because it changes with the font and the window size.
;   It is worked out fresh each time, from two things we can both measure:
;
;     THE GRID          F11 gives us the screen as text. The longest line is
;                       how many columns there are, the number of lines is how
;                       many rows.
;
;     THE CANVAS        The terminal is its own child window - the one that
;                       fills the space between the toolbars and the status
;                       bar. Windows will tell us its client size exactly.
;
;   The column under the mouse is then a proportion, not a division: how far
;   across the canvas the mouse is, times how many columns there are. Worked
;   as one sum - offset times columns, divided by width - nothing is rounded
;   until the very end, so the answer is exact everywhere on the screen.
;
;   It used to be done the other way round: divide the canvas by the columns
;   first to get one cell's width, then divide the mouse offset by that. On a
;   machine where the division comes out whole - 800 / 80 = 10 - the two are
;   identical. On a machine where it does not, DPI scaling being the usual
;   reason, the cell width got rounded down and the error grew a little with
;   every column, until far enough right it picked the wrong word. That is the
;   fault this order of operations removes.
;
;   The candidate sizes still get checked against the canvas: a terminal lays
;   its grid out on whole pixels, so on an unscaled machine the true column
;   count divides the canvas evenly and a wrong guess does not. The code tries
;   80 and 132 columns, and 24, 25, 43 and 50 rows, and prefers whichever
;   divides cleanly - falling back to the smallest size that can hold what is
;   on screen when, as on a scaled machine, nothing divides exactly.
;
;-----------------------------------------------------------------------------
;   HOW THE HIGHLIGHT HAPPENS
;
;   By dragging, exactly like you would. Mouse down on the first character of
;   the word, across to the last one, mouse up. ERA does its own selecting, so
;   the highlight you get is a real ERA highlight and not a picture of one
;   painted over the top.
;
;   The word goes on the clipboard from here rather than by pressing ERA's own
;   Copy button. We are the one who worked out where the word starts and ends,
;   so we already know it exactly - asking ERA to hand it back would cost
;   another click into ERA and another wait, and could not tell us anything we
;   did not already know.
;
;   The mouse is put back where you left it, and a small tooltip shows what
;   was copied. Reading the screen with F11 happens quietly - no tooltip for
;   that, only for the copy.
;=============================================================================


;--- settings ---------------------------------------------------------------

global EW_ERA_EXE   := "wInteg.exe"     ; the ERA terminal
global EW_ERA_TITLE := "ERA Port"       ; and the words in its title

; Which click picks a word out. "" is a plain double click. Put "^" here for
; Ctrl + double click, "+" for Shift, if you would rather keep the plain one
; for ERA itself.
global EW_MODIFIER  := ""

global EW_DOUBLE_MS := 400   ; two clicks closer together than this is a
                             ; double click. Windows uses 500 by default.

global EW_RESTORE_MOUSE := true        ; put the pointer back afterwards

; How the drag is walked across the word. ERA paints the highlight from the
; mouse moves it is given, so it can only highlight as far as it was told
; about - too few steps, or steps too close together to be processed, and you
; get half a word highlighted even though the right word was copied.
;
; Windows coalesces mouse movement, so what matters is not how many moves we
; send but how many ERA gets round to reading. One stop per character with a
; real pause at each gives it no chance to skip any.
global EW_DRAG_POST    := false ; post the drag at the terminal as mouse
                               ; messages instead of moving the real pointer.
                               ; Faster, and it leaves your pointer alone.
                               ; Set false to go back to moving the pointer.
global EW_POST_MS      := 5   ; pause between posted moves. Posted messages
                              ; queue in order and are not thrown away, but a
                              ; beat between them gives ERA time to paint each
                              ; one before the next arrives.
global EW_POST_DOWN_MS := 30  ; pause after the move that walks the pointer
                              ; to the start of the word, and again after the
                              ; button-down that anchors the drag there.
                              ; Gives ERA time to take the anchor from where
                              ; we said rather than where your click left it,
                              ; so the first character is not left out of the
                              ; highlight.

global EW_DRAG_STEPS   := 0   ; 0 = one stop per character. A number forces
                              ; that many stops instead, whatever the length.
global EW_DRAG_MS      := 2  ; how long the pointer waits at each stop. The
                              ; stops are what matter, not the wait - the whole
                              ; word still lights up at 8, so this is margin.
global EW_DRAG_HOLD_MS := 70  ; and how long it waits on the last character
                              ; before the button comes back up, so the final
                              ; move is read before the selection is settled

global EW_OVERLAY   := true  ; paint the highlight ourselves - an overlay
                             ; window over the word - instead of dragging
                             ; ERA's own selection into place. ERA parks its
                             ; block caret on the cell you clicked and paints
                             ; it over any selection, so its own highlight
                             ; always showed a hole at the character you
                             ; clicked on. The overlay has no hole and costs
                             ; no time. It leaves ERA's caret and selection
                             ; completely alone. Set false for the old drag.

global EW_TIP       := true  ; show what was copied, at the pointer
global EW_TIP_MS    := 1200  ; and take it away again after this long
global EW_TIP_DX    := 12    ; where the tooltip sits, measured from the
global EW_TIP_DY    := 19    ; point of the arrow. This puts its corner at the
                             ; bottom right tip of the cursor, so it hangs off
                             ; the pointer and leaves the word readable.

global EW_SETTLE_MS := 20    ; how long after your button comes up before we
                             ; press anything of our own. Counted from the
                             ; release, so a slow click does not push it out.
                             ; Measured with injected input, the drag survives
                             ; even with no pause at all and the button still
                             ; held, so this is insurance rather than need.

global EW_DEBUG     := false   ; write what the drag did to eraword_debug.txt

; Characters that are part of a word. Everything else ends it. Note that the
; box drawing bar is deliberately NOT in here, so |87370P1200BKL gives you the
; part number without the bar.
global EW_WORD_RE   := "[A-Za-z0-9]|[\-\.\/_#\*]"

; Cross reference screens carry the make code on the front of the part
; number, run together as one word: KIAK0C0WS005 is make KI, part AK0C0WS005.
; The make is on the screen because you asked for that make - it is not part
; of what you are copying, so it comes off.
;
; Only on that screen, and only in that column. A part number anywhere else
; is taken exactly as it reads.
global EW_STRIP_MAKE   := true
global EW_STRIP_SCREEN := "Description Cross Reference"  ; the heading that
                                                         ; says which screen
global EW_STRIP_COL    := "Part#"        ; the column heading it sits under
global EW_STRIP_NEXT   := "Description"  ; and the next one along, which is
                                         ; where that column stops
global EW_STRIP_LEN    := 2              ; how long the make code is


;--- state ------------------------------------------------------------------

global gEW_Busy := false
global gEW_ClickTick := 0      ; when your second click went down. The drag
                               ; has to wait out Windows' double click time
                               ; from here - see EW_PickWord.


;--- the hotkey -------------------------------------------------------------
;
;   The tilde means ERA still gets the click. We are listening in, not
;   standing in the way.
;
Hotkey, % "~" EW_MODIFIER "LButton", EW_Click
return

EW_Click:
    EW_OnClick()
return


;=============================================================================
;   A CLICK
;
;   Two clicks in quick succession, both inside the terminal, is our cue.
;   Anything else is left alone.
;=============================================================================
EW_OnClick() {
    global gEW_Busy, EW_DOUBLE_MS, gEW_ClickTick
    global EW_ERA_EXE, EW_ERA_TITLE
    static lastTick := 0, lastX := 0, lastY := 0

    if (gEW_Busy)
        return

    ; Any click takes the overlay highlight down, the same way a click takes
    ; a real ERA selection down.
    Gui, EWHL:Destroy

    MouseGetPos, mx, my

    tick := A_TickCount
    near := (Abs(mx - lastX) <= 4 && Abs(my - lastY) <= 4)
    isDouble := (tick - lastTick <= EW_DOUBLE_MS) && near

    lastTick := tick, lastX := mx, lastY := my
    if (!isDouble)
        return

    lastTick := 0            ; so a third click does not fire a second time

    ; Only when ERA is the window you are working in. A double click in some
    ; other program that happens to sit over the terminal is that program's
    ; business, not ours. Checked here, after the double is recognised, so
    ; single clicks - which is nearly all of them - cost nothing.
    if (!WinActive(EW_ERA_TITLE . " ahk_exe " . EW_ERA_EXE))
        return

    gEW_ClickTick := tick
    gEW_Busy := true
    EW_PickWord(mx, my)
    gEW_Busy := false
}


;=============================================================================
;   THE WORK
;=============================================================================
EW_PickWord(mx, my) {
    global EW_RESTORE_MOUSE, EW_DRAG_STEPS, EW_DRAG_MS, EW_DRAG_HOLD_MS
    global EW_OVERLAY
    global EW_DRAG_POST, EW_POST_MS, EW_POST_DOWN_MS, gEW_ClickTick
    global EW_DEBUG, EW_SETTLE_MS
    global EW_ERA_EXE, EW_ERA_TITLE

    ; The window you are in, not merely an ERA window that exists somewhere.
    ; EW_OnClick already insisted ERA is active before calling us, so this is
    ; how we pick the right one when more than one is open, as much as a
    ; second check.
    era := WinActive(EW_ERA_TITLE . " ahk_exe " . EW_ERA_EXE)
    if (!era)
        return

    term := EW_Terminal(era)
    if (!term)
        return

    ; Where the canvas is and how big it is - the client area, in screen
    ; coordinates, because that is the space the mouse position is in. Client
    ; rather than window so that a border, if the canvas ever grows one, does
    ; not shift every cell over by its width.
    if (!EW_ClientRect(term, tx, ty, tw, th))
        return

    ; Was the click actually on the terminal, or on a toolbar?
    if (mx < tx || mx >= tx + tw || my < ty || my >= ty + th)
        return

    ; F11 hands back whatever is selected if anything IS selected, and only
    ; falls back to the whole screen when nothing is. So a highlight left over
    ; from last time would come back instead of the screen. One click clears
    ; it - which is exactly what your own click did a moment ago, so in normal
    ; use this second attempt never happens.
    screen := EW_Screen(era)
    if (!EW_LooksLikeScreen(screen)) {
        MouseMove, mx, my, 0
        Click
        Sleep, 40
        screen := EW_Screen(era)
    }
    if (!EW_LooksLikeScreen(screen))
        return

    lines := EW_Lines(screen)
    grid  := EW_Grid(tw, th, lines)
    if (!IsObject(grid))
        return

    ; Which cell is that? A proportion, worked as one sum so nothing is
    ; rounded until the end. Dividing the canvas into a cell size first and
    ; then dividing by that loses a fraction of a pixel per cell whenever the
    ; canvas does not divide evenly - which it does not on a DPI scaled
    ; machine - and the loss compounds across the screen until the far side
    ; is a whole cell out. This way it cannot.
    col := ((mx - tx) * grid.cols) // tw
    row := ((my - ty) * grid.rows) // th

    span := EW_WordAt(lines, row, col)
    if (!IsObject(span))
        return                       ; clicked on a space, or past the text

    ; Drag from the left edge of the first character to the right edge of the
    ; last one.
    ;
    ; ERA snaps each end of the selection to the nearest character boundary,
    ; not to the character the pointer is over. Start from the middle of the
    ; first cell and it rounds forward to the boundary on the right, and the
    ; first character is left out. So aim just inside each outer edge - far
    ; enough in to be unambiguously this character, close enough to the edge
    ; to round the way we want at both ends.
    ;
    ; How far in is measured off the cell, not fixed in pixels. A quarter of
    ; a cell stays on the right side of the midpoint whatever size the cell
    ; is; a fixed two pixels was fine at 80 columns but on a narrow DPI
    ; scaled cell it could land past the middle, ERA would snap forward, and
    ; the first character was left out of the highlight.
    ; The same proportional sum as above, run the other way: cell to pixel
    ; instead of pixel to cell.
    pad := tw // (grid.cols * 4)
    if (pad < 1)
        pad := 1

    ; The left end goes EXACTLY on the boundary between the space and the
    ; first character - not a couple of pixels inside the character, as it
    ; used to. Measurement showed ERA rounding the anchor up to the next
    ; boundary: anchored 2px inside the first cell, the selection started one
    ; character late, every time, and no amount of timing changed it. The
    ; boundary itself is the one x that every rounding rule - up, down or
    ; nearest - agrees belongs to the first character's edge.
    ; The right end stays just inside the last character, where rounding up
    ; gives that character's right edge, which is what we want there.
    x1 := tx + (span.c1 * tw) // grid.cols
    x2 := tx + ((span.c2 + 1) * tw) // grid.cols - pad
    y  := ty + ((2 * row + 1) * th) // (2 * grid.rows)

    ; Draw the highlight ourselves instead of asking ERA to.
    ;
    ; ERA's own selection was never actually wrong - but ERA also moves its
    ; block caret to the cell you clicked, and paints the caret on top of the
    ; selection, so the character you clicked on always looked left out. You
    ; usually click the front of a word, which is why it was usually the first
    ; character. No drag ERA performs can paint over its own caret, so the
    ; honest fix is to stop borrowing ERA's highlight: a thin overlay window,
    ; the exact rectangle of the word, gone again on your next click or after
    ; a moment. Nothing is pressed, dragged or waited for, so the highlight
    ; is also immediate - the old drag spent well over 100ms walking the
    ; pointer, this spends none.
    if (EW_OVERLAY) {
        yTop := ty + (row * th) // grid.rows
        yBot := ty + ((row + 1) * th) // grid.rows
        xr   := tx + ((span.c2 + 1) * tw) // grid.cols
        EW_ShowHighlight(x1, yTop, xr - x1, yBot - yTop)

        if (EW_DEBUG)
            FileAppend, % "want=[" span.text "]"
                       . " cells " span.c1 "-" span.c2 " row " row
                       . " grid " grid.cols "x" grid.rows
                       . " canvas " tw "x" th " at " tx "," ty
                       . " overlay " x1 "," yTop " " (xr - x1) "x" (yBot - yTop) "`n"
                       , %A_ScriptDir%\eraword_debug.txt

        text := EW_StripMake(lines, row, span)
        Clipboard := text
        EW_Tip(text)
        return
    }

    ; Wait for your button to actually come up, then a moment more.
    ;
    ; The pause is counted from the release, not from the click. A click held
    ; longer than usual therefore costs nothing extra beyond the holding: we
    ; start counting when your finger lifts, wherever that falls.
    ;
    ; Press while your button is still down, or the instant it comes up, and
    ; ERA is still in the middle of your own click: our drag gets cut off
    ; wherever it had reached, and you see part of the word lit. That is the
    ; old two-characters-highlighted fault. It looks like a drag problem while
    ; really being a timing one - the copy was always right, because the text
    ; comes off the screen rather than off the highlight.
    KeyWait, LButton, T0.5
    released := A_TickCount
    Sleep, %EW_SETTLE_MS%

    ; One stop per character. ERA paints the highlight from the mouse moves it
    ; is given, so it can only light up what it was actually told about - jump
    ; from the first character straight to the last and you get part of a word
    ; highlighted, even though the copy is still right, because the text comes
    ; off the screen rather than off the highlight.
    steps := EW_DRAG_STEPS ? EW_DRAG_STEPS : (span.c2 - span.c1)
    if (steps < 1)
        steps := 1

    if (EW_DRAG_POST)
    {
        ; Post the drag straight at the terminal as mouse messages.
        ;
        ; Faster than moving the pointer, and it leaves your pointer where you
        ; put it, so there is nothing to move back afterwards.
        WM_MOUSEMOVE   := 0x0200
        WM_LBUTTONDOWN := 0x0201
        WM_LBUTTONUP   := 0x0202
        MK_LBUTTON     := 0x0001

        ; Walk the pointer to the start of the word BEFORE the button goes
        ; down, and let that move be read, so the anchor is taken from where
        ; we said rather than from wherever your own click left things. Then
        ; anchor, state it once more with the button down, and walk forward
        ; across the word. Forward only - ERA selects rightward happily, but
        ; a drag run backwards loses most of the word.
        PostMessage, %WM_MOUSEMOVE%, 0, % EW_LParam(term, x1, y)
                   , , ahk_id %term%
        Sleep, %EW_POST_DOWN_MS%

        PostMessage, %WM_LBUTTONDOWN%, %MK_LBUTTON%, % EW_LParam(term, x1, y)
                   , , ahk_id %term%

        PostMessage, %WM_MOUSEMOVE%, %MK_LBUTTON%, % EW_LParam(term, x1, y)
                   , , ahk_id %term%
        Sleep, %EW_POST_DOWN_MS%

        Loop, %steps%
        {
            sx := x1 + ((x2 - x1) * A_Index) // steps
            PostMessage, %WM_MOUSEMOVE%, %MK_LBUTTON%, % EW_LParam(term, sx, y)
                       , , ahk_id %term%
            Sleep, %EW_POST_MS%
        }

        PostMessage, %WM_LBUTTONUP%, 0, % EW_LParam(term, x2, y), , ahk_id %term%

        if (EW_DEBUG)
            FileAppend, % "want=[" span.text "]"
                       . " cells " span.c1 "-" span.c2 " row " row
                       . " grid " grid.cols "x" grid.rows
                       . " canvas " tw "x" th " at " tx "," ty
                       . " x " x1 "-" x2 " y " y
                       . " pad " pad " steps " steps "`n"
                       , %A_ScriptDir%\eraword_debug.txt
    }
    else
    {
        ; The pointer way. ERA does not read the drag off the mouse messages -
        ; it polls the real pointer on a timer while the button is down. So
        ; walking the pointer stop by stop buys nothing: all that matters is
        ; that it DWELLS at the start long enough for one poll to catch it
        ; there, and again at the end. Two jumps and two waits, and the whole
        ; word lights up, faster than the old walk ever did.
        MouseGetPos, ox, oy

        MouseMove, x1, y, 0
        Click, Down Left
        Sleep, %EW_DRAG_HOLD_MS%

        MouseMove, x2, y, 0
        Sleep, %EW_DRAG_HOLD_MS%
        Click, Up Left

        if (EW_RESTORE_MOUSE)
            MouseMove, ox, oy, 0
    }

    ; The word goes on the clipboard from here, not by pressing ERA's own
    ; Copy button. We already know exactly what was selected - we are the one
    ; who worked out where the selection starts and ends - so asking ERA to
    ; tell us costs a click into ERA and a wait, and buys nothing.
    ; The make code comes off first, on the screens that carry one.
    text := EW_StripMake(lines, row, span)

    Clipboard := text

    EW_Tip(text)
}


;=============================================================================
;   A SCREEN POINT AS AN lParam
;
;   Mouse messages carry the position in client coordinates of the window
;   being told, packed two shorts to a value. Everything else in here works
;   in screen coordinates, so this is the one place that converts.
;=============================================================================
EW_LParam(hwnd, sx, sy) {
    VarSetCapacity(pt, 8, 0)
    NumPut(sx, pt, 0, "Int")
    NumPut(sy, pt, 4, "Int")
    DllCall("ScreenToClient", "Ptr", hwnd, "Ptr", &pt)
    cx := NumGet(pt, 0, "Int")
    cy := NumGet(pt, 4, "Int")
    return (cy << 16) | (cx & 0xFFFF)
}


;=============================================================================
;   THE TOOLTIP
;
;   Just the word, beside the pointer, gone again in under a second. It is
;   only shown for the copy - the F11 that reads the screen happens quietly.
;=============================================================================
EW_Tip(text) {
    global EW_TIP, EW_TIP_MS, EW_TIP_DX, EW_TIP_DY
    if (!EW_TIP)
        return

    MouseGetPos, mx, my
    ToolTip, %text%, % mx + EW_TIP_DX, % my + EW_TIP_DY
    SetTimer, EW_TipOff, % -EW_TIP_MS
}

EW_TipOff:
    ToolTip
return


;=============================================================================
;   THE GRID
;
;   How many columns and rows the terminal is showing, by measuring rather
;   than assuming. Returns { cols, rows } or "" if nothing sensible came out.
;
;   Only the counts - not a cell size in pixels. A cell is not necessarily a
;   whole number of pixels wide once DPI scaling is involved, so the counts
;   are the honest measurement and the callers turn them into pixels
;   proportionally, each in one sum.
;=============================================================================
EW_Grid(cw, chh, lines) {
    if (cw < 100 || chh < 100)
        return ""

    ; How wide is the screen, in characters? The longest line tells us which
    ; of the two terminal widths we are looking at.
    longest := 0
    for i, line in lines
        if (StrLen(line) > longest)
            longest := StrLen(line)

    cols := EW_BestFit(cw, (longest > 80) ? [132, 80] : [80, 132], longest)
    rows := EW_BestFit(chh, [24, 25, 43, 50], lines.MaxIndex())
    if (!cols || !rows)
        return ""

    return { cols: cols, rows: rows }
}

;-----------------------------------------------------------------------------
;   Of the sizes a terminal actually comes in, which one divides the canvas
;   evenly AND is big enough to hold what we can see? The first candidate that
;   does both wins; if none divides evenly - the normal state of affairs on a
;   DPI scaled machine, where a cell is not a whole number of pixels - we fall
;   back to the first one that is merely big enough, rather than giving up.
;-----------------------------------------------------------------------------
EW_BestFit(pixels, candidates, atLeast) {
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
;   WHERE THE CANVAS IS
;
;   The client area of a window, in screen coordinates - where the characters
;   actually are, as opposed to where the window is. For a borderless child
;   the two are the same thing, but this does not have to assume so.
;=============================================================================
EW_ClientRect(hwnd, ByRef x, ByRef y, ByRef w, ByRef h) {
    VarSetCapacity(rc, 16, 0)
    if (!DllCall("GetClientRect", "Ptr", hwnd, "Ptr", &rc))
        return false
    w := NumGet(rc, 8, "Int")
    h := NumGet(rc, 12, "Int")

    VarSetCapacity(pt, 8, 0)                 ; the client's (0,0), asked where
    if (!DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", &pt))
        return false
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")

    return (w > 0 && h > 0)
}


;=============================================================================
;   THE WORD UNDER A CELL
;
;   Walk left from the cell until the character stops being part of a word,
;   then walk right the same way. Returns { c1, c2, text }, or "" if that cell
;   is not on a word at all.
;=============================================================================
EW_WordAt(lines, row, col) {
    global EW_WORD_RE

    line := lines[row + 1]               ; rows count from 0, arrays from 1
    if (line = "")
        return ""

    len := StrLen(line)
    if (col < 0 || col >= len)
        return ""

    if (!EW_IsWordChar(SubStr(line, col + 1, 1)))
        return ""

    c1 := col
    while (c1 > 0 && EW_IsWordChar(SubStr(line, c1, 1)))
        c1--

    c2 := col
    while (c2 < len - 1 && EW_IsWordChar(SubStr(line, c2 + 2, 1)))
        c2++

    text := SubStr(line, c1 + 1, c2 - c1 + 1)

    ; A word made only of punctuation - a row of dots on a heading, the dashes
    ; in a rule - is not something anyone means to select.
    if (!RegExMatch(text, "[A-Za-z0-9]"))
        return ""

    return { c1: c1, c2: c2, text: text }
}

EW_IsWordChar(ch) {
    global EW_WORD_RE
    return RegExMatch(ch, "^(" . EW_WORD_RE . ")$") ? true : false
}


;=============================================================================
;   THE MAKE CODE
;
;   On the cross reference screen the Part# column reads make code first and
;   part number after, with nothing between them: KIAK0C0WS005 is make KI,
;   part AK0C0WS005. Two characters come off the front.
;
;   Both tests have to pass before anything is taken off. The screen has to be
;   that screen, recognised by its heading, and the word has to sit inside the
;   Part# column, found by where that column heading starts and where the next
;   one does. Anywhere else the word is taken exactly as it reads.
;
;   Only the clipboard is affected. The highlight in ERA still covers the
;   whole word, because the whole word is what is on the screen.
;=============================================================================
EW_StripMake(lines, row, span) {
    global EW_STRIP_MAKE, EW_STRIP_SCREEN, EW_STRIP_COL, EW_STRIP_NEXT
    global EW_STRIP_LEN

    if (!EW_STRIP_MAKE)
        return span.text

    ; Is this that screen, and which line is the column heading on? Both
    ; answers come out of one walk down the screen.
    onScreen := false, head := 0
    for i, ln in lines {
        if (!onScreen && InStr(ln, EW_STRIP_SCREEN))
            onScreen := true
        if (!head && InStr(ln, EW_STRIP_COL))
            head := i
    }
    if (!onScreen || !head)
        return span.text

    ; Rows count from 0 and lines from 1. The word has to be below the
    ; heading - the heading itself is not a part number.
    if (row + 1 <= head)
        return span.text

    ; Where the column starts and where it stops, in the same columns the word
    ; was measured in. The search for the next heading begins past the first
    ; one, so a column heading that is a word inside another cannot match
    ; itself.
    headLine := lines[head]
    c1 := InStr(headLine, EW_STRIP_COL) - 1
    c2 := InStr(headLine, EW_STRIP_NEXT, false, c1 + 2) - 1
    if (c2 < 0)
        return span.text

    if (span.c1 < c1 || span.c2 >= c2)
        return span.text

    ; A word no longer than the make code is not a part number with a make on
    ; the front of it, whatever column it is sitting in.
    if (StrLen(span.text) <= EW_STRIP_LEN)
        return span.text

    return SubStr(span.text, EW_STRIP_LEN + 1)
}


;=============================================================================
;   THE HIGHLIGHT  -  a window, not a selection
;
;   A borderless, click-through window laid exactly over the word. It cannot
;   have a hole where ERA's caret is, because ERA is not painting it, and it
;   costs nothing to show, because nothing is dragged and nothing waited for.
;   It comes down on your next click - the same way a real selection would -
;   or by itself after the tooltip's lifetime, whichever comes first.
;=============================================================================
EW_ShowHighlight(x, y, w, h) {
    global EW_TIP_MS

    Gui, EWHL:Destroy
    ; E0x20 is click-through: your mouse works as if the overlay were not
    ; there. NoActivate so focus never leaves ERA.
    Gui, EWHL:-Caption +ToolWindow +AlwaysOnTop +E0x20 -DPIScale +LastFound
    Gui, EWHL:Color, 2F6FD0
    Gui, EWHL:Show, x%x% y%y% w%w% h%h% NA
    WinSet, Transparent, 120

    SetTimer, EW_HideHighlight, % -1 * EW_TIP_MS
}

EW_HideHighlight:
    Gui, EWHL:Destroy
return


;=============================================================================
;   THE SCREEN  -  F11, the same as StockCheck uses
;
;   The clipboard is put back the way it was, unless we are about to replace
;   it with the word anyway.
;=============================================================================
EW_Screen(era) {
    saved := ClipboardAll
    Clipboard := ""

    ; You just clicked in it, so it is almost always already the front window.
    ; Only make it one when it is not - WinWaitActive on a window that is
    ; already active still costs a scheduling round trip every time.
    if (!WinActive("ahk_id " . era)) {
        WinActivate, ahk_id %era%
        WinWaitActive, ahk_id %era%, , 2
        if (ErrorLevel) {
            Clipboard := saved
            return ""
        }
    }

    SendInput, {F11}
    ClipWait, 2, 1
    if (ErrorLevel) {
        Clipboard := saved
        return ""
    }

    screen := Clipboard
    Clipboard := saved
    return screen
}

;-----------------------------------------------------------------------------
;   Is this the whole screen, or is it a few words someone had highlighted?
;
;   A screen is a full page of a terminal: two dozen lines, most of a hundred
;   characters across. A selection is neither. We only ever measure the grid
;   off something that passes this.
;-----------------------------------------------------------------------------
EW_LooksLikeScreen(screen) {
    if (screen = "")
        return false

    lines := EW_Lines(screen)
    if (lines.MaxIndex() < 10)
        return false

    longest := 0
    for i, line in lines
        if (StrLen(line) > longest)
            longest := StrLen(line)

    return (longest >= 40)
}

EW_Lines(screen) {
    out := []
    Loop, Parse, screen, `n, `r
        out.Insert(A_LoopField)

    ; A trailing empty line is the newline at the end, not a row of the
    ; screen. Leaving it in would make every row one pixel too short.
    while (out.MaxIndex() > 0 && Trim(out[out.MaxIndex()]) = "")
        out.Remove(out.MaxIndex())

    return out
}


;=============================================================================
;   ERA
;-----------------------------------------------------------------------------
;   The terminal canvas: the child that fills the middle of the window.
;
;   It is found by shape rather than by name, because its class name has a
;   number baked into it that changes between versions. Nothing else in that
;   window is both that wide and that tall - the toolbars are 52 pixels high
;   and the status bar 23.
;-----------------------------------------------------------------------------
EW_Terminal(era) {
    static lastEra := 0, lastTerm := 0

    ; The canvas does not move house between clicks, so remember it. Checked
    ; every time rather than trusted - if ERA has been closed and reopened the
    ; handle is dead and we look again.
    if (era = lastEra && lastTerm && DllCall("IsWindow", "Ptr", lastTerm))
        return lastTerm

    WinGetPos, wx, wy, ww, wh, ahk_id %era%

    best := 0, bestArea := 0
    for i, kid in EW_Kids(era, false) {
        if (!kid.vis)
            continue
        w := kid.r - kid.l, h := kid.b - kid.t
        if (w < ww * 0.8 || h < wh * 0.5)     ; not the main canvas
            continue

        ; Of the nested windows that all fill that space, take the innermost -
        ; the one with no child of its own that is just as big. It is the one
        ; the characters are actually drawn on.
        area := w * h
        if (!best || area <= bestArea) {
            best := kid.hwnd
            bestArea := area
        }
    }

    lastEra := era, lastTerm := best
    return best
}


;=============================================================================
;   WINDOWS PLUMBING  -  as in StockCheck.ahk, WM_GETTEXT not GetWindowText
;
;   wantText is off when all we need is where the controls are. Asking thirty
;   toolbar buttons what they are called, one message at a time, is work done
;   for nothing when the answer is thrown away.
;=============================================================================
global gEW_Kids := []
global gEW_WantText := true

EW_Kids(hwnd, wantText := true) {
    global gEW_Kids, gEW_WantText
    gEW_Kids := []
    gEW_WantText := wantText

    cb := RegisterCallback("EW_KidProc", "Fast")
    DllCall("EnumChildWindows", "Ptr", hwnd, "Ptr", cb, "Ptr", 0)
    DllCall("GlobalFree", "Ptr", cb)

    return gEW_Kids
}

EW_KidProc(hChild, lParam) {
    global gEW_Kids, gEW_WantText

    VarSetCapacity(buf, 256 * 2, 0)
    cls := ""
    if (DllCall("GetClassName", "Ptr", hChild, "Str", buf, "Int", 256))
        cls := buf

    ok := false
    VarSetCapacity(buf2, 512 * 2, 0)
    if (gEW_WantText) {
        junk := 0
        ok := DllCall("SendMessageTimeoutW", "Ptr", hChild, "UInt", 0x000D
            , "Ptr", 512, "Str", buf2, "UInt", 0x0002, "UInt", 200, "PtrP", junk)
        VarSetCapacity(buf2, -1)
    }

    VarSetCapacity(rect, 16, 0)
    DllCall("GetWindowRect", "Ptr", hChild, "Ptr", &rect)

    gEW_Kids.Insert({ hwnd: hChild
                    , cls:  cls
                    , text: ok ? buf2 : ""
                    , vis:  DllCall("IsWindowVisible", "Ptr", hChild)
                    , l:    NumGet(rect,  0, "Int")
                    , t:    NumGet(rect,  4, "Int")
                    , r:    NumGet(rect,  8, "Int")
                    , b:    NumGet(rect, 12, "Int") })
    return true
}
