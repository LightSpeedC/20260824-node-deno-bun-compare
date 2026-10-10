// B-11 テスト実行
// node:test の API で 200 件のテストを定義する。3 ランタイムそれぞれの
// テストランナーで同じファイルを実行し、node:test 互換性と実行時間を比べる。

import { test } from "node:test";
import assert from "node:assert/strict";

const CASES = 200;

/** 決定的な擬似乱数（mulberry32） */
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

const rand = makeRandom(20260825);

// 毎回同じ入力になるようシードから先に作っておく
const inputs = [];
for (let i = 0; i < CASES; i++) {
	inputs.push({
		n: Math.floor(rand() * 100000),
		s: "case-" + i.toString(36),
		arr: [3, 1, 2].map((v) => v * (i + 1)),
	});
}

for (let i = 0; i < CASES; i++) {
	const { n, s, arr } = inputs[i];

	test(`case ${i}: 数値・文字列・配列の基本操作`, () => {
		assert.equal(typeof n, "number");
		assert.ok(n >= 0);
		assert.equal(Math.abs(-n), n);

		assert.ok(s.startsWith("case-"));
		assert.equal(s.toUpperCase().toLowerCase(), s);
		assert.equal(s.split("-").length, 2);

		const sorted = [...arr].sort((a, b) => a - b);
		assert.deepEqual(sorted, [arr[1], arr[2], arr[0]]);
		assert.equal(
			arr.reduce((a, b) => a + b, 0),
			6 * (i + 1),
		);

		const obj = { n, s, nested: { arr } };
		assert.deepEqual(JSON.parse(JSON.stringify(obj)), obj);
	});
}
