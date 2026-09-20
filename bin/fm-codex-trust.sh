#!/usr/bin/env bash
# Register Codex directory trust during an explicitly authorized project intake.
# Usage: fm-codex-trust.sh --project-add <project-root>
#
# Call only after the operator has authorized this project's intake: adding,
# cloning, or creating it in the main home, as directed by
# .agents/skills/project-management/SKILL.md, or provisioning a secondmate
# whose project list names it, as directed by
# .agents/skills/secondmate-provisioning/SKILL.md, for the clone that
# provisioning creates in that home. The required flag asserts that intake
# authorization; repository presence or a worker launch is NOT consent. Never
# call from spawn, fleet sync, a discovered clone, or registry recovery.
# Codex persists trust at the primary repository root, covering its linked
# worktrees; accepting its directory dialog is not session-scoped.
#
# Follows fm-claude-trust.sh's structural scope validation and atomic store
# replacement, but never overwrites an existing trust decision. Only an exact
# primary checkout root is accepted, never a linked worktree, subdirectory,
# filesystem root, or home directory. An existing trusted entry is a no-op;
# any existing entry is left unchanged, with an explicit untrusted decision
# reported as such.
#
# Uses the existing Node dependency. Writes only the launching user's
# ${CODEX_HOME:-$HOME/.codex}/config.toml. CODEX_HOME must be absolute when set.
# Follows a config symlink to its owned regular-file target, retaining the link.
# The scan answers one question - is this project path already decided - and
# stops the moment it knows, so a construct it cannot read after that answer
# is never reached. Ordinary TOML it only has to skip over is skipped without
# interpretation: multiline arrays and strings, array tables, comments, and
# unrelated tables of any shape. Only a genuinely ambiguous projects entry
# refuses: a projects-rooted construct outside Codex's canonical
# [projects."<path>"] table could name this project in a spelling the scan
# cannot compare, and appending beside it could duplicate its table. Malformed
# TOML - an unterminated string, value, or table header - refuses too, since
# appending to it would land inside an unclosed construct. Every refusal
# happens BEFORE any write, and existing bytes are never reserialized.
# Rechecks the original bytes and file identity before atomic replacement and
# verifies the result afterward. Concurrent changes cause a retry, then refusal;
# as in the Claude helper, the final check/rename window is not a vendor lock.
# Returns nonzero on refusal; registration is best effort and never blocks
# intake or a later spawn. Intake reports it without undoing the project or
# treating it as permission to answer the directory dialog. Hook trust is never
# touched. The directory dialog remains available for an operator decision.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() { echo 'usage: fm-codex-trust.sh --project-add <project-root>' >&2; }
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "$0"
  exit 0
fi
[ "$#" -eq 2 ] && [ "$1" = --project-add ] || { usage; exit 2; }
refuse() { echo "error: refusing to register Codex trust: $1" >&2; exit 1; }
real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

PROJECT=$(real_dir "$2") || refuse "'$2' is not an accessible directory"
[ "$PROJECT" != / ] || refuse 'the filesystem root is not a project'
if [ -n "${HOME:-}" ]; then
  USER_HOME_REAL=$(real_dir "$HOME") || true
  [ "$PROJECT" != "${USER_HOME_REAL:-}" ] || refuse 'the home directory is not a project'
fi
TOP=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || refuse "'$PROJECT' is not a Git checkout"
TOP=$(real_dir "$TOP") || refuse 'could not resolve the checkout root'
[ "$TOP" = "$PROJECT" ] || refuse "'$PROJECT' is a subdirectory, not the project root"
GIT_PATH=$(git -C "$PROJECT" rev-parse --absolute-git-dir 2>/dev/null) || refuse 'could not resolve the Git directory'
GIT_PATH=$(real_dir "$GIT_PATH") || refuse 'could not resolve the Git directory'
COMMON=$(git -C "$PROJECT" rev-parse --git-common-dir 2>/dev/null) || refuse 'could not resolve the common directory'
COMMON=$(cd -P -- "$PROJECT" && real_dir "$COMMON") || refuse 'could not resolve the common directory'
[ "$GIT_PATH" = "$COMMON" ] || refuse "'$PROJECT' is a linked worktree, not the primary project root"

if [ -n "${CODEX_HOME:-}" ]; then
  case "$CODEX_HOME" in /*) ;; *) refuse 'CODEX_HOME must be absolute' ;; esac
  CONFIG_DIR=$CODEX_HOME
else
  [ -n "${HOME:-}" ] || refuse 'neither CODEX_HOME nor HOME is set'
  CONFIG_DIR=$HOME/.codex
fi
command -v node >/dev/null 2>&1 || refuse 'node is required'

node - "$CONFIG_DIR/config.toml" "$PROJECT" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { TextDecoder } = require("node:util");
const [storeArg, project] = process.argv.slice(2);
const refuse = (reason) => { throw new Error(reason); };
const quotePath = (value) => JSON.stringify(value).replace(/\x7f/g, "\\u007f");

function read(file) {
  let info;
  try { info = fs.lstatSync(file); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  if (!info.isFile() || info.uid !== process.getuid()) {
    refuse(`${file} must be a regular file owned by this user`);
  }
  return { bytes: fs.readFileSync(file), info };
}
function same(left, right) {
  if (left === null || right === null) return left === right;
  return left.bytes.equals(right.bytes) && ["dev", "ino", "mtimeMs", "mode", "size"].every(
    (key) => left.info[key] === right.info[key],
  );
}
function resolveStore() {
  try { return fs.realpathSync(storeArg); }
  catch (error) {
    if (error.code !== "ENOENT") throw error;
    try { fs.lstatSync(storeArg); refuse(`${storeArg} is a broken symlink`); }
    catch (missing) { if (missing.code !== "ENOENT") throw missing; }
    return path.resolve(storeArg);
  }
}

// Walks statements, not values: a value is consumed only far enough to find
// where it ends, so anything that is not a projects entry is skipped whole.
function existingEntry(bytes) {
  const raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const canonicalTable = /^\[projects\.("(?:[^"\\\x00-\x1f]|\\.)*")\]$/;
  const trustStatement = /^trust_level\s*=\s*"(trusted|untrusted)"\s*(?:#.*)?$/;
  let at = 0;
  let line = 1;
  const refuseAt = (where, why) => refuse(`line ${where}: ${why}`);
  const blanks = () => { while (raw[at] === " " || raw[at] === "\t") at += 1; };
  const comment = () => { while (at < raw.length && raw[at] !== "\n") at += 1; };

  function skipString(where) {
    const quote = raw[at];
    if (raw.startsWith(quote.repeat(3), at)) {
      for (at += 3; at < raw.length; at += 1) {
        if (quote === '"' && raw[at] === "\\") {
          if (raw[at + 1] === "\n") line += 1;
          at += 1;
          continue;
        }
        if (raw[at] === "\n") { line += 1; continue; }
        if (raw.startsWith(quote.repeat(3), at)) {
          let run = 0;
          while (raw[at + run] === quote) run += 1;
          at += Math.min(run, 5);
          return;
        }
      }
      refuseAt(where, "unterminated multiline string; config left unchanged");
    }
    for (at += 1; at < raw.length; at += 1) {
      if (raw[at] === "\n") break;
      if (quote === '"' && raw[at] === "\\") {
        if (raw[at + 1] === undefined || raw[at + 1] === "\n") break;
        at += 1;
        continue;
      }
      if (raw[at] === quote) { at += 1; return; }
    }
    refuseAt(where, "unterminated string; config left unchanged");
  }
  // A statement must finish before the append point, or a new table could land
  // inside an unclosed array, inline table, or multiline string.
  function skipValue(where) {
    const stack = [];
    while (at < raw.length) {
      const char = raw[at];
      if (char === '"' || char === "'") { skipString(where); continue; }
      if (char === "#") { comment(); continue; }
      if (char === "[" || char === "{") { stack.push(char); at += 1; continue; }
      if (char === "]" || char === "}") {
        if (stack.pop() !== (char === "]" ? "[" : "{")) refuseAt(where, "unbalanced value; config left unchanged");
        at += 1;
        continue;
      }
      if (char === "\n") {
        if (!stack.length) return;
        line += 1;
      }
      at += 1;
    }
    if (stack.length) refuseAt(where, "unterminated value; config left unchanged");
  }
  // Key parts stay raw; only the root is decoded, because only the root
  // decides whether a construct can name a project at all.
  function readKey(where) {
    const parts = [];
    for (;;) {
      blanks();
      const char = raw[at];
      const from = at;
      if (char === '"' || char === "'") {
        if (raw.startsWith(char.repeat(3), at)) refuseAt(where, "multiline key; config left unchanged");
        skipString(where);
      } else {
        while (at < raw.length && /[A-Za-z0-9_-]/.test(raw[at])) at += 1;
        if (at === from) return null;
      }
      parts.push(raw.slice(from, at));
      blanks();
      if (raw[at] !== ".") return parts;
      at += 1;
    }
  }
  function rootKey(part, where) {
    if (part[0] === "'") return part.slice(1, -1);
    if (part[0] !== '"') return part;
    try { return JSON.parse(part); }
    catch { return refuseAt(where, "unreadable quoted key; config left unchanged"); }
  }

  let inProject = false;
  let decision;
  for (;;) {
    while (at < raw.length) {
      const char = raw[at];
      if (char === " " || char === "\t" || char === "\r") { at += 1; continue; }
      if (char === "\n") { at += 1; line += 1; continue; }
      if (char === "#") { comment(); continue; }
      break;
    }
    if (at >= raw.length) return decision;
    const where = line;
    const from = at;
    if (raw[at] === "[") {
      if (inProject) return decision;
      const arrayTable = raw[at + 1] === "[";
      at += arrayTable ? 2 : 1;
      const parts = readKey(where);
      blanks();
      const closer = arrayTable ? "]]" : "]";
      if (!parts || !raw.startsWith(closer, at)) refuseAt(where, "noncanonical or ambiguous table header");
      at += closer.length;
      const header = raw.slice(from, at);
      blanks();
      if (raw[at] === "#") comment();
      if (at < raw.length && raw[at] !== "\n" && raw[at] !== "\r") {
        refuseAt(where, "noncanonical or ambiguous table header");
      }
      const canonical = arrayTable ? null : header.match(canonicalTable);
      if (!canonical) {
        if (rootKey(parts[0], where) === "projects") refuseAt(where, "noncanonical or ambiguous table header");
        continue;
      }
      let name;
      try { name = JSON.parse(canonical[1]); }
      catch { refuseAt(where, "noncanonical project path quoting"); }
      if (quotePath(name) !== canonical[1]) refuseAt(where, "noncanonical project path quoting");
      if (name === project) { inProject = true; decision = "unspecified"; }
      continue;
    }
    const parts = readKey(where);
    blanks();
    if (!parts || raw[at] !== "=" || rootKey(parts[0], where) === "projects") {
      refuseAt(where, "noncanonical or ambiguous assignment (including dotted or inline projects)");
    }
    at += 1;
    blanks();
    skipValue(where);
    if (inProject) {
      const trust = raw.slice(from, at).trim().match(trustStatement);
      if (trust) return trust[1];
    }
  }
}

function stage(file, bytes, mode) {
  const temp = path.join(path.dirname(file), `.config.toml.fm-trust.${process.pid}.${crypto.randomBytes(8).toString("hex")}`);
  const fd = fs.openSync(temp, "wx", 0o600);
  try {
    fs.writeFileSync(fd, bytes);
    fs.fchmodSync(fd, mode);
    fs.fsyncSync(fd);
  } catch (error) { fs.unlinkSync(temp); throw error; }
  finally { fs.closeSync(fd); }
  return temp;
}
function attempt() {
  const store = resolveStore();
  const original = read(store);
  const before = original?.bytes ?? Buffer.alloc(0);
  const existing = existingEntry(before);
  if (existing !== undefined) {
    const detail = existing === "untrusted" ? "explicitly untrusted; decision preserved" : `existing ${existing} entry`;
    console.log(`unchanged: ${project} (${detail})`);
    return true;
  }
  if (original) fs.accessSync(store, fs.constants.W_OK);
  const newline = before.includes(Buffer.from("\r\n")) ? "\r\n" : "\n";
  const separator = before.length === 0 ? "" : (before[before.length - 1] === 10 ? newline : newline + newline);
  const quoted = quotePath(project);
  const addition = `${separator}[projects.${quoted}]${newline}trust_level = "trusted"${newline}`;
  const candidate = Buffer.concat([before, Buffer.from(addition)]);
  const mode = original ? original.info.mode & 0o777 : 0o600;
  fs.mkdirSync(path.dirname(store), { recursive: true, mode: 0o700 });
  let temp = stage(store, candidate, mode);
  try {
    if (resolveStore() !== store || !same(read(store), original)) return false;
    fs.renameSync(temp, store);
    temp = null;
    if (resolveStore() !== store || !read(store)?.bytes.equals(candidate)) return false;
    console.log(`trusted: ${project}`);
    return true;
  } finally {
    if (temp) fs.unlinkSync(temp);
  }
}
try {
  let recorded = false;
  for (let i = 0; i < 2 && !recorded; i += 1) recorded = attempt();
  if (!recorded) refuse("config.toml changed while recording trust; retry after the writer settles");
} catch (error) {
  console.error(`error: refusing to register Codex trust: ${error.message}`);
  process.exit(1);
}
NODE
