// B-05 ファイル I/O
// 小さいファイルを大量に「書く → 読む → 消す」。Windows ではファイル1件あたりの
// オーバーヘッドが大きく、ウイルス対策の影響も出やすい段。
// 件数は BENCH_FILE_COUNT で変更できる（既定 10000）。

import { mkdirSync, rmSync, writeFileSync, readFileSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { now, report, envInt, projectRoot } from "./_report.mjs";

const COUNT = envInt("BENCH_FILE_COUNT", 10000);
const RUNTIME_TAG = globalThis.process?.env?.BENCH_RUNTIME ?? "unknown";

// ランタイムごとに別ディレクトリを使い、並行実行や残骸の混入を避ける
const workDir = join(projectRoot, "tmp", "bench-io", RUNTIME_TAG);

rmSync(workDir, { recursive: true, force: true });
mkdirSync(workDir, { recursive: true });

const payload = "x".repeat(512);

const t0 = now();
for (let i = 0; i < COUNT; i++) {
	writeFileSync(join(workDir, `f${i}.txt`), payload + i);
}
const t1 = now();

let readBytes = 0;
for (let i = 0; i < COUNT; i++) {
	readBytes += readFileSync(join(workDir, `f${i}.txt`), "utf8").length;
}
const t2 = now();

const listed = readdirSync(workDir).length;
const t3 = now();

for (let i = 0; i < COUNT; i++) {
	unlinkSync(join(workDir, `f${i}.txt`));
}
const t4 = now();

rmSync(workDir, { recursive: true, force: true });

report("B-05", t4 - t0, {
	count: COUNT,
	writeMs: Math.round((t1 - t0) * 1000) / 1000,
	readMs: Math.round((t2 - t1) * 1000) / 1000,
	listMs: Math.round((t3 - t2) * 1000) / 1000,
	deleteMs: Math.round((t4 - t3) * 1000) / 1000,
	listed,
	readBytes,
});
