// 計測スクリプトが Windows PowerShell 5.1 で子プロセスの終了コードを取れることを確かめる (i261011-01)
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..");

// Start-Process -PassThru で受けたプロセスは、Handle に触れないまま WaitForExit(ミリ秒) で待つと ExitCode が空になる。
// 空になるのは、出力をリダイレクトし、子が少し時間をかけて終わるとき (すぐ終わる子では再現しない)。
// 計測スクリプトと同じ形で、5.1 の性質を実測して残す
// PowerShell を 2 回起動するので、bun test の既定 (5 秒) では足りないことがある
test("5.1 では Handle に触れずに待つと ExitCode が空になり、触れてから待つと取れる", { timeout: 60000 }, () => {
	const tmp = join(root, "tmp").replaceAll("\\", "/");
	mkdirSync(tmp, { recursive: true });
	const run = (touch: boolean) => execFileSync("powershell", ["-NoProfile", "-Command",
		`$p = Start-Process -FilePath cmd -ArgumentList '/c','ping -n 2 127.0.0.1 >nul & exit 3' -PassThru -WindowStyle Hidden -RedirectStandardOutput '${tmp}/sp-out.txt' -RedirectStandardError '${tmp}/sp-err.txt'; ${touch ? "$null = $p.Handle; " : ""}$null = $p.WaitForExit(30000); Write-Output ('[' + $p.ExitCode + ']')`,
	], { encoding: "utf8", timeout: 60000 }).trim();
	assert.equal(run(false), "[]");
	assert.equal(run(true), "[3]");
});

// Start-Process -PassThru を使う計測スクリプトは、すべて直後に Handle に触れている
const scripts = [
	"src/scripts/20_run_bench/run-bench.ps1",
	"src/scripts/30_run_install_bench/run-install-bench.ps1",
	"src/scripts/40_run_compile_bench/run-compile-bench.ps1",
];
for (const rel of scripts) {
	test(`${rel} は Start-Process -PassThru の直後に Handle に触れる`, () => {
		const lines = readFileSync(join(root, rel), "utf8").split(/\r?\n/);
		const starts = lines.flatMap((l, i) => (/Start-Process\b.*-PassThru/.test(l) ? [i] : []));
		assert.ok(starts.length > 0, "Start-Process -PassThru が見つからない");
		for (const i of starts) {
			const near = lines.slice(i, i + 4).join("\n");
			assert.match(near, /\.Handle\b/, `${i + 1} 行目の Start-Process の直後に Handle が無い`);
		}
	});
}
