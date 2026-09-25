# Telescript Companion Interface - Windows state watcher
#
# Long-running helper started by the module. Watches the Telescript window and prints one
# line of JSON to stdout whenever something changes:
#   {"running":true,"view":"prompter","line":38,"lines":412,"title":"my script.rtf*"}
#   {"running":false}
#
# Everything is read with plain Win32 calls (no injected code, no pointers passed into the
# target process): window visibility (editor vs prompter view), the first visible line of
# the script control (scroll direction / speed) and the window title.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-watch.ps1 -IntervalMs 100 -ParentPid 1234

param(
	[int]$IntervalMs = 100,
	[int]$ParentPid = 0
)

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class WatchResult {
	public bool Found;
	public string View = "unknown";
	public int Line = -1;
	public int Lines = -1;
	public string Title = "";
}

public class TCIWatch {
	delegate bool EnumProc(IntPtr h, IntPtr l);
	[StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

	[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
	[DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
	[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
	[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
	[DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
	[DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
	[DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, int msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);

	static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
	static string Txt(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }

	// EM_GETFIRSTVISIBLELINE = 0xCE, EM_GETLINECOUNT = 0xBA. Neither takes a pointer, so they are
	// safe across processes; SMTO_ABORTIFHUNG stops a frozen Telescript from freezing the watcher.
	static int Ask(IntPtr h, int msg) {
		IntPtr res;
		IntPtr ok = SendMessageTimeout(h, msg, IntPtr.Zero, IntPtr.Zero, 2, 250, out res);
		return ok == IntPtr.Zero ? -1 : (int)res.ToInt64();
	}

	public static WatchResult Sample(uint pid) {
		var r = new WatchResult();
		IntPtr main = IntPtr.Zero;
		EnumWindows((h, l) => {
			uint p; GetWindowThreadProcessId(h, out p);
			if (p == pid && main == IntPtr.Zero && IsWindowVisible(h) && Cls(h).StartsWith("TeleScript")) main = h;
			return true;
		}, IntPtr.Zero);
		if (main == IntPtr.Zero) return r;

		r.Found = true;
		r.Title = Txt(main);

		IntPtr edit = IntPtr.Zero;
		long bestArea = -1;
		bool barFound = false, barVisible = false;
		EnumChildWindows(main, (c, l) => {
			if (GetParent(c) != main) return true;
			string cls = Cls(c);
			if (cls.StartsWith("RICHEDIT") || cls.StartsWith("RichEdit")) {
				RECT rc; GetWindowRect(c, out rc);
				long area = (long)(rc.Right - rc.Left) * (rc.Bottom - rc.Top);
				if (area > bestArea) { bestArea = area; edit = c; }
			} else if (cls == "msctls_statusbar32" || cls == "ToolbarWindow32") {
				barFound = true;
				if (IsWindowVisible(c)) barVisible = true;
			}
			return true;
		}, IntPtr.Zero);

		if (barFound) r.View = barVisible ? "editor" : "prompter";
		if (edit != IntPtr.Zero) {
			r.Line = Ask(edit, 206);
			r.Lines = Ask(edit, 186);
		}
		return r;
	}
}
'@

function ConvertTo-JsonString([string]$Text) {
	$sb = New-Object System.Text.StringBuilder
	foreach ($ch in $Text.ToCharArray()) {
		$code = [int]$ch
		if ($ch -eq '"') { [void]$sb.Append('\"') }
		elseif ($ch -eq '\') { [void]$sb.Append('\\') }
		elseif ($code -lt 32 -or $code -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
		else { [void]$sb.Append($ch) }
	}
	return $sb.ToString()
}

$names = 'TeleScriptAV', 'TeleScriptPro', 'TeleScriptMax'
$pidCached = 0
$last = $null
$nextParentCheck = [DateTime]::UtcNow.AddSeconds(2)

while ($true) {
	$result = $null
	if ($pidCached -ne 0) { $result = [TCIWatch]::Sample([uint32]$pidCached) }
	if ($null -eq $result -or -not $result.Found) {
		$proc = Get-Process -Name $names -ErrorAction SilentlyContinue | Select-Object -First 1
		$pidCached = if ($proc) { $proc.Id } else { 0 }
		$result = if ($pidCached -ne 0) { [TCIWatch]::Sample([uint32]$pidCached) } else { $null }
	}

	if ($null -eq $result -or -not $result.Found) {
		$json = '{"running":false}'
	} else {
		$line = if ($result.Line -ge 0) { [string]$result.Line } else { 'null' }
		$lines = if ($result.Lines -ge 0) { [string]$result.Lines } else { 'null' }
		$json = '{"running":true,"view":"' + $result.View + '","line":' + $line + ',"lines":' + $lines + ',"title":"' + (ConvertTo-JsonString $result.Title) + '"}'
	}

	if ($json -ne $last) {
		[Console]::Out.WriteLine($json)
		[Console]::Out.Flush()
		$last = $json
	}

	if ($ParentPid -ne 0 -and [DateTime]::UtcNow -gt $nextParentCheck) {
		if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { exit 0 }
		$nextParentCheck = [DateTime]::UtcNow.AddSeconds(2)
	}

	Start-Sleep -Milliseconds $(if ($pidCached -eq 0) { 500 } else { $IntervalMs })
}
