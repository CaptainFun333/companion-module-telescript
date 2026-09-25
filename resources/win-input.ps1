# Telescript Companion Interface - Windows input helper
#
# Sends a single keystroke or mouse click using low-level Win32 calls, so it
# works no matter which window has focus (as long as this process and
# Telescript run in the same user session / elevation level).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-input.ps1 -Mode key -Modifiers ctrl,shift -Key c
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-input.ps1 -Mode click -Button right -X 400 -Y 300
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-input.ps1 -Mode moverelative -DX 0 -DY -15
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-input.ps1 -Mode wheel -Notches 1
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-input.ps1 -Mode middleclick
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-input.ps1 -Mode serve
#
# -Mode serve is what the module uses: one long-running process that compiles the Win32 helper once and
# then executes tab-separated commands read from stdin, one per line, in order:
#   <id>	key	<mods,comma>	<key>   <id>	click	<button>	<x>	<y>   <id>	move	<dx>	<dy>
#   <id>	wheel	<notches>          <id>	middle
# and answering "<id>	ok" or "<id>	err	<message>" (after printing "ready" once at startup).
# Starting a fresh PowerShell for every press cost about a second each.

param(
	[Parameter(Mandatory = $true)][string]$Mode,
	[string]$Modifiers = '',
	[string]$Key = '',
	[string]$Button = 'left',
	[int]$X = 0,
	[int]$Y = 0,
	[int]$DX = 0,
	[int]$DY = 0,
	[int]$Notches = 0,
	[int]$Red = 0,
	[int]$Green = 0,
	[int]$Blue = 0,
	[string]$Scope = 'selection',
	[switch]$DryRun
)

Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class TCIInput {
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}

public class TCIDialog {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)] static extern IntPtr SendText(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)] static extern IntPtr SendBuf(IntPtr h, uint m, IntPtr w, StringBuilder l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr h);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr m);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr m, int pos);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr m, int pos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuString(IntPtr m, uint id, StringBuilder s, int n, uint flag);

    static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
    public static string Text(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }

    // visible top-level dialogs of a process
    public static List<IntPtr> Dialogs(uint pid) {
        var r = new List<IntPtr>();
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h) && Cls(h) == "#32770") r.Add(h); return true; }, IntPtr.Zero);
        return r;
    }

    // walk the menu bar by item names ("&Format" matches "Format"; shortcut text after a tab is ignored) and return the command id
    static string Norm(string s) { int t = s.IndexOf('\t'); if (t >= 0) s = s.Substring(0, t); return s.Replace("&", "").Trim().ToLowerInvariant(); }
    public static uint FindCommand(IntPtr hwnd, string[] path) {
        IntPtr menu = GetMenu(hwnd);
        for (int depth = 0; depth < path.Length; depth++) {
            if (menu == IntPtr.Zero) return 0;
            int n = GetMenuItemCount(menu); IntPtr next = IntPtr.Zero; uint found = 0; bool hit = false;
            for (int i = 0; i < n; i++) {
                var sb = new StringBuilder(256); GetMenuString(menu, (uint)i, sb, 256, 0x400);
                if (Norm(sb.ToString()) != Norm(path[depth])) continue;
                hit = true; next = GetSubMenu(menu, i); found = GetMenuItemID(menu, i); break;
            }
            if (!hit) return 0;
            if (depth == path.Length - 1) return next == IntPtr.Zero ? found : 0;
            menu = next;
        }
        return 0;
    }

    public static void Post(IntPtr h, uint msg, uint w) { PostMessage(h, msg, (IntPtr)w, IntPtr.Zero); }
    public static bool Send(IntPtr h, uint msg, IntPtr w, IntPtr l, uint timeoutMs, out IntPtr res) { return SendMessageTimeout(h, msg, w, l, 2, timeoutMs, out res) != IntPtr.Zero; }
    public static int GetCheck(IntPtr dlg, int id) { IntPtr c = GetDlgItem(dlg, id); IntPtr r; if (c == IntPtr.Zero || !Send(c, 0xF0, IntPtr.Zero, IntPtr.Zero, 1000, out r)) return -1; return (int)r; }
    public static bool Click(IntPtr dlg, int id, uint timeoutMs) { IntPtr c = GetDlgItem(dlg, id); IntPtr r; return c != IntPtr.Zero && Send(c, 0xF5, IntPtr.Zero, IntPtr.Zero, timeoutMs, out r); }
    public static bool SetText(IntPtr dlg, int id, string s) { IntPtr c = GetDlgItem(dlg, id); if (c == IntPtr.Zero) return false; SendText(c, 0xC, IntPtr.Zero, s); return true; }
    public static string GetText(IntPtr dlg, int id) { IntPtr c = GetDlgItem(dlg, id); if (c == IntPtr.Zero) return null; var sb = new StringBuilder(64); SendBuf(c, 0xD, (IntPtr)64, sb); return sb.ToString(); }
}
'@

$KEYEVENTF_KEYUP = 0x0002
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004
$MOUSEEVENTF_RIGHTDOWN = 0x0008
$MOUSEEVENTF_RIGHTUP = 0x0010

$VkMap = @{
	'a' = 0x41; 'b' = 0x42; 'c' = 0x43; 'd' = 0x44; 'e' = 0x45; 'f' = 0x46; 'g' = 0x47; 'h' = 0x48
	'i' = 0x49; 'j' = 0x4A; 'k' = 0x4B; 'l' = 0x4C; 'm' = 0x4D; 'n' = 0x4E; 'o' = 0x4F; 'p' = 0x50
	'q' = 0x51; 'r' = 0x52; 's' = 0x53; 't' = 0x54; 'u' = 0x55; 'v' = 0x56; 'w' = 0x57; 'x' = 0x58
	'y' = 0x59; 'z' = 0x5A
	'0' = 0x30; '1' = 0x31; '2' = 0x32; '3' = 0x33; '4' = 0x34; '5' = 0x35; '6' = 0x36; '7' = 0x37
	'8' = 0x38; '9' = 0x39
	'f1' = 0x70; 'f2' = 0x71; 'f3' = 0x72; 'f4' = 0x73; 'f5' = 0x74; 'f6' = 0x75; 'f7' = 0x76
	'f8' = 0x77; 'f9' = 0x78; 'f10' = 0x79; 'f11' = 0x7A; 'f12' = 0x7B; 'f13' = 0x7C; 'f14' = 0x7D
	'f15' = 0x7E; 'f16' = 0x7F; 'f17' = 0x80; 'f18' = 0x81; 'f19' = 0x82; 'f20' = 0x83
	'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'space' = 0x20; 'backspace' = 0x08
	'delete' = 0x2E; 'escape' = 0x1B; 'esc' = 0x1B
	'left' = 0x25; 'up' = 0x26; 'right' = 0x27; 'down' = 0x28
	'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22; 'insert' = 0x2D
}

$ModMap = @{
	'ctrl' = 0x11; 'control' = 0x11
	'alt' = 0x12; 'option' = 0x12
	'shift' = 0x10
	'win' = 0x5B; 'windows' = 0x5B; 'cmd' = 0x5B; 'command' = 0x5B; 'meta' = 0x5B
}

$HoldMs = 30

function Wait-Ms {
	param([double]$Ms)

	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	while ($sw.Elapsed.TotalMilliseconds -lt $Ms) { }
}

function Send-Key {
	param([string]$ModifiersStr, [string]$KeyName, [int]$Repeat = 1)

	$mods = @()
	if ($ModifiersStr -ne '') {
		foreach ($m in $ModifiersStr.Split(',')) {
			$m2 = $m.Trim().ToLower()
			if ($m2 -ne '' -and $ModMap.ContainsKey($m2)) { $mods += $ModMap[$m2] }
		}
	}

	$keyName2 = $KeyName.Trim().ToLower()
	if (-not $VkMap.ContainsKey($keyName2)) {
		throw "Unknown key name: '$KeyName'"
	}
	$vk = $VkMap[$keyName2]

	foreach ($m in $mods) { [TCIInput]::keybd_event([byte]$m, 0, 0, [UIntPtr]::Zero) }
	for ($r = 0; $r -lt [Math]::Max(1, $Repeat); $r++) {
		[TCIInput]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
		if ($Repeat -gt 1) { Wait-Ms 2 } else { Start-Sleep -Milliseconds $HoldMs }
		[TCIInput]::keybd_event([byte]$vk, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
		if ($r -lt $Repeat - 1) { Wait-Ms 2 }
	}
	for ($i = $mods.Count - 1; $i -ge 0; $i--) {
		[TCIInput]::keybd_event([byte]$mods[$i], 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
	}
}

function Send-Click {
	param([string]$ClickButton, [int]$Xpos, [int]$Ypos)

	[TCIInput]::SetCursorPos($Xpos, $Ypos)
	Start-Sleep -Milliseconds $HoldMs

	switch ($ClickButton.ToLower()) {
		'right' {
			[TCIInput]::mouse_event($MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, [UIntPtr]::Zero)
			Start-Sleep -Milliseconds $HoldMs
			[TCIInput]::mouse_event($MOUSEEVENTF_RIGHTUP, 0, 0, 0, [UIntPtr]::Zero)
		}
		'double' {
			[TCIInput]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
			[TCIInput]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
			Start-Sleep -Milliseconds 60
			[TCIInput]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
			[TCIInput]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
		}
		default {
			[TCIInput]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
			Start-Sleep -Milliseconds $HoldMs
			[TCIInput]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
		}
	}
}

$MOUSEEVENTF_MIDDLEDOWN = 0x0020
$MOUSEEVENTF_MIDDLEUP = 0x0040
$MOUSEEVENTF_WHEEL = 0x0800

function Send-Wheel {
	param([int]$WheelNotches)

	$step = if ($WheelNotches -lt 0) { -120 } else { 120 }
	$data = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$step), 0)
	for ($i = 0; $i -lt [Math]::Abs($WheelNotches); $i++) {
		[TCIInput]::mouse_event($MOUSEEVENTF_WHEEL, 0, 0, $data, [UIntPtr]::Zero)
	}
}

function Send-MiddleClickHere {
	[TCIInput]::mouse_event($MOUSEEVENTF_MIDDLEDOWN, 0, 0, 0, [UIntPtr]::Zero)
	Start-Sleep -Milliseconds $HoldMs
	[TCIInput]::mouse_event($MOUSEEVENTF_MIDDLEUP, 0, 0, 0, [UIntPtr]::Zero)
}

# Sets the colour of the selected text (or all text) through Telescript's own Format > Colors... dialog.
# Control ids are those of the Colors dialog in TeleScript AV 7.x: 1096 Text radio, 1390 "Set text to selected color",
# 1385 "Apply to selection", 1386 "Apply to all text", 1383 / 1389 background / window boxes (kept off), 706-708 R/G/B, 1391 OK, 2 Cancel.
$KnownColorsCommand = @{ '7.3.1.71' = 40154 }

function Set-TextColor {
	param([int]$R, [int]$G, [int]$B, [string]$ScopeName, [bool]$Dry)

	$proc = Get-Process -Name 'TeleScriptAV', 'TeleScriptPro', 'TeleScriptMax' -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $proc) { throw 'Telescript is not running' }
	$main = $proc.MainWindowHandle
	# Telescript detaches its menu bar in Prompter view, so the menu can only be searched in Editor view. Look the command up when the
	# menu is there and remember it; otherwise use what was learned earlier, or (only on a build that has been checked) its known id.
	$cmd = [TCIDialog]::FindCommand($main, @('Format', 'Colors...'))
	if ($cmd -ne 0) { $script:ColorsCommand = $cmd }
	elseif ($script:ColorsCommand) { $cmd = $script:ColorsCommand }
	else {
		$ver = ''
		try { $ver = $proc.MainModule.FileVersionInfo.FileVersion } catch { }
		if ($KnownColorsCommand.ContainsKey($ver)) { $cmd = $KnownColorsCommand[$ver] }
	}
	if ($cmd -eq 0) { throw "Couldn't find Format > Colors: Telescript's menu is hidden in Prompter view and this Telescript version isn't one I know. Press the button once in Editor view and it will work in both views." }

	$procId = [uint32]$proc.Id
	$before = [TCIDialog]::Dialogs($procId)
	[TCIDialog]::Post($main, 0x111, $cmd)

	$dlg = [IntPtr]::Zero
	$deadline = [DateTime]::UtcNow.AddMilliseconds(2500)
	while ($dlg -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) {
		Start-Sleep -Milliseconds 20
		foreach ($x in [TCIDialog]::Dialogs($procId)) {
			if ($before -notcontains $x -and [TCIDialog]::Text($x) -like '*Color*') { $dlg = $x }
		}
	}
	if ($dlg -eq [IntPtr]::Zero) { throw "The Colors dialog didn't open (it may only be available in Editor view)" }

	$ok = $false
	try {
		function Set-Check([int]$Id, [int]$Want) {
			$have = [TCIDialog]::GetCheck($dlg, $Id)
			if ($have -lt 0) { throw "Colors dialog control $Id not found (different Telescript version?)" }
			if ($have -ne $Want) { [void][TCIDialog]::Click($dlg, $Id, 2000) }
		}
		Set-Check 1096 1                                   # "Set this color:" Text
		Set-Check 1390 1                                   # set text colour
		Set-Check 1383 0                                   # leave background alone
		Set-Check 1389 0                                   # leave window colour alone
		Set-Check $(if ($ScopeName -eq 'all') { 1386 } else { 1385 }) 1

		foreach ($pair in @(@(706, $R), @(707, $G), @(708, $B))) {
			[void][TCIDialog]::SetText($dlg, $pair[0], [string]$pair[1])
		}
		Start-Sleep -Milliseconds 30
		$got = @([TCIDialog]::GetText($dlg, 706), [TCIDialog]::GetText($dlg, 707), [TCIDialog]::GetText($dlg, 708))
		if ($got[0] -ne [string]$R -or $got[1] -ne [string]$G -or $got[2] -ne [string]$B) { throw ("Colors dialog did not accept the color (wanted $R,$G,$B, it shows " + ($got -join ',') + ')') }

		if ($Dry) { [Console]::Error.WriteLine(("dry run: rgb=" + ($got -join ',') + " hsl=" + ((703, 704, 705 | ForEach-Object { [TCIDialog]::GetText($dlg, $_) }) -join ','))) }
		if (-not $Dry) { [void][TCIDialog]::Click($dlg, 1391, 5000) }   # OK
		$ok = $true
	}
	finally {
		if (-not $ok -or $Dry) { [void][TCIDialog]::Click($dlg, 2, 2000) }   # Cancel: never leave a modal dialog open
	}
	$deadline = [DateTime]::UtcNow.AddMilliseconds(2000)
	while ([TCIDialog]::Dialogs($procId) -contains $dlg -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
	if ([TCIDialog]::Dialogs($procId) -contains $dlg) { throw 'The Colors dialog did not close' }
}

function Move-CursorRelative {
	param([int]$DeltaX, [int]$DeltaY)

	$current = [System.Windows.Forms.Cursor]::Position
	[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($current.X + $DeltaX), ($current.Y + $DeltaY))
}

function Start-InputServer {
	$script:HoldMs = 10
	[Console]::Out.WriteLine('ready')
	[Console]::Out.Flush()
	while ($true) {
		$line = [Console]::In.ReadLine()
		if ($null -eq $line) { break }
		if ($line.Trim() -eq '') { continue }
		$parts = $line.Split("`t")
		$id = $parts[0]
		try {
			switch ($parts[1]) {
				'key' { Send-Key -ModifiersStr $parts[2] -KeyName $parts[3] -Repeat $(if ($parts.Length -gt 4 -and $parts[4] -ne '') { [int]$parts[4] } else { 1 }) }
				'click' { Send-Click -ClickButton $parts[2] -Xpos ([int]$parts[3]) -Ypos ([int]$parts[4]) }
				'move' { Move-CursorRelative -DeltaX ([int]$parts[2]) -DeltaY ([int]$parts[3]) }
				'wheel' { Send-Wheel -WheelNotches ([int]$parts[2]) }
				'color' { Set-TextColor -R ([int]$parts[2]) -G ([int]$parts[3]) -B ([int]$parts[4]) -ScopeName $parts[5] -Dry ($parts.Length -gt 6 -and $parts[6] -eq 'dry') }
				'middle' { Send-MiddleClickHere }
				default { throw "Unknown command '$($parts[1])'" }
			}
			$reply = "$id`tok"
		} catch {
			$reply = "$id`terr`t" + ($_.Exception.Message -replace '[\r\n\t]+', ' ')
		}
		[Console]::Out.WriteLine($reply)
		[Console]::Out.Flush()
	}
}

switch ($Mode.ToLower()) {
	'serve' { Start-InputServer }
	'key' { Send-Key -ModifiersStr $Modifiers -KeyName $Key }
	'click' { Send-Click -ClickButton $Button -Xpos $X -Ypos $Y }
	'moverelative' { Move-CursorRelative -DeltaX $DX -DeltaY $DY }
	'wheel' { Send-Wheel -WheelNotches $Notches }
	'color' { Set-TextColor -R $Red -G $Green -B $Blue -ScopeName $Scope -Dry $DryRun.IsPresent }
	'middleclick' { Send-MiddleClickHere }
	default {
		Write-Error "Unknown mode: $Mode"
		exit 1
	}
}
