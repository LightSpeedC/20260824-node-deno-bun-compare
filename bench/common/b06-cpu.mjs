// B-06 CPU バウンド処理
// V8（Node）と JavaScriptCore（Bun）の素の実行速度差を見る。
// 数値ループ・文字列処理・配列操作の 3 種を同一の反復回数で回す。

import { now, report, envInt } from "./_report.mjs";

const SCALE = envInt("BENCH_CPU_SCALE", 1);

/** 決定的な擬似乱数（mulberry32）。乱数の質より再現性を優先する */
function makeRandom(seed) {
	let a = seed >>> 0;
	return function () {
		a = (a + 0x6d2b79f5) >>> 0;
		let t = a;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

function benchNumeric() {
	const n = 20_000_000 * SCALE;
	let acc = 0;
	for (let i = 1; i <= n; i++) {
		acc += Math.sqrt(i) / (i % 97 + 1);
	}
	return acc;
}

function benchString() {
	const n = 200_000 * SCALE;
	const words = ["node", "deno", "bun", "runtime", "benchmark", "javascript"];
	let total = 0;
	for (let i = 0; i < n; i++) {
		const s = words[i % words.length] + "-" + i.toString(36);
		total += s.toUpperCase().split("-").length + s.indexOf("n");
	}
	return total;
}

function benchArray() {
	const n = 1_000_000 * SCALE;
	const rand = makeRandom(20260825);
	const arr = new Array(n);
	for (let i = 0; i < n; i++) {
		arr[i] = rand();
	}
	arr.sort((a, b) => a - b);
	let sum = 0;
	for (let i = 0; i < n; i += 1000) {
		sum += arr[i];
	}
	return sum;
}

const t0 = now();
const r1 = benchNumeric();
const t1 = now();
const r2 = benchString();
const t2 = now();
const r3 = benchArray();
const t3 = now();

report("B-06", t3 - t0, {
	scale: SCALE,
	numericMs: Math.round((t1 - t0) * 1000) / 1000,
	stringMs: Math.round((t2 - t1) * 1000) / 1000,
	arrayMs: Math.round((t3 - t2) * 1000) / 1000,
	// 最適化で処理ごと消されないよう結果を残す
	checksum: Math.round((r1 + r2 + r3) * 1000) / 1000,
});
