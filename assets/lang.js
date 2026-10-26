// The language of a file whose name does not say: an extensionless script
// such as bin/outbox names its interpreter on the first line instead.
// Returns a Shiki language id, or undefined.
const INTERPRETERS = {
  ruby: "ruby", python: "python", python2: "python", python3: "python", node: "javascript", nodejs: "javascript",
  deno: "typescript", bun: "javascript", sh: "bash", bash: "bash", zsh: "bash", dash: "bash", ash: "bash",
  ksh: "bash", fish: "fish", perl: "perl", php: "php", lua: "lua", awk: "awk", gawk: "awk", Rscript: "r",
  tclsh: "tcl", pwsh: "powershell", make: "make",
};

export function shebangLang(contents) {
  const m = /^#![ \t]*(\S+)(?:[ \t]+(.*))?/.exec(contents.slice(0, 256));
  if (!m) return undefined;
  let [, program, rest = ""] = m;
  let name = program.split("/").pop();
  if (name === "env") {
    // `env -S ruby -w`, `env FOO=1 ruby`: the first word that is not a flag or an assignment.
    name = rest.split(/\s+/).find((w) => w && !w.startsWith("-") && !w.includes("=")) ?? "";
  }
  return INTERPRETERS[name] ?? INTERPRETERS[name.replace(/[\d.]+$/, "")];
}
