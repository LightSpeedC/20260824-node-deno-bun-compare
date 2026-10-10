// B-10 単一実行ファイル化の対象となる最小 CLI。
// 依存を持たず、引数を受けて出力するだけ。バンドル対象の複雑さを揃えるため
// あえて素の JavaScript のみで書く。

const args = globalThis.process?.argv?.slice(2) ?? [];
const name = args[0] ?? "world";

const lines = [
	`hello, ${name}`,
	`argv: ${JSON.stringify(args)}`,
	`platform: ${globalThis.process?.platform ?? "unknown"}`,
];

console.log(lines.join("\n"));
