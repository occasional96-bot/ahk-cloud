; ============================================================
; Pre-pick List Extractor - posted AHK script (WorkspaceClient)
;   Ctrl+Shift+P  -> Pick PDF -> Excel (.xlsx)
;   Ctrl+Shift+G  -> Pick PDF -> Google Sheets (clipboard + sheets.new)
;   Ctrl+Shift+I  -> Manage ignore list (GUI)
; No #directives here: the WorkspaceClient injects #NoEnv / #Persistent /
; #SingleInstance Off / #NoTrayIcon itself. Overriding them breaks the client.
; ============================================================

global PrepickDir := A_AppData . "\WorkspaceClient\prepick"
global IgnoreFile := PrepickDir . "\ignore.txt"
global PyScript   := PrepickDir . "\prepick_parse.py"
global IgnoreList := []

try {
    if !FileExist(PrepickDir)
        FileCreateDir, %PrepickDir%
    LoadIgnoreList()
    WritePythonScript()
} catch e {
    MsgBox, 16, Pre-pick startup error, % "Pre-pick could not start.`n`n" e.Message " (line " e.Line ")"
}
return

; ------------------------------------------------------------
; Hotkeys
; ------------------------------------------------------------
^+p::
    FileSelectFile, pdfPath, 3, , Select Pre-pick PDF, PDF Files (*.pdf)
    if (pdfPath = "")
        return
    ExtractFromPDF(pdfPath, "excel")
return

^+g::
    FileSelectFile, pdfPath, 3, , Select Pre-pick PDF, PDF Files (*.pdf)
    if (pdfPath = "")
        return
    ExtractFromPDF(pdfPath, "sheets")
return

^+i::
    BuildIgnoreGUI()
return

; ------------------------------------------------------------
; Run embedded Python on the PDF, open the result
; ------------------------------------------------------------
ExtractFromPDF(pdfPath, target := "excel") {
    global IgnoreFile, PyScript
    LoadIgnoreList()

    SplitPath, pdfPath, , pdfDir, , pdfName
    xlsxPath := pdfDir . "\" . pdfName . "_extracted.xlsx"
    tsvPath  := A_Temp . "\prepick_clip.tsv"
    errPath  := A_Temp . "\prepick_err.txt"
    if FileExist(errPath)
        FileDelete, %errPath%

    PyExe := ResolvePy()
    if (PyExe = "") {
        MsgBox, 48, Pre-pick - Python not found, % "No usable Python on this PC.`n`nThe extractor needs the embedded Python that ships with the latest WorkspaceClient:`n" A_AppData "\WorkspaceClient\assets\py\python.exe`n`nThis machine doesn't have it (the client handed over the Windows Store stub instead). Ask the admin to re-deploy / Publish the latest client build, then try again."
        return
    }

    if (target = "sheets") {
        if FileExist(tsvPath)
            FileDelete, %tsvPath%
        RunWait, "%PyExe%" "%PyScript%" "%pdfPath%" "%IgnoreFile%" "-" "%errPath%" "%tsvPath%", , Hide
        if !FileExist(tsvPath) {
            ShowPrepickError(errPath, PyExe)
            return
        }
        FileRead, tsvData, %tsvPath%
        Clipboard := tsvData
        Run, https://sheets.new
        MsgBox, 64, Pre-pick -> Google Sheets, % "Data copied to the clipboard.`n`nA new Google Sheet is opening in your browser.`nClick cell A1 and press Ctrl+V to paste."
        return
    }

    if FileExist(xlsxPath)
        FileDelete, %xlsxPath%
    RunWait, "%PyExe%" "%PyScript%" "%pdfPath%" "%IgnoreFile%" "%xlsxPath%" "%errPath%", , Hide
    if !FileExist(xlsxPath) {
        ShowPrepickError(errPath, PyExe)
        return
    }
    Run, %xlsxPath%
}

; Find a REAL Python. Prefer the client's embedded one; never use the
; Windows Store stub in \WindowsApps\ (it silently does nothing).
ResolvePy() {
    emb := A_AppData . "\WorkspaceClient\assets\py\python.exe"
    if FileExist(emb)
        return emb
    EnvGet, e, WSC_PYTHON
    if (e != "" && FileExist(e) && !InStr(e, "\WindowsApps\"))
        return e
    return ""
}

ShowPrepickError(errPath, PyExe) {
    global PyScript
    errMsg := ""
    if FileExist(errPath)
        FileRead, errMsg, %errPath%
    if (errMsg = "")
        errMsg := "No output and no error text.`nPython: " . PyExe . "`nScript: " . PyScript
    Clipboard := errMsg
    MsgBox, 16, Pre-pick error (copied to clipboard), %errMsg%
}

; ------------------------------------------------------------
; Write the Python parser to disk
; ------------------------------------------------------------
WritePythonScript() {
    global PyScript
    if FileExist(PyScript)
        FileDelete, %PyScript%
    FileAppend, % "import sys, traceback`r`n", %PyScript%
    FileAppend, % "err_path = sys.argv[4] if len(sys.argv) > 4 else None`r`n", %PyScript%
    FileAppend, % "try:`r`n", %PyScript%
    FileAppend, % "    import re`r`n", %PyScript%
    FileAppend, % "    from pypdf import PdfReader`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    pdf_path = sys.argv[1]`r`n", %PyScript%
    FileAppend, % "    ignore_path = sys.argv[2]`r`n", %PyScript%
    FileAppend, % "    out_path = sys.argv[3]`r`n", %PyScript%
    FileAppend, % "    tsv_path = sys.argv[5] if len(sys.argv) > 5 else None`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    ignored = set()`r`n", %PyScript%
    FileAppend, % "    try:`r`n", %PyScript%
    FileAppend, % "        with open(ignore_path, 'r', encoding='utf-8') as f:`r`n", %PyScript%
    FileAppend, % "            for line in f:`r`n", %PyScript%
    FileAppend, % "                s = line.strip()`r`n", %PyScript%
    FileAppend, % "                if s:`r`n", %PyScript%
    FileAppend, % "                    ignored.add(s.upper())`r`n", %PyScript%
    FileAppend, % "    except FileNotFoundError:`r`n", %PyScript%
    FileAppend, % "        pass`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    reader = PdfReader(pdf_path)`r`n", %PyScript%
    FileAppend, % "    text = ''`r`n", %PyScript%
    FileAppend, % "    for page in reader.pages:`r`n", %PyScript%
    FileAppend, % "        text += page.extract_text() + '\n'`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    lines = text.splitlines()`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    results = []`r`n", %PyScript%
    FileAppend, % "    current_reg = None`r`n", %PyScript%
    FileAppend, % "    current_parts = []`r`n", %PyScript%
    FileAppend, % "    has_01k = False`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    reg_re = re.compile(r'^\s*\d{4}\s+K\s+([A-Z0-9]{5,8})\s')`r`n", %PyScript%
    FileAppend, % "    op01k_re = re.compile(r'\b01K[A-Z0-9]+')`r`n", %PyScript%
    FileAppend, % "    part_re = re.compile(r'\b(KI|NG)([A-Z0-9]+)\s+(\d+)\s+([A-Z0-9]+)')`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    def flush():`r`n", %PyScript%
    FileAppend, % "        global current_reg, current_parts, has_01k`r`n", %PyScript%
    FileAppend, % "        if current_reg and has_01k and current_parts:`r`n", %PyScript%
    FileAppend, % "            results.append((current_reg, list(current_parts)))`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    for line in lines:`r`n", %PyScript%
    FileAppend, % "        if 'Parts Report' in line or 'Aggregated Parts Report' in line:`r`n", %PyScript%
    FileAppend, % "            break`r`n", %PyScript%
    FileAppend, % "        m_reg = reg_re.match(line)`r`n", %PyScript%
    FileAppend, % "        if m_reg:`r`n", %PyScript%
    FileAppend, % "            flush()`r`n", %PyScript%
    FileAppend, % "            current_reg = m_reg.group(1)`r`n", %PyScript%
    FileAppend, % "            current_parts = []`r`n", %PyScript%
    FileAppend, % "            has_01k = False`r`n", %PyScript%
    FileAppend, % "        if op01k_re.search(line):`r`n", %PyScript%
    FileAppend, % "            has_01k = True`r`n", %PyScript%
    FileAppend, % "        m_part = part_re.search(line)`r`n", %PyScript%
    FileAppend, % "        if m_part and current_reg:`r`n", %PyScript%
    FileAppend, % "            part_num = m_part.group(2)`r`n", %PyScript%
    FileAppend, % "            qty = m_part.group(3)`r`n", %PyScript%
    FileAppend, % "            bin1 = m_part.group(4)`r`n", %PyScript%
    FileAppend, % "            if part_num.upper() not in ignored:`r`n", %PyScript%
    FileAppend, % "                current_parts.append((part_num, qty, bin1))`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    flush()`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    if tsv_path:`r`n", %PyScript%
    FileAppend, % "        with open(tsv_path, 'w', encoding='utf-8') as f:`r`n", %PyScript%
    FileAppend, % "            f.write('Reg\tPart Number\tQty\tBin1\n')`r`n", %PyScript%
    FileAppend, % "            for reg, parts in results:`r`n", %PyScript%
    FileAppend, % "                for p in parts:`r`n", %PyScript%
    FileAppend, % "                    f.write(reg + '\t' + p[0] + '\t' + p[1] + '\t' + p[2] + '\n')`r`n", %PyScript%
    FileAppend, % "`r`n", %PyScript%
    FileAppend, % "    if out_path and out_path != '-':`r`n", %PyScript%
    FileAppend, % "        from openpyxl import Workbook`r`n", %PyScript%
    FileAppend, % "        from openpyxl.styles import Alignment, Font`r`n", %PyScript%
    FileAppend, % "        wb = Workbook()`r`n", %PyScript%
    FileAppend, % "        ws = wb.active`r`n", %PyScript%
    FileAppend, % "        ws.title = 'PrePick'`r`n", %PyScript%
    FileAppend, % "        ws.append(['Reg', 'Part Number', 'Qty', 'Bin1'])`r`n", %PyScript%
    FileAppend, % "        for c in ws[1]:`r`n", %PyScript%
    FileAppend, % "            c.font = Font(bold=True)`r`n", %PyScript%
    FileAppend, % "        row_idx = 2`r`n", %PyScript%
    FileAppend, % "        wrap = Alignment(wrap_text=True, vertical='top')`r`n", %PyScript%
    FileAppend, % "        for reg, parts in results:`r`n", %PyScript%
    FileAppend, % "            parts_col = chr(10).join(p[0] for p in parts)`r`n", %PyScript%
    FileAppend, % "            qty_col = chr(10).join(p[1] for p in parts)`r`n", %PyScript%
    FileAppend, % "            bin_col = chr(10).join(p[2] for p in parts)`r`n", %PyScript%
    FileAppend, % "            ws.cell(row=row_idx, column=1, value=reg).alignment = wrap`r`n", %PyScript%
    FileAppend, % "            ws.cell(row=row_idx, column=2, value=parts_col).alignment = wrap`r`n", %PyScript%
    FileAppend, % "            ws.cell(row=row_idx, column=3, value=bin_col).alignment = wrap`r`n", %PyScript%
    FileAppend, % "            ws.cell(row=row_idx, column=4, value=bin_col).alignment = wrap`r`n", %PyScript%
    FileAppend, % "            row_idx += 1`r`n", %PyScript%
    FileAppend, % "        ws.column_dimensions['A'].width = 12`r`n", %PyScript%
    FileAppend, % "        ws.column_dimensions['B'].width = 18`r`n", %PyScript%
    FileAppend, % "        ws.column_dimensions['C'].width = 6`r`n", %PyScript%
    FileAppend, % "        ws.column_dimensions['D'].width = 12`r`n", %PyScript%
    FileAppend, % "        wb.save(out_path)`r`n", %PyScript%
    FileAppend, % "except Exception:`r`n", %PyScript%
    FileAppend, % "    if err_path:`r`n", %PyScript%
    FileAppend, % "        try:`r`n", %PyScript%
    FileAppend, % "            with open(err_path, 'w', encoding='utf-8') as f:`r`n", %PyScript%
    FileAppend, % "                f.write(traceback.format_exc())`r`n", %PyScript%
    FileAppend, % "        except Exception:`r`n", %PyScript%
    FileAppend, % "            pass`r`n", %PyScript%
    FileAppend, % "    sys.exit(1)`r`n", %PyScript%
}

; ------------------------------------------------------------
; Ignore list helpers
; ------------------------------------------------------------
LoadIgnoreList() {
    global IgnoreList, IgnoreFile
    IgnoreList := []
    if !FileExist(IgnoreFile) {
        FileAppend, , %IgnoreFile%
        return
    }
    FileRead, content, %IgnoreFile%
    Loop, Parse, content, `n, `r
    {
        item := Trim(A_LoopField)
        if (item != "")
            IgnoreList.Push(item)
    }
}

SaveIgnoreList() {
    global IgnoreList, IgnoreFile
    if FileExist(IgnoreFile)
        FileDelete, %IgnoreFile%
    for i, item in IgnoreList {
        FileAppend, %item%`n, %IgnoreFile%
    }
}

; ------------------------------------------------------------
; Ignore list GUI
; ------------------------------------------------------------
BuildIgnoreGUI() {
    global IgnoreList, IgnoreLB, NewItem
    LoadIgnoreList()

    Gui, Ignore:Destroy
    Gui, Ignore:New, +Resize, Manage Ignore List
    Gui, Ignore:Font, s10, Segoe UI
    Gui, Ignore:Add, Text, , Part numbers to ignore (no KI prefix):
    Gui, Ignore:Add, ListBox, vIgnoreLB w320 h180

    for i, item in IgnoreList {
        GuiControl, Ignore:, IgnoreLB, %item%
    }

    Gui, Ignore:Add, Edit, vNewItem w220 xm
    Gui, Ignore:Add, Button, gAddIgnore x+5 w90, Add
    Gui, Ignore:Add, Button, gRemoveIgnore xm w90, Remove selected
    Gui, Ignore:Add, Button, gSaveIgnore x+5 w90 Default, Save
    Gui, Ignore:Add, Button, gCancelIgnore x+5 w90, Close
    Gui, Ignore:Show, , Manage Ignore List
}

AddIgnore:
    Gui, Ignore:Submit, NoHide
    if (NewItem != "") {
        IgnoreList.Push(Trim(NewItem))
        GuiControl, Ignore:, IgnoreLB, %NewItem%
        GuiControl, Ignore:, NewItem,
    }
return

RemoveIgnore:
    GuiControlGet, sel, Ignore:, IgnoreLB
    if (sel = "")
        return
    newArr := []
    for i, item in IgnoreList {
        if (item != sel)
            newArr.Push(item)
    }
    IgnoreList := newArr
    GuiControl, Ignore:, IgnoreLB, |
    for i, item in IgnoreList
        GuiControl, Ignore:, IgnoreLB, %item%
return

SaveIgnore:
    SaveIgnoreList()
    Gui, Ignore:Destroy
return

CancelIgnore:
IgnoreGuiClose:
IgnoreGuiEscape:
    Gui, Ignore:Destroy
return