; ============================================================================
;  Pad Counter PRO — CSV Receiver (AutoHotkey v1)
; ----------------------------------------------------------------------------
;  Runs on YOUR PC. Polls the Railway server for queued "Save CSV to folder"
;  exports, downloads each CSV, and drops it into the folder set below.
;
;  HOW IT WORKS
;    1. In the dashboard Settings, set "Export action" = "Save CSV to folder".
;    2. Click Export on a completed batch ? the server queues a job.
;    3. This script polls /export-jobs/next, downloads /export/range-csv,
;       saves it to FOLDER, then calls /export-jobs/done (marks it Exported).
;
;  SETUP
;    - Install AutoHotkey v1 (https://www.autohotkey.com/), then double-click
;      this file. A green "H" icon appears in the system tray = running.
;    - Edit the CONFIG block below first.
;    - To run on login: put a shortcut to this file in your Startup folder
;      (Win+R ? shell:startup).
; ============================================================================

#NoEnv
#SingleInstance Force
SetBatchLines, -1
#Persistent

; --- CONFIG · edit these -----------------------------------------------------
SERVER_URL   := "https://pad-counter-pro-production.up.railway.app"  ; no trailing slash
FOLDER       := "S:\Parts\ERA-Stocktake-Count-Entry\sheets-to-be-entered"        ; destination folder ON THIS PC (no trailing slash)
TOKEN        := ""                         ; must EXACTLY match Railway EXPORT_TOKEN ("" if not set)
POLL_SECONDS := 5                          ; how often to check the server
; -----------------------------------------------------------------------------

; Normalise: strip trailing slashes/backslashes so we can build clean URLs/paths
SERVER_URL := RegExReplace(SERVER_URL, "/+$", "")
FOLDER     := RegExReplace(FOLDER, "[\\/]+$", "")

IfNotExist, %FOLDER%
    FileCreateDir, %FOLDER%

TrayTip, Pad Counter CSV Receiver, Watching for exports`nFolder: %FOLDER%, 5, 1

SetTimer, PollOnce, % POLL_SECONDS * 1000
return

PollOnce:
    qs := (TOKEN != "") ? ("?token=" TOKEN) : ""
    line := HttpGetText(SERVER_URL "/export-jobs/next" qs)
    if (line = "")          ; no job (204/empty) or transient error ? wait, retry next tick
        return
    StringSplit, p, line, |   ; p1=id  p2=pages  p3=filename
    if (p1 = "" || p2 = "" || p3 = "")
        return
    dest := FOLDER "\" p3
    UrlDownloadToFile, % SERVER_URL "/export/range-csv?pages=" p2, %dest%
    if ErrorLevel {          ; download failed ? leave job claimed; stale-requeue re-serves it
        TrayTip, Pad Counter CSV Receiver, Download failed for %p3% — will retry, 4, 2
        return
    }
    HttpGetText(SERVER_URL "/export-jobs/done?id=" p1 ((TOKEN != "") ? ("&token=" TOKEN) : ""))
    TrayTip, Pad Counter CSV Receiver, Saved %p3%, 3, 1
return

; Simple text GET via WinHTTP. Returns ResponseText on HTTP 200, else "".
HttpGetText(url) {
    try {
        whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", url, false)
        whr.Send()
        return (whr.Status = 200) ? whr.ResponseText : ""
    } catch e {
        return ""
    }
}


