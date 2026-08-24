<#
	Node.js / Deno / Bun 比較検証 — P1 環境整備
	ランタイムと計測ツールをプロジェクト内 tools/ 配下に隔離配置する。
	システム（PATH・レジストリ・既存のグローバル環境）には一切手を入れない。
#>
[CmdletBinding()]
param(
	# 既に配置済みのものも削除して再取得する
	[switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$Root        = Split-Path -Parent $PSScriptRoot
$ToolsDir    = Join-Path $Root 'tools'
$DownloadDir = Join-Path $Root 'tmp\downloads'
$ResultsDir  = Join-Path $Root 'results'

# ---------------------------------------------------------------------------
# 対象一覧（バージョンはここで固定する。検証中は上げない）
#   Mode: tree = アーカイブ内のルートフォルダをまとめて配置
#         exe  = アーカイブ内の実行ファイルだけを取り出す
#         raw  = 単体の実行ファイルを直接ダウンロード
# ---------------------------------------------------------------------------
$Items = @(
	[pscustomobject]@{
		Key = 'node26'; Label = 'Node.js 26 (Current)'; Version = '26.7.0'; Role = '主軸'
		Dir = 'node-v26.7.0-win-x64'; Exe = 'node.exe'; Mode = 'tree'
		Url = 'https://nodejs.org/dist/v26.7.0/node-v26.7.0-win-x64.zip'
		Sha256Url = 'https://nodejs.org/dist/v26.7.0/SHASUMS256.txt'; Sha256Kind = 'list'
		VersionArg = '-v'
	}
	[pscustomobject]@{
		Key = 'node24'; Label = 'Node.js 24 (Active LTS)'; Version = '24.19.0'; Role = '参考'
		Dir = 'node-v24.19.0-win-x64'; Exe = 'node.exe'; Mode = 'tree'
		Url = 'https://nodejs.org/dist/v24.19.0/node-v24.19.0-win-x64.zip'
		Sha256Url = 'https://nodejs.org/dist/v24.19.0/SHASUMS256.txt'; Sha256Kind = 'list'
		VersionArg = '-v'
	}
	[pscustomobject]@{
		Key = 'deno'; Label = 'Deno'; Version = '2.9.5'; Role = '主軸'
		Dir = 'deno-2.9.5'; Exe = 'deno.exe'; Mode = 'exe'
		Url = 'https://github.com/denoland/deno/releases/download/v2.9.5/deno-x86_64-pc-windows-msvc.zip'
		Sha256Url = 'https://github.com/denoland/deno/releases/download/v2.9.5/deno-x86_64-pc-windows-msvc.zip.sha256sum'; Sha256Kind = 'single'
		VersionArg = '-V'
	}
	[pscustomobject]@{
		Key = 'bun'; Label = 'Bun'; Version = '1.4.0'; Role = '主軸'
		Dir = 'bun-1.4.0'; Exe = 'bun.exe'; Mode = 'exe'
		Url = 'https://github.com/oven-sh/bun/releases/download/bun-v1.4.0/bun-windows-x64.zip'
		Sha256Url = $null; Sha256Kind = $null
		VersionArg = '-v'
	}
	[pscustomobject]@{
		Key = 'hyperfine'; Label = 'hyperfine (コマンド計測)'; Version = '1.20.0'; Role = '計測ツール'
		Dir = 'hyperfine-1.20.0'; Exe = 'hyperfine.exe'; Mode = 'exe'
		Url = 'https://github.com/sharkdp/hyperfine/releases/download/v1.20.0/hyperfine-v1.20.0-x86_64-pc-windows-msvc.zip'
		Sha256Url = $null; Sha256Kind = $null
		VersionArg = '--version'
	}
	[pscustomobject]@{
		Key = 'oha'; Label = 'oha (HTTP 負荷生成)'; Version = '1.16.0'; Role = '計測ツール'
		Dir = 'oha-1.16.0'; Exe = 'oha.exe'; Mode = 'raw'
		Url = 'https://github.com/hatoo/oha/releases/download/v1.16.0/oha-windows-amd64.exe'
		Sha256Url = $null; Sha256Kind = $null
		VersionArg = '--version'
	}
)

# ---------------------------------------------------------------------------
# 補助関数
# ---------------------------------------------------------------------------
function New-DirIfMissing {
	param([Parameter(Mandatory)][string]$Path)
	if (-not (Test-Path -LiteralPath $Path)) {
		New-Item -ItemType Directory -Path $Path -Force | Out-Null
	}
}

function Get-RemoteFile {
	param(
		[Parameter(Mandatory)][string]$Url,
		[Parameter(Mandatory)][string]$OutFile
	)
	if (Test-Path -LiteralPath $OutFile) {
		Write-Host ("    ダウンロード済みを再利用: {0}" -f (Split-Path -Leaf $OutFile))
		return
	}
	Write-Host ("    取得中: {0}" -f $Url)
	$tmp = "$OutFile.part"
	Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 900
	Move-Item -LiteralPath $tmp -Destination $OutFile -Force
	$mb = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1)
	Write-Host ("    完了: {0} MB" -f $mb)
}

function Get-ExpectedSha256 {
	param(
		[AllowNull()][AllowEmptyString()][string]$Url,
		[AllowNull()][AllowEmptyString()][string]$Kind,
		[Parameter(Mandatory)][string]$FileName
	)
	if ([string]::IsNullOrEmpty($Url)) { return $null }
	$text = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 300).Content
	# GitHub の .sha256sum は octet-stream で返るためバイト列になることがある
	if ($text -is [byte[]]) { $text = [System.Text.Encoding]::UTF8.GetString($text) }
	if ($Kind -eq 'list') {
		$pattern = [regex]::Escape($FileName)
		foreach ($line in ($text -split "`n")) {
			if ($line -match $pattern) {
				$m = [regex]::Match($line, '[0-9a-fA-F]{64}')
				if ($m.Success) { return $m.Value.ToLower() }
			}
		}
		return $null
	}
	$m = [regex]::Match($text, '[0-9a-fA-F]{64}')
	if ($m.Success) { return $m.Value.ToLower() }
	return $null
}

# env.txt は公開・共有される想定なので、パス中のユーザ名を伏せる。
# ユーザープロファイルの実パスと、念のためユーザ名単体の両方を置換する。
function ConvertTo-MaskedPath {
	param([AllowNull()][AllowEmptyString()][string]$Path)
	if ([string]::IsNullOrEmpty($Path)) { return '' }
	$masked = $Path
	$profileDir = [Environment]::GetFolderPath('UserProfile')
	if (-not [string]::IsNullOrEmpty($profileDir)) {
		$parent = Split-Path -Parent $profileDir
		$masked = $masked -replace [regex]::Escape($profileDir), (Join-Path $parent '<username>')
	}
	if (-not [string]::IsNullOrEmpty($env:USERNAME)) {
		$masked = $masked -replace [regex]::Escape($env:USERNAME), '<username>'
	}
	return $masked
}

function Expand-ToStaging {
	param(
		[Parameter(Mandatory)][string]$ArchivePath,
		[Parameter(Mandatory)][string]$StagingPath
	)
	if (Test-Path -LiteralPath $StagingPath) {
		Remove-Item -LiteralPath $StagingPath -Recurse -Force
	}
	New-DirIfMissing $StagingPath
	Expand-Archive -LiteralPath $ArchivePath -DestinationPath $StagingPath -Force
}

# ---------------------------------------------------------------------------
# 事前チェック
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== P1 環境整備: tools/ 配下へのランタイム隔離配置 ==='
Write-Host ("プロジェクト: {0}" -f $Root)
Write-Host ''

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
	throw ("このスクリプトは x64 (AMD64) 専用です。検出: {0}" -f $env:PROCESSOR_ARCHITECTURE)
}

New-DirIfMissing $ToolsDir
New-DirIfMissing $DownloadDir
New-DirIfMissing $ResultsDir

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
$Placed = @()

foreach ($item in $Items) {
	$targetDir = Join-Path $ToolsDir $item.Dir
	$targetExe = Join-Path $targetDir $item.Exe

	Write-Host ("[{0}] {1} {2}" -f $item.Key, $item.Label, $item.Version)

	if ($Force -and (Test-Path -LiteralPath $targetDir)) {
		Write-Host '    -Force 指定のため既存を削除します'
		Remove-Item -LiteralPath $targetDir -Recurse -Force
	}

	if (Test-Path -LiteralPath $targetExe) {
		Write-Host '    配置済みのためスキップ'
	}
	else {
		$fileName = Split-Path -Leaf ([uri]$item.Url).AbsolutePath
		$archive  = Join-Path $DownloadDir $fileName

		Get-RemoteFile -Url $item.Url -OutFile $archive

		$expected = Get-ExpectedSha256 -Url $item.Sha256Url -Kind $item.Sha256Kind -FileName $fileName
		if ($expected) {
			$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
			if ($actual -cne $expected) {
				throw ("SHA256 が一致しません: {0}`n  期待値: {1}`n  実測値: {2}" -f $fileName, $expected, $actual)
			}
			Write-Host '    SHA256 検証: 一致'
		}
		else {
			Write-Host '    SHA256 検証: 公式の照合値が無いためスキップ（実測値を env.txt に記録します）'
		}

		switch ($item.Mode) {
			'tree' {
				$staging = Join-Path $DownloadDir ("_staging_" + $item.Key)
				Expand-ToStaging -ArchivePath $archive -StagingPath $staging
				$rootDir = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
				if (-not $rootDir) { throw ("アーカイブ内にフォルダが見つかりません: {0}" -f $fileName) }
				# 中途半端に残った配置先があると Move-Item が入れ子になるため先に消す
				if (Test-Path -LiteralPath $targetDir) { Remove-Item -LiteralPath $targetDir -Recurse -Force }
				Move-Item -LiteralPath $rootDir.FullName -Destination $targetDir -Force
				Remove-Item -LiteralPath $staging -Recurse -Force
			}
			'exe' {
				$staging = Join-Path $DownloadDir ("_staging_" + $item.Key)
				Expand-ToStaging -ArchivePath $archive -StagingPath $staging
				$found = Get-ChildItem -LiteralPath $staging -Recurse -File -Filter $item.Exe | Select-Object -First 1
				if (-not $found) { throw ("アーカイブ内に {0} が見つかりません: {1}" -f $item.Exe, $fileName) }
				New-DirIfMissing $targetDir
				Copy-Item -LiteralPath $found.FullName -Destination $targetExe -Force
				Remove-Item -LiteralPath $staging -Recurse -Force
			}
			'raw' {
				New-DirIfMissing $targetDir
				Copy-Item -LiteralPath $archive -Destination $targetExe -Force
			}
			default { throw ("未対応の Mode: {0}" -f $item.Mode) }
		}
		Write-Host ("    配置完了: {0}" -f $targetExe)
	}

	# 版数の実測（グローバル環境ではなく配置したバイナリを明示パスで呼ぶ）
	$reported = ''
	try {
		$reported = (& $targetExe $item.VersionArg 2>&1 | Out-String).Trim()
	}
	catch {
		$reported = ("実行できませんでした: {0}" -f $_.Exception.Message)
	}
	$firstLine = ($reported -split "`r?`n")[0]
	Write-Host ("    版数確認: {0}" -f $firstLine)

	$Placed += [pscustomobject]@{
		Key      = $item.Key
		Label    = $item.Label
		Role     = $item.Role
		Version  = $item.Version
		Exe      = $targetExe
		Reported = $reported
		Sha256   = (Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLower()
	}
	Write-Host ''
}

# ---------------------------------------------------------------------------
# 後続スクリプトが参照する定義ファイル
# ---------------------------------------------------------------------------
$manifest = [ordered]@{
	generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
	toolsDir    = $ToolsDir
	entries     = @()
}
foreach ($p in $Placed) {
	$manifest.entries += [ordered]@{
		key = $p.Key; label = $p.Label; role = $p.Role
		version = $p.Version; exe = $p.Exe; sha256 = $p.Sha256
	}
}
$manifestPath = Join-Path $ToolsDir 'runtimes.json'
$json = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("定義ファイルを出力: {0}" -f $manifestPath)

# ---------------------------------------------------------------------------
# 検証環境の記録（results/env.txt）
# ---------------------------------------------------------------------------
$os    = Get-CimInstance Win32_OperatingSystem
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$memGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$plan  = (powercfg /getactivescheme | Out-String).Trim()
$sysDrive = Get-CimInstance Win32_DiskDrive | Select-Object -First 1

# Windows 11 のモダンスタンバイ機では powercfg のプランが「バランス」1つに統合され、
# 設定アプリの「電源モード」がオーバーレイとしてその上に乗る。計測条件としては
# プランよりこのオーバーレイの方が効くため、両方を記録する。
$overlayGuid = ''
try {
	$overlayGuid = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActiveOverlayAcPowerScheme' -ErrorAction Stop
}
catch {
	$overlayGuid = ''
}
if ([string]::IsNullOrWhiteSpace($overlayGuid)) {
	$overlayText = '未設定（バランス相当）'
}
else {
	$head = ((powercfg /query $overlayGuid 2>&1 | Out-String) -split "`r?`n")[0]
	$m = [regex]::Match($head, '\(([^)]+)\)')
	if ($m.Success) {
		$overlayText = ('{0}  [{1}]' -f $m.Groups[1].Value, $overlayGuid)
	}
	else {
		$overlayText = $overlayGuid
	}
}

$battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
if ($battery) {
	if ($battery.BatteryStatus -eq 2) {
		$powerSource = 'AC 接続'
	}
	else {
		$powerSource = ('バッテリー駆動（状態コード {0}）' -f $battery.BatteryStatus)
	}
}
else {
	$powerSource = 'バッテリーなし（AC 固定）'
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('===========================================================')
$lines.Add(' Node.js / Deno / Bun 比較検証 — 検証環境の記録')
$lines.Add('===========================================================')
$lines.Add(('記録日時       : {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
$lines.Add('※ パス中の Windows ユーザ名は <username> に伏せてあります。')
$lines.Add('')
$lines.Add('--- ハードウェア / OS -------------------------------------')
$lines.Add(('OS             : {0} (build {1})' -f $os.Caption, $os.BuildNumber))
$lines.Add(('CPU            : {0}' -f $cpu.Name.Trim()))
$lines.Add(('物理コア / 論理: {0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors))
$lines.Add(('メモリ         : {0} GB' -f $memGB))
$lines.Add(('ストレージ     : {0}' -f $sysDrive.Model))
$lines.Add(('電源プラン     : {0}' -f $plan))
$lines.Add(('電源モード(AC) : {0}' -f $overlayText))
$lines.Add(('電源供給       : {0}' -f $powerSource))
$lines.Add('')
$lines.Add('--- 検証対象（tools/ 配下に隔離配置）----------------------')
foreach ($p in $Placed) {
	$lines.Add(('[{0}] {1}' -f $p.Role, $p.Label))
	$lines.Add(('  指定バージョン : {0}' -f $p.Version))
	$lines.Add(('  実行ファイル   : {0}' -f (ConvertTo-MaskedPath $p.Exe)))
	$lines.Add(('  SHA256         : {0}' -f $p.Sha256))
	foreach ($rl in ($p.Reported -split "`r?`n")) {
		if ($rl.Trim()) { $lines.Add(('  版数出力       : {0}' -f $rl.Trim())) }
	}
	$lines.Add('')
}
$lines.Add('--- 参考: システムのグローバル環境（今回は使用しない）-----')
foreach ($g in @('node', 'deno', 'bun', 'npm')) {
	$cmd = Get-Command $g -ErrorAction SilentlyContinue
	if ($cmd) {
		$gv = ''
		try { $gv = (& $g --version 2>&1 | Out-String).Trim() -split "`r?`n" | Select-Object -First 1 } catch { $gv = '(取得失敗)' }
		$lines.Add(('{0,-6}: {1}  [{2}]' -f $g, $gv, (ConvertTo-MaskedPath $cmd.Source)))
	}
	else {
		$lines.Add(('{0,-6}: 未インストール' -f $g))
	}
}
$lines.Add('')
$lines.Add('--- 計測時の注意 ------------------------------------------')
$lines.Add('* 計測は必ず tools/ 配下の実行ファイルを明示パスで呼ぶこと。')
$lines.Add('  グローバルの node / deno は別バージョンのため混在させない。')
$lines.Add('* 計測は AC 接続かつ電源モード「最大パフォーマンス」で行う。')
$lines.Add('  この機種には powercfg の「高パフォーマンス」プランが存在しないため、')
$lines.Add('  設定アプリの電源モード（オーバーレイ）で制御する。')
$lines.Add('* 計測中は常駐アプリを止める。')
$lines.Add('* ウイルス対策のリアルタイムスキャンは依存インストール時間に影響する。')

$envPath = Join-Path $ResultsDir 'env.txt'
[System.IO.File]::WriteAllLines($envPath, $lines, (New-Object System.Text.UTF8Encoding($true)))

Write-Host ("検証環境を記録: {0}" -f $envPath)
Write-Host ''
Write-Host '=== P1 環境整備 完了 ==='
