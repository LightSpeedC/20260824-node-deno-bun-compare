<#
	Node.js / Deno / Bun 比較検証 — P6 集計

	results/raw/ 配下の生結果（measurements.json / install.json / compat.json / compile.json）を
	1 つに束ね、項目ごとの相対スコアと評価軸ごとの重み付きスコアを計算する。

	定性評価は results/qualitative.json に手で書いたスコアを読み込む（無ければ該当軸を除外する）。
	結論の文章は人が書く。このスクリプトは数値だけを出す。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root       = Split-Path -Parent $PSScriptRoot
$RawDir     = Join-Path $Root 'results\raw'
$ResultsDir = Join-Path $Root 'results'

function Read-JsonIfExists {
	param([Parameter(Mandatory)][string]$Path)
	if (-not (Test-Path -LiteralPath $Path)) { return $null }
	return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

$meas    = Read-JsonIfExists (Join-Path $RawDir 'measurements.json')
$install = Read-JsonIfExists (Join-Path $RawDir 'install.json')
$compat  = Read-JsonIfExists (Join-Path $RawDir 'compat.json')
$compile = Read-JsonIfExists (Join-Path $RawDir 'compile.json')
$qual    = Read-JsonIfExists (Join-Path $ResultsDir 'qualitative.json')

if (-not $meas) { throw 'results/raw/measurements.json がありません。先に run-bench.ps1 を実行してください。' }

# 比較対象（node24 は参考値として最後に置く）
$RuntimeOrder = @('node26', 'deno', 'bun', 'node24')
$RuntimeLabels = @{
	node26 = 'Node.js 26.7.0'
	node24 = 'Node.js 24.19.0 (参考)'
	deno   = 'Deno 2.9.5'
	bun    = 'Bun 1.4.0'
}

# 項目 → 評価軸の対応。Higher=$true は「大きいほど良い」指標
$ItemMeta = [ordered]@{
	'B-01' = @{ Item = '空スクリプト起動';  Axis = '起動性能';       Higher = $false; Unit = 'ms' }
	'B-02' = @{ Item = '依存込み起動';      Axis = '起動性能';       Higher = $false; Unit = 'ms' }
	'B-03' = @{ Item = 'HTTP スループット'; Axis = '実行性能';       Higher = $true;  Unit = 'req/s' }
	'B-04' = @{ Item = 'JSON 処理';         Axis = '実行性能';       Higher = $false; Unit = 'ms' }
	'B-05' = @{ Item = 'ファイル I/O';      Axis = '実行性能';       Higher = $false; Unit = 'ms' }
	'B-06' = @{ Item = 'CPU バウンド処理';  Axis = '実行性能';       Higher = $false; Unit = 'ms' }
	'B-07' = @{ Item = 'SQLite';            Axis = '実行性能';       Higher = $false; Unit = 'ms' }
	'B-08' = @{ Item = '依存インストール';  Axis = 'パッケージ管理'; Higher = $false; Unit = '秒' }
	'B-09' = @{ Item = 'TypeScript 実行';   Axis = 'TypeScript';     Higher = $false; Unit = 'ms' }
	'B-10' = @{ Item = '単一実行ファイル';  Axis = 'ツールチェーン'; Higher = $false; Unit = '秒' }
	'B-11' = @{ Item = 'テスト実行';        Axis = 'ツールチェーン'; Higher = $false; Unit = 'ms' }
	'P-03' = @{ Item = 'npm 互換性';        Axis = 'npm 互換性';     Higher = $true;  Unit = '%' }
}

$AxisWeights = [ordered]@{
	'起動性能'       = 15
	'実行性能'       = 20
	'npm 互換性'     = 15
	'TypeScript'     = 10
	'ツールチェーン' = 10
	'パッケージ管理' = 10
	'運用・サポート' = 10
	'開発体験'       = 5
	'Windows 対応'   = 5
}

# ---------------------------------------------------------------------------
# 生結果を「項目 × ランタイム」の一覧に正規化する
# ---------------------------------------------------------------------------
$Rows = New-Object System.Collections.Generic.List[object]

function Add-Row {
	param(
		[Parameter(Mandatory)][string]$Id,
		[Parameter(Mandatory)][string]$Runtime,
		[Parameter(Mandatory)][bool]$Ok,
		[AllowNull()][object]$Value,
		[string]$Variant = '',
		[string]$Note = ''
	)
	$m = $ItemMeta[$Id]
	$Rows.Add([pscustomobject]@{
		id = $Id; item = $m.Item; axis = $m.Axis; unit = $m.Unit; higherIsBetter = [bool]$m.Higher
		runtime = $Runtime; variant = $Variant
		value = $(if ($null -ne $Value) { [math]::Round([double]$Value, 3) } else { $null })
		ok = $Ok; note = $Note
	})
}

# --- run-bench.ps1 の結果 ---
foreach ($m in $meas.measurements) {
	if (-not $ItemMeta.Contains($m.id)) { continue }
	# B-03 は共通版（node:http）だけを横並び比較に使う。固有 API 版は別枠で保持する
	if ($m.id -eq 'B-03' -and $m.variant -ne 'node:http') { continue }
	$val = $null
	if ($m.ok -and ($m.PSObject.Properties.Name -contains 'median')) { $val = $m.median }
	Add-Row -Id $m.id -Runtime $m.runtime -Ok ([bool]$m.ok) -Value $val -Variant ([string]$m.variant) -Note ([string]$m.note)
}

# --- B-08 依存インストール（キャッシュ有りの時間を代表値にする） ---
$PmToRuntimes = @{ npm = @('node26', 'node24'); deno = @('deno'); bun = @('bun') }
if ($install) {
	foreach ($r in $install.results) {
		if ($r.scenario -ne 'キャッシュ有') { continue }
		foreach ($rt in $PmToRuntimes[$r.pm]) {
			Add-Row -Id 'B-08' -Runtime $rt -Ok ([bool]$r.ok) -Value $(if ($r.ok) { $r.seconds } else { $null }) `
				-Variant $r.pm -Note ([string]$r.note)
		}
	}
}

# --- P3 npm 互換性（成功率 %） ---
if ($compat) {
	$byRuntime = $compat.results | Where-Object { $_.package -ne '(全体)' } | Group-Object runtime
	foreach ($g in $byRuntime) {
		$total = @($g.Group).Count
		$ok = @($g.Group | Where-Object { $_.imported -and $_.usable }).Count
		$rate = 0.0
		if ($total -gt 0) { $rate = 100.0 * $ok / $total }
		Add-Row -Id 'P-03' -Runtime $g.Name -Ok $true -Value $rate -Note ("{0}/{1} パッケージ" -f $ok, $total)
	}
}

# --- B-10 単一実行ファイル化 ---
if ($compile) {
	foreach ($r in $compile.results) {
		Add-Row -Id 'B-10' -Runtime $r.runtime -Ok ([bool]$r.ok) -Value $(if ($r.ok) { $r.seconds } else { $null }) `
			-Variant $r.method -Note ([string]$r.note)
	}
}

# ---------------------------------------------------------------------------
# 相対スコア（各項目の最良値を 100 とする）
# ---------------------------------------------------------------------------
$ScoreRows = New-Object System.Collections.Generic.List[object]

foreach ($id in $ItemMeta.Keys) {
	$group = @($Rows | Where-Object { $_.id -eq $id })
	if ($group.Count -eq 0) { continue }
	$valid = @($group | Where-Object { $_.ok -and $null -ne $_.value -and $_.value -gt 0 })
	if ($valid.Count -eq 0) {
		foreach ($r in $group) {
			$ScoreRows.Add([pscustomobject]@{ id = $id; item = $r.item; axis = $r.axis; runtime = $r.runtime; value = $r.value; score = 0.0; ok = $false; note = $r.note })
		}
		continue
	}
	$higher = $valid[0].higherIsBetter
	if ($higher) {
		$best = ($valid | Measure-Object -Property value -Maximum).Maximum
	}
	else {
		$best = ($valid | Measure-Object -Property value -Minimum).Minimum
	}
	foreach ($r in $group) {
		$score = 0.0
		if ($r.ok -and $null -ne $r.value -and $r.value -gt 0) {
			if ($higher) { $score = 100.0 * $r.value / $best }
			else { $score = 100.0 * $best / $r.value }
		}
		$ScoreRows.Add([pscustomobject]@{
			id = $id; item = $r.item; axis = $r.axis; runtime = $r.runtime
			value = $r.value; score = [math]::Round($score, 1); ok = $r.ok; note = $r.note
		})
	}
}

# ---------------------------------------------------------------------------
# 評価軸ごとのスコア（定量は項目平均、定性は qualitative.json）
# ---------------------------------------------------------------------------
$AxisScores = New-Object System.Collections.Generic.List[object]

foreach ($axis in $AxisWeights.Keys) {
	foreach ($rt in $RuntimeOrder) {
		$items = @($ScoreRows | Where-Object { $_.axis -eq $axis -and $_.runtime -eq $rt })
		$score = $null
		$source = ''
		if ($items.Count -gt 0) {
			$score = [math]::Round((($items | Measure-Object -Property score -Average).Average), 1)
			$source = '定量'
		}
		elseif ($qual) {
			$q = $qual.scores | Where-Object { $_.axis -eq $axis } | Select-Object -First 1
			if ($q -and ($q.PSObject.Properties.Name -contains $rt)) {
				# 5 段階を 100 点満点に換算する
				$score = [math]::Round(20.0 * [double]$q.$rt, 1)
				$source = '定性'
			}
		}
		$AxisScores.Add([pscustomobject]@{
			axis = $axis; weight = $AxisWeights[$axis]; runtime = $rt
			score = $score; source = $source
		})
	}
}

# 総合スコア（評価軸のスコアが揃っているものだけで重み付け平均）
$Totals = New-Object System.Collections.Generic.List[object]
foreach ($rt in $RuntimeOrder) {
	$rows = @($AxisScores | Where-Object { $_.runtime -eq $rt -and $null -ne $_.score })
	$wsum = 0.0
	$acc = 0.0
	foreach ($r in $rows) {
		$wsum += $r.weight
		$acc += $r.weight * $r.score
	}
	$total = $null
	if ($wsum -gt 0) { $total = [math]::Round($acc / $wsum, 1) }
	$Totals.Add([pscustomobject]@{
		runtime = $rt; label = $RuntimeLabels[$rt]
		total = $total; coveredWeight = $wsum
		missingAxes = @($AxisScores | Where-Object { $_.runtime -eq $rt -and $null -eq $_.score } | ForEach-Object { $_.axis })
	})
}

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------
$payload = [ordered]@{
	generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
	settings    = $meas.settings
	runtimes    = $RuntimeOrder
	axisWeights = $AxisWeights
	rows        = $Rows
	scores      = $ScoreRows
	axisScores  = $AxisScores
	totals      = $Totals
	httpNative  = @($meas.measurements | Where-Object { $_.id -eq 'B-03' -and $_.variant -ne 'node:http' })
	install     = $(if ($install) { $install.results } else { @() })
	compat      = $(if ($compat) { $compat.results } else { @() })
	compile     = $(if ($compile) { $compile.results } else { @() })
	qualitative = $(if ($qual) { $qual } else { $null })
}
$outPath = Join-Path $ResultsDir 'summary.json'
[System.IO.File]::WriteAllText($outPath, ($payload | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

# 画面向けの一覧
Write-Host ''
Write-Host '=== 項目別 実測値と相対スコア（最良 = 100）==='
$fmtHeader = "{0,-6} {1,-18} {2,-8}" -f 'ID', '項目', '単位'
foreach ($rt in $RuntimeOrder) { $fmtHeader += ("{0,22}" -f $RuntimeLabels[$rt]) }
Write-Host $fmtHeader
Write-Host ('-' * $fmtHeader.Length)
foreach ($id in $ItemMeta.Keys) {
	$m = $ItemMeta[$id]
	$rowsForId = @($ScoreRows | Where-Object { $_.id -eq $id })
	if ($rowsForId.Count -eq 0) { continue }
	$line = "{0,-6} {1,-18} {2,-8}" -f $id, $m.Item, $m.Unit
	foreach ($rt in $RuntimeOrder) {
		$r = $rowsForId | Where-Object { $_.runtime -eq $rt } | Select-Object -First 1
		if (-not $r) { $line += ("{0,22}" -f '—') }
		elseif (-not $r.ok) { $line += ("{0,22}" -f 'NG') }
		else { $line += ("{0,22}" -f ("{0:N1} ({1:N0})" -f $r.value, $r.score)) }
	}
	Write-Host $line
}

Write-Host ''
Write-Host '=== 評価軸スコア（100 点満点）==='
$hdr = "{0,-16} {1,-6} {2,-6}" -f '評価軸', '重み', '種別'
foreach ($rt in $RuntimeOrder) { $hdr += ("{0,22}" -f $RuntimeLabels[$rt]) }
Write-Host $hdr
Write-Host ('-' * $hdr.Length)
foreach ($axis in $AxisWeights.Keys) {
	$first = $AxisScores | Where-Object { $_.axis -eq $axis } | Select-Object -First 1
	$line = "{0,-16} {1,-6} {2,-6}" -f $axis, $AxisWeights[$axis], $first.source
	foreach ($rt in $RuntimeOrder) {
		$r = $AxisScores | Where-Object { $_.axis -eq $axis -and $_.runtime -eq $rt } | Select-Object -First 1
		if (-not $r -or $null -eq $r.score) { $line += ("{0,22}" -f '未評価') }
		else { $line += ("{0,22}" -f ("{0:N1}" -f $r.score)) }
	}
	Write-Host $line
}

Write-Host ''
Write-Host '=== 総合スコア ==='
foreach ($t in $Totals) {
	$missing = ''
	if (@($t.missingAxes).Count -gt 0) { $missing = "  未評価軸: " + (@($t.missingAxes) -join ', ') }
	if ($null -eq $t.total) {
		Write-Host ("{0,-24} 算出不可{1}" -f $t.label, $missing)
	}
	else {
		Write-Host ("{0,-24} {1,6:N1} 点  （評価済み重み {2}/100）{3}" -f $t.label, $t.total, $t.coveredWeight, $missing)
	}
}

Write-Host ''
Write-Host ("集計結果: {0}" -f $outPath)
Write-Host '=== P6 集計 完了 ==='
