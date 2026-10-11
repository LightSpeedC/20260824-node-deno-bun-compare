# Node.js / Deno / Bun 比較検証 課題

> 📅 作成: 2026-10-10 / 更新: 2026-10-11

[⌂](../../README.md)

## 1. 再計測

<details>
<summary>i261010-01 ✅ <strong>済</strong> ランタイムを更新したら全項目を測り直す</summary>

Node.js・Deno・Bun の新しい版が出たら、11 項目と npm 互換性をすべて測り直し、レポートを作り直します。

- ✅ **済** 2026-10-10 時点の最新版で再計測する（Node.js 26.11.1 / 24.21.0、Deno 2.9.7、Bun 1.4.3）
- ✅ **済** 互換性の見本を better-sqlite3 から bcrypt 6.0.0（版を固定）に替える
- ✅ **済** レポートと README の数値を差し替える

</details>

<details>
<summary>i261011-01 ⬜ <strong>未</strong> 計測スクリプトを Windows PowerShell 5.1 で動くようにする</summary>

再計測では 5.1 で動かすと次の 2 つが起き、pwsh 7 で流し直しました。共通ルールは ps1 が 5.1 で動くことを求めています。

- ⬜ **未** 依存インストール計測で、子プロセスの終了コードが空になる
- ⬜ **未** 単一実行ファイル化で、Node.js SEA の進捗メッセージ（標準エラー出力）を失敗と判定する

</details>

[⌂](../../README.md)
