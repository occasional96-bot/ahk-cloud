#NoEnv
#SingleInstance Force
SetBatchLines, -1

global UIA := UIA_Interface()
global lastVal := ""
global busy := false
global resetRect := ""

SetTimer, WatchField, 150
SetTimer, CacheResetRect, 1000
return

#IfWinActive DMS - Google Chrome
$^v::
    DoResetPasteQuery(true)
return
#IfWinActive

; Global hook - works even when the click is what activates Chrome
~LButton::
    if busy
        return
    if !IsObject(resetRect)
        return
    CoordMode, Mouse, Screen
    MouseGetPos, mx, my, winUnderMouse
    WinGetTitle, t, ahk_id %winUnderMouse%
    if !InStr(t, "DMS - Google Chrome")
        return
    if (mx >= resetRect.l && mx <= resetRect.r && my >= resetRect.t && my <= resetRect.b) {
        WinActivate, ahk_id %winUnderMouse%
        Sleep, 100
        DoResetPasteQuery(false)
    }
return

CacheResetRect:
    if busy
        return
    if !WinExist("DMS - Google Chrome")
        return
    try {
        root := UIA.ElementFromHandle(WinExist("DMS - Google Chrome"))
        btn := root.FindFirstBy("AutomationId=button-1107")
        if btn
            resetRect := btn.CurrentBoundingRectangle
    }
return

FindField(root) {
    try return root.FindFirstBy("ControlType=Edit AND Name=Material code", 0x4, 2)
    return ""
}

GetFieldValue(root) {
    fld := FindField(root)
    if !fld
        return "<NOFIELD>"
    try return fld.CurrentValue
    return "<ERR>"
}

DoResetPasteQuery(clickReset) {
    global UIA, busy
    if busy
        return
    busy := true

    part := Trim(Clipboard)
    if (part = "") {
        busy := false
        return
    }

    root := UIA.ElementFromHandle(WinExist("DMS - Google Chrome"))
    if !root {
        busy := false
        return
    }

    if (clickReset) {
        try {
            btn := root.FindFirstBy("AutomationId=button-1107")
            if btn
                ClickBtn(btn)
        }
    }

    Sleep, 1300   ; absorb ExtJS delayed reset wipe

    cleared := false
    Loop, 30 {
        if (GetFieldValue(root) = "") {
            cleared := true
            break
        }
        Sleep, 100
    }
    if !cleared {
        busy := false
        return
    }

    ; type as real keystrokes (no mouse) - ExtJS model needs key events
    ok := false
    Loop, 3 {
        fld := FindField(root)
        if !fld {
            Sleep, 200
            continue
        }
        try fld.SetFocus()
        Sleep, 150
        SendInput, ^a
        Sleep, 50
        SendInput, {Raw}%part%
        Loop, 8 {
            Sleep, 100
            if (GetFieldValue(root) = part) {
                ok := true
                break
            }
        }
        if ok
            break
    }
    if !ok {
        busy := false
        return
    }

    Sleep, 200
    try {
        qbtn := root.FindFirstBy("AutomationId=button-1106")
        if qbtn
            ClickBtn(qbtn)
    }
    busy := false
}

WatchField:
    if (busy || !WinActive("DMS - Google Chrome"))
        return
    try focused := UIA.GetFocusedElement()
    catch
        return
    if (!focused || focused.CurrentControlType != 50004 || !InStr(focused.CurrentName, "Material code")) {
        lastVal := ""
        return
    }
    try val := focused.CurrentValue
    catch
        return
    if (val != lastVal && val != "") {
        clip := Trim(Clipboard)
        if (val = clip && RegExMatch(val, "^\d{8}-\d{2}$")) {
            Sleep, 100
            try {
                root := UIA.ElementFromHandle(WinExist("A"))
                btn := root.FindFirstBy("AutomationId=button-1106")
                if btn
                    ClickBtn(btn)
            }
        }
    }
    lastVal := val
return

; Invoke pattern (background, no mouse) with physical-click fallback
ClickBtn(el) {
    try {
        if el.GetCurrentPropertyValue(30031) {
            el.GetCurrentPatternAs("Invoke").Invoke()
            return 1
        }
    }
    try {
        r := el.CurrentBoundingRectangle
        if (r.r > r.l && r.b > r.t) {
            x := (r.l + r.r) // 2
            y := (r.t + r.b) // 2
            CoordMode, Mouse, Screen
            MouseGetPos, ox, oy
            Click, %x% %y%
            MouseMove, %ox%, %oy%, 0
            return 1
        }
    }
    return 0
}

/*
	UIA_Interface_ChromeMin.ahk - minimal extraction of Descolada's UIA_Interface.ahk (AHK v1)
	Supports exactly this API surface (verified against Chrome):
	  UIA_Interface() init; ElementFromHandle, GetFocusedElement (incl. Chromium accessibility
	  activation), FindFirst, FindAll, FindFirstBy expressions, CreateCondition/Property/And/Or/
	  Not/True conditions, element properties CurrentControlType/CurrentName/CurrentValue/
	  CurrentBoundingRectangle (+ any property via GetCurrentPropertyValue), SetFocus, SetValue,
	  element.Click() (Invoke pattern; native-click fallback), Value pattern.
	NOT included: all other patterns, events, caching, TextRanges, Dump/Highlight/Wait helpers,
	FindByPath and __Get sugar paths that depend on them.
	Source of every member: the full library (byte-identical extraction), 2026-07-09.
*/
class UIA_Base {
	__New(p:="", flag:=0, version:="") {
		ObjRawSet(this,"__Type","IUIAutomation" SubStr(this.__Class,5))
		,ObjRawSet(this,"__Value",p)
		,ObjRawSet(this,"__Flag",flag)
		,ObjRawSet(this,"__Version",version)
	}
	__Get(members*) {
		local
		global UIA_Enum
		member := members[1]
		if member not in base,__UIA,TreeWalkerTrue,TrueCondition
		{
			if (!InStr(member, "Current")) {
				baseKey := this
				While (ObjGetBase(baseKey)) {
					if baseKey.HasKey("Current" member)
						return this["Current" member]
					baseKey := ObjGetBase(baseKey)
				}
			}
			if ObjHasKey(UIA_Enum, member) {
				return UIA_Enum[member]
			} else if RegexMatch(member, "i)PatternId|EventId|PropertyId|AttributeId|ControlTypeId|AnnotationType|StyleId|LandmarkTypeId|HeadingLevel|ChangeId|MetadataId", match) {
				return UIA_Enum["UIA_" match](member)
			} else if InStr(this.__Class, "UIA_Element") {
				if (prop := UIA_Enum.UIA_PropertyId(member))
					return this.GetCurrentPropertyValue(prop)
				else if (RegExMatch(member, "i)=|\.|^[+-]?\d+$") || (RegexMatch(member, "^([A-Za-z]+)\d*$", match) && UIA_Enum.UIA_ControlTypeId(match1))) {
					for _, member in members
						this := InStr(member, "=") ? this.FindFirstBy(member, 2) : this.FindByPath(member)
					return this
				} else if ((SubStr(member, 1, 6) = "Cached") && (prop := UIA_Enum.UIA_PropertyId(SubStr(member, 7))))
					return this.GetCachedPropertyValue(prop)
				else if (member ~= "i)Pattern\d?") {
					if UIA_Enum.UIA_PatternId(member)
						return this.GetCurrentPatternAs(member)
					else if ((SubStr(member, 1, 6) = "Cached") && UIA_Enum.UIA_PatternId(pattern := SubStr(member, 7)))
						return this.GetCachedPatternAs(pattern)
				}
			}
			throw Exception("Property not supported by the " this.__Class " Class.",-1,member)
		}
	}
	__Set(member, value) {
		if (member != "base") {
			if !InStr(member, "Current")
				try return this["Current" member] := value
			throw Exception("Assigning values not supported by the " this.__Class " Class.",-1,member)
		}
	}
	__Call(member, params*) {
		local
		global UIA_Base, UIA_Enum
		if member not in base,HasKey
		{
			if RegexMatch(member, "i)^(?:UIA_)?(PatternId|EventId|PropertyId|AttributeId|ControlTypeId|AnnotationType|StyleId|LandmarkTypeId|HeadingLevel|ChangeId|MetadataId)$", match) {
				return UIA_Enum["UIA_" match1](params*)
			} else if !ObjHasKey(UIA_Base,member)&&!ObjHasKey(this,member)&&!(member = "_NewEnum") {
				throw Exception("Method Call not supported by the " this.__Class " Class.",-1,member)
			}
		}
	}
	__Delete() {
		this.__Flag ? ((this.__Flag == 2) ? DllCall("GlobalFree", "Ptr", this.__Value) : ObjRelease(this.__Value)):
	}
	__Vt(n) {
		return NumGet(NumGet(this.__Value+0,"ptr")+n*A_PtrSize,"ptr")
	}
}
class UIA_Interface extends UIA_Base {
	static __IID := "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}"
	ElementFromHandle(hwnd:="A", ByRef activateChromiumAccessibility:=True) {
		local
		if hwnd is not integer
			hwnd := WinExist(hwnd)
		if !hwnd
			return
		if (activateChromiumAccessibility != 0)
			activateChromiumAccessibility := this.ActivateChromiumAccessibility(hwnd)
		return UIA_Hr(DllCall(this.__Vt(6), "ptr",this.__Value, "ptr",hwnd, "ptr*",out:=""))? UIA_Element(out):
	}
	GetFocusedElement(ByRef activateChromiumAccessibility:=True) {
		local
		if (activateChromiumAccessibility!=0)
			activateChromiumAccessibility := this.ActivateChromiumAccessibility()
		return UIA_Hr(DllCall(this.__Vt(8), "ptr",this.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	CreateTreeWalker(condition) {
		local out
		return UIA_Hr(DllCall(this.__Vt(13), "ptr",this.__Value, "ptr",(IsObject(condition)?condition:this.CreateCondition(condition)).__Value, "ptr*",out:=""))? new UIA_TreeWalker(out):
	}
	CreateTrueCondition() {
		local out
		return UIA_Hr(DllCall(this.__Vt(21), "ptr",this.__Value, "ptr*",out:=""))? new UIA_BoolCondition(out):
	}
	CreatePropertyCondition(propertyId, value, type:=0xC) {
		local
		global UIA_Enum, UIA_PropertyCondition
		if propertyId is not integer
			propertyId := UIA_Enum.UIA_PropertyId(propertyId)
		if ((maybeVar := UIA_Enum.UIA_PropertyVariantType(propertyId)) && (type = 0xC))
			type := maybeVar
		var := UIA_ComVar(type, value)
		return UIA_Hr((A_PtrSize == 4) ? DllCall(this.__Vt(23), "ptr",this.__Value, "int",propertyId, "int64", NumGet(var.ptr+0, 0, "int64"), "int64", NumGet(var.ptr+0, 8, "int64"), "ptr*",out:="") : DllCall(this.__Vt(23), "ptr",this.__Value, "int",propertyId, "ptr",var.ptr, "ptr*",out:=""))? new UIA_PropertyCondition(out, 1):
	}
	CreatePropertyConditionEx(propertyId, value, type:=0xC, flags:=0x1) {
		local
		global UIA_Enum, UIA_PropertyCondition
		if propertyId is not integer
			propertyId := UIA_Enum.UIA_PropertyId(propertyId)
		if ((maybeVar := UIA_Enum.UIA_PropertyVariantType(propertyId)) && (type = 0xC))
			type := maybeVar
		var := UIA_ComVar(type, value)
		if (type != 8)
			flags := 0
		return UIA_Hr((A_PtrSize == 4) ? DllCall(this.__Vt(24), "ptr",this.__Value, "int",propertyId, "int64", NumGet(var.ptr+0, 0, "int64"), "int64", NumGet(var.ptr+0, 8, "int64"), "uint",flags, "ptr*",out:="") : DllCall(this.__Vt(24), "ptr",this.__Value, "int",propertyId, "ptr", var.ptr, "uint",flags, "ptr*",out:=""))? new UIA_PropertyCondition(out, 1):
	}
	CreateAndCondition(c1,c2) {
		local out
		return UIA_Hr(DllCall(this.__Vt(25), "ptr",this.__Value, "ptr",c1.__Value, "ptr",c2.__Value, "ptr*",out:=""))? new UIA_AndCondition(out, 1):
	}
	CreateOrCondition(c1,c2) {
		local out
		return UIA_Hr(DllCall(this.__Vt(28), "ptr",this.__Value, "ptr",c1.__Value, "ptr",c2.__Value, "ptr*",out:=""))? new UIA_OrCondition(out, 1):
	}
	CreateNotCondition(c) {
		local out
		return UIA_Hr(DllCall(this.__Vt(31), "ptr",this.__Value, "ptr",c.__Value, "ptr*",out:=""))? new UIA_NotCondition(out, 1):
	}
	CreateCondition(propertyOrExpr, valueOrFlags:="", flags:=0) {
		local
		global UIA_Enum
		if InStr(propertyOrExpr, "=") {
			match := "", match3 := "", match5 := "", currentCondition := "", fullCondition := "", operator := "", valueOrFlags := ((!valueOrFlags) ? 0 : valueOrFlags), counter := 1, conditions := [], currentExpr := "(" propertyOrExpr ")"
			while RegexMatch(currentExpr, "i) *(NOT|!)? *(\w+?(?<!UIA_CONDITION)) *=(?: *(\d+|'.*?(?<=[^\\]|[^\\]\\\\)')|([^()]*?)) *(?: FLAGS=(\d))? *?( AND | OR |&&|\|\||[()]|$) *", match) {
				if !match
					break
				match3 := (match3 == "") ? match4 : match3
				currentFlags := (match5 == "") ? valueOrFlags : match5
				if ((SubStr(match3,1,1) == "'") && (SubStr(match3,0,1) == "'"))
					match3 := StrReplace(RegexReplace(SubStr(match3,2,StrLen(match3)-2), "(?<=[^\\]|[^\\]\\\\)\\'", "'"), "\\", "\")
				conditions[counter] := this.CreateCondition(match2, match3, currentFlags)
				if (match1 == "NOT")
					match1 := "!"
				currentExpr := StrReplace(currentExpr, match, " " match1 "UIA_CONDITION=" counter (match6 ? ((match6 == ")") ? ") " : match6) : ""))
				counter++
			}
			currentExpr := StrReplace(StrReplace(StrReplace(currentExpr, " OR ", "||"), " AND ", "&&"), "NOT", "!")
			While RegexMatch(currentExpr, "! *(\((?:[^)(]+|(?1))*+\))", match) {
				match1 := SubStr(match1, 2, StrLen(match1)-2)
				currentExpr := StrReplace(currentExpr, match, "(" RegexReplace(match1, "([^)(]+?|\((?:[^)(]+|(?1))*+\)) *(\|\||&&|\)|$) *", "!$1$2$3") ")")
				currentExpr := StrReplace(currentExpr, "!!", "")
			}
			pos:=1, match:=""
			While (pos := RegexMatch(currentExpr, "! *UIA_CONDITION=(\d+)", match, pos+StrLen(match))) {
				conditions[match1] := this.CreateNotCondition(conditions[match1])
				currentExpr := StrReplace(currentExpr, match, "UIA_CONDITION=" match1)
				pos -= 1
			}
			currentExpr := StrReplace(currentExpr, " ", ""), parenthesisMatch:=""
			While RegexMatch(currentExpr, "\(([^()]+)\)", parenthesisMatch) {
				pos := 1, match:="", match1:="", fullCondition:="", operator:=""
				while (pos := RegexMatch(parenthesisMatch1, "UIA_CONDITION=(\d+)(&&|\|\||$)", match, pos+StrLen(match))) {
					fullCondition := (operator == "&&") ? this.CreateAndCondition(fullCondition, conditions[match1]) : (operator == "||") ? this.CreateOrCondition(fullCondition, conditions[match1]) : conditions[match1]
					operator := match2
				}
				conditions[counter] := fullCondition
				currentExpr := StrReplace(currentExpr, parenthesisMatch, "UIA_CONDITION=" counter)
				counter++
			}
			return conditions[counter-1]
		} else {
			if RegexMatch(propertyOrExpr, "^\d+$")
				propCond := propertyOrExpr
			else {
				if (propertyOrExpr = "Type")
					propertyOrExpr := "ControlType"
				RegexMatch(propertyOrExpr, "i)(?:UIA_)?\K.+?(?=(Id)?PropertyId|$)", propertyOrExpr), propCond := UIA_Enum.UIA_PropertyId(propertyOrExpr), propertyOrExpr := StrReplace(StrReplace(propertyOrExpr, "AnnotationAnnotation", "Annotation"), "StylesStyle", "Style")
			}
			if valueOrFlags is not integer
			{
				valueOrFlags := IsFunc("UIA_Enum.UIA_" propertyOrExpr "Id") ? UIA_Enum["UIA_" propertyOrExpr "Id"](valueOrFlags) : IsFunc("UIA_Enum.UIA_" propertyOrExpr) ? UIA_Enum["UIA_" propertyOrExpr](valueOrFlags) : valueOrFlags
			}
			if propCond
				return this.CreatePropertyConditionEx(propCond, valueOrFlags,, flags)
		}
	}
	ElementFromChromium(winTitle:="A", activateChromiumAccessibility:=True, timeOut:=500) {
		local
		try ControlGet, cHwnd, Hwnd,, Chrome_RenderWidgetHostHWND1, %winTitle%
		if !cHwnd
			return
		cEl := this.ElementFromHandle(cHwnd,False)
		if (activateChromiumAccessibility != 0) {
			SendMessage, WM_GETOBJECT := 0x003D, 0, 1, , ahk_id %cHwnd%
			if cEl {
				cEl.CurrentName
				if (cEl.CurrentControlType == 50030) {
					startTime := A_TickCount
					while (!cEl.CurrentValue && (A_TickCount-startTime < timeOut))
						Sleep, 20
				}
			}
		}
		return cEl
	}
	ActivateChromiumAccessibility(hwnd:="A", cacheRequest:=0, timeOut:=500) {
		static activatedHwnds := {}
		if hwnd is not integer
			hwnd := WinExist(hwnd)
		if activatedHwnds[hwnd]
			return
		activatedHwnds[hwnd] := 1
		return this.ElementFromChromium("ahk_id " hwnd,, timeOut)
	}
}
class UIA_Element extends UIA_Base {
	static __IID := "{d22108aa-8ac5-49a5-837b-37bbb3d7591e}"
	CurrentControlType[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(21), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
	CurrentName[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(23), "ptr",this.__Value, "ptr*",out:=""))?UIA_GetBSTRValue(out):
		}
	}
	CurrentBoundingRectangle[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(43), "ptr",this.__Value, "ptr",&(rect,VarSetCapacity(rect,16))))?UIA_RectToObject(rect):
		}
	}
	CurrentValue[] {
		get {
			return this.GetCurrentPropertyValue("Value")
		}
		set {
			return this.SetValue(value)
		}
	}
	SetFocus() {
		return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value))
	}
	FindFirst(c:="", scope:=0x4, cacheRequest:="") {
		local
		if !cacheRequest
			return UIA_Hr(DllCall(this.__Vt(5), "ptr",this.__Value, "uint",scope, "ptr", (c:=(c=""?this.TrueCondition:(IsObject(c)?c:this.__UIA.CreateCondition(c)))).__Value, "ptr*",out:=""))? UIA_Element(out):
		return this.FindFirstBuildCache(c, scope, cacheRequest)
	}
	FindAll(c:="", scope:=0x4, cacheRequest:="") {
		local
		if !cacheRequest
			return UIA_Hr(DllCall(this.__Vt(6), "ptr",this.__Value, "uint",scope, "ptr", (c:=(c=""?this.TrueCondition:(IsObject(c)?c:this.__UIA.CreateCondition(c)))).__Value, "ptr*",out:=""))? UIA_ElementArray(out):
		return this.FindAllBuildCache(c, scope, cacheRequest)
	}
	GetCurrentPropertyValue(propertyId, ByRef out:="") {
		if propertyId is not integer
			propertyId := UIA_Enum.UIA_PropertyId(propertyId)
		return UIA_Hr(DllCall(this.__Vt(10), "ptr",this.__Value, "uint", propertyId, "ptr",UIA_Variant(out)))? UIA_VariantData(out):UIA_VariantClear(out)
	}
	GetCurrentPatternAs(pattern, ByRef usedPattern:="") {
		local riid, out
		if (usedPattern := InStr(pattern, "Pattern") ? pattern : UIA_Pattern(pattern, this))
			return UIA_Hr(DllCall(this.__Vt(14), "ptr",this.__Value, "int",UIA_%usedPattern%.__PatternId, "ptr",UIA_GUID(riid,UIA_%usedPattern%.__iid), "ptr*",out:="")) ? new UIA_%usedPattern%(out,1):
		throw Exception("Pattern not implemented.",-1, "UIA_" pattern "Pattern")
	}
	GetClickablePoint() {
		local
		return UIA_Hr(DllCall(this.__Vt(84), "ptr",this.__Value, "ptr", &(point,VarSetCapacity(point,8)), "ptr*",out:=""))&&out? {x:NumGet(point,0,"int"), y:NumGet(point,4,"int")}:
	}
	GetClickablePointRelativeTo(relativeTo:="") {
		local
		res := this.GetClickablePoint()
		relativeTo := (relativeTo == "") ? A_CoordModeMouse : relativeTo
		StringLower, relativeTo, relativeTo
		if (relativeTo == "screen")
			return res
		else {
			hwnd := this.GetParentHwnd()
			if ((relativeTo == "window") || (relativeTo == "relative")) {
				VarSetCapacity(RECT, 16)
				DllCall("user32\GetWindowRect", "Ptr", hwnd, "Ptr", &RECT)
				return {x:(res.x-NumGet(&RECT, 0, "Int")), y:(res.y-NumGet(&RECT, 4, "Int"))}
			} else if (relativeTo == "client") {
				VarSetCapacity(pt,8,0), NumPut(res.x,&pt,0,"int"), NumPut(res.y,&pt,4,"int")
				DllCall("ScreenToClient", "Ptr",hwnd, "Ptr",&pt)
				return {x:NumGet(pt,"int"), y:NumGet(pt,4,"int")}
			}
		}
	}
	GetParentHwnd() {
		local TW, hwndNotZeroCond, hwndRoot, hwnd
		hwndNotZeroCond := this.__UIA.CreateNotCondition(this.__UIA.CreatePropertyCondition(UIA_Enum.UIA_PropertyId("NativeWindowHandle"), 0))
		TW := this.__UIA.CreateTreeWalker(hwndNotZeroCond)
		try {
			hwnd := TW.NormalizeElement(this).GetCurrentPropertyValue(UIA_Enum.UIA_PropertyId("NativeWindowHandle"))
			return hwndRoot := DllCall("user32\GetAncestor", Ptr,hwnd, UInt,2, Ptr)
		} catch {
			return 0
		}
	}
	SetValue(val, pattern:="") {
		if !pattern {
			try {
				this.GetCurrentPatternAs("Value").SetValue(val)
			} catch {
				this.GetCurrentPatternAs("LegacyIAccessible").SetValue(val)
			}
		} else {
			this.GetCurrentPatternAs(pattern).SetValue(val)
		}
	}
	Click(WhichButtonOrSleepTime:="", ClickCountAndSleepTime:=1, DownOrUp:="", Relative:="") {
		local
		global UIA_Enum
		if ((WhichButtonOrSleepTime == "") or RegexMatch(WhichButtonOrSleepTime, "^\d+$")) {
			SleepTime := WhichButtonOrSleepTime ? WhichButtonOrSleepTime : -1
			if (this.GetCurrentPropertyValue(UIA_Enum.UIA_IsInvokePatternAvailablePropertyId)) {
				this.GetCurrentPatternAs("Invoke").Invoke()
				Sleep, %SleepTime%
				return 1
			}
			if (this.GetCurrentPropertyValue(UIA_Enum.UIA_IsTogglePatternAvailablePropertyId)) {
				togglePattern := this.GetCurrentPatternAs("Toggle"), toggleState := togglePattern.CurrentToggleState
				togglePattern.Toggle()
				if (togglePattern.CurrentToggleState != toggleState) {
					Sleep, %SleepTime%
					return 1
				}
			}
			if (this.GetCurrentPropertyValue(UIA_Enum.UIA_IsExpandCollapsePatternAvailablePropertyId)) {
				if ((expandState := (pattern := this.GetCurrentPatternAs("ExpandCollapse")).CurrentExpandCollapseState) == 0)
					pattern.Expand()
				Else
					pattern.Collapse()
				if (pattern.CurrentExpandCollapseState != expandState) {
					Sleep, %SleepTime%
					return 1
				}
			}
			if (this.GetCurrentPropertyValue(UIA_Enum.UIA_IsSelectionItemPatternAvailablePropertyId)) {
				selectionPattern := this.GetCurrentPatternAs("SelectionItem"), selectionState := selectionPattern.CurrentIsSelected
				selectionPattern.Select()
				if (selectionPattern.CurrentIsSelected != selectionState) {
					Sleep, %sleepTime%
					return 1
				}
			}
			if (this.GetCurrentPropertyValue(UIA_Enum.UIA_IsLegacyIAccessiblePatternAvailablePropertyId)) {
				this.GetCurrentPatternAs("LegacyIAccessible").DoDefaultAction()
				Sleep, %sleepTime%
				return 1
			}
			return 0
		} else {
			rel := [0,0]
			if (Relative && !InStr(Relative, "rel"))
				rel := StrSplit(Relative, " "), Relative := ""
			ClickCount := 1, SleepTime := -1
			if (ClickCountAndSleepTime := StrSplit(ClickCountAndSleepTime, " "))[2] {
				ClickCount := ClickCountAndSleepTime[1], SleepTime := ClickCountAndSleepTime[2]
			} else if ClickCountAndSleepTime[1] {
				if (ClickCountAndSleepTime[1] > 9) {
					SleepTime := ClickCountAndSleepTime[1]
				} else {
					ClickCount := ClickCountAndSleepTime[1]
				}
			}
			try pos := this.GetClickablePointRelativeTo()
			if !(pos.x || pos.y) {
				pos := this.GetCurrentPos()
				Click, % (pos.x+pos.w//2+rel[1]) " " (pos.y+pos.h//2+rel[2]) " " WhichButtonOrSleepTime (ClickCount ? " " ClickCount : "") (DownOrUp ? " " DownOrUp : "") (Relative ? " " Relative : "")
			} else {
				Click, % (pos.x+rel[1]) " " (pos.y+rel[2]) " " WhichButtonOrSleepTime (ClickCount ? " " ClickCount : "") (DownOrUp ? " " DownOrUp : "") (Relative ? " " Relative : "")
			}
			Sleep, %SleepTime%
		}
	}
	GetCurrentPos(relativeTo:="") {
		local
		relativeTo := (relativeTo == "") ? A_CoordModeMouse : relativeTo
		StringLower, relativeTo, relativeTo
		br := this.CurrentBoundingRectangle
		if (relativeTo == "screen")
			return {x:br.l, y:br.t, w:(br.r-br.l), h:(br.b-br.t)}
		else {
			hwnd := this.GetParentHwnd()
			if ((relativeTo == "window") || (relativeTo == "relative")) {
				VarSetCapacity(RECT, 16)
				DllCall("user32\GetWindowRect", "Ptr", hwnd, "Ptr", &RECT)
				return {x:(br.l-NumGet(&RECT, 0, "Int")), y:(br.t-NumGet(&RECT, 4, "Int")), w:(br.r-br.l), h:(br.b-br.t)}
			} else if (relativeTo == "client") {
				VarSetCapacity(pt,8,0), NumPut(br.l,&pt,0,"int"), NumPut(br.t,&pt,4,"int")
				DllCall("ScreenToClient", "Ptr",hwnd, "Ptr",&pt)
				return {x:NumGet(pt,"int"), y:NumGet(pt,4,"int"), w:(br.r-br.l), h:(br.b-br.t)}
			}
		}
	}
	FindFirstBy(expr, scope:=0x4, matchMode:=3, caseSensitive:=True, cacheRequest:="") {
		local
		global UIA_Enum
		static MatchSubstringSupported := !InStr(A_OSVersion, "WIN") && (StrSplit(A_OSVersion, ".")[3] >= 17763)
		if ((matchMode == 3) || (matchMode==2 && MatchSubstringSupported)) {
			return this.FindFirst(this.__UIA.CreateCondition(expr, ((matchMode==2)?2:0)|!caseSensitive), scope, cacheRequest)
		}
		pos := 1, match := "", createCondition := "", operator := "", bufName := []
		while (pos := RegexMatch(expr, "i) *(NOT|!)? *(\w+?) *=(?: *(\d+|'.*?(?<=[^\\]|[^\\]\\\\)')|(.*?))(?: FLAGS=(\d))?( AND | OR | && | \|\| |$)", match, pos+StrLen(match))) {
			if !match
				break
			if ((StrLen(match3) > 1) && (SubStr(match3,1,1) == "'") && (SubStr(match3,0,1) == "'"))
				match3 := StrReplace(RegexReplace(SubStr(match3,2,StrLen(match3)-2), "(?<=[^\\]|[^\\]\\\\)\\'", "'"), "\\", "\")
			else if match4
				match3 := match4
			if ((isNamedProperty := RegexMatch(match2, "i)Name|AutomationId|Value|ClassName|FrameworkId")) && !bufName[1] && ((matchMode != 2) || ((matchMode == 2) && !MatchSubstringSupported)) && (matchMode != 3)) {
				bufName[1] := (match1 ? "NOT " : "") match2, bufName[2] := match3, bufName[3] := match5
				Continue
			}
			newCondition := this.__UIA.CreateCondition(match2, match3, match5 ? match5 : ((((matchMode==2) && isNamedProperty)?2:0)|!caseSensitive))
			if match1
				newCondition := this.__UIA.CreateNotCondition(newCondition)
			fullCondition := (operator == " AND " || operator == " && ") ? this.__UIA.CreateAndCondition(fullCondition, newCondition) : (operator == " OR " || operator == " || ") ? this.__UIA.CreateOrCondition(fullCondition, newCondition) : newCondition
			operator := match6
		}
		if (bufName[1]) {
			notProp := InStr(bufName[1], "NOT "), property := StrReplace(StrReplace(bufName[1], "NOT "), "Current"), value := bufName[2], caseSensitive := bufName[3] ? !(bufName[3]&1) : caseSensitive
			if (property = "value")
				property := "ValueValue"
			if (MatchSubstringSupported && (matchMode==1)) {
				propertyCondition := this.__UIA.CreatePropertyConditionEx(UIA_Enum["UIA_" property "PropertyId"], value,, 2|!caseSensitive)
				if notProp
					propertyCondition := this.__UIA.CreateNotCondition(propertyCondition)
			} else
				propertyCondition := this.__UIA.CreateNotCondition(this.__UIA.CreatePropertyCondition(UIA_Enum["UIA_" property "PropertyId"], ""))
			fullCondition := IsObject(fullCondition) ? this.__UIA.CreateAndCondition(propertyCondition, fullCondition) : propertyCondition
			for _, element in this.FindAll(fullCondition, scope, cacheRequest) {
				curValue := element["Current" property]
				if notProp {
					if (((matchMode == 1) && !InStr(SubStr(curValue, 1, StrLen(value)), value, caseSensitive)) || ((matchMode == 2) && !InStr(curValue, value, caseSensitive)) || (InStr(matchMode, "RegEx") && !RegExMatch(curValue, value)))
						return element
				} else {
					if (((matchMode == 1) && InStr(SubStr(curValue, 1, StrLen(value)), value, caseSensitive)) || ((matchMode == 2) && InStr(curValue, value, caseSensitive)) || (InStr(matchMode, "RegEx") && RegExMatch(curValue, value)))
						return element
				}
			}
		} else {
			return this.FindFirst(fullCondition, scope, cacheRequest)
		}
	}
}
class UIA_ElementArray extends UIA_Base {
	static __IID := "{14314595-b4bc-4055-95f2-58f2e42c9855}"
	Length[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
	GetElement(i) {
		local
		return UIA_Hr(DllCall(this.__Vt(4), "ptr",this.__Value, "int",i, "ptr*",out:=""))? UIA_Element(out):
	}
}
class UIA_TreeWalker extends UIA_Base {
	static __IID := "{4042c624-389c-4afc-a630-9df854a541fc}"
	Condition[] {
		get {
			local out
			return UIA_Hr(DllCall(this.__Vt(15), "ptr",this.__Value, "ptr*",out:=""))?new UIA_Condition(out):
		}
	}
	GetParentElement(e) {
		local
		return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr",e.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetFirstChildElement(e) {
		local
		return UIA_Hr(DllCall(this.__Vt(4), "ptr",this.__Value, "ptr",e.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetLastChildElement(e) {
		local
		return UIA_Hr(DllCall(this.__Vt(5), "ptr",this.__Value, "ptr",e.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetNextSiblingElement(e) {
		local
		return UIA_Hr(DllCall(this.__Vt(6), "ptr",this.__Value, "ptr",e.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetPreviousSiblingElement(e) {
		local
		return UIA_Hr(DllCall(this.__Vt(7), "ptr",this.__Value, "ptr",e.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	NormalizeElement(e) {
		local
		return UIA_Hr(DllCall(this.__Vt(8), "ptr",this.__Value, "ptr",e.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetParentElementBuildCache(e, cacheRequest) {
		local
		return UIA_Hr(DllCall(this.__Vt(9), "ptr",this.__Value, "ptr",e.__Value, "ptr",cacheRequest.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetFirstChildElementBuildCache(e, cacheRequest) {
		local
		return UIA_Hr(DllCall(this.__Vt(10), "ptr",this.__Value, "ptr",e.__Value, "ptr",cacheRequest.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetLastChildElementBuildCache(e, cacheRequest) {
		local
		return UIA_Hr(DllCall(this.__Vt(11), "ptr",this.__Value, "ptr",e.__Value, "ptr",cacheRequest.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetNextSiblingElementBuildCache(e, cacheRequest) {
		local
		return UIA_Hr(DllCall(this.__Vt(12), "ptr",this.__Value, "ptr",e.__Value, "ptr",cacheRequest.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	GetPreviousSiblingElementBuildCache(e, cacheRequest) {
		local
		return UIA_Hr(DllCall(this.__Vt(13), "ptr",this.__Value, "ptr",e.__Value, "ptr",cacheRequest.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
	NormalizeElementBuildCache(e, cacheRequest) {
		local
		return UIA_Hr(DllCall(this.__Vt(14), "ptr",this.__Value, "ptr",e.__Value, "ptr",cacheRequest.__Value, "ptr*",out:=""))? UIA_Element(out):
	}
}
class UIA_Condition extends UIA_Base {
	static __IID := "{352ffba8-0973-437c-a61f-f64cafd81df9}"
}
class UIA_PropertyCondition extends UIA_Condition {
	static __IID := "{99ebf2cb-5578-4267-9ad4-afd6ea77e94b}"
	PropertyId[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
	PropertyValue[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(4), "ptr",this.__Value, "ptr",UIA_Variant(out:="")))&&out?UIA_VariantData(out):UIA_VariantClear(out)
		}
	}
	PropertyConditionFlags[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(5), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
}
class UIA_AndCondition extends UIA_Condition {
	static __IID := "{a7d0af36-b912-45fe-9855-091ddc174aec}"
	ChildCount[] {
		get {
			local out
			return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
	GetChildren() {
		local
		global UIA_AndCondition, UIA_OrCondition, UIA_BoolCondition, UIA_NotCondition, UIA_PropertyCondition
		ret := UIA_Hr(DllCall(this.__Vt(5), "ptr",this.__Value, "ptr*",out:="")), arr := []
		if (out && (safeArray := ComObj(0x2003,out,1))) {
			for k in safeArray {
				obj := ComObject(9, k, 1), ObjAddRef(k)
				for _, n in ["Property", "Bool", "And", "Or", "Not"] {
					if ComObjQuery(obj, UIA_%n%Condition.__IID) {
						arr.Push(new UIA_%n%Condition(k))
						break
					}
				}
				ObjRelease(k)
			}
			return arr
		}
		return
	}
}
class UIA_OrCondition extends UIA_Condition {
	static __IID := "{8753f032-3db1-47b5-a1fc-6e34a266c712}"
	ChildCount[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
	GetChildren() {
		local
		global UIA_AndCondition, UIA_OrCondition, UIA_BoolCondition, UIA_NotCondition, UIA_PropertyCondition
		ret := UIA_Hr(DllCall(this.__Vt(5), "ptr",this.__Value, "ptr*",out:="")), arr := []
		if (out && (safeArray := ComObject(0x2003,out,1))) {
			for k in safeArray {
				obj := ComObject(9, k, 1)
				for _, n in ["Property", "Bool", "And", "Or", "Not"] {
					if ComObjQuery(obj, UIA_%n%Condition.__IID) {
						arr.Push(new UIA_%n%Condition(k,1))
						break
					}
				}
			}
			return arr
		}
		return
	}
}
class UIA_BoolCondition extends UIA_Condition {
	static __IID := "{1B4E1F2E-75EB-4D0B-8952-5A69988E2307}"
	BooleanValue[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
}
class UIA_NotCondition extends UIA_Condition {
	static __IID := "{f528b657-847b-498c-8896-d52b565407a1}"
	GetChild() {
		local
		global UIA_AndCondition, UIA_OrCondition, UIA_BoolCondition, UIA_NotCondition, UIA_PropertyCondition
		ret := UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr*",out:="")), obj := ComObject(9, out, 1)
		for k, v in ["Bool", "Property", "And", "Or", "Not"] {
			if ComObjQuery(obj, UIA_%v%Condition.__IID)
				return ret?new UIA_%v%Condition(out):
		}
		return UIA_Hr(0x80004005)
	}
}
class UIA_InvokePattern extends UIA_Base {
	static	__IID := "{fb377fbe-8ea6-46d5-9c73-6499642d3059}"
		,	__PatternID := 10000
	Invoke() {
		return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value))
	}
}
class UIA_ValuePattern extends UIA_Base {
	static	__IID := "{A94CD8B1-0844-4CD6-9D2D-640537AB39E9}"
		,	__PatternID := 10002
	CurrentValue[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(4), "ptr",this.__Value, "ptr*",out:=""))?UIA_GetBSTRValue(out):
		}
		set {
			return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr",&value))
		}
	}
	CurrentIsReadOnly[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(5), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
	CachedValue[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(6), "ptr",this.__Value, "ptr*",out:=""))?UIA_GetBSTRValue(out):
		}
	}
	CachedIsReadOnly[] {
		get {
			local
			return UIA_Hr(DllCall(this.__Vt(7), "ptr",this.__Value, "ptr*",out:=""))?out:
		}
	}
	SetValue(val) {
		return UIA_Hr(DllCall(this.__Vt(3), "ptr",this.__Value, "ptr",&val))
	}
}
UIA_Interface(maxVersion:="", activateScreenReader:=1) {
	local max, uiaBase, e
	static uia := "", cleanup := ""
	if (IsObject(uia) && (maxVersion == ""))
		return uia
	if (!IsObject(cleanup))
		cleanup := new UIA_Cleanup(activateScreenReader)
	max := (maxVersion?maxVersion:UIA_Enum.UIA_MaxVersion_Interface)+1
	while (--max) {
		if (!IsObject(UIA_Interface%max%) || (max == 1))
			continue
		try {
			if uia:=ComObjCreate("{e22ad333-b25f-460c-83d0-0581107395c9}",UIA_Interface%max%.__IID) {
				uia:=new UIA_Interface%max%(uia, 1, max), uiaBase := uia.base
				Loop, %max%
					uiaBase := uiaBase.base
				uiaBase.__UIA:=uia, uiaBase.TrueCondition:=uia.CreateTrueCondition(), uiaBase.TreeWalkerTrue := uia.CreateTreeWalker(uiaBase.TrueCondition)
				return uia
			}
		}
	}
	try {
		if uia:=ComObjCreate("{ff48dba4-60ef-4201-aa87-54103eef594e}","{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")
			return uia:=new UIA_Interface(uia, 1, 1), uia.base.base.__UIA:=uia, uia.base.base.CurrentVersion:=1, uia.base.base.TrueCondition:=uia.CreateTrueCondition(), uia.base.base.TreeWalkerTrue := uia.CreateTreeWalker(uia.base.base.TrueCondition)
		throw "UIAutomation Interface failed to initialize."
	} catch e
		MsgBox, 262160, UIA Startup Error, % IsObject(e)?"IUIAutomation Interface is not registered.":e.Message
	return
}
class UIA_Cleanup {
	__New(screenreader) {
		this.ScreenReaderActivate := screenreader, this.ScreenReaderStartingState := UIA_GetScreenReader()
		if (this.ScreenReaderActivate && !this.ScreenReaderStartingState)
			UIA_SetScreenReader(1)
	}
	__Delete() {
		if (this.ScreenReaderActivate)
			UIA_SetScreenReader(this.ScreenReaderStartingState)
	}
}
UIA_GetScreenReader() {
	local screenreader := 0
	if (A_PtrSize = 4)
		DllCall("user32.dll\SystemParametersInfo", "uint", 0x0046, "uint", 0, "ptr*", screenreader, "uint", 0)
	else
		DllCall("user32.dll\SystemParametersInfo", "uint", 0x0046, "uint", 0, "ptr*", screenreader)
	return screenreader
}
UIA_SetScreenReader(state, fWinIni:=2) {
	DllCall("user32.dll\SystemParametersInfo", "uint", 0x0047, "uint", state, "ptr", 0, "uint", fWinIni)
}
UIA_Hr(hr) {
	local
	static err:={0x8000FFFF:"Catastrophic failure.",0x80004001:"Not implemented.",0x8007000E:"Out of memory.",0x80070057:"One or more arguments are not valid.",0x80004002:"Interface not supported.",0x80004003:"Pointer not valid.",0x80070006:"Handle not valid.",0x80004004:"Operation aborted.",0x80004005:"Unspecified error.",0x80070005:"General access denied.",0x800401E5:"The object identified by this moniker could not be found.",0x80040201:"UIA_E_ELEMENTNOTAVAILABLE",0x80040200:"UIA_E_ELEMENTNOTENABLED",0x80131509:"UIA_E_INVALIDOPERATION",0x80040202:"UIA_E_NOCLICKABLEPOINT",0x80040204:"UIA_E_NOTSUPPORTED",0x80040203:"UIA_E_PROXYASSEMBLYNOTLOADED",0x80131505:"COR_E_TIMEOUT"}
	if hr&&(hr&=0xFFFFFFFF) {
		RegExMatch(Exception("",-2).what,"(\w+).(\w+)",i)
		throw Exception(UIA_Hex(hr) " - " err[hr], -2, i2 "  (" i1 ")")
	}
	return !hr
}
UIA_Element(e,flag:=1) {
	local max, riid
	static v := "", previousVersion := ""
	if !e
		return
	if (previousVersion != UIA_Enum.UIA_CurrentVersion_Element)
		v := ""
	else if v
		return (v==1)?new UIA_Element(e,flag,1):new UIA_Element%v%(e,flag,v)
	max := UIA_Enum.UIA_CurrentVersion_Element+1
	While (--max) {
		if UIA_GUID(riid, UIA_Element%max%.__IID)
			return new UIA_Element%max%(e,flag,v:=max)
	}
	return new UIA_Element(e,flag,v:=1)
}
UIA_Pattern(p, el) {
	local i, patternName, patternAvailableId
	static maxPatternVersions := {Selection:2, Text:2, TextRange:3, Transform:2}
	if p is integer
		return patternName := UIA_Enum.UIA_Pattern(p)
	else
		patternName := InStr(p, "Pattern") ? p : p "Pattern", i:=2
	Loop {
		i++
		if !(UIA_Enum.UIA_PatternId(patternName i) && IsObject(UIA_%patternName%%i%) && UIA_%patternName%%i%.__iid && UIA_%patternName%%i%.__PatternID)
			break
	}
	While (--i > 1) {
		if ((patternAvailableId := UIA_Enum["UIA_Is" patternName i "AvailablePropertyId"]) && el.GetCurrentPropertyValue(patternAvailableId))
			return patternName i
	}
	return patternName
}
UIA_Enum(e) {
	if ObjHasKey(UIA_Enum, e)
		return UIA_Enum[e]
	else if ObjHasKey(UIA_Enum, "UIA_" e)
		return UIA_Enum["UIA_" e]
}
UIA_ElementArray(p, uia:="",flag:=1) {
	local
	global UIA_ElementArray
	if !p
		return
	a:=new UIA_ElementArray(p,flag),out:=[]
	Loop % a.Length
		out[A_Index]:=a.GetElement(A_Index-1)
	return out, out.base:={UIA_ElementArray:a}
}
UIA_RectToObject(ByRef r) {
	static b:={__Class:"object",__Type:"RECT",Struct:Func("UIA_RectStructure")}
	return {l:NumGet(r,0,"Int"),t:NumGet(r,4,"Int"),r:NumGet(r,8,"Int"),b:NumGet(r,12,"Int"),base:b}
}
UIA_RectStructure(this, ByRef r) {
	static sides:="ltrb"
	VarSetCapacity(r,16)
	Loop Parse, sides
		NumPut(this[A_LoopField],r,(A_Index-1)*4,"Int")
}
UIA_SafeArrayToAHKArray(safearray) {
	local
	b:={__Class:"object",__Type:"SafeArray",__Value:safearray}
	out := []
	for k in safearray
		out.Push(k)
	return out, out.base:=b
}
UIA_Hex(p) {
	local
	setting:=A_FormatInteger
	SetFormat,IntegerFast,H
	out:=p+0 ""
	SetFormat,IntegerFast,%setting%
	return out
}
UIA_GUID(ByRef GUID, sGUID) {
	if !sGUID
		return
	VarSetCapacity(GUID,16,0)
	return DllCall("ole32\CLSIDFromString", "wstr",sGUID, "ptr",&GUID)>=0?&GUID:""
}
UIA_Variant(ByRef var,type:=0,val:=0) {
	static SIZEOF_VARIANT := 8 + (2 * A_PtrSize)
	VarSetCapacity(var, SIZEOF_VARIANT), ComObject(0x400C, &var)[] := type&&(type!=8)?ComObject(type,type=0xB?(!val?0:-1):val):val
	return &var
}
UIA_ComVar(Type := 0xC, val:=0) {
    static base := { __Get: Func("ComVarGet"), __Set: Func("ComVarSet")
	, __Delete: Func("ComVarDel") }
	cv := {base: base}
    cv.SetCapacity("buf", 24), ptr := cv.GetAddress("buf")
    NumPut(0, NumPut(0, ptr+0, "int64"), "int64")
	cv.ref := ComObject(0x400C, ptr)
	cv.ref[] := (type!=0xC)&&(type!=8)?ComObject(type,type=0xB?(!val?0:-1):val):val
	cv.ptr := ComObjValue(cv.ref)
	return cv
}
ComVarGet(cv, p*) {
    if p.MaxIndex() = ""
        return cv.ref[]
}
ComVarSet(cv, v, p*) {
    if p.MaxIndex() = ""
        return cv.ref[] := v
}
ComVarDel(cv) {
    DllCall("oleaut32\VariantClear", "ptr", cv.GetAddress("buf"))
}
UIA_IsVariant(ByRef vt, ByRef type:="", offset:=0, flag:=1) {
	local
	size:=VarSetCapacity(vt),type:=NumGet(vt,offset,"UShort")
	return size>=16&&size<=24&&type>=0&&(type<=23||type|0x2000)
}
UIA_VariantType(type){
	static _:={2:[2,"short"]
	,3:[4,"int"]
	,4:[4,"float"]
	,5:[8,"double"]
	,0xA:[4,"uint"]
	,0xB:[2,"short"]
	,0x10:[1,"char"]
	,0x11:[1,"uchar"]
	,0x12:[2,"ushort"]
	,0x13:[4,"uint"]
	,0x14:[8,"int64"]
	,0x15:[8,"uint64"]}
	return _.haskey(type)?_[type]:[A_PtrSize,"ptr"]
}
UIA_VariantData(ByRef p, flag:=1, offset:=0) {
	local
	if flag {
		var := !UIA_IsVariant(p,vt, offset)?"Invalid Variant":ComObject(0x400C, &p)[]
		UIA_VariantClear(&p)
	} else {
		vt:=NumGet(p+0,offset,"UShort"), var := !(vt>=0&&(vt<=23||vt|0x2000))?"Invalid Variant":ComObject(0x400C, p)[]
		UIA_VariantClear(p)
	}
	return vt=11?-var:var
}
UIA_VariantClear(pvar) {
	DllCall("oleaut32\VariantClear", "ptr",pvar)
}
UIA_GetSafeArrayValue(p,type,flag:=1){
	local
	t:=UIA_VariantType(type),item:={},pv:=NumGet(p+8+A_PtrSize,"ptr")
	loop % NumGet(p+8+2*A_PtrSize,"uint") {
		item.Insert((type=8)?StrGet(NumGet(pv+(A_Index-1)*t.1,t.2),"utf-16"):NumGet(pv+(A_Index-1)*t.1,t.2))
	}
	if flag
		DllCall("oleaut32\SafeArrayDestroy","ptr", p)
	return item
}
UIA_GetBSTRValue(ByRef bstr) {
	local
	val := StrGet(bstr)
	DllCall("oleaut32\SysFreeString", "ptr", bstr)
	return val
}
class UIA_Enum {
	static UIA_MaxVersion_Interface := 1
	static UIA_CurrentVersion_Element := 1
	static UIA_ControlTypePropertyId := 30003
	static UIA_NamePropertyId := 30005
	static UIA_AutomationIdPropertyId := 30011
	static UIA_ClassNamePropertyId := 30012
	static UIA_FrameworkIdPropertyId := 30024
	static UIA_IsExpandCollapsePatternAvailablePropertyId := 30028
	static UIA_IsInvokePatternAvailablePropertyId := 30031
	static UIA_IsSelectionItemPatternAvailablePropertyId := 30036
	static UIA_IsTogglePatternAvailablePropertyId := 30041
	static UIA_ValueValuePropertyId := 30045
	static UIA_IsLegacyIAccessiblePatternAvailablePropertyId := 30090
	UIA_PatternId(n:="") {
		static name:={10000:"InvokePattern",10001:"SelectionPattern",10002:"ValuePattern",10003:"RangeValuePattern",10004:"ScrollPattern",10005:"ExpandCollapsePattern",10006:"GridPattern",10007:"GridItemPattern",10008:"MultipleViewPattern",10009:"WindowPattern",10010:"SelectionItemPattern",10011:"DockPattern",10012:"TablePattern",10013:"TableItemPattern",10014:"TextPattern",10015:"TogglePattern",10016:"TransformPattern",10017:"ScrollItemPattern",10018:"LegacyIAccessiblePattern",10019:"ItemContainerPattern",10020:"VirtualizedItemPattern",10021:"SynchronizedInputPattern",10022:"ObjectModelPattern",10023:"AnnotationPattern",10024:"TextPattern2",10025:"StylesPattern",10026:"SpreadsheetPattern",10027:"SpreadsheetItemPattern",10028:"TransformPattern2",10029:"TextChildPattern",10030:"DragPattern",10031:"DropTargetPattern",10032:"TextEditPattern",10033:"CustomNavigationPattern",10034:"SelectionPattern2"}, id:={InvokePattern:10000,SelectionPattern:10001,ValuePattern:10002,RangeValuePattern:10003,ScrollPattern:10004,ExpandCollapsePattern:10005,GridPattern:10006,GridItemPattern:10007,MultipleViewPattern:10008,WindowPattern:10009,SelectionItemPattern:10010,DockPattern:10011,TablePattern:10012,TableItemPattern:10013,TextPattern:10014,TogglePattern:10015,TransformPattern:10016,ScrollItemPattern:10017,LegacyIAccessiblePattern:10018,ItemContainerPattern:10019,VirtualizedItemPattern:10020,SynchronizedInputPattern:10021,ObjectModelPattern:10022,AnnotationPattern:10023,TextPattern2:10024,StylesPattern:10025,SpreadsheetPattern:10026,SpreadsheetItemPattern:10027,TransformPattern2:10028,TextChildPattern:10029,DragPattern:10030,DropTargetPattern:10031,TextEditPattern:10032,CustomNavigationPattern:10033,SelectionPattern2:10034}
		if !n
			return id
		if n is integer
			return name[n]
		if ObjHasKey(id, n "Pattern")
			return id[n "Pattern"]
		else if ObjHasKey(id, n)
			return id[n]
		return id[RegexReplace(n, "(?:UIA_)?(.+?)(?:Id)?$", "$1")]
	}
	UIA_PropertyId(n:="") {
		local
		static ids:="RuntimeId:30000,BoundingRectangle:30001,ProcessId:30002,ControlType:30003,LocalizedControlType:30004,Name:30005,AcceleratorKey:30006,AccessKey:30007,HasKeyboardFocus:30008,IsKeyboardFocusable:30009,IsEnabled:30010,AutomationId:30011,ClassName:30012,HelpText:30013,ClickablePoint:30014,Culture:30015,IsControlElement:30016,IsContentElement:30017,LabeledBy:30018,IsPassword:30019,NativeWindowHandle:30020,ItemType:30021,IsOffscreen:30022,Orientation:30023,FrameworkId:30024,IsRequiredForForm:30025,ItemStatus:30026,IsDockPatternAvailable:30027,IsExpandCollapsePatternAvailable:30028,IsGridItemPatternAvailable:30029,IsGridPatternAvailable:30030,IsInvokePatternAvailable:30031,IsMultipleViewPatternAvailable:30032,IsRangeValuePatternAvailable:30033,IsScrollPatternAvailable:30034,IsScrollItemPatternAvailable:30035,IsSelectionItemPatternAvailable:30036,IsSelectionPatternAvailable:30037,IsTablePatternAvailable:30038,IsTableItemPatternAvailable:30039,IsTextPatternAvailable:30040,IsTogglePatternAvailable:30041,IsTransformPatternAvailable:30042,IsValuePatternAvailable:30043,IsWindowPatternAvailable:30044,ValueValue:30045,ValueIsReadOnly:30046,RangeValueValue:30047,RangeValueIsReadOnly:30048,RangeValueMinimum:30049,RangeValueMaximum:30050,RangeValueLargeChange:30051,RangeValueSmallChange:30052,ScrollHorizontalScrollPercent:30053,ScrollHorizontalViewSize:30054,ScrollVerticalScrollPercent:30055,ScrollVerticalViewSize:30056,ScrollHorizontallyScrollable:30057,ScrollVerticallyScrollable:30058,SelectionSelection:30059,SelectionCanSelectMultiple:30060,SelectionIsSelectionRequired:30061,GridRowCount:30062,GridColumnCount:30063,GridItemRow:30064,GridItemColumn:30065,GridItemRowSpan:30066,GridItemColumnSpan:30067,GridItemContainingGrid:30068,DockDockPosition:30069,ExpandCollapseExpandCollapseState:30070,MultipleViewCurrentView:30071,MultipleViewSupportedViews:30072,WindowCanMaximize:30073,WindowCanMinimize:30074,WindowWindowVisualState:30075,WindowWindowInteractionState:30076,WindowIsModal:30077,WindowIsTopmost:30078,SelectionItemIsSelected:30079,SelectionItemSelectionContainer:30080,TableRowHeaders:30081,TableColumnHeaders:30082,TableRowOrColumnMajor:30083,TableItemRowHeaderItems:30084,TableItemColumnHeaderItems:30085,ToggleToggleState:30086,TransformCanMove:30087,TransformCanResize:30088,TransformCanRotate:30089,IsLegacyIAccessiblePatternAvailable:30090,LegacyIAccessibleChildId:30091,LegacyIAccessibleName:30092,LegacyIAccessibleValue:30093,LegacyIAccessibleDescription:30094,LegacyIAccessibleRole:30095,LegacyIAccessibleState:30096,LegacyIAccessibleHelp:30097,LegacyIAccessibleKeyboardShortcut:30098,LegacyIAccessibleSelection:30099,LegacyIAccessibleDefaultAction:30100,AriaRole:30101,AriaProperties:30102,IsDataValidForForm:30103,ControllerFor:30104,DescribedBy:30105,FlowsTo:30106,ProviderDescription:30107,IsItemContainerPatternAvailable:30108,IsVirtualizedItemPatternAvailable:30109,IsSynchronizedInputPatternAvailable:30110,OptimizeForVisualContent:30111,IsObjectModelPatternAvailable:30112,AnnotationAnnotationTypeId:30113,AnnotationAnnotationTypeName:30114,AnnotationAuthor:30115,AnnotationDateTime:30116,AnnotationTarget:30117,IsAnnotationPatternAvailable:30118,IsTextPattern2Available:30119,StylesStyleId:30120,StylesStyleName:30121,StylesFillColor:30122,StylesFillPatternStyle:30123,StylesShape:30124,StylesFillPatternColor:30125,StylesExtendedProperties:30126,IsStylesPatternAvailable:30127,IsSpreadsheetPatternAvailable:30128,SpreadsheetItemFormula:30129,SpreadsheetItemAnnotationObjects:30130,SpreadsheetItemAnnotationTypes:30131,IsSpreadsheetItemPatternAvailable:30132,Transform2CanZoom:30133,IsTransformPattern2Available:30134,LiveSetting:30135,IsTextChildPatternAvailable:30136,IsDragPatternAvailable:30137,DragIsGrabbed:30138,DragDropEffect:30139,DragDropEffects:30140,IsDropTargetPatternAvailable:30141,DropTargetDropTargetEffect:30142,DropTargetDropTargetEffects:30143,DragGrabbedItems:30144,Transform2ZoomLevel:30145,Transform2ZoomMinimum:30146,Transform2ZoomMaximum:30147,FlowsFrom:30148,IsTextEditPatternAvailable:30149,IsPeripheral:30150,IsCustomNavigationPatternAvailable:30151,PositionInSet:30152,SizeOfSet:30153,Level:30154,AnnotationTypes:30155,AnnotationObjects:30156,LandmarkType:30157,LocalizedLandmarkType:30158,FullDescription:30159,FillColor:30160,OutlineColor:30161,FillType:30162,VisualEffects:30163,OutlineThickness:30164,CenterPoint:30165,Rotation:30166,Size:30167,IsSelectionPattern2Available:30168,Selection2FirstSelectedItem:30169,Selection2LastSelectedItem:30170,Selection2CurrentSelectedItem:30171,Selection2ItemCount:30173,IsDialog:30174"
		if !n
			return ids
		if n is integer
		{
			RegexMatch(ids, "([^,]+):" n, m)
			return m1
		}
		n := StrReplace(StrReplace(n, "UIA_"), "PropertyId")
		if (SubStr(n,1,7) = "Current")
			n := SubStr(n,8)
		RegexMatch(ids, "i)(?:^|,)" n "(?:" n ")?(?:Id)?:(\d+)", m)
		if (!m1 && (n = "type"))
			return 30003
		return m1
	}
	UIA_PropertyVariantType(id){
		static type:={30000:0x2003,30001:0x2005,30002:3,30003:3,30004:8,30005:8,30006:8,30007:8,30008:0xB,30009:0xB,30010:0xB,30011:8,30012:8,30013:8,30014:0x2005,30015:3,30016:0xB,30017:0xB,30018:0xD,30019:0xB,30020:3,30021:8,30022:0xB,30023:3,30024:8,30025:0xB,30026:8,30027:0xB,30028:0xB,30029:0xB,30030:0xB,30031:0xB,30032:0xB,30033:0xB,30034:0xB,30035:0xB,30036:0xB,30037:0xB,30038:0xB,30039:0xB,30040:0xB,30041:0xB,30042:0xB,30043:0xB,30044:0xB,30045:8,30046:0xB,30047:5,30048:0xB,30049:5,30050:5,30051:5,30052:5,30053:5,30054:5,30055:5,30056:5,30057:0xB,30058:0xB,30059:0x200D,30060:0xB,30061:0xB,30062:3,30063:3,30064:3,30065:3,30066:3,30067:3,30068:0xD,30069:3,30070:3,30071:3,30072:0x2003,30073:0xB,30074:0xB,30075:3,30076:3,30077:0xB,30078:0xB,30079:0xB,30080:0xD,30081:0x200D,30082:0x200D,30083:0x2003,30084:0x200D,30085:0x200D,30086:3,30087:0xB,30088:0xB,30089:0xB,30090:0xB,30091:3,30092:8,30093:8,30094:8,30095:3,30096:3,30097:8,30098:8,30099:0x200D,30100:8}, type2:={30101:8,30102:8,30103:0xB,30104:0xD,30105:0xD,30106:0xD,30107:8,30108:0xB,30109:0xB,30110:0xB,30111:0xB,30112:0xB,30113:3,30114:8,30115:8,30116:8,30117:0xD,30118:0xB,30119:0xB,30120:3,30121:8,30122:3,30123:8,30124:8,30125:3,30126:8,30127:0xB,30128:0xB,30129:8,30130:0x200D,30131:0x2003,30132:0xB,30133:0xB,30134:0xB,30135:3,30136:0xB,30137:0xB,30138:0xB,30139:8,30140:0x2008,30141:0xB,30142:8,30143:0x2008,30144:0x200D,30145:5,30146:5,30147:5,30148:0x200D,30149:0xB,30150:0xB,30151:0xB,30152:3,30153:3,30154:3,30155:0x2003,30156:0x2003,30157:3,30158:8,30159:8,30160:3,30161:0x2003,30162:3,30163:3,30164:0x2005,30165:0x2005,30166:5,30167:0x2005,30168:0xB}
		return ObjHasKey(type, id) ? type[id] : type2[id]
	}
	UIA_ControlTypeId(n:="") {
		static id:={Button:50000,Calendar:50001,CheckBox:50002,ComboBox:50003,Edit:50004,Hyperlink:50005,Image:50006,ListItem:50007,List:50008,Menu:50009,MenuBar:50010,MenuItem:50011,ProgressBar:50012,RadioButton:50013,ScrollBar:50014,Slider:50015,Spinner:50016,StatusBar:50017,Tab:50018,TabItem:50019,Text:50020,ToolBar:50021,ToolTip:50022,Tree:50023,TreeItem:50024,Custom:50025,Group:50026,Thumb:50027,DataGrid:50028,DataItem:50029,Document:50030,SplitButton:50031,Window:50032,Pane:50033,Header:50034,HeaderItem:50035,Table:50036,TitleBar:50037,Separator:50038,SemanticZoom:50039,AppBar:50040}, name:={50000:"Button",50001:"Calendar",50002:"CheckBox",50003:"ComboBox",50004:"Edit",50005:"Hyperlink",50006:"Image",50007:"ListItem",50008:"List",50009:"Menu",50010:"MenuBar",50011:"MenuItem",50012:"ProgressBar",50013:"RadioButton",50014:"ScrollBar",50015:"Slider",50016:"Spinner",50017:"StatusBar",50018:"Tab",50019:"TabItem",50020:"Text",50021:"ToolBar",50022:"ToolTip",50023:"Tree",50024:"TreeItem",50025:"Custom",50026:"Group",50027:"Thumb",50028:"DataGrid",50029:"DataItem",50030:"Document",50031:"SplitButton",50032:"Window",50033:"Pane",50034:"Header",50035:"HeaderItem",50036:"Table",50037:"TitleBar",50038:"Separator",50039:"SemanticZoom",50040:"AppBar"}
		if !n
			return id
		if n is integer
			return name[n]
		if ObjHasKey(id, n)
			return id[n]
		return id[StrReplace(StrReplace(n, "ControlTypeId"), "UIA_")]
	}
}




