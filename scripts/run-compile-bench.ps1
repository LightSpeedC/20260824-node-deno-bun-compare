<#
	Node.js / Deno / Bun 比較検証 — B-10 単一実行ファイル化

	同じ 1 ファイルの CLI（bench/common/b10-cli.mjs）を各ランタイムの機能で
	実行ファイルに固め、所要時間・出力サイズ・実際に動くかを比べる。

	  Deno : deno compile
	  Bun  : bun build --compile
	  Node : Single Executable Application（--experimental-sea-config ＋ postject）
	         postject は npm 依存のため、取得できない場合は「未実施」として記録する。
#>
[CmdletBinding()]
param(
	[int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$Root     = Split-Path -Parent $PSScriptRoot
$BenchDir = Join-Path $Root 'bench'
$ToolsDir = Join-Path $Root 'tools'
$WorkRoot = Join-Path $Root 'tmp\compile'
$RawDir   = Join-Path $Root 'results\raw'

foreach ($d in @($WorkRoot, $RawDir)) {
	if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$manifest = Get-Content -LiteralPath (Join-Path $ToolsDir 'runtimes.json') -Raw | ConvertFrom-Json
function Get-ToolExe {
	param([Parameter(Mandatory)][string]$Key)
	$e = $manifest.entries | Where-Object { $_.key -eq $Key } | Select-Object -First 1
	if (-not $e) { throw ("tools/runtimes.json に '{0}' がありません" -f $Key) }
	return $e.exe
}

$Node26 = Get-ToolExe 'node26'
$Deno   = Get-ToolExe 'deno'
$Bun    = Get-ToolExe 'bun'
$NpmCli = Join-Path (Split-Path -Parent $Node26) 'node_modules\npm\bin\npm-cli.js'
$Source = Join-Path $BenchDir 'common\b10-cli.mjs'

function Invoke-Measured {
	param(
		[Parameter(Mandatory)][string]$Exe,
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgList,
		[Parameter(Mandatory)][string]$WorkDir,
		[Parameter(Mandatory)][string]$LogTag,
		[int]$Timeout = 900
	)
	$outLog = Join-Path $WorkRoot ("{0}.out.txt" -f $LogTag)
	$errLog = Join-Path $WorkRoot ("{0}.err.txt" -f $LogTag)
	foreach ($f in @($outLog, $errLog)) {
		if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
	}
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	$p = Start-Process -FilePath $Exe -ArgumentList $ArgList -WorkingDirectory $WorkDir -PassThru `
		-WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
	$exited = $p.WaitForExit($Timeout * 1000)
	$sw.Stop()
	if (-not $exited) {
		try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
	}
	$code = -1
	if ($exited) { $code = $p.ExitCode }
	$o = ''
	$e = ''
	try { $o = Get-Content -LiteralPath $outLog -Raw -ErrorAction Stop } catch { $o = '' }
	try { $e = Get-Content -LiteralPath $errLog -Raw -ErrorAction Stop } catch { $e = '' }
	return [pscustomobject]@{ Ms = $sw.Elapsed.TotalMilliseconds; ExitCode = $code; TimedOut = (-not $exited); Out = [string]$o; Err = [string]$e }
}

function Get-FirstLines {
	param([AllowNull()][string]$Text, [int]$Count = 3)
	if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
	return (($Text.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First $Count) -join ' / ')
}

function Save-Raw {
	param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
	[System.IO.File]::WriteAllText((Join-Path $RawDir $Name), $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-Executable {
	param([Parameter(Mandatory)][string]$Path)
	if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Works = $false; Detail = '実行ファイルが生成されていない' } }
	$res = Invoke-Measured -Exe $Path -ArgList @('claude') -WorkDir $WorkRoot -LogTag ("verify-" + (Split-Path -Leaf $Path)) -Timeout 60
	$works = ($res.ExitCode -eq 0 -and $res.Out -match 'hello, claude')
	return [pscustomobject]@{ Works = $works; Detail = (Get-FirstLines -Text ($res.Out + "`n" + $res.Err)) }
}

$Results = New-Object System.Collections.Generic.List[object]
$startedAt = Get-Date

Write-Host ''
Write-Host '=== B-10 単一実行ファイル化 ==='
Write-Host ("対象ソース: {0}" -f $Source)
Write-Host ''

# ---------------------------------------------------------------------------
# Deno: deno compile
# ---------------------------------------------------------------------------
Write-Host '[deno] deno compile'
$denoOut = Join-Path $WorkRoot 'cli-deno.exe'
if (Test-Path -LiteralPath $denoOut) { Remove-Item -LiteralPath $denoOut -Force }
$r = Invoke-Measured -Exe $Deno -ArgList @('compile', '-A', '--output', $denoOut, $Source) -WorkDir $WorkRoot -LogTag 'deno-compile' -Timeout $TimeoutSec
Save-Raw -Name 'B-10_deno.txt' -Text ("EXIT={0}`n--- stdout ---`n{1}`n--- stderr ---`n{2}" -f $r.ExitCode, $r.Out, $r.Err)
$sizeMB = 0.0
if (Test-Path -LiteralPath $denoOut) { $sizeMB = [math]::Round((Get-Item -LiteralPath $denoOut).Length / 1MB, 1) }
$verify = Test-Executable -Path $denoOut
Write-Host ("    {0,7:N1} 秒  {1,7:N1} MB  動作: {2}" -f ($r.Ms / 1000), $sizeMB, $(if ($verify.Works) { 'OK' } else { 'NG' }))
$Results.Add([pscustomobject]@{
	id = 'B-10'; runtime = 'deno'; method = 'deno compile'
	seconds = [math]::Round($r.Ms / 1000, 2); sizeMB = $sizeMB
	ok = ($r.ExitCode -eq 0 -and $verify.Works); exitCode = $r.ExitCode
	verified = $verify.Works
	note = $(if ($r.ExitCode -eq 0 -and $verify.Works) { '' } else { Get-FirstLines -Text ($r.Err + "`n" + $verify.Detail) -Count 3 })
})

# ---------------------------------------------------------------------------
# Bun: bun build --compile
# ---------------------------------------------------------------------------
Write-Host '[bun] bun build --compile'
$bunOut = Join-Path $WorkRoot 'cli-bun.exe'
if (Test-Path -LiteralPath $bunOut) { Remove-Item -LiteralPath $bunOut -Force }
$r = Invoke-Measured -Exe $Bun -ArgList @('build', '--compile', '--outfile', $bunOut, $Source) -WorkDir $WorkRoot -LogTag 'bun-compile' -Timeout $TimeoutSec
Save-Raw -Name 'B-10_bun.txt' -Text ("EXIT={0}`n--- stdout ---`n{1}`n--- stderr ---`n{2}" -f $r.ExitCode, $r.Out, $r.Err)
$sizeMB = 0.0
if (Test-Path -LiteralPath $bunOut) { $sizeMB = [math]::Round((Get-Item -LiteralPath $bunOut).Length / 1MB, 1) }
$verify = Test-Executable -Path $bunOut
Write-Host ("    {0,7:N1} 秒  {1,7:N1} MB  動作: {2}" -f ($r.Ms / 1000), $sizeMB, $(if ($verify.Works) { 'OK' } else { 'NG' }))
$Results.Add([pscustomobject]@{
	id = 'B-10'; runtime = 'bun'; method = 'bun build --compile'
	seconds = [math]::Round($r.Ms / 1000, 2); sizeMB = $sizeMB
	ok = ($r.ExitCode -eq 0 -and $verify.Works); exitCode = $r.ExitCode
	verified = $verify.Works
	note = $(if ($r.ExitCode -eq 0 -and $verify.Works) { '' } else { Get-FirstLines -Text ($r.Err + "`n" + $verify.Detail) -Count 3 })
})

# ---------------------------------------------------------------------------
# Node: Single Executable Application
#   1) sea-config.json から blob を作る
#   2) node.exe を複製する
#   3) postject で blob を注入する（npm から取得）
# ---------------------------------------------------------------------------
Write-Host '[node26] Single Executable Application (SEA)'
$seaDir = Join-Path $WorkRoot 'node-sea'
if (Test-Path -LiteralPath $seaDir) { Remove-Item -LiteralPath $seaDir -Recurse -Force }
New-Item -ItemType Directory -Path $seaDir -Force | Out-Null

Copy-Item -LiteralPath $Source -Destination (Join-Path $seaDir 'cli.js') -Force
# package.json が無いと npm が親ディレクトリを探して
# 「Tracker "idealTree" already exists」で失敗するため、最小の定義を置く
$seaPkg = [ordered]@{ name = 'node-sea-bench'; private = $true; version = '1.0.0' }
[System.IO.File]::WriteAllText((Join-Path $seaDir 'package.json'), ($seaPkg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
$seaConfig = [ordered]@{
	main   = 'cli.js'
	output = 'sea-prep.blob'
	disableExperimentalSEAWarning = $true
}
[System.IO.File]::WriteAllText((Join-Path $seaDir 'sea-config.json'), ($seaConfig | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

$totalMs = 0.0
$nodeOk = $true
$nodeNote = ''

# 1) blob 生成
$r1 = Invoke-Measured -Exe $Node26 -ArgList @('--experimental-sea-config', 'sea-config.json') -WorkDir $seaDir -LogTag 'node-sea-blob' -Timeout $TimeoutSec
$totalMs += $r1.Ms
if ($r1.ExitCode -ne 0) {
	$nodeOk = $false
	$nodeNote = 'blob 生成に失敗: ' + (Get-FirstLines -Text ($r1.Err + "`n" + $r1.Out))
}

# 2) node.exe の複製
$nodeOut = Join-Path $seaDir 'cli-node.exe'
if ($nodeOk) {
	Copy-Item -LiteralPath $Node26 -Destination $nodeOut -Force
}

# 3) postject を取得して注入
$postjectLog = ''
if ($nodeOk) {
	$r2 = Invoke-Measured -Exe $Node26 -ArgList @($NpmCli, 'install', 'postject', '--no-audit', '--no-fund', '--loglevel=error') -WorkDir $seaDir -LogTag 'node-sea-postject-install' -Timeout $TimeoutSec
	$totalMs += $r2.Ms
	$postjectLog = $r2.Err
	$postjectCli = Join-Path $seaDir 'node_modules\postject\dist\cli.js'
	if ($r2.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $postjectCli)) {
		$nodeOk = $false
		$nodeNote = 'postject を取得できなかった（npm 依存）: ' + (Get-FirstLines -Text ($r2.Err + "`n" + $r2.Out))
	}
	else {
		$r3 = Invoke-Measured -Exe $Node26 -ArgList @(
			$postjectCli, 'cli-node.exe', 'NODE_SEA_BLOB', 'sea-prep.blob',
			'--sentinel-fuse', 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2'
		) -WorkDir $seaDir -LogTag 'node-sea-inject' -Timeout $TimeoutSec
		$totalMs += $r3.Ms
		if ($r3.ExitCode -ne 0) {
			$nodeOk = $false
			$nodeNote = 'postject の注入に失敗: ' + (Get-FirstLines -Text ($r3.Err + "`n" + $r3.Out))
		}
		$postjectLog += "`n--- inject ---`n" + $r3.Out + $r3.Err
	}
}

Save-Raw -Name 'B-10_node26.txt' -Text ("OK={0} NOTE={1}`n--- blob ---`n{2}`n{3}`n--- postject ---`n{4}" -f $nodeOk, $nodeNote, $r1.Out, $r1.Err, $postjectLog)

$sizeMB = 0.0
if (Test-Path -LiteralPath $nodeOut) { $sizeMB = [math]::Round((Get-Item -LiteralPath $nodeOut).Length / 1MB, 1) }
$verify = [pscustomobject]@{ Works = $false; Detail = $nodeNote }
if ($nodeOk) { $verify = Test-Executable -Path $nodeOut }
Write-Host ("    {0,7:N1} 秒  {1,7:N1} MB  動作: {2}" -f ($totalMs / 1000), $sizeMB, $(if ($verify.Works) { 'OK' } else { 'NG' }))
if (-not $verify.Works) { Write-Host ("    理由: {0}" -f (Get-FirstLines -Text ($nodeNote + "`n" + $verify.Detail) -Count 2)) }

$Results.Add([pscustomobject]@{
	id = 'B-10'; runtime = 'node26'; method = 'SEA (--experimental-sea-config + postject)'
	seconds = [math]::Round($totalMs / 1000, 2); sizeMB = $sizeMB
	ok = ($nodeOk -and $verify.Works); exitCode = $(if ($nodeOk) { 0 } else { 1 })
	verified = $verify.Works
	note = $(if ($nodeOk -and $verify.Works) { '手順が 3 段（blob 生成・node.exe 複製・postject 注入）で npm 依存あり' } else { Get-FirstLines -Text ($nodeNote + "`n" + $verify.Detail) -Count 3 })
})

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------
$finishedAt = Get-Date
$payload = [ordered]@{
	startedAt = $startedAt.ToString('yyyy-MM-dd HH:mm:ss')
	finishedAt = $finishedAt.ToString('yyyy-MM-dd HH:mm:ss')
	results = $Results
}
[System.IO.File]::WriteAllText((Join-Path $RawDir 'compile.json'), ($payload | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ("結果: {0}" -f (Join-Path $RawDir 'compile.json'))
Write-Host '=== B-10 完了 ==='
