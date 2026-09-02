@echo off
rem HTML → Markdown 変換。実体は共通環境の html2md.exe（プロジェクトを問わず 1 本）
rem このプロジェクトの資料は docs/ 配下にあるため --dir docs を渡す
cd /d "%~dp0..\.."
N:\2026\html2md\html2md.exe --root . --dir docs %*
pause