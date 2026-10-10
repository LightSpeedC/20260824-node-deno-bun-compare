// B-04 JSON 処理
// 10 MB の JSON を parse → 集計/変換 → stringify する。
// parse・変換・stringify を個別に計測して、どの段で差が出るかを分ける。

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { now, report, fixturesDir } from "./_report.mjs";

const path = join(fixturesDir, "large.json");
const text = readFileSync(path, "utf8");

const t0 = now();
const doc = JSON.parse(text);
const t1 = now();

// 変換: 都市ごとの集計 + レコードの射影
const byCity = new Map();
const projected = new Array(doc.records.length);
for (let i = 0; i < doc.records.length; i++) {
	const r = doc.records[i];
	const cur = byCity.get(r.city);
	if (cur === undefined) {
		byCity.set(r.city, { city: r.city, count: 1, score: r.score, points: r.profile.points });
	} else {
		cur.count++;
		cur.score += r.score;
		cur.points += r.profile.points;
	}
	projected[i] = {
		id: r.id,
		label: r.name + "@" + r.city,
		score: r.score,
		level: r.profile.level,
		tag: r.tags[0],
	};
}
const summary = [...byCity.values()].sort((a, b) => b.count - a.count);
const t2 = now();

const outText = JSON.stringify({ summary, projected });
const t3 = now();

// ピークメモリ（取得できるランタイムだけ）
let heapMB = null;
try {
	const mu = globalThis.process?.memoryUsage;
	if (typeof mu === "function") {
		heapMB = Math.round((mu().heapUsed / 1024 / 1024) * 10) / 10;
	}
} catch {
	heapMB = null;
}

report("B-04", t3 - t0, {
	inputMB: Math.round((text.length / 1024 / 1024) * 10) / 10,
	records: doc.records.length,
	parseMs: Math.round((t1 - t0) * 1000) / 1000,
	transformMs: Math.round((t2 - t1) * 1000) / 1000,
	stringifyMs: Math.round((t3 - t2) * 1000) / 1000,
	outputMB: Math.round((outText.length / 1024 / 1024) * 10) / 10,
	cities: summary.length,
	heapUsedMB: heapMB,
});
