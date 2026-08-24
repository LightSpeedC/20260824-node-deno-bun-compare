// ベンチ用のテストデータ生成。
// 生成物（bench/fixtures/）は .gitignore で除外し、このスクリプトと固定シードだけを残す。
// 同じシードから同じデータが再現できるので、後日でも同条件で計測できる。

import { mkdirSync, writeFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { fixturesDir } from "./common/_report.mjs";

const SEED = 20260825;
const TARGET_MB = 10;

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

const FIRST = ["佐藤", "鈴木", "高橋", "田中", "伊藤", "渡辺", "山本", "中村"];
const CITY = ["東京", "大阪", "名古屋", "札幌", "福岡", "仙台", "広島", "那覇"];
const TAGS = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"];

function buildRecord(rand, id) {
	const tagCount = 1 + Math.floor(rand() * 3);
	const tags = [];
	for (let i = 0; i < tagCount; i++) {
		tags.push(TAGS[Math.floor(rand() * TAGS.length)]);
	}
	return {
		id,
		name: FIRST[Math.floor(rand() * FIRST.length)] + id,
		city: CITY[Math.floor(rand() * CITY.length)],
		score: Math.round(rand() * 10000) / 100,
		active: rand() > 0.5,
		// 日付はシードから決定的に作る（実行時刻に依存させない）
		registeredAt: new Date(1700000000000 + id * 60000).toISOString(),
		tags,
		profile: {
			level: 1 + Math.floor(rand() * 60),
			points: Math.floor(rand() * 1000000),
			note: "行動ログの要約テキスト" + id.toString(36),
		},
	};
}

mkdirSync(fixturesDir, { recursive: true });

const jsonPath = join(fixturesDir, "large.json");
if (existsSync(jsonPath) && statSync(jsonPath).size > TARGET_MB * 1024 * 1024 * 0.9) {
	console.log(`既存を再利用: ${jsonPath} (${(statSync(jsonPath).size / 1024 / 1024).toFixed(1)} MB)`);
} else {
	const rand = makeRandom(SEED);
	const records = [];
	let bytes = 0;
	let id = 0;
	// 目標サイズに達するまでレコードを積む
	while (bytes < TARGET_MB * 1024 * 1024) {
		const rec = buildRecord(rand, id++);
		records.push(rec);
		bytes += JSON.stringify(rec).length + 1;
	}
	const doc = { seed: SEED, count: records.length, records };
	writeFileSync(jsonPath, JSON.stringify(doc));
	const mb = statSync(jsonPath).size / 1024 / 1024;
	console.log(`生成: ${jsonPath}`);
	console.log(`  レコード数: ${records.length}  サイズ: ${mb.toFixed(1)} MB  シード: ${SEED}`);
}

console.log("テストデータの準備完了");
