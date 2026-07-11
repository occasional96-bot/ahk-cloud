F11::
url := "https://csv-server-production-efc6.up.railway.app/upload"

files := []
;files.Push("C:\Temp\stdpartski.csv")
;files.Push("C:\Temp\stdpartshy.csv")
files.Push("C:\Users\runsheet\Documents\PSdata\02-KAINE-LOCATION KIA IUA BYD Data.csv")
;files.Push("C:\Users\kainet\OneDrive - Hopper Motor Group\Documents\PSdata\04E-INVOICE-SCAN-APP Data.csv")

for index, file in files
{
    if !FileExist(file) {
        MsgBox, 48, Error, File not found:`n%file%
        return
    }

    cmd := "curl -s -F ""file=@" . file . """ " . url
    RunWait, %ComSpec% /c %cmd% > "%TEMP%\csv_upload_result.txt" 2>&1,, Hide
    FileRead, result, %TEMP%\csv_upload_result.txt

    if !InStr(result, "Uploaded successfully") {
        MsgBox, 48, Error, Upload failed on file #%index%:`n%file%`n`n%result%
        return
    }
}

MsgBox, 64, Done!, All files uploaded successfully!
return

