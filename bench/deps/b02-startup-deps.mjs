// B-02 依存込み起動
// 実用的な依存をいくつか import した状態の起動コストを測る。
// API には踏み込まず、モジュールの評価だけを強制する（パッケージのバージョン差に
// 影響されないようにするため）。計測は hyperfine が外側で行う。

import * as zod from "zod";
import * as dayjs from "dayjs";
import * as nanoid from "nanoid";
import * as picocolors from "picocolors";
import * as mitt from "mitt";

// 最適化で import ごと消えないよう、各モジュールのエクスポート数を数える
const mods = { zod, dayjs, nanoid, picocolors, mitt };
let keys = 0;
for (const m of Object.values(mods)) {
	keys += Object.keys(m).length;
}

// 出力は 1 文字だけ（I/O の影響を最小にする）
if (keys < 0) {
	console.log("unreachable");
}
