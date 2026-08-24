<#
	Node.js / Deno / Bun 比較検証 — B-08 依存インストール計測 と P3 npm 互換性チェック

	各パッケージマネージャに専用の作業ディレクトリとキャッシュを与え、
	同一の package.json（bench/compat）に対して
	  1) クリーン（キャッシュ無し・lock 無し）
	  2) キャッシュ有り（node_modules だけ削除）
	の 2 条件でインストール時間を測る。
	その後、それぞれの node_modules に対して対応するランタイムで
	npm パッケージの import を試し、成功／失敗を記録する。
#>
[CmdletBinding()]
param(
	# 1 回のインストールを待つ上限（秒）
	[int]$TimeoutSec = 1200,
	# インストール計測をスキップして互換性チェックだけ行う
	[switch]$CompatOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$Root      = Split-Path -Parent $PSScriptRoot
$BenchDir  = Join-Path $Root 'bench'
$ToolsDir  = Join-Path $Root 'tools'
$WorkRoot  = Join-Path $Root 'tmp\install'
$RawDir    = Join-Path $Root 'results\raw'

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
$Node24 = Get-ToolExe 'node24'
$Deno   = Get-ToolExe 'deno'
$Bun    = Get-ToolExe 'bun'
$NpmCli = Join-Path (Split-Path -Parent $Node26) 'node_modules\npm\bin\npm-cli.js'

# ---------------------------------------------------------------------------
# パッケージマネージャ定義
# ---------------------------------------------------------------------------
$PMs = @(
	[pscustomobject]@{
		Key = 'npm'; Label = 'npm（Node 26 同梱）'
		Exe = $Node26
		InstallArgs = @($NpmCli, 'install', '--no-audit', '--no-fund', '--loglevel=error')
		CacheEnvName = 'npm_config_cache'
		# npm は postinstall スクリプトを既定で実行する
		ScriptPolicy = '既定で実行'
		Runtimes = @(
			[pscustomobject]@{ Key = 'node26'; Exe = $Node26; RunArgs = @() }
			[pscustomobject]@{ Key = 'node24'; Exe = $Node24; RunArgs = @() }
		)
	}
	[pscustomobject]@{
		Key = 'deno'; Label = 'deno install'
		Exe = $Deno
		InstallArgs = @('install', '--allow-scripts')
		CacheEnvName = 'DENO_DIR'
		ScriptPolicy = '--allow-scripts で明示的に許可'
		Runtimes = @(
			[pscustomobject]@{ Key = 'deno'; Exe = $Deno; RunArgs = @('run', '-A') }
		)
	}
	[pscustomobject]@{
		Key = 'bun'; Label = 'bun install'
		Exe = $Bun
		InstallArgs = @('install')
		CacheEnvName = 'BUN_INSTALL_CACHE_DIR'
		ScriptPolicy = '既定でブロック（trustedDependencies が必要）'
		Runtimes = @(
			[pscustomobject]@{ Key = 'bun'; Exe = $Bun; RunArgs = @('run') }
		)
	}
)

$LockFiles = @('package-lock.json', 'npm-shrinkwrap.json', 'bun.lock', 'bun.lockb', 'deno.lock')

# ---------------------------------------------------------------------------
# 補助関数
# ---------------------------------------------------------------------------
function Invoke-Measured {
	param(
		[Parameter(Mandatory)][string]$Exe,
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgList,
		[Parameter(Mandatory)][string]$WorkDir,
		[hashtable]$EnvVars = @{},
		[Parameter(Mandatory)][string]$LogTag,
		[int]$Timeout = 1200
	)
	$outLog = Join-Path $WorkRoot ("{0}.out.txt" -f $LogTag)
	$errLog = Join-Path $WorkRoot ("{0}.err.txt" -f $LogTag)
	foreach ($f in @($outLog, $errLog)) {
		if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
	}

	# 子プロセスに渡すため、いったん自プロセスの環境変数を書き換える
	$saved = @{}
	foreach ($k in $EnvVars.Keys) {
		$saved[$k] = [Environment]::GetEnvironmentVariable($k)
		[Environment]::SetEnvironmentVariable($k, $EnvVars[$k])
	}
	try {
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
	}
	finally {
		foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
	}

	$outText = ''
	$errText = ''
	try { $outText = Get-Content -LiteralPath $outLog -Raw -ErrorAction Stop } catch { $outText = '' }
	try { $errText = Get-Content -LiteralPath $errLog -Raw -ErrorAction Stop } catch { $errText = '' }

	return [pscustomobject]@{
		Ms       = $sw.Elapsed.TotalMilliseconds
		ExitCode = $code
		TimedOut = (-not $exited)
		Out      = [string]$outText
		Err      = [string]$errText
	}
}

function Get-DirStats {
	param([Parameter(Mandatory)][string]$Path)
	if (-not (Test-Path -LiteralPath $Path)) {
		return [pscustomobject]@{ Files = 0; MB = 0.0 }
	}
	$files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
	$sum = ($files | Measure-Object -Property Length -Sum).Sum
	if (-not $sum) { $sum = 0 }
	return [pscustomobject]@{ Files = @($files).Count; MB = [math]::Round($sum / 1MB, 1) }
}

function Remove-IfExists {
	param([Parameter(Mandatory)][string]$Path)
	if (Test-Path -LiteralPath $Path) {
		Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
	}
}

function Save-Raw {
	param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
	[System.IO.File]::WriteAllText((Join-Path $RawDir $Name), $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FirstLines {
	param([AllowNull()][string]$Text, [int]$Count = 3)
	if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
	return (($Text.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First $Count) -join ' / ')
}

# ---------------------------------------------------------------------------
# B-08 依存インストール
# ---------------------------------------------------------------------------
$InstallResults = New-Object System.Collections.Generic.List[object]
$startedAt = Get-Date

Write-Host ''
Write-Host '=== B-08 依存インストール / P3 npm 互換性チェック ==='
Write-Host ("対象 package.json: {0}" -f (Join-Path $BenchDir 'compat\package.json'))
Write-Host ''

foreach ($pm in $PMs) {
	$work  = Join-Path $WorkRoot $pm.Key
	$cache = Join-Path $WorkRoot ("cache-" + $pm.Key)

	Write-Host ("[{0}] {1}" -f $pm.Key, $pm.Label)

	if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
	Copy-Item -LiteralPath (Join-Path $BenchDir 'compat\package.json') -Destination (Join-Path $work 'package.json') -Force

	$envVars = @{ }
	$envVars[$pm.CacheEnvName] = $cache

	if (-not $CompatOnly) {
		# --- 1) クリーン（キャッシュも lock も無い状態） ---
		Remove-IfExists (Join-Path $work 'node_modules')
		foreach ($lf in $LockFiles) { Remove-IfExists (Join-Path $work $lf) }
		Remove-IfExists $cache

		$clean = Invoke-Measured -Exe $pm.Exe -ArgList $pm.InstallArgs -WorkDir $work -EnvVars $envVars `
			-LogTag ("install-{0}-clean" -f $pm.Key) -Timeout $TimeoutSec
		$cleanStats = Get-DirStats (Join-Path $work 'node_modules')
		Save-Raw -Name ("B-08_{0}_clean.txt" -f $pm.Key) -Text ("EXIT={0} TIMEDOUT={1}`n--- stdout ---`n{2}`n--- stderr ---`n{3}" -f $clean.ExitCode, $clean.TimedOut, $clean.Out, $clean.Err)

		$okClean = ($clean.ExitCode -eq 0 -and -not $clean.TimedOut)
		Write-Host ("    クリーン    : {0,8:N1} 秒  終了コード {1}  node_modules {2} ファイル / {3} MB{4}" -f `
			($clean.Ms / 1000), $clean.ExitCode, $cleanStats.Files, $cleanStats.MB, $(if ($clean.TimedOut) { '  ★タイムアウト' } else { '' }))

		$InstallResults.Add([pscustomobject]@{
			id = 'B-08'; pm = $pm.Key; label = $pm.Label; scenario = 'クリーン'
			seconds = [math]::Round($clean.Ms / 1000, 2)
			exitCode = $clean.ExitCode; timedOut = $clean.TimedOut; ok = $okClean
			files = $cleanStats.Files; sizeMB = $cleanStats.MB
			scriptPolicy = $pm.ScriptPolicy
			note = $(if ($okClean) { '' } else { Get-FirstLines -Text ($clean.Err + "`n" + $clean.Out) -Count 4 })
		})

		# --- 2) キャッシュ有り（node_modules だけ削除。lock とキャッシュは残す） ---
		Remove-IfExists (Join-Path $work 'node_modules')

		$cached = Invoke-Measured -Exe $pm.Exe -ArgList $pm.InstallArgs -WorkDir $work -EnvVars $envVars `
			-LogTag ("install-{0}-cached" -f $pm.Key) -Timeout $TimeoutSec
		$cachedStats = Get-DirStats (Join-Path $work 'node_modules')
		Save-Raw -Name ("B-08_{0}_cached.txt" -f $pm.Key) -Text ("EXIT={0} TIMEDOUT={1}`n--- stdout ---`n{2}`n--- stderr ---`n{3}" -f $cached.ExitCode, $cached.TimedOut, $cached.Out, $cached.Err)

		$okCached = ($cached.ExitCode -eq 0 -and -not $cached.TimedOut)
		Write-Host ("    キャッシュ有: {0,8:N1} 秒  終了コード {1}  node_modules {2} ファイル / {3} MB{4}" -f `
			($cached.Ms / 1000), $cached.ExitCode, $cachedStats.Files, $cachedStats.MB, $(if ($cached.TimedOut) { '  ★タイムアウト' } else { '' }))

		$InstallResults.Add([pscustomobject]@{
			id = 'B-08'; pm = $pm.Key; label = $pm.Label; scenario = 'キャッシュ有'
			seconds = [math]::Round($cached.Ms / 1000, 2)
			exitCode = $cached.ExitCode; timedOut = $cached.TimedOut; ok = $okCached
			files = $cachedStats.Files; sizeMB = $cachedStats.MB
			scriptPolicy = $pm.ScriptPolicy
			note = $(if ($okCached) { '' } else { Get-FirstLines -Text ($cached.Err + "`n" + $cached.Out) -Count 4 })
		})

		# 生成された lock ファイルを記録
		$locks = @()
		foreach ($lf in $LockFiles) {
			if (Test-Path -LiteralPath (Join-Path $work $lf)) { $locks += $lf }
		}
		Write-Host ("    lock ファイル: {0}" -f $(if ($locks.Count) { $locks -join ', ' } else { '（生成なし）' }))
	}
	Write-Host ''
}

# ---------------------------------------------------------------------------
# P3 npm 互換性チェック
# ---------------------------------------------------------------------------
$CompatResults = New-Object System.Collections.Generic.List[object]

Write-Host '--- P3 npm 互換性チェック ---'
foreach ($pm in $PMs) {
	$work = Join-Path $WorkRoot $pm.Key
	if (-not (Test-Path -LiteralPath (Join-Path $work 'node_modules'))) {
		Write-Host ("[{0}] node_modules が無いためスキップ" -f $pm.Key)
		continue
	}
	Copy-Item -LiteralPath (Join-Path $BenchDir 'compat\check-compat.mjs') -Destination (Join-Path $work 'check-compat.mjs') -Force

	foreach ($rt in $pm.Runtimes) {
		$argList = @($rt.RunArgs) + @('check-compat.mjs')
		$res = Invoke-Measured -Exe $rt.Exe -ArgList $argList -WorkDir $work -LogTag ("compat-{0}" -f $rt.Key) -Timeout 300
		Save-Raw -Name ("P3_compat_{0}.txt" -f $rt.Key) -Text ("EXIT={0}`n--- stdout ---`n{1}`n--- stderr ---`n{2}" -f $res.ExitCode, $res.Out, $res.Err)

		$line = ($res.Out -split "`r?`n") | Where-Object { $_ -like 'COMPAT *' } | Select-Object -First 1
		if (-not $line) {
			Write-Host ("[{0}] 互換性チェック自体が失敗: {1}" -f $rt.Key, (Get-FirstLines -Text ($res.Err + "`n" + $res.Out)))
			$CompatResults.Add([pscustomobject]@{
				runtime = $rt.Key; installedBy = $pm.Key; package = '(全体)'; kind = ''
				imported = $false; usable = $false; ms = 0
				reason = '互換性チェックスクリプトが完走しなかった: ' + (Get-FirstLines -Text ($res.Err + "`n" + $res.Out))
			})
			continue
		}
		$obj = $line.Substring(7) | ConvertFrom-Json
		$okCount = 0
		foreach ($e in $obj.results) {
			if ($e.imported -and $e.usable) { $okCount++ }
			$CompatResults.Add([pscustomobject]@{
				runtime = $rt.Key; installedBy = $pm.Key
				package = $e.name; kind = $e.kind
				imported = [bool]$e.imported; usable = [bool]$e.usable
				ms = $e.ms; reason = [string]$e.reason
			})
		}
		Write-Host ("[{0}] {1} / {2} パッケージが import かつ利用可（インストール: {3}）" -f $rt.Key, $okCount, @($obj.results).Count, $pm.Key)
		foreach ($e in $obj.results) {
			if (-not ($e.imported -and $e.usable)) {
				Write-Host ("      NG  {0,-16} {1}" -f $e.name, $e.reason)
			}
		}
	}
}
Write-Host ''

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------
$finishedAt = Get-Date
if (-not $CompatOnly) {
	$installPayload = [ordered]@{
		startedAt = $startedAt.ToString('yyyy-MM-dd HH:mm:ss')
		finishedAt = $finishedAt.ToString('yyyy-MM-dd HH:mm:ss')
		results = $InstallResults
	}
	[System.IO.File]::WriteAllText((Join-Path $RawDir 'install.json'), ($installPayload | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
	Write-Host ("インストール計測: {0}" -f (Join-Path $RawDir 'install.json'))
}
$compatPayload = [ordered]@{
	generatedAt = $finishedAt.ToString('yyyy-MM-dd HH:mm:ss')
	results = $CompatResults
}
[System.IO.File]::WriteAllText((Join-Path $RawDir 'compat.json'), ($compatPayload | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("互換性チェック  : {0}" -f (Join-Path $RawDir 'compat.json'))
Write-Host ("所要時間        : {0:N1} 分" -f ($finishedAt - $startedAt).TotalMinutes)
Write-Host ''
Write-Host '=== B-08 / P3 完了 ==='
