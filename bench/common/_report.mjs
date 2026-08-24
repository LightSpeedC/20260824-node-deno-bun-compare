// 自己計測系ベンチの共通ヘルパ。
// 3 ランタイムすべてで動くよう Web 標準 API と node: プレフィックスのみを使う。

import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

/** このファイルのあるディレクトリ（bench/common） */
export const commonDir = dirname(fileURLToPath(import.meta.url));

/** bench/ ディレクトリ */
export const benchDir = join(commonDir, "..");

/** bench/fixtures ディレクトリ */
export const fixturesDir = join(benchDir, "fixtures");

/** プロジェクトルート */
export const projectRoot = join(benchDir, "..");

/** 高分解能タイマ */
export function now() {
	return performance.now();
}

/**
 * 計測結果を JSON 1 行で標準出力に書き出す。
 * ドライバ（run-bench.ps1）はこの行だけを拾って集計する。
 */
export function report(id, ms, detail) {
	const payload = { id, ms: Math.round(ms * 1000) / 1000 };
	if (detail !== undefined) {
		payload.detail = detail;
	}
	console.log("BENCH " + JSON.stringify(payload));
}

/**
 * 実行できなかった場合の報告。項目を空欄にせず理由を残す。
 */
export function reportUnsupported(id, reason) {
	console.log("BENCH " + JSON.stringify({ id, unsupported: true, reason: String(reason) }));
}

/** 環境変数を安全に読む（Deno でも process 経由で読める） */
export function envInt(name, fallback) {
	let raw;
	try {
		raw = globalThis.process?.env?.[name];
	} catch {
		raw = undefined;
	}
	const n = Number(raw);
	return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}
