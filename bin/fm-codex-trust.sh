#!/usr/bin/env bash
# Register Codex directory trust during an explicitly authorized project intake.
# Usage: fm-codex-trust.sh --project-add <project-root>
#
# Call only after the operator has approved adding/cloning/creating this project,
# as directed by .agents/skills/project-management/SKILL.md. The required flag
# asserts that intake authorization; repository presence or a worker launch is
# NOT consent. Never call from spawn, fleet sync, seeding, or registry recovery.
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
# Recognizes only canonical [projects."<path>"] tables and single-line
# statements. Noncanonical projects constructs, quoted root keys, multiline
# values, unbalanced delimiters, or otherwise ambiguous syntax refuse BEFORE
# any write. This is a conservative presence check, not a general TOML parser.
# Existing bytes are never reserialized. An owned regular config.toml.bak is
# atomically replaced with the original bytes before replacing config.toml.
# A missing config has no previous bytes to back up.
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
const backup = `${storeArg}.bak`;
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

// Mask single-line strings and comments before recognizing statement shapes.
// Quoted root keys might spell "projects" with TOML escapes, so every such
// construct refuses rather than trying to implement a general TOML reader.
// Multiline values refuse too: a line-shaped header inside one is not a table.
function maskLine(line, number) {
  let masked = "";
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === "#") break;
    if (char !== '"' && char !== "'") { masked += char; continue; }
    if (line.slice(i, i + 3) === char.repeat(3)) {
      refuse(`line ${number}: multiline values are not supported; config left unchanged`);
    }
    const quote = char;
    let closed = false;
    for (i += 1; i < line.length; i += 1) {
      if (quote === '"' && line[i] === "\\") { i += 1; continue; }
      if (line[i] === quote) { closed = true; break; }
    }
    if (!closed) refuse(`line ${number}: unterminated string; config left unchanged`);
    masked += "Q";
  }
  return masked.trim();
}
function existingEntry(bytes) {
  const raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const entries = new Map();
  let currentProject = null;
  const key = "[A-Za-z0-9_-]+";
  const table = new RegExp(`^\\[(${key})(?:\\s*\\.\\s*(?:${key}|Q))*\\]$`);
  const assignment = new RegExp(`^(${key})(?:\\s*\\.\\s*(?:${key}|Q))*\\s*=\\s*(.+)$`);
  for (const [index, line] of raw.split(/\r?\n/).entries()) {
    const number = index + 1;
    const masked = maskLine(line, number);
    if (!masked) continue;
    const canonical = line.trim().match(/^\[projects\.("(?:[^"\\\x00-\x1f]|\\.)*")\]\s*(?:#.*)?$/);
    if (canonical) {
      let name;
      try { name = JSON.parse(canonical[1]); }
      catch { refuse(`line ${number}: noncanonical project path quoting`); }
      if (quotePath(name) !== canonical[1]) refuse(`line ${number}: noncanonical project path quoting`);
      if (entries.has(name)) refuse(`line ${number}: duplicate project table`);
      entries.set(name, "unspecified");
      currentProject = name;
      continue;
    }
    if (masked.startsWith("[")) {
      const match = masked.match(table);
      if (!match || match[1] === "projects" || line.trim().match(/^\[\s*["']/)) {
        refuse(`line ${number}: noncanonical or ambiguous table header`);
      }
      currentProject = null;
      continue;
    }
    const match = masked.match(assignment);
    if (!match || match[1] === "projects" || line.trim().match(/^["']/)) {
      refuse(`line ${number}: noncanonical or ambiguous assignment (including dotted or inline projects)`);
    }
    // A statement must finish on its own line, or appending a table could land
    // inside an array or inline table. Unknown/multiline shapes are refused.
    const stack = [];
    for (const char of match[2]) {
      if (char === "[" || char === "{") stack.push(char);
      if (char === "]" || char === "}") {
        if (stack.pop() !== (char === "]" ? "[" : "{")) refuse(`line ${number}: unbalanced value`);
      }
    }
    if (stack.length) refuse(`line ${number}: multiline or unbalanced value`);
    if (currentProject !== null) {
      const trust = line.trim().match(/^trust_level\s*=\s*"(trusted|untrusted)"\s*(?:#.*)?$/);
      if (trust) entries.set(currentProject, trust[1]);
    }
  }
  return entries.get(project);
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
  const previousBackup = read(backup); // Refuse a foreign file or symlink.
  const newline = before.includes(Buffer.from("\r\n")) ? "\r\n" : "\n";
  const separator = before.length === 0 ? "" : (before[before.length - 1] === 10 ? newline : newline + newline);
  const quoted = quotePath(project);
  const addition = `${separator}[projects.${quoted}]${newline}trust_level = "trusted"${newline}`;
  const candidate = Buffer.concat([before, Buffer.from(addition)]);
  const mode = original ? original.info.mode & 0o777 : 0o600;
  fs.mkdirSync(path.dirname(store), { recursive: true, mode: 0o700 });
  let temp = stage(store, candidate, mode);
  let backupTemp;
  try {
    if (original) backupTemp = stage(backup, before, 0o600);
    if (resolveStore() !== store || !same(read(store), original) || !same(read(backup), previousBackup)) return false;
    if (backupTemp) { fs.renameSync(backupTemp, backup); backupTemp = null; }
    if (resolveStore() !== store || !same(read(store), original)) return false;
    fs.renameSync(temp, store);
    temp = null;
    if (resolveStore() !== store || !read(store)?.bytes.equals(candidate)) return false;
    console.log(`trusted: ${project}`);
    return true;
  } finally {
    if (temp) fs.unlinkSync(temp);
    if (backupTemp) fs.unlinkSync(backupTemp);
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
