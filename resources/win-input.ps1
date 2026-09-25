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
	[int]$Notches = 0
)

Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class TCIInput {
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
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
	'middleclick' { Send-MiddleClickHere }
	default {
		Write-Error "Unknown mode: $Mode"
		exit 1
	}
}
