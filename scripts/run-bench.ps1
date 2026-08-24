<#
	Node.js / Deno / Bun 比較検証 — ベンチマーク実行ドライバ
	対象項目: B-01 起動 / B-02 依存込み起動 / B-03 HTTP / B-04 JSON /
	          B-05 ファイル I/O / B-06 CPU / B-07 SQLite / B-09 TypeScript / B-11 テスト

	使い方:
	  .\run-bench.ps1                      本計測（既定 10 回）
	  .\run-bench.ps1 -Quick               予備計測（3 回・HTTP は 5 秒）
	  .\run-bench.ps1 -Only B-04,B-06      項目を絞る
#>
[CmdletBinding()]
param(
	# 自己計測系の試行回数
	[int]$Runs = 10,
	# hyperfine のウォームアップ回数
	[int]$Warmup = 3,
	# B-05 で作るファイル数
	[int]$FileCount = 2000,
	# B-03 の負荷時間（秒）と同時接続数
	[int]$HttpSeconds = 10,
	[int]$HttpConnections = 50,
	# 実行する項目 ID を絞る
	[string[]]$Only,
	# 予備計測モード
	[switch]$Quick,
	# 既存の measurements.json に結果を足す（項目を分割して実行するとき）
	[switch]$Append
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$Root       = Split-Path -Parent $PSScriptRoot
$BenchDir   = Join-Path $Root 'bench'
$ToolsDir   = Join-Path $Root 'tools'
$TmpDir     = Join-Path $Root 'tmp'
$RawDir     = Join-Path $Root 'results\raw'

if ($Quick) {
	if (-not $PSBoundParameters.ContainsKey('Runs'))        { $Runs = 3 }
	if (-not $PSBoundParameters.ContainsKey('Warmup'))      { $Warmup = 1 }
	if (-not $PSBoundParameters.ContainsKey('HttpSeconds')) { $HttpSeconds = 5 }
}

foreach ($d in @($TmpDir, $RawDir)) {
	if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------------------------------------------------------------------------
# ランタイム定義（tools/runtimes.json から実行ファイルを解決する）
# ---------------------------------------------------------------------------
$manifestPath = Join-Path $ToolsDir 'runtimes.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
	throw "tools/runtimes.json がありません。先に scripts\setup-runtimes.ps1 を実行してください。"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

function Get-ToolExe {
	param([Parameter(Mandatory)][string]$Key)
	$e = $manifest.entries | Where-Object { $_.key -eq $Key } | Select-Object -First 1
	if (-not $e) { throw ("tools/runtimes.json に '{0}' がありません" -f $Key) }
	if (-not (Test-Path -LiteralPath $e.exe)) { throw ("実行ファイルが見つかりません: {0}" -f $e.exe) }
	return $e.exe
}

$Hyperfine = Get-ToolExe 'hyperfine'
$Oha       = Get-ToolExe 'oha'

$Runtimes = @(
	[pscustomobject]@{ Key = 'node26'; Label = 'Node.js 26.7.0'; Exe = (Get-ToolExe 'node26'); RunArgs = @();               TestArgs = @('--test') }
	[pscustomobject]@{ Key = 'node24'; Label = 'Node.js 24.19.0'; Exe = (Get-ToolExe 'node24'); RunArgs = @();               TestArgs = @('--test') }
	[pscustomobject]@{ Key = 'deno';   Label = 'Deno 2.9.5';      Exe = (Get-ToolExe 'deno');   RunArgs = @('run', '-A');    TestArgs = @('test', '-A', '--no-check') }
	[pscustomobject]@{ Key = 'bun';    Label = 'Bun 1.4.0';       Exe = (Get-ToolExe 'bun');    RunArgs = @('run');          TestArgs = @('test') }
)

# ---------------------------------------------------------------------------
# 共通ヘルパ
# ---------------------------------------------------------------------------
function Test-Wanted {
	param([Parameter(Mandatory)][string]$Id)
	if (-not $Only) { return $true }
	return ($Only -contains $Id)
}

function Get-Stats {
	param([Parameter(Mandatory)][double[]]$Values)
	$sorted = @($Values | Sort-Object)
	$n = $sorted.Count
	if ($n -eq 0) { return $null }
	if ($n % 2 -eq 1) {
		$median = $sorted[[int](($n - 1) / 2)]
	}
	else {
		$median = ($sorted[($n / 2) - 1] + $sorted[$n / 2]) / 2
	}
	$mean = ($Values | Measure-Object -Average).Average
	$sd = 0.0
	if ($n -gt 1) {
		$sumSq = 0.0
		foreach ($v in $Values) { $sumSq += [math]::Pow($v - $mean, 2) }
		$sd = [math]::Sqrt($sumSq / ($n - 1))
	}
	$cv = 0.0
	if ($mean -ne 0) { $cv = $sd / $mean }
	return [pscustomobject]@{
		n = $n; median = $median; mean = $mean
		min = $sorted[0]; max = $sorted[-1]; sd = $sd; cv = $cv
	}
}

$Measurements = New-Object System.Collections.Generic.List[object]

function Add-Measurement {
	param(
		[Parameter(Mandatory)][string]$Id,
		[Parameter(Mandatory)][string]$Item,
		[Parameter(Mandatory)][string]$Runtime,
		[string]$Variant = 'common',
		[Parameter(Mandatory)][string]$Metric,
		[Parameter(Mandatory)][string]$Unit,
		[AllowNull()][object]$Stats,
		[AllowNull()][object]$Detail,
		[Parameter(Mandatory)][bool]$Ok,
		[string]$Note = ''
	)
	$rec = [ordered]@{
		id = $Id; item = $Item; runtime = $Runtime; variant = $Variant
		metric = $Metric; unit = $Unit; ok = $Ok; note = $Note
	}
	if ($Stats) {
		$rec.n      = $Stats.n
		$rec.median = [math]::Round($Stats.median, 3)
		$rec.mean   = [math]::Round($Stats.mean, 3)
		$rec.min    = [math]::Round($Stats.min, 3)
		$rec.max    = [math]::Round($Stats.max, 3)
		$rec.sd     = [math]::Round($Stats.sd, 3)
		$rec.cv     = [math]::Round($Stats.cv, 4)
	}
	if ($Detail) { $rec.detail = $Detail }
	$Measurements.Add([pscustomobject]$rec)
}

# ファイル名に使えない文字を落とす。'node:http' のような値をそのまま
# パスに入れると NTFS の代替データストリーム扱いになり、Remove-Item が失敗する。
function ConvertTo-SafeName {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
	return ($Text -replace '[^A-Za-z0-9_.\-]', '_')
}

function Save-Raw {
	param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
	$p = Join-Path $RawDir (ConvertTo-SafeName $Name)
	[System.IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# --- 自己計測（スクリプト自身が BENCH 行を出力する） ---
function Invoke-SelfTimed {
	param(
		[Parameter(Mandatory)][object]$Runtime,
		[Parameter(Mandatory)][string]$ScriptPath,
		[Parameter(Mandatory)][string]$Id,
		[Parameter(Mandatory)][string]$Item
	)
	$samples = New-Object System.Collections.Generic.List[double]
	$lastDetail = $null
	$firstError = ''
	$unsupported = ''
	$rawLines = New-Object System.Collections.Generic.List[string]

	for ($i = 1; $i -le $Runs; $i++) {
		$argList = @($Runtime.RunArgs) + @($ScriptPath)
		$out = ''
		try {
			$out = (& $Runtime.Exe @argList 2>&1 | Out-String)
		}
		catch {
			$out = "EXCEPTION: " + $_.Exception.Message
		}
		$rawLines.Add(("--- run {0} ---`n{1}" -f $i, $out.Trim()))
		$line = ($out -split "`r?`n") | Where-Object { $_ -like 'BENCH *' } | Select-Object -First 1
		if (-not $line) {
			if (-not $firstError) { $firstError = ($out.Trim() -split "`r?`n" | Select-Object -First 3) -join ' / ' }
			continue
		}
		$obj = $null
		try { $obj = ($line.Substring(6)) | ConvertFrom-Json } catch { $obj = $null }
		if (-not $obj) { continue }
		if ($obj.PSObject.Properties.Name -contains 'unsupported') {
			$unsupported = [string]$obj.reason
			break
		}
		$samples.Add([double]$obj.ms)
		if ($obj.PSObject.Properties.Name -contains 'detail') { $lastDetail = $obj.detail }
	}

	Save-Raw -Name ("{0}_{1}.txt" -f $Id, $Runtime.Key) -Text ($rawLines -join "`n")

	if ($unsupported) {
		Add-Measurement -Id $Id -Item $Item -Runtime $Runtime.Key -Metric '所要時間' -Unit 'ms' `
			-Stats $null -Detail $null -Ok $false -Note ("未対応: " + $unsupported)
		Write-Host ("    {0,-16} 未対応: {1}" -f $Runtime.Key, $unsupported)
		return
	}
	if ($samples.Count -eq 0) {
		Add-Measurement -Id $Id -Item $Item -Runtime $Runtime.Key -Metric '所要時間' -Unit 'ms' `
			-Stats $null -Detail $null -Ok $false -Note ("計測失敗: " + $firstError)
		Write-Host ("    {0,-16} 失敗: {1}" -f $Runtime.Key, $firstError)
		return
	}
	$stats = Get-Stats -Values $samples.ToArray()
	Add-Measurement -Id $Id -Item $Item -Runtime $Runtime.Key -Metric '所要時間' -Unit 'ms' `
		-Stats $stats -Detail $lastDetail -Ok $true
	Write-Host ("    {0,-16} 中央値 {1,10:N2} ms   (n={2}, 変動係数 {3:P1})" -f $Runtime.Key, $stats.median, $stats.n, $stats.cv)
}

# --- hyperfine によるプロセス単位の計測 ---
function Invoke-Hyperfine {
	param(
		[Parameter(Mandatory)][object]$Runtime,
		[Parameter(Mandatory)][string[]]$CommandParts,
		[Parameter(Mandatory)][string]$Id,
		[Parameter(Mandatory)][string]$Item,
		[string]$Variant = 'common'
	)
	$exportPath = Join-Path $TmpDir ("hf-{0}-{1}.json" -f $Id, $Runtime.Key)
	if (Test-Path -LiteralPath $exportPath) { Remove-Item -LiteralPath $exportPath -Force }

	# --shell=none の hyperfine はコマンド文字列を shell-words 規則で分割するため、
	# Windows のバックスラッシュがエスケープとして食われる。スラッシュに直して渡す。
	$cmd = (@($CommandParts | ForEach-Object { $_ -replace '\\', '/' }) -join ' ')
	$hfArgs = @(
		'-N'                                  # シェルを介さない（起動時間に cmd.exe を混ぜない）
		'--warmup', "$Warmup"
		'--runs', "$Runs"
		'--export-json', $exportPath
		'--style', 'none'
		'--command-name', ("{0}:{1}" -f $Id, $Runtime.Key)
		$cmd
	)
	$out = ''
	try {
		$out = (& $Hyperfine @hfArgs 2>&1 | Out-String)
	}
	catch {
		$out = "EXCEPTION: " + $_.Exception.Message
	}
	Save-Raw -Name ("{0}_{1}_{2}_hyperfine.txt" -f $Id, $Runtime.Key, $Variant) -Text ($cmd + "`n`n" + $out)

	if (-not (Test-Path -LiteralPath $exportPath)) {
		$note = ($out.Trim() -split "`r?`n" | Select-Object -First 3) -join ' / '
		Add-Measurement -Id $Id -Item $Item -Runtime $Runtime.Key -Variant $Variant -Metric '所要時間' -Unit 'ms' `
			-Stats $null -Detail $null -Ok $false -Note ("計測失敗: " + $note)
		Write-Host ("    {0,-16} 失敗: {1}" -f $Runtime.Key, $note)
		return
	}
	$j = Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json
	$res = $j.results[0]
	$times = @($res.times | ForEach-Object { [double]$_ * 1000 })
	$stats = Get-Stats -Values $times
	Add-Measurement -Id $Id -Item $Item -Runtime $Runtime.Key -Variant $Variant -Metric '所要時間' -Unit 'ms' `
		-Stats $stats -Detail ([ordered]@{ command = $cmd; exitCodes = @($res.exit_codes | Select-Object -Unique) }) -Ok $true
	Write-Host ("    {0,-16} 中央値 {1,10:N2} ms   (n={2}, 変動係数 {3:P1})" -f $Runtime.Key, $stats.median, $stats.n, $stats.cv)
}

# --- HTTP サーバの起動・停止 ---
function Start-BenchServer {
	param(
		[Parameter(Mandatory)][string]$Exe,
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgList,
		[Parameter(Mandatory)][int]$Port,
		[Parameter(Mandatory)][string]$Tag
	)
	$safeTag = ConvertTo-SafeName $Tag
	$outLog = Join-Path $TmpDir ("srv-{0}.out.txt" -f $safeTag)
	$errLog = Join-Path $TmpDir ("srv-{0}.err.txt" -f $safeTag)
	foreach ($f in @($outLog, $errLog)) {
		if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
	}
	$env:BENCH_PORT = "$Port"
	$proc = Start-Process -FilePath $Exe -ArgumentList $ArgList -PassThru -WindowStyle Hidden `
		-RedirectStandardOutput $outLog -RedirectStandardError $errLog

	$ready = $false
	for ($i = 0; $i -lt 160; $i++) {
		[System.Threading.Thread]::Sleep(250)
		if ($proc.HasExited) { break }
		$txt = ''
		try { $txt = Get-Content -LiteralPath $outLog -Raw -ErrorAction Stop } catch { $txt = '' }
		if ($txt -and $txt -match 'READY') {
			try {
				$c = New-Object System.Net.Sockets.TcpClient
				$c.Connect('127.0.0.1', $Port)
				$c.Close()
				$ready = $true
				break
			}
			catch { }
		}
	}
	$errText = ''
	try { $errText = (Get-Content -LiteralPath $errLog -Raw -ErrorAction Stop) } catch { $errText = '' }
	return [pscustomobject]@{ Process = $proc; Ready = $ready; OutLog = $outLog; ErrLog = $errLog; ErrText = $errText }
}

function Stop-BenchServer {
	param([Parameter(Mandatory)][object]$Server)
	if ($Server.Process -and -not $Server.Process.HasExited) {
		try { Stop-Process -Id $Server.Process.Id -Force -ErrorAction Stop } catch { }
	}
	# TIME_WAIT でポートが掴まれたままにならないよう少し待つ
	[System.Threading.Thread]::Sleep(700)
}

# --- B-03 HTTP 計測 ---
$script:HttpPort = 3200

function Invoke-HttpBench {
	param(
		[Parameter(Mandatory)][object]$Runtime,
		[Parameter(Mandatory)][string]$ServerScript,
		[Parameter(Mandatory)][string]$Variant,
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RunArgs
	)
	$script:HttpPort++
	$port = $script:HttpPort
	$tag = "{0}-{1}" -f $Runtime.Key, $Variant
	$argList = @($RunArgs) + @($ServerScript)

	$srv = Start-BenchServer -Exe $Runtime.Exe -ArgList $argList -Port $port -Tag $tag
	if (-not $srv.Ready) {
		Stop-BenchServer -Server $srv
		$note = ($srv.ErrText.Trim() -split "`r?`n" | Select-Object -First 3) -join ' / '
		if (-not $note) { $note = 'READY 出力を確認できませんでした' }
		Add-Measurement -Id 'B-03' -Item 'HTTP スループット' -Runtime $Runtime.Key -Variant $Variant `
			-Metric 'req/s' -Unit 'req/s' -Stats $null -Detail $null -Ok $false -Note ("サーバ起動失敗: " + $note)
		Write-Host ("    {0,-16} [{1}] サーバ起動失敗: {2}" -f $Runtime.Key, $Variant, $note)
		return
	}

	$ohaArgs = @(
		'--no-tui'
		'--output-format', 'json'
		'-c', "$HttpConnections"
		'-z', ("{0}s" -f $HttpSeconds)
		('http://127.0.0.1:{0}/' -f $port)
	)
	$json = ''
	try {
		$json = (& $Oha @ohaArgs 2>&1 | Out-String)
	}
	catch {
		$json = "EXCEPTION: " + $_.Exception.Message
	}
	Stop-BenchServer -Server $srv
	Save-Raw -Name ("B-03_{0}_{1}_oha.json" -f $Runtime.Key, $Variant) -Text $json.Trim()

	$parsed = $null
	try { $parsed = $json | ConvertFrom-Json } catch { $parsed = $null }
	if (-not $parsed -or -not $parsed.summary) {
		$note = ($json.Trim() -split "`r?`n" | Select-Object -First 3) -join ' / '
		Add-Measurement -Id 'B-03' -Item 'HTTP スループット' -Runtime $Runtime.Key -Variant $Variant `
			-Metric 'req/s' -Unit 'req/s' -Stats $null -Detail $null -Ok $false -Note ("負荷計測失敗: " + $note)
		Write-Host ("    {0,-16} [{1}] 負荷計測失敗" -f $Runtime.Key, $Variant)
		return
	}

	$rps = [double]$parsed.summary.requestsPerSec
	$p50 = $null; $p99 = $null
	if ($parsed.latencyPercentiles) {
		$p50 = [double]$parsed.latencyPercentiles.p50 * 1000
		$p99 = [double]$parsed.latencyPercentiles.p99 * 1000
	}
	$codes = @{}
	if ($parsed.statusCodeDistribution) {
		foreach ($pr in $parsed.statusCodeDistribution.PSObject.Properties) { $codes[$pr.Name] = $pr.Value }
	}
	$detail = [ordered]@{
		connections = $HttpConnections
		durationSec = $HttpSeconds
		successRate = $parsed.summary.successRate
		p50Ms       = $(if ($null -ne $p50) { [math]::Round($p50, 3) } else { $null })
		p99Ms       = $(if ($null -ne $p99) { [math]::Round($p99, 3) } else { $null })
		statusCodes = $codes
		port        = $port
	}
	# 1 回の負荷試験なので統計は単一値として扱う
	$stats = Get-Stats -Values @($rps)
	Add-Measurement -Id 'B-03' -Item 'HTTP スループット' -Runtime $Runtime.Key -Variant $Variant `
		-Metric 'req/s' -Unit 'req/s' -Stats $stats -Detail $detail -Ok $true
	Write-Host ("    {0,-16} [{1,-12}] {2,12:N0} req/s   p99 {3,8:N2} ms" -f $Runtime.Key, $Variant, $rps, $p99)
}

# ---------------------------------------------------------------------------
# 実行
# ---------------------------------------------------------------------------
$startedAt = Get-Date
Write-Host ''
Write-Host '=== ベンチマーク実行 ==='
Write-Host ("試行回数: {0}  ウォームアップ: {1}  ファイル数(B-05): {2}  HTTP: {3}秒/{4}接続" -f $Runs, $Warmup, $FileCount, $HttpSeconds, $HttpConnections)
if ($Only) { Write-Host ("対象項目: {0}" -f ($Only -join ', ')) }
Write-Host ''

$env:BENCH_FILE_COUNT = "$FileCount"

# テストデータの用意
$fixture = Join-Path $BenchDir 'fixtures\large.json'
if (-not (Test-Path -LiteralPath $fixture)) {
	Write-Host 'テストデータを生成します...'
	& (Get-ToolExe 'node26') (Join-Path $BenchDir 'gen-fixtures.mjs') | Out-Null
}

# --- B-01 空スクリプト起動 ---
if (Test-Wanted 'B-01') {
	Write-Host '[B-01] 空スクリプト起動'
	foreach ($rt in $Runtimes) {
		Invoke-Hyperfine -Runtime $rt -Id 'B-01' -Item '空スクリプト起動' `
			-CommandParts (@($rt.Exe) + $rt.RunArgs + @((Join-Path $BenchDir 'common\b01-startup.mjs')))
	}
	Write-Host ''
}

# --- B-02 依存込み起動 ---
if (Test-Wanted 'B-02') {
	Write-Host '[B-02] 依存込み起動'
	$depsScript = Join-Path $BenchDir 'deps\b02-startup-deps.mjs'
	$depsModules = Join-Path $BenchDir 'deps\node_modules'
	if (-not (Test-Path -LiteralPath $depsModules)) {
		Write-Host '    未実施: bench/deps/node_modules がありません（scripts\run-install-bench.ps1 を先に実行）'
		foreach ($rt in $Runtimes) {
			Add-Measurement -Id 'B-02' -Item '依存込み起動' -Runtime $rt.Key -Metric '所要時間' -Unit 'ms' `
				-Stats $null -Detail $null -Ok $false -Note '未実施: 依存が未インストール'
		}
	}
	else {
		foreach ($rt in $Runtimes) {
			Invoke-Hyperfine -Runtime $rt -Id 'B-02' -Item '依存込み起動' `
				-CommandParts (@($rt.Exe) + $rt.RunArgs + @($depsScript))
		}
	}
	Write-Host ''
}

# --- B-03 HTTP スループット ---
if (Test-Wanted 'B-03') {
	Write-Host '[B-03] HTTP スループット'
	$commonServer = Join-Path $BenchDir 'common\b03-http.mjs'
	foreach ($rt in $Runtimes) {
		Invoke-HttpBench -Runtime $rt -ServerScript $commonServer -Variant 'node:http' -RunArgs $rt.RunArgs
	}
	# ランタイム固有 API 版
	$denoRt = $Runtimes | Where-Object { $_.Key -eq 'deno' } | Select-Object -First 1
	Invoke-HttpBench -Runtime $denoRt -ServerScript (Join-Path $BenchDir 'native\deno\b03-http.ts') -Variant 'Deno.serve' -RunArgs $denoRt.RunArgs
	$bunRt = $Runtimes | Where-Object { $_.Key -eq 'bun' } | Select-Object -First 1
	Invoke-HttpBench -Runtime $bunRt -ServerScript (Join-Path $BenchDir 'native\bun\b03-http.mjs') -Variant 'Bun.serve' -RunArgs $bunRt.RunArgs
	Write-Host ''
}

# --- 自己計測系 ---
$SelfTimed = @(
	[pscustomobject]@{ Id = 'B-04'; Item = 'JSON 処理';        Script = 'common\b04-json.mjs' }
	[pscustomobject]@{ Id = 'B-05'; Item = 'ファイル I/O';     Script = 'common\b05-fileio.mjs' }
	[pscustomobject]@{ Id = 'B-06'; Item = 'CPU バウンド処理'; Script = 'common\b06-cpu.mjs' }
	[pscustomobject]@{ Id = 'B-07'; Item = 'SQLite';           Script = 'common\b07-sqlite.mjs' }
)
foreach ($b in $SelfTimed) {
	if (-not (Test-Wanted $b.Id)) { continue }
	Write-Host ("[{0}] {1}" -f $b.Id, $b.Item)
	foreach ($rt in $Runtimes) {
		$env:BENCH_RUNTIME = $rt.Key
		Invoke-SelfTimed -Runtime $rt -ScriptPath (Join-Path $BenchDir $b.Script) -Id $b.Id -Item $b.Item
	}
	Write-Host ''
}

# --- B-09 TypeScript 実行（プロセス単位。型ストリップの費用を含める） ---
if (Test-Wanted 'B-09') {
	Write-Host '[B-09] TypeScript 実行（設定なしで .ts を直接実行）'
	foreach ($rt in $Runtimes) {
		Invoke-Hyperfine -Runtime $rt -Id 'B-09' -Item 'TypeScript 実行' `
			-CommandParts (@($rt.Exe) + $rt.RunArgs + @((Join-Path $BenchDir 'common\b09-types.ts')))
	}
	Write-Host ''
}

# --- B-11 テスト実行 ---
if (Test-Wanted 'B-11') {
	Write-Host '[B-11] テスト実行（node:test の 200 件を各ランナーで）'
	$suite = Join-Path $BenchDir 'tests\suite.test.mjs'
	foreach ($rt in $Runtimes) {
		Invoke-Hyperfine -Runtime $rt -Id 'B-11' -Item 'テスト実行' `
			-CommandParts (@($rt.Exe) + $rt.TestArgs + @($suite))
	}
	Write-Host ''
}

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------
$finishedAt = Get-Date
$outJson = Join-Path $RawDir 'measurements.json'

# -Append 指定時は、今回測り直していない項目を前回の結果から引き継ぐ
$Combined = New-Object System.Collections.Generic.List[object]
if ($Append -and (Test-Path -LiteralPath $outJson)) {
	$prev = Get-Content -LiteralPath $outJson -Raw | ConvertFrom-Json
	$newKeys = @{}
	foreach ($m in $Measurements) { $newKeys[("{0}|{1}|{2}" -f $m.id, $m.runtime, $m.variant)] = $true }
	$carried = 0
	foreach ($m in $prev.measurements) {
		$k = "{0}|{1}|{2}" -f $m.id, $m.runtime, $m.variant
		if (-not $newKeys.ContainsKey($k)) { $Combined.Add($m); $carried++ }
	}
	Write-Host ("前回の結果から {0} 件を引き継ぎました" -f $carried)
}
foreach ($m in $Measurements) { $Combined.Add($m) }
$Measurements = $Combined

$payload = [ordered]@{
	startedAt  = $startedAt.ToString('yyyy-MM-dd HH:mm:ss')
	finishedAt = $finishedAt.ToString('yyyy-MM-dd HH:mm:ss')
	settings   = [ordered]@{
		runs = $Runs; warmup = $Warmup; fileCount = $FileCount
		httpSeconds = $HttpSeconds; httpConnections = $HttpConnections
		quick = [bool]$Quick; appended = [bool]$Append
	}
	measurements = $Measurements
}
[System.IO.File]::WriteAllText($outJson, ($payload | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

function Get-Field {
	param([Parameter(Mandatory)][object]$Row, [Parameter(Mandatory)][string]$Name)
	if ($Row.PSObject.Properties.Name -contains $Name) { return $Row.$Name }
	return ''
}

$csvPath = Join-Path $Root 'results\measurements.csv'
$csvRows = $Measurements | Select-Object id, item, runtime, variant, metric, unit, ok,
	@{ Name = 'n';      Expression = { Get-Field -Row $_ -Name 'n' } },
	@{ Name = 'median'; Expression = { Get-Field -Row $_ -Name 'median' } },
	@{ Name = 'min';    Expression = { Get-Field -Row $_ -Name 'min' } },
	@{ Name = 'max';    Expression = { Get-Field -Row $_ -Name 'max' } },
	@{ Name = 'sd';     Expression = { Get-Field -Row $_ -Name 'sd' } },
	@{ Name = 'cv';     Expression = { Get-Field -Row $_ -Name 'cv' } },
	note
# Excel で開いても日本語が化けないよう BOM 付き UTF-8 で書く
$csvText = (($csvRows | ConvertTo-Csv -NoTypeInformation) -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($csvPath, $csvText, (New-Object System.Text.UTF8Encoding($true)))

Write-Host ("計測結果: {0}" -f $outJson)
Write-Host ("集計 CSV : {0}" -f $csvPath)
Write-Host ("所要時間 : {0:N1} 分" -f ($finishedAt - $startedAt).TotalMinutes)
Write-Host ''
Write-Host '=== ベンチマーク実行 完了 ==='
