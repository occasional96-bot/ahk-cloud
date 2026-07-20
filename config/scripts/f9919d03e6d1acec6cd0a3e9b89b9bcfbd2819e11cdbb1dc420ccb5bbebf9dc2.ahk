#Persistent
SetTimer, Era_F1, 200
return

Era_F1:
Under := WinExist(,"No previous menu")
PostMessage, 0x10,, , , ahk_id %Under%  ; WM_CLOSE (faster & cleaner)
outlook := WinExist("Reminder(s)")
PostMessage, 0x10,, , , ahk_id %outlook%  ; WM_CLOSE (faster & cleaner)
return

^Esc::
    Reload
return