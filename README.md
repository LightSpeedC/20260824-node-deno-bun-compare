# Node.js / Deno / Bun 比較検証

> 📅 作成: 2026-08-24 / 更新: 2026-09-03 検証完了。11 項目 × 各 10 回試行

## 概要

Node.js・Deno・Bun を、それぞれの最新バージョンで Windows 11 の同一マシン上で動かして比較したプロジェクトです。 起動時間・HTTP スループット・JSON 処理・ファイル I/O・CPU 処理・SQLite・依存インストール・TypeScript 実行・単一実行ファイル化・テスト実行の 計 11 項目を計測し、あわせて npm パッケージ 8 個の互換性を確認しました。 3 ランタイムはシステムに入れず、公式配布物をプロジェクト内 `tools/` に隔離配置しています。

## 1. 結果レポート

用途別の推奨、11 項目の実測値と内訳、評価軸ごとのスコア、そして結果の読み方の注意までをまとめたものです。

[結果レポートを開く](docs/report/report.md)

### 総合スコア

| ランタイム | 総合スコア | 性格 |
|---|---:|---|
| Bun 1.4.0 | 85.0 | 11 項目のうち 9 項目で最速。起動系は他を 2〜4 倍引き離す。LTS 相当の枠が無い |
| Deno 2.9.5 | 68.2 | 権限が既定で拒否される唯一のランタイム。キャッシュ有インストールが 1.3 秒と圧倒的 |
| Node.js 26.7.0 | 63.0 | 速度は中位だが LTS・SQLite 最速・実績で崩れない |
| Node.js 24.19.0（参考） | 63.5 | 26 系との差は起動系で最大 8% 程度 |

### 用途別の推奨

| 用途 | 推奨 |
|---|---|
| 長期運用する業務 API サーバ | **Node.js 26** |
| 社内向け CLI ツール | **Bun** |
| 使い捨てのスクリプト・自動化 | **Bun** |
| フロントエンドのビルド基盤 | **Bun** |
| 既存 Node.js プロジェクトの高速化 | **Bun** |
| 外部コードを実行するサンドボックス用途 | **Deno** |

> [!WARNING]
> **総合スコアだけで決めない**：配点は速さ関連で 45 点を占めており、順位は重みの帰結でもあります。 「運用・サポート」の重みを上げれば Node.js が最上位になります。レポートの章 7 に、この数字を信用しすぎないための注意を 5 点挙げています。

## 2. 比較検証 計画書

何を測り、どう測り、どう判断するかを着手前に決めた文書です。評価軸の重み付け、ベンチマーク項目 B-01〜B-11 の設計、公平に測るためのルール、実施フロー、リスクと対策を含みます。計画から変えた点（B-05 の件数など）も記録してあります。

[検証計画書を開く](docs/plan/comparison-plan.md)

### 再現手順

```powershell
# 1. ランタイムと計測ツールを tools/ に配置（SHA256 検証つき）
src\scripts\10_setup_runtimes\setup-runtimes.ps1

# 2. ベンチ本体（-Append で項目を分けて実行できる）
src\scripts\20_run_bench\run-bench.ps1 -Runs 10 -Warmup 3 -Only B-01,B-02,B-09,B-11
src\scripts\20_run_bench\run-bench.ps1 -Runs 10 -Warmup 3 -FileCount 2000 -Only B-04,B-05,B-06,B-07 -Append
src\scripts\20_run_bench\run-bench.ps1 -Only B-03 -HttpSeconds 10 -HttpConnections 50 -Append

# 3. 依存インストールと npm 互換性
src\scripts\30_run_install_bench\run-install-bench.ps1

# 4. 単一実行ファイル化
src\scripts\40_run_compile_bench\run-compile-bench.ps1

# 5. 集計
src\scripts\50_build_report\build-report.ps1
```

### ディレクトリ構成

```
README.*                 このファイル
docs/plan/               検証計画書
docs/report/             結果レポート
bench/                   ベンチマーク本体（common / native / deps / compat / tests）
src/scripts/             導入・計測・集計スクリプト（NN_名前/ の番号付きフォルダ。.ps1 と .cmd ランチャー）
results/                 env.txt・measurements.csv・summary.json・qualitative.json・raw/
tools/                   隔離配置したランタイムの実体（git 管理外・再取得可）と html2md ランチャー
tmp/                     一時ファイル（git 管理外）
```

## 3. 検証対象バージョン

| ランタイム | 系列 | バージョン | リリース日 | SHA256 検証 |
|---|---|---|---|---|
| Node.js ✅ **主軸** | Current | `v26.7.0` | 2026-08-05 | 公式 SHASUMS と一致 |
| Node.js | Active LTS (Krypton) | `v24.19.0` | 2026-08-03 | 公式 SHASUMS と一致 |
| Node.js | Maintenance LTS (Jod) | `v22.23.2` | 2026-07-28 | **対象外** |
| Deno ✅ **主軸** | stable | `v2.9.5` | 2026-08-06 | 公式 sha256sum と一致 |
| Bun ✅ **主軸** | stable | `v1.4.0` | 2026-08-20 | 公式照合値なし（実測値を記録） |

### 検証環境

Windows 11 Home（build 26200）／ Intel Core i7-11370H（4 物理コア・8 論理）／ メモリ 15.8 GB ／ NVMe SSD。 計測は AC 接続かつ電源モード「最大パフォーマンス」で実施しました。計測ツールは hyperfine 1.20.0 と oha 1.16.0 です。 環境と版数、バイナリの SHA256 は `results/env.txt` に記録しています。

システムのグローバル環境（`node v25.8.2` / `deno 1.31.1` / `bun 1.4.0`）には手を入れていません。 計測はすべて `tools/` 配下の実行ファイルを明示パスで呼び出しています。
