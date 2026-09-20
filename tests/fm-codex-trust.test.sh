#!/usr/bin/env bash
# Behavior tests for Codex project intake, conservative refusal of ambiguous
# project entries, exact config preservation, and structural project-root
# validation.
# Uses only the existing Node dependency, including on stock macOS Python 3.9.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-trust)
TRUST="$ROOT/bin/fm-codex-trust.sh"

make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  PROJ="$CASE_DIR/project"
  WT="$CASE_DIR/worktree"
  CONFIG="$CASE_DIR/codex"
  USER_DIR="$CASE_DIR/user"
  mkdir -p "$CONFIG" "$USER_DIR"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
}

run_trust() {
  HOME="$USER_DIR" CODEX_HOME="$CONFIG" "$TRUST" "$@" 2>&1
}

write_entry() {
  node - "$CONFIG/config.toml" "$PROJ" "$1" <<'NODE'
const fs = require('node:fs');
const [store, project, level] = process.argv.slice(2);
fs.writeFileSync(store, `[projects.${JSON.stringify(project)}]\ntrust_level = ${JSON.stringify(level)}\n`);
NODE
}

assert_trusted() {
  node - "$CONFIG/config.toml" "$PROJ" "$WT" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [store, project, worktree] = process.argv.slice(2);
const text = fs.readFileSync(store, 'utf8').replaceAll('\r\n', '\n');
assert.ok(text.includes(`[projects.${JSON.stringify(project)}]\ntrust_level = "trusted"\n`));
assert.ok(!text.includes(JSON.stringify(worktree)), 'must register the primary root, not its worktree');
NODE
}

assert_appended_to() {
  node - "$1" "$CONFIG/config.toml" "$PROJ" "$2" <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const [beforePath, afterPath, project, newline] = process.argv.slice(2);
const before = fs.readFileSync(beforePath);
const after = fs.readFileSync(afterPath);
const separator = before.length === 0 ? '' : (before[before.length - 1] === 10 ? newline : newline + newline);
const suffix = Buffer.from(`${separator}[projects.${JSON.stringify(project)}]${newline}trust_level = "trusted"${newline}`);
assert.deepEqual(after, Buffer.concat([before, suffix]), 'unrelated config bytes changed');
NODE
}

assert_refused_unchanged() {
  local expected=$1 output
  shift
  cp "$CONFIG/config.toml" "$CASE_DIR/before"
  if output=$(run_trust "$@"); then
    fail "registration unexpectedly succeeded: $*"
  fi
  assert_contains "$output" "$expected" 'refusal explains the unsafe input'
  cmp -s "$CASE_DIR/before" "$CONFIG/config.toml" || fail 'refusal rewrote config.toml'
}

make_case absent
if run_trust "$PROJ" >/dev/null; then
  fail 'missing project-intake authorization succeeded'
fi
[ ! -e "$CONFIG/config.toml" ] || fail 'unauthorized call created config.toml'
output=$(run_trust --project-add "$PROJ")
assert_contains "$output" "trusted: $PROJ" 'a first registration reports the write it performed'
assert_trusted
pass 'only an explicitly authorized intake registers an absent project entry'

make_case preserved
node - "$CONFIG/config.toml" "$PROJ" <<'NODE'
const fs = require('node:fs');
const [store, project] = process.argv.slice(2);
const key = JSON.stringify(project);
fs.writeFileSync(store, `# Keep ordering, comments, spacing, CRLF, and no final newline.
model = 'example-model' # keep this comment
model_reasoning_effort="high"
developer_instructions = """
Leave this prose alone, including the entry it quotes:
[projects.${key}]
trust_level   =   "trusted"
"""
notice = '''
A literal block holding an unbalanced ] and a # that opens no comment.
'''
[projects."/other/trusted"]
trust_level = "trusted"
custom_key = [ 1, 2 ]
[projects."/other/untrusted"]
trust_level = "untrusted"
[mcp_servers."example.server"]
command = "local-server"
args = [
  "--example",
  # a comment inside the array
  "projects.not_a_key",
  "# still string data",
]
[[shell_environment_policy.rules]]
name = "example"
projects.enabled = false
[features]
hooks = false
projects = true`.replaceAll('\n', '\r\n'));
NODE
cp "$CONFIG/config.toml" "$CASE_DIR/before"
run_trust --project-add "$PROJ" >/dev/null
assert_trusted
assert_appended_to "$CASE_DIR/before" $'\r\n'
cp "$CONFIG/config.toml" "$CASE_DIR/once"
run_trust --project-add "$PROJ" >/dev/null
cmp -s "$CASE_DIR/once" "$CONFIG/config.toml" || fail 'trusted project was rewritten'
pass 'multiline, nested-projects, and unrelated constructs are skipped intact; repeated registration is a no-op'

make_case short_circuit
node - "$CONFIG/config.toml" "$PROJ" <<'NODE'
const fs = require('node:fs');
const [store, project] = process.argv.slice(2);
fs.writeFileSync(store, `[projects.${JSON.stringify(project)}]
trust_level = "trusted"

[projects.'/other/path']
trust_level = "untrusted"
`);
NODE
cp "$CONFIG/config.toml" "$CASE_DIR/before"
output=$(run_trust --project-add "$PROJ")
assert_contains "$output" 'existing trusted entry' 'settled decision is reported without reading further'
cmp -s "$CASE_DIR/before" "$CONFIG/config.toml" || fail 'settled project was rewritten'
pass 'an already trusted project no-ops without judging the rest of the file'

make_case untrusted
write_entry untrusted
cp "$CONFIG/config.toml" "$CASE_DIR/before"
output=$(run_trust --project-add "$PROJ")
assert_contains "$output" 'explicitly untrusted; decision preserved' 'untrusted decision is reported'
cmp -s "$CASE_DIR/before" "$CONFIG/config.toml" || fail 'untrusted decision was changed'
pass 'canonical untrusted decision is a reported no-op'

make_case unexpected
write_entry undecided
cp "$CONFIG/config.toml" "$CASE_DIR/before"
run_trust --project-add "$PROJ" >/dev/null
cmp -s "$CASE_DIR/before" "$CONFIG/config.toml" || fail 'existing project entry was changed'
pass 'any existing canonical project entry is left unchanged'

for shape in quoted literal spaced dotted inline escaped array_table projects_parent subtable; do
  make_case "syntax-$shape"
  node - "$CONFIG/config.toml" "$PROJ" "$shape" <<'NODE'
const fs = require('node:fs');
const [store, project, shape] = process.argv.slice(2);
const key = JSON.stringify(project);
const cases = {
  quoted: `[ "projects" . '${project}' ]\ntrust_level = "untrusted"\n`,
  literal: `[projects.'${project}']\ntrust_level = "untrusted"\n`,
  spaced: `[ projects . ${key} ]\ntrust_level = "untrusted"\n`,
  dotted: `projects.${key}.trust_level = "untrusted"\n`,
  inline: `projects = { ${key} = { trust_level = "untrusted" } }\n`,
  escaped: `["\\u0070rojects".${key}]\ntrust_level = "untrusted"\n`,
  array_table: `[[projects.${key}]]\ntrust_level = "untrusted"\n`,
  projects_parent: `[projects]\n${key} = { trust_level = "untrusted" }\n`,
  subtable: `[projects.${key}.nested]\nkey = "value"\n`,
};
fs.writeFileSync(store, cases[shape]);
NODE
  assert_refused_unchanged 'refusing to register Codex trust' --project-add "$PROJ"
done
pass 'every noncanonical construct that could name this project refuses before writing'

make_case malformed
printf '[projects\n' > "$CONFIG/config.toml"
assert_refused_unchanged 'table header' --project-add "$PROJ"
printf 'model = "unfinished\n' > "$CONFIG/config.toml"
assert_refused_unchanged 'unterminated string' --project-add "$PROJ"
printf 'args = [\n"unfinished",\n' > "$CONFIG/config.toml"
assert_refused_unchanged 'unterminated value' --project-add "$PROJ"
printf 'text = """\nunfinished\n' > "$CONFIG/config.toml"
assert_refused_unchanged 'unterminated multiline string' --project-add "$PROJ"
pass 'incomplete tables, strings, and values refuse without writes'

make_case scope
printf '# untouched\n' > "$CONFIG/config.toml"
mkdir -p "$PROJ/subdir" "$CASE_DIR/plain"
assert_refused_unchanged 'linked worktree' --project-add "$WT"
assert_refused_unchanged 'subdirectory' --project-add "$PROJ/subdir"
assert_refused_unchanged 'not a Git checkout' --project-add "$CASE_DIR/plain"
assert_refused_unchanged 'filesystem root' --project-add /
assert_refused_unchanged 'home directory' --project-add "$USER_DIR"
GIT_DIR="$PROJ/.git" GIT_WORK_TREE="$WT" \
  assert_refused_unchanged 'linked worktree' --project-add "$WT"
pass 'only primary project roots qualify, despite inherited Git overrides'

make_case symlink
printf '# symlink target\n' > "$CASE_DIR/actual.toml"
chmod 640 "$CASE_DIR/actual.toml"
ln -s "$CASE_DIR/actual.toml" "$CONFIG/config.toml"
run_trust --project-add "$PROJ" >/dev/null
[ -L "$CONFIG/config.toml" ] || fail 'config symlink was replaced'
assert_trusted
node - "$CASE_DIR/actual.toml" <<'NODE'
require('node:assert/strict').equal(require('node:fs').statSync(process.argv[2]).mode & 0o777, 0o640);
NODE
pass 'owned config symlinks and existing permissions survive registration'

make_case symlinked_home
REAL_CONFIG=$CONFIG
CONFIG="$CASE_DIR/linked-codex"
ln -s "$REAL_CONFIG" "$CONFIG"
output=$(run_trust --project-add "$PROJ")
assert_contains "$output" "trusted: $PROJ" 'a first registration through a linked directory reports its own write'
assert_trusted
[ -L "$CONFIG" ] || fail 'config directory symlink was replaced'
[ -f "$REAL_CONFIG/config.toml" ] || fail 'config landed outside the linked directory'
cp "$REAL_CONFIG/config.toml" "$CASE_DIR/once"
output=$(run_trust --project-add "$PROJ")
assert_contains "$output" 'existing trusted entry' 'a later call reports the settled decision'
cmp -s "$CASE_DIR/once" "$REAL_CONFIG/config.toml" || fail 'second call rewrote the config'
pass 'a fresh config in a symlinked config directory reports its own write, then unchanged'

make_case atomic_failure
printf '# original\n' > "$CONFIG/config.toml"
cp "$CONFIG/config.toml" "$CASE_DIR/before"
cat > "$CASE_DIR/rename-failure.cjs" <<'NODE'
const fs = require('node:fs');
const rename = fs.renameSync;
fs.renameSync = (from, to) => {
  if (to.endsWith('/config.toml')) throw new Error('simulated publication failure');
  return rename(from, to);
};
NODE
if NODE_OPTIONS="--require=$CASE_DIR/rename-failure.cjs" run_trust --project-add "$PROJ" > "$CASE_DIR/output"; then
  fail 'simulated publication failure unexpectedly succeeded'
fi
assert_contains "$(cat "$CASE_DIR/output")" 'simulated publication failure' 'fault injection reached atomic publication'
cmp -s "$CASE_DIR/before" "$CONFIG/config.toml" || fail 'publication failure truncated config'
[ -z "$(find "$CONFIG" -name '.config.toml.fm-trust.*' -print)" ] || fail 'publication failure stranded staging files'
pass 'failed atomic publication leaves the original config untouched'

make_case quoted
PROJ="$CASE_DIR/project with \"quotes\" and \\ café"
fm_git_init_commit "$PROJ"
run_trust --project-add "$PROJ" >/dev/null
assert_trusted
run_trust --project-add "$PROJ" >/dev/null
pass 'quoted, backslash, and Unicode path keys register idempotently'

make_case default_store
HOME="$USER_DIR" CODEX_HOME='' "$TRUST" --project-add "$PROJ" >/dev/null
[ -f "$USER_DIR/.codex/config.toml" ] || fail 'default store was not used'
[ ! -e "$CONFIG/config.toml" ] || fail 'override store was unexpectedly written'
if HOME="$USER_DIR" CODEX_HOME=relative "$TRUST" --project-add "$PROJ" > "$CASE_DIR/output" 2>&1; then
  fail 'relative CODEX_HOME was accepted'
fi
assert_contains "$(cat "$CASE_DIR/output")" 'CODEX_HOME must be absolute' 'relative-store refusal'
pass 'default HOME store and absolute CODEX_HOME override are isolated correctly'

echo '# all fm-codex-trust tests passed'
