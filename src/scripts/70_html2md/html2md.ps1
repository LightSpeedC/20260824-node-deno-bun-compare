<#
	HTML → Markdown 変換

	~/.claude/CLAUDE.md の「HTML→Markdown 変換ルール」に従って、HTML から
	Markdown を生成する。HTML が正で、Markdown は生成物。
	**Markdown を直接編集してはいけない**（次回の実行で上書きされる）。
	内容を変えるときは HTML を直してこのスクリプトを再実行する。

	変換対象: プロジェクト直下の README.html と docs/ 配下の *.html

	HTML 側に必要な目印（このスクリプトが読む属性）:
	  <svg id="xxx">              … images/xxx.svg として切り出す。id 必須
	  <div class="callout ...">   … callout-important / callout-warning /
	                                callout-caution を併記すると対応する
	                                GitHub アラートになる。無指定は NOTE
	  <code class="language-xxx"> … フェンスの言語指定になる
	  class="md-skip"             … その要素を Markdown に出力しない

	生成後に次の 2 点を機械的に検査する:
	  - 相対リンクの参照先が実在するか
	  - Markdown 側にしか存在しない段落が無いか
#>
# 正規表現の置換に ScriptBlock を渡すため PowerShell 6 以降が必要
# （Windows PowerShell 5.1 は ScriptBlock をデリゲートに変換できない）
#Requires -Version 6.0

[CmdletBinding()]
param(
	# 生成せず、変換結果と検査結果だけを表示する
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# このスクリプトは src/scripts/NN_xxx/ に置くため、3 階層上がプロジェクトルート
$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

# ---------------------------------------------------------------------------
# 文字列ユーティリティ
# ---------------------------------------------------------------------------
function Convert-Entity {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
	$t = $Text
	$t = $t -replace '&lt;', '<'
	$t = $t -replace '&gt;', '>'
	$t = $t -replace '&quot;', '"'
	$t = $t -replace '&#39;', "'"
	$t = $t -replace '&nbsp;', ' '
	# &amp; は最後に戻す（他の実体参照を壊さないため）
	$t = $t -replace '&amp;', '&'
	return $t
}

function Get-ClassList {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$OpenTag)
	$m = [regex]::Match($OpenTag, 'class="([^"]*)"')
	if (-not $m.Success) { return @() }
	return @($m.Groups[1].Value -split '\s+' | Where-Object { $_ })
}

function Get-Attr {
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string]$OpenTag,
		[Parameter(Mandatory)][string]$Name
	)
	$m = [regex]::Match($OpenTag, ('{0}="([^"]*)"' -f [regex]::Escape($Name)))
	if (-not $m.Success) { return '' }
	return $m.Groups[1].Value
}

# GitHub の見出しアンカーを再現する。
# 小文字化 → 記号を除去 → 空白 1 文字ごとにハイフン 1 個。
function Get-Anchor {
	param([Parameter(Mandatory)][string]$Heading)
	$a = $Heading.ToLowerInvariant()
	$a = $a -replace '[^\p{L}\p{N}\s\-_]', ''
	$a = $a.Trim()
	$a = $a -replace '\s', '-'
	return $a
}

# 拡張子を .md に差し替える。アンカーとクエリは保つ
function Convert-LinkTarget {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Href)
	if ($Href -match '^(https?:|mailto:|#)') { return $Href }
	return ($Href -replace '\.html(?=$|[#?])', '.md')
}

# ---------------------------------------------------------------------------
# インライン要素の変換
# ---------------------------------------------------------------------------
function Convert-Inline {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)
	$t = $Html

	# 改行とタブを空白 1 個に潰す（HTML の折り返しは意味を持たない）
	$t = $t -replace '\s*\r?\n\s*', ' '
	$t = $t -replace '<br\s*/?>', ' '

	# リンク: 拡張子を .md に置き換える
	$t = [regex]::Replace($t, '<a\b[^>]*href="([^"]*)"[^>]*>(.*?)</a>', {
		param($m)
		$href = Convert-LinkTarget $m.Groups[1].Value
		$text = ($m.Groups[2].Value -replace '<[^>]+>', '').Trim()
		return ('[{0}]({1})' -f $text, $href)
	})

	# バッジは色でしか区別していないので太字に落とす
	$t = [regex]::Replace($t, '<span\b[^>]*class="[^"]*\bbadge\b[^"]*"[^>]*>(.*?)</span>', {
		param($m)
		$inner = ($m.Groups[1].Value -replace '<[^>]+>', '').Trim()
		if (-not $inner) { return '' }
		# バッジは CSS の余白で本文と離れていたので、空白 1 個を補って続く文と分ける
		return ('**{0}** ' -f $inner)
	})

	$t = [regex]::Replace($t, '<code\b[^>]*>(.*?)</code>', {
		param($m)
		$inner = ($m.Groups[1].Value -replace '<[^>]+>', '')
		return ('`{0}`' -f (Convert-Entity $inner))
	})
	$t = [regex]::Replace($t, '<(strong|b)\b[^>]*>(.*?)</\1>', {
		param($m)
		$inner = ($m.Groups[2].Value -replace '<[^>]+>', '').Trim()
		if (-not $inner) { return '' }
		return ('**{0}**' -f $inner)
	})
	$t = [regex]::Replace($t, '<(em|i)\b[^>]*>(.*?)</\1>', {
		param($m)
		$inner = ($m.Groups[2].Value -replace '<[^>]+>', '').Trim()
		if (-not $inner) { return '' }
		return ('*{0}*' -f $inner)
	})

	# 残ったタグを落とす
	$t = $t -replace '<[^>]+>', ''
	$t = Convert-Entity $t
	$t = $t -replace '[ \t]{2,}', ' '
	return $t.Trim()
}

# ---------------------------------------------------------------------------
# ブロックの切り出し
# ---------------------------------------------------------------------------
# $Start の位置にある開きタグに対応する閉じタグの終端位置を返す（入れ子対応）
function Get-BlockEnd {
	param(
		[Parameter(Mandatory)][string]$Html,
		[Parameter(Mandatory)][int]$Start,
		[Parameter(Mandatory)][string]$Tag
	)
	$open = "<$Tag"
	$close = "</$Tag>"
	$depth = 0
	$i = $Start
	while ($i -lt $Html.Length) {
		$nextOpen = $Html.IndexOf($open, $i, [StringComparison]::OrdinalIgnoreCase)
		$nextClose = $Html.IndexOf($close, $i, [StringComparison]::OrdinalIgnoreCase)
		if ($nextClose -lt 0) { return $Html.Length }
		if ($nextOpen -ge 0 -and $nextOpen -lt $nextClose) {
			$depth++
			$i = $nextOpen + $open.Length
			continue
		}
		$depth--
		if ($depth -le 0) { return $nextClose + $close.Length }
		$i = $nextClose + $close.Length
	}
	return $Html.Length
}

# ---------------------------------------------------------------------------
# テーブル
# ---------------------------------------------------------------------------
function Convert-Table {
	param([Parameter(Mandatory)][string]$TableHtml)

	$headCells = @()
	$mHead = [regex]::Match($TableHtml, '(?s)<thead>(.*?)</thead>')
	if ($mHead.Success) {
		foreach ($c in [regex]::Matches($mHead.Groups[1].Value, '(?s)<th\b([^>]*)>(.*?)</th>')) {
			$headCells += (Convert-Inline $c.Groups[2].Value)
		}
	}

	$bodyRows = New-Object System.Collections.Generic.List[object]
	$mBody = [regex]::Match($TableHtml, '(?s)<tbody>(.*?)</tbody>')
	$bodySrc = if ($mBody.Success) { $mBody.Groups[1].Value } else { $TableHtml }
	foreach ($rowM in [regex]::Matches($bodySrc, '(?s)<tr\b[^>]*>(.*?)</tr>')) {
		$cells = New-Object System.Collections.Generic.List[object]
		foreach ($c in [regex]::Matches($rowM.Groups[1].Value, '(?s)<td\b([^>]*)>(.*?)</td>')) {
			$cells.Add([pscustomobject]@{
				Classes = (Get-ClassList $c.Groups[1].Value)
				Text    = (Convert-Inline $c.Groups[2].Value)
			})
		}
		if ($cells.Count -gt 0) { $bodyRows.Add($cells) }
	}
	if ($headCells.Count -eq 0 -and $bodyRows.Count -eq 0) { return @() }

	$colCount = $headCells.Count
	foreach ($r in $bodyRows) { if ($r.Count -gt $colCount) { $colCount = $r.Count } }

	# 数値列（td.num が1つ以上あり、num 以外の数値でないセルが無い列）は右寄せ
	$align = @()
	for ($i = 0; $i -lt $colCount; $i++) {
		$numCount = 0
		$total = 0
		foreach ($r in $bodyRows) {
			if ($i -ge $r.Count) { continue }
			$total++
			if ($r[$i].Classes -contains 'num') { $numCount++ }
		}
		if ($total -gt 0 -and $numCount -eq $total) { $align += '---:' } else { $align += '---' }
	}

	$lines = New-Object System.Collections.Generic.List[string]
	$h = @()
	for ($i = 0; $i -lt $colCount; $i++) {
		if ($i -lt $headCells.Count) { $h += $headCells[$i] } else { $h += '' }
	}
	$lines.Add('| ' + ($h -join ' | ') + ' |')
	$lines.Add('|' + ($align -join '|') + '|')
	foreach ($r in $bodyRows) {
		$cols = @()
		for ($i = 0; $i -lt $colCount; $i++) {
			if ($i -lt $r.Count) { $cols += $r[$i].Text } else { $cols += '' }
		}
		$lines.Add('| ' + ($cols -join ' | ') + ' |')
	}
	return , $lines.ToArray()
}

# ---------------------------------------------------------------------------
# リスト
# ---------------------------------------------------------------------------
function Convert-List {
	param(
		[Parameter(Mandatory)][string]$ListHtml,
		[Parameter(Mandatory)][bool]$Ordered
	)
	$lines = New-Object System.Collections.Generic.List[string]
	$n = 0
	foreach ($li in [regex]::Matches($ListHtml, '(?s)<li\b[^>]*>(.*?)</li>')) {
		$text = Convert-Inline $li.Groups[1].Value
		if (-not $text) { continue }
		$n++
		if ($Ordered) { $lines.Add(('{0}. {1}' -f $n, $text)) }
		else { $lines.Add('- ' + $text) }
	}
	return , $lines.ToArray()
}

# 目次: <li><a href="#chNN">見出し</a></li> を、生成後の見出しアンカーに向ける
function Convert-Toc {
	param(
		[Parameter(Mandatory)][string]$TocHtml,
		[Parameter(Mandatory)][hashtable]$AnchorMap
	)
	$lines = New-Object System.Collections.Generic.List[string]
	$n = 0
	foreach ($li in [regex]::Matches($TocHtml, '(?s)<li\b[^>]*>(.*?)</li>')) {
		$a = [regex]::Match($li.Groups[1].Value, '<a\b[^>]*href="#([^"]+)"[^>]*>(.*?)</a>')
		if (-not $a.Success) { continue }
		$n++
		$id = $a.Groups[1].Value
		$text = Convert-Inline $a.Groups[2].Value
		$anchor = if ($AnchorMap.ContainsKey($id)) { $AnchorMap[$id] } else { $id }
		$lines.Add(('{0}. [{1}](#{2})' -f $n, $text, $anchor))
	}
	return , $lines.ToArray()
}

# ---------------------------------------------------------------------------
# SVG の切り出し
# ---------------------------------------------------------------------------
function Export-Svg {
	param(
		[Parameter(Mandatory)][string]$SvgHtml,
		[Parameter(Mandatory)][string]$ImagesDir,
		[Parameter(Mandatory)][bool]$Write
	)
	$openTag = [regex]::Match($SvgHtml, '<svg\b[^>]*>').Value
	$id = Get-Attr $openTag 'id'
	if (-not $id) { throw 'svg 要素に id がありません。切り出し先のファイル名が決められません。' }

	$viewBox = Get-Attr $openTag 'viewBox'
	$w = ''
	$h = ''
	if ($viewBox -match '^\s*[\d.\-]+\s+[\d.\-]+\s+([\d.]+)\s+([\d.]+)\s*$') {
		$w = $Matches[1]
		$h = $Matches[2]
	}
	$label = Get-Attr $openTag 'aria-label'

	# 単体ファイルとして開けるよう xmlns と width/height を付ける
	$attrs = 'xmlns="http://www.w3.org/2000/svg"'
	if ($viewBox) { $attrs += (' viewBox="{0}"' -f $viewBox) }
	if ($w -and $h) { $attrs += (' width="{0}" height="{1}"' -f $w, $h) }
	$attrs += ' role="img"'
	if ($label) { $attrs += (' aria-label="{0}"' -f $label) }

	$inner = [regex]::Replace($SvgHtml, '(?s)^<svg\b[^>]*>', '')
	$inner = [regex]::Replace($inner, '(?s)</svg>\s*$', '')

	# 透過のままだとダークモードで文字が読めないので白背景を最初に置く。
	# defs の直後に入れて、グラデーション定義より後ろに来るようにする
	$bg = "`t<rect width=`"100%`" height=`"100%`" fill=`"#ffffff`"/>"
	$defsEnd = $inner.IndexOf('</defs>', [StringComparison]::OrdinalIgnoreCase)
	if ($defsEnd -ge 0) {
		$cut = $defsEnd + '</defs>'.Length
		$inner = $inner.Substring(0, $cut) + "`r`n" + $bg + $inner.Substring($cut)
	}
	else {
		$inner = "`r`n" + $bg + $inner
	}

	$svg = ('<svg {0}>{1}</svg>' -f $attrs, $inner)
	$svg = ($svg -replace '\r?\n', "`r`n")
	if (-not $svg.EndsWith("`r`n")) { $svg += "`r`n" }

	$fileName = "$id.svg"
	if ($Write) {
		if (-not (Test-Path -LiteralPath $ImagesDir)) { New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null }
		[System.IO.File]::WriteAllText((Join-Path $ImagesDir $fileName), $svg, (New-Object System.Text.UTF8Encoding($false)))
	}
	return [pscustomobject]@{ FileName = $fileName; Label = $label }
}

# ---------------------------------------------------------------------------
# 本体: 1 ファイルを変換する
# ---------------------------------------------------------------------------
function Convert-HtmlFile {
	param(
		[Parameter(Mandatory)][string]$HtmlPath,
		[Parameter(Mandatory)][bool]$Write
	)
	$html = [System.IO.File]::ReadAllText($HtmlPath, (New-Object System.Text.UTF8Encoding($false)))
	$docDir = Split-Path -Parent $HtmlPath
	$imagesDir = Join-Path $docDir 'images'

	# コメントと style/script を落とす
	$html = [regex]::Replace($html, '(?s)<!--.*?-->', '')
	$html = [regex]::Replace($html, '(?s)<style\b[^>]*>.*?</style>', '')
	$html = [regex]::Replace($html, '(?s)<script\b[^>]*>.*?</script>', '')

	$bodyStart = $html.IndexOf('<body', [StringComparison]::OrdinalIgnoreCase)
	if ($bodyStart -lt 0) { throw "body が見つかりません: $HtmlPath" }
	$bodyStart = $html.IndexOf('>', $bodyStart) + 1
	$bodyEnd = $html.IndexOf('</body>', [StringComparison]::OrdinalIgnoreCase)
	if ($bodyEnd -lt 0) { $bodyEnd = $html.Length }
	$body = $html.Substring($bodyStart, $bodyEnd - $bodyStart)

	# 章番号 → アンカーの対応表を先に作る（目次が参照するため）
	$anchorMap = @{}
	$chapterNo = 0
	foreach ($sec in [regex]::Matches($body, '(?s)<section\b([^>]*)>(.*?)<h1\b[^>]*>(.*?)</h1>')) {
		$secId = Get-Attr $sec.Groups[1].Value 'id'
		$chapterNo++
		$title = Convert-Inline $sec.Groups[3].Value
		if ($secId) { $anchorMap[$secId] = Get-Anchor ('{0}. {1}' -f $chapterNo, $title) }
	}

	$out = New-Object System.Collections.Generic.List[string]
	$svgFiles = New-Object System.Collections.Generic.List[object]
	$chapterNo = 0
	# 章（section）の中かどうかで見出しレベルを 1 段下げる
	$inSection = $false

	function Add-Block {
		param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
		if ($out.Count -gt 0) { $out.Add('') }
		$out.Add($Text)
	}

	$pos = 0
	while ($pos -lt $body.Length) {
		$lt = $body.IndexOf('<', $pos)
		if ($lt -lt 0) { break }
		$gt = $body.IndexOf('>', $lt)
		if ($gt -lt 0) { break }
		$openTag = $body.Substring($lt, $gt - $lt + 1)
		$tagName = ([regex]::Match($openTag, '^</?([a-zA-Z0-9]+)')).Groups[1].Value.ToLowerInvariant()
		$classes = Get-ClassList $openTag

		# 閉じタグはブロックの開始ではないので、状態だけ更新して読み進める
		if ($openTag.StartsWith('</')) {
			if ($tagName -eq 'section') { $inSection = $false }
			$pos = $gt + 1
			continue
		}

		if ($classes -contains 'md-skip') {
			$pos = Get-BlockEnd -Html $body -Start $lt -Tag $tagName
			continue
		}

		switch ($tagName) {
			'div' {
				if ($classes -contains 'titlebar') {
					$end = Get-BlockEnd -Html $body -Start $lt -Tag 'div'
					$blk = $body.Substring($lt, $end - $lt)
					$t = [regex]::Match($blk, '(?s)<h1\b[^>]*>(.*?)</h1>')
					if ($t.Success) { Add-Block ('# ' + (Convert-Inline $t.Groups[1].Value)) }
					$meta = [regex]::Match($blk, '(?s)<div\b[^>]*class="meta"[^>]*>(.*?)</div>')
					if ($meta.Success) {
						$parts = @()
						foreach ($s in [regex]::Matches($meta.Groups[1].Value, '(?s)<span\b[^>]*>(.*?)</span>')) {
							$v = Convert-Inline $s.Groups[1].Value
							if ($v) { $parts += $v }
						}
						# 区切り記号は足さない（HTML に無い文字を増やさないため）
						if ($parts.Count -gt 0) { Add-Block ('> ' + ($parts -join ' ')) }
					}
					$pos = $end
					break
				}
				if ($classes -contains 'callout') {
					$end = Get-BlockEnd -Html $body -Start $lt -Tag 'div'
					$inner = $body.Substring($gt + 1, $end - ('</div>'.Length) - ($gt + 1))
					$kind = 'NOTE'
					if ($classes -contains 'callout-important') { $kind = 'IMPORTANT' }
					elseif ($classes -contains 'callout-warning') { $kind = 'WARNING' }
					elseif ($classes -contains 'callout-caution') { $kind = 'CAUTION' }
					$text = Convert-Inline $inner
					$lines = @("> [!$kind]")
					foreach ($seg in ($text -split '(?<=。)\s+')) {
						if ($seg.Trim()) { $lines += ('> ' + $seg.Trim()) }
					}
					Add-Block ($lines -join "`n")
					$pos = $end
					break
				}
				if ($classes -contains 'toc') {
					$end = Get-BlockEnd -Html $body -Start $lt -Tag 'div'
					$blk = $body.Substring($lt, $end - $lt)
					$h = [regex]::Match($blk, '(?s)<h2\b[^>]*>(.*?)</h2>')
					if ($h.Success) { Add-Block ('## ' + (Convert-Inline $h.Groups[1].Value)) }
					$items = Convert-Toc -TocHtml $blk -AnchorMap $anchorMap
					if ($items.Count -gt 0) { Add-Block ($items -join "`n") }
					$pos = $end
					break
				}
				# .tw など単なるラッパは中身をそのまま処理する
				$pos = $gt + 1
			}
			'section' {
				$chapterNo++
				$inSection = $true
				$secEnd = Get-BlockEnd -Html $body -Start $lt -Tag 'section'
				$h1 = [regex]::Match($body.Substring($lt, $secEnd - $lt), '(?s)<h1\b[^>]*>(.*?)</h1>')
				if ($h1.Success) {
					Add-Block ('## {0}. {1}' -f $chapterNo, (Convert-Inline $h1.Groups[1].Value))
					# h1 を消費して残りを続けて処理する
					$pos = $lt + $h1.Index + $h1.Length
				}
				else {
					$pos = $gt + 1
				}
			}
			'h1' {
				# section 外の h1（通常は無い）
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'h1'
				$pos = $end
			}
			'h2' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'h2'
				$inner = $body.Substring($gt + 1, $end - ('</h2>'.Length) - ($gt + 1))
				$level = if ($inSection) { '### ' } else { '## ' }
				Add-Block ($level + (Convert-Inline $inner))
				$pos = $end
			}
			'h3' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'h3'
				$inner = $body.Substring($gt + 1, $end - ('</h3>'.Length) - ($gt + 1))
				$level = if ($inSection) { '#### ' } else { '### ' }
				Add-Block ($level + (Convert-Inline $inner))
				$pos = $end
			}
			'p' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'p'
				$inner = $body.Substring($gt + 1, $end - ('</p>'.Length) - ($gt + 1))
				$text = Convert-Inline $inner
				if ($text) { Add-Block $text }
				$pos = $end
			}
			'ul' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'ul'
				$items = Convert-List -ListHtml ($body.Substring($lt, $end - $lt)) -Ordered $false
				if ($items.Count -gt 0) { Add-Block ($items -join "`n") }
				$pos = $end
			}
			'ol' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'ol'
				$items = Convert-List -ListHtml ($body.Substring($lt, $end - $lt)) -Ordered $true
				if ($items.Count -gt 0) { Add-Block ($items -join "`n") }
				$pos = $end
			}
			'pre' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'pre'
				$blk = $body.Substring($lt, $end - $lt)
				$codeM = [regex]::Match($blk, '(?s)<code\b([^>]*)>(.*?)</code>')
				$lang = ''
				$code = ''
				if ($codeM.Success) {
					$code = $codeM.Groups[2].Value
					foreach ($c in (Get-ClassList $codeM.Groups[1].Value)) {
						if ($c -like 'language-*') { $lang = $c.Substring('language-'.Length) }
					}
				}
				else {
					$code = [regex]::Replace($blk, '(?s)^<pre\b[^>]*>', '')
					$code = [regex]::Replace($code, '(?s)</pre>\s*$', '')
				}
				$code = Convert-Entity ($code -replace '<[^>]+>', '')
				# 前後の空行だけを落とす（行頭のインデントは保つ）
				$code = $code -replace '\A(\s*\r?\n)+', ''
				$code = $code -replace '(\r?\n\s*)+\z', ''
				Add-Block ('```' + $lang + "`n" + $code + "`n" + '```')
				$pos = $end
			}
			'table' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'table'
				$rows = Convert-Table ($body.Substring($lt, $end - $lt))
				if ($rows.Count -gt 0) { Add-Block ($rows -join "`n") }
				$pos = $end
			}
			'svg' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'svg'
				$info = Export-Svg -SvgHtml ($body.Substring($lt, $end - $lt)) -ImagesDir $imagesDir -Write $Write
				$svgFiles.Add($info.FileName)
				Add-Block ('![{0}](images/{1})' -f $info.Label, $info.FileName)
				$pos = $end
			}
			'footer' {
				$end = Get-BlockEnd -Html $body -Start $lt -Tag 'footer'
				$blk = $body.Substring($lt, $end - $lt)
				foreach ($pm in [regex]::Matches($blk, '(?s)<p\b[^>]*>(.*?)</p>')) {
					$text = Convert-Inline $pm.Groups[1].Value
					if ($text) { Add-Block $text }
				}
				$pos = $end
			}
			default {
				$pos = $gt + 1
			}
		}
	}

	$md = ($out -join "`n").TrimEnd() + "`n"
	$md = $md -replace '\r?\n', "`r`n"

	$mdPath = [System.IO.Path]::ChangeExtension($HtmlPath, '.md')
	if ($Write) {
		[System.IO.File]::WriteAllText($mdPath, $md, (New-Object System.Text.UTF8Encoding($false)))
	}
	# @($list) を [pscustomobject] のハッシュテーブル内で使うと
	# 「Argument types do not match」で落ちるため .ToArray() を使う
	return [pscustomobject]@{
		HtmlPath = $HtmlPath
		MdPath   = $mdPath
		Markdown = $md
		Svgs     = $svgFiles.ToArray()
	}
}

# ---------------------------------------------------------------------------
# 検査
# ---------------------------------------------------------------------------
# 相対リンクの参照先が実在するか
function Test-Links {
	param([Parameter(Mandatory)][object]$Result)
	$dir = Split-Path -Parent $Result.MdPath
	$bad = @()
	foreach ($m in [regex]::Matches($Result.Markdown, '\]\(([^)]+)\)')) {
		$target = $m.Groups[1].Value
		if ($target -match '^(https?:|mailto:|#)') { continue }
		$path = ($target -split '#')[0]
		if (-not $path) { continue }
		$full = [System.IO.Path]::GetFullPath((Join-Path $dir ($path -replace '/', '\')))
		if (-not (Test-Path -LiteralPath $full)) { $bad += $target }
	}
	return , $bad
}

# HTML 側のリンクが .md を指していないか、また参照先が実在するか。
# Markdown 側だけを検査すると、変換で .md になった分と区別できず見逃すため
# HTML 側も独立に検査する。
function Test-HtmlLinks {
	param([Parameter(Mandatory)][string]$HtmlPath)
	$html = [System.IO.File]::ReadAllText($HtmlPath, (New-Object System.Text.UTF8Encoding($false)))
	$dir = Split-Path -Parent $HtmlPath
	$pointsToMd = @()
	$missing = @()
	foreach ($m in [regex]::Matches($html, 'href="([^"]+)"')) {
		$href = $m.Groups[1].Value
		if ($href -match '^(https?:|mailto:|#)') { continue }
		if ($href -match '\.md($|[#?])') {
			$pointsToMd += $href
			continue
		}
		$path = ($href -split '#')[0]
		if (-not $path) { continue }
		$full = [System.IO.Path]::GetFullPath((Join-Path $dir ($path -replace '/', '\')))
		if (-not (Test-Path -LiteralPath $full)) { $missing += $href }
	}
	return [pscustomobject]@{ PointsToMd = $pointsToMd; Missing = $missing }
}

# Markdown 側にしか存在しない段落が無いか。
# HTML の可視テキストを 1 本に潰し、Markdown の各段落の素の文字列が
# その中に現れるかで判定する。
function Test-ExtraParagraphs {
	param([Parameter(Mandatory)][object]$Result)
	$html = [System.IO.File]::ReadAllText($Result.HtmlPath, (New-Object System.Text.UTF8Encoding($false)))
	$html = [regex]::Replace($html, '(?s)<!--.*?-->', '')
	$html = [regex]::Replace($html, '(?s)<style\b[^>]*>.*?</style>', '')
	$html = [regex]::Replace($html, '(?s)<script\b[^>]*>.*?</script>', '')
	$plainHtml = Convert-Entity ($html -replace '<[^>]+>', ' ')
	$plainHtml = ($plainHtml -replace '\s+', '')

	$extra = @()
	foreach ($para in ($Result.Markdown -split '\r?\n\r?\n')) {
		$p = $para.Trim()
		if (-not $p) { continue }
		# 画像・表の区切り・アンカーだけの行は比較対象にしない
		if ($p -match '^!\[') { continue }
		if ($p -match '^\|') { continue }
		if ($p -match '^```') { continue }
		# Markdown 記法を落として素の文字列にする
		$bare = $p
		$bare = $bare -replace '^#{1,6}\s*', ''
		$bare = $bare -replace '^>\s*\[![A-Z]+\]\s*', ''
		$bare = $bare -replace '(?m)^>\s?', ''
		$bare = $bare -replace '(?m)^[-*]\s+', ''
		$bare = $bare -replace '(?m)^\d+\.\s+', ''
		$bare = $bare -replace '\[([^\]]*)\]\([^)]*\)', '$1'
		$bare = $bare -replace '\*\*', ''
		$bare = $bare -replace '`', ''
		$bare = $bare -replace '\*', ''
		# 章見出しに付けた連番は HTML に無いので除く
		$bare = $bare -replace '^\d+\.\s*', ''
		$bare = ($bare -replace '\s+', '')
		if (-not $bare) { continue }
		if (-not $plainHtml.Contains($bare)) {
			$head = $p -replace '\r?\n', ' '
			if ($head.Length -gt 90) { $head = $head.Substring(0, 90) + '…' }
			$extra += $head
		}
	}
	return , $extra
}

# ---------------------------------------------------------------------------
# 実行
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== HTML → Markdown 変換 ==='
if ($DryRun) { Write-Host '（-DryRun: ファイルは書き出しません）' }
Write-Host ("プロジェクト: {0}" -f $Root)
Write-Host ''

$targets = New-Object System.Collections.Generic.List[string]
$readme = Join-Path $Root 'README.html'
if (Test-Path -LiteralPath $readme) { $targets.Add($readme) }
$docsDir = Join-Path $Root 'docs'
if (Test-Path -LiteralPath $docsDir) {
	foreach ($f in (Get-ChildItem -LiteralPath $docsDir -Recurse -File -Filter '*.html' | Sort-Object FullName)) {
		$targets.Add($f.FullName)
	}
}
if ($targets.Count -eq 0) { throw '変換対象の HTML が見つかりません。' }

$problems = 0
foreach ($t in $targets) {
	$rel = $t.Substring($Root.Length + 1)
	$res = Convert-HtmlFile -HtmlPath $t -Write (-not $DryRun)
	$lines = ($res.Markdown -split '\r?\n').Count
	Write-Host ("[{0}]" -f $rel)
	Write-Host ("    -> {0}  ({1} 行)" -f ($res.MdPath.Substring($Root.Length + 1)), $lines)
	if ($res.Svgs.Count -gt 0) {
		Write-Host ("    画像: {0}" -f (($res.Svgs | ForEach-Object { "images/$_" }) -join ', '))
	}

	# HTML 側: .md を指していないか、参照先が実在するか
	$htmlLinks = Test-HtmlLinks -HtmlPath $t
	if ($htmlLinks.PointsToMd.Count -gt 0) {
		$problems += $htmlLinks.PointsToMd.Count
		Write-Host ("    ★HTML のリンクが .md を指している {0} 件: {1}" -f `
			$htmlLinks.PointsToMd.Count, ($htmlLinks.PointsToMd -join ', '))
		Write-Host '        HTML には常に .html と書く（.md への置き換えはこのスクリプトが行う）'
	}
	if ($htmlLinks.Missing.Count -gt 0) {
		$problems += $htmlLinks.Missing.Count
		Write-Host ("    ★HTML 側のリンク切れ {0} 件: {1}" -f `
			$htmlLinks.Missing.Count, ($htmlLinks.Missing -join ', '))
	}
	if ($htmlLinks.PointsToMd.Count -eq 0 -and $htmlLinks.Missing.Count -eq 0) {
		Write-Host '    HTML 側のリンク: すべて .html で参照先も実在'
	}

	# Markdown 側: 参照先が実在するか
	$bad = Test-Links -Result $res
	if ($bad.Count -gt 0) {
		$problems += $bad.Count
		Write-Host ("    ★リンク切れ {0} 件: {1}" -f $bad.Count, ($bad -join ', '))
	}
	else {
		Write-Host '    Markdown 側のリンク: リンク切れなし'
	}

	$extra = Test-ExtraParagraphs -Result $res
	if ($extra.Count -gt 0) {
		$problems += $extra.Count
		Write-Host ("    ★HTML に無い段落 {0} 件:" -f $extra.Count)
		foreach ($e in $extra) { Write-Host ("        {0}" -f $e) }
	}
	else {
		Write-Host '    HTML に無い段落なし'
	}
	Write-Host ''
}

if ($problems -gt 0) {
	Write-Host ("=== 変換完了。ただし {0} 件の指摘あり ===" -f $problems)
	exit 1
}
Write-Host '=== 変換完了 ==='
