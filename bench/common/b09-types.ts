// B-09 TypeScript 実行
// 設定ファイルもトランスパイル手順も無しに .ts を直接実行できるかを見る。
// Node の型ストリップは消去可能な構文しか通さないため、enum・namespace・
// パラメータプロパティは意図的に使わない（3 ランタイム共通で動く書き方に揃える）。

import { join } from "node:path";
import { now, report } from "./_report.mjs";

type City = "東京" | "大阪" | "名古屋" | "札幌";

interface Member {
	id: number;
	name: string;
	city: City;
	score: number;
	tags: readonly string[];
}

type Summary<T extends { city: City }> = {
	city: City;
	count: number;
	items: T[];
};

const CITIES: readonly City[] = ["東京", "大阪", "名古屋", "札幌"];

function makeMember(id: number): Member {
	return {
		id,
		name: `member-${id.toString(36)}`,
		city: CITIES[id % CITIES.length],
		score: (id % 1000) / 10,
		tags: id % 2 === 0 ? ["even"] : ["odd", "prime?"],
	};
}

function summarize<T extends { city: City }>(items: readonly T[]): Summary<T>[] {
	const map = new Map<City, Summary<T>>();
	for (const item of items) {
		const cur = map.get(item.city);
		if (cur === undefined) {
			map.set(item.city, { city: item.city, count: 1, items: [item] });
		} else {
			cur.count++;
			cur.items.push(item);
		}
	}
	return [...map.values()].sort((a, b) => b.count - a.count);
}

const t0 = now();
const members: Member[] = [];
for (let i = 0; i < 200_000; i++) {
	members.push(makeMember(i));
}
const summary = summarize(members);
const t1 = now();

report("B-09", t1 - t0, {
	members: members.length,
	groups: summary.length,
	// join を1回呼んで node:path の解決も含める
	sample: join("bench", "common", "b09-types.ts"),
});
