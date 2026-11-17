#!/bin/bash
# Keep Anton's global agent rules in one place.
#
#   ~/.agents/global-rules.md   the shared rules (edit this one)
#   ~/.agents/codex-only.md     optional rules that only Codex should see
#   ~/.claude/CLAUDE.md         loads the shared file with `@~/.agents/global-rules.md`
#   ~/.codex/AGENTS.md          GENERATED here: header + shared rules + codex-only rules
#
# Codex cannot import files, so AGENTS.md is a built copy. Other tools (the Atoll skill installer,
# the CI run notifier) edit AGENTS.md or CLAUDE.md in place between <!-- NAME:START --> and
# <!-- NAME:END --> markers. Before it rebuilds anything this script copies those marker blocks back
# into the shared file (so an installer re-run is kept, not overwritten) and removes them from
# CLAUDE.md (which only needs the import line). Safe to run any time and as often as you like:
# when nothing needs changing it writes nothing.
#
# Env overrides (used by the tests): GLOBAL_RULES_FILE, GLOBAL_RULES_CODEX_ONLY, CODEX_AGENTS_FILE,
# CLAUDE_MD_FILE, GLOBAL_RULES_STATE_DIR. Exit codes: 0 ok, 2 missing shared file, 3 secret-like text.
set -euo pipefail

SHARED="${GLOBAL_RULES_FILE:-$HOME/.agents/global-rules.md}"
CODEX_ONLY="${GLOBAL_RULES_CODEX_ONLY:-$HOME/.agents/codex-only.md}"
AGENTS="${CODEX_AGENTS_FILE:-$HOME/.codex/AGENTS.md}"
CLAUDE="${CLAUDE_MD_FILE:-$HOME/.claude/CLAUDE.md}"
STATE="${GLOBAL_RULES_STATE_DIR:-$HOME/.agents/.global-rules-sync}"
MARKERS=(ATOLL:GLOBAL-INSTRUCTIONS CI-RUN-NOTIFICATIONS)
TILDE="~"
tilde() { printf "%s" "${1/#$HOME/$TILDE}"; }
IMPORT_LINE="@$(tilde "$SHARED")"
LOG="$STATE/sync.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

[ -f "$SHARED" ] || { echo "sync-global-rules: $SHARED does not exist (run install-global-rules.sh)" >&2; exit 2; }
mkdir -p "$STATE"

# One run at a time; a stale lock (crashed run) is cleared after a minute.
LOCK="$STATE/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
  else exit 0; fi
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$LOCK"' EXIT

# --- helpers ---------------------------------------------------------------------------------
# block_of <file> <NAME>: print the first <!-- NAME:START --> ... <!-- NAME:END --> block.
block_of() {
  awk -v s="<!-- $2:START -->" -v e="<!-- $2:END -->" \
    '!p && $0==s {p=1} p {print} p && $0==e {exit}' "$1"
}
# replace_block <file> <NAME> <blockfile>: swap the first block for blockfile (append when absent),
# drop any later copies of that block.
replace_block() {
  awk -v s="<!-- $2:START -->" -v e="<!-- $2:END -->" -v bf="$3" '
    BEGIN { while ((getline l < bf) > 0) blk = blk l "\n" }
    $0==s && !skip { if (!done) { printf "%s", blk; done=1 } skip=1; next }
    skip { if ($0==e) skip=0; next }
    { print }
    END { if (!done) { if (NR) print ""; printf "%s", blk } }' "$1"
}
strip_block() {
  awk -v s="<!-- $2:START -->" -v e="<!-- $2:END -->" '
    $0==s {skip=1; next} skip {if ($0==e) skip=0; next} {print}' "$1" |
    cat -s | awk 'NF {for (i=0;i<b;i++) print ""; b=0; print; next} {b++}'
}
# write_file <target> <contentfile>: atomic replace, keeps the target's mode, refuses symlinks.
write_file() {
  local target="$1" src="$2" mode tmp
  if [ -L "$target" ]; then echo "sync-global-rules: $target is a symlink, not touching it" >&2; log "skip symlink $target"; return 1; fi
  mkdir -p "$(dirname "$target")"
  mode="$(stat -f %Lp "$target" 2>/dev/null || echo 600)"
  tmp="$(mktemp "$(dirname "$target")/.$(basename "$target").sync.XXXXXX")"
  cat "$src" > "$tmp"; chmod "$mode" "$tmp"; mv -f "$tmp" "$target"
}

# --- 1. secret check (never prints the text it matched) ----------------------------------------
SECRET_RE='(sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[Bb]earer +[A-Za-z0-9._~+/=-]{20,}|(password|passwd|secret|api[_-]?key|token)[A-Za-z_]* *[:=] *[^ ]{8,})'
for f in "$SHARED" "$CODEX_ONLY"; do
  if [ -f "$f" ] && grep -Eq "$SECRET_RE" "$f"; then
    echo "sync-global-rules: $f looks like it contains a secret; nothing was changed. Remove it and run again." >&2
    log "refused: secret-like text in $f"
    exit 3
  fi
done

# --- 2. take marker blocks written by other installers back into the shared file ---------------
for src in "$AGENTS" "$CLAUDE"; do
  [ -f "$src" ] || continue
  for name in "${MARKERS[@]}"; do
    block_of "$src" "$name" > "$TMP/blk"
    [ -s "$TMP/blk" ] || continue
    grep -qxF "<!-- $name:END -->" "$TMP/blk" || continue   # unterminated block: ignore
    block_of "$SHARED" "$name" > "$TMP/cur"
    cmp -s "$TMP/blk" "$TMP/cur" && continue
    cp -p "$SHARED" "$STATE/global-rules.md.prev"
    replace_block "$SHARED" "$name" "$TMP/blk" > "$TMP/new"
    write_file "$SHARED" "$TMP/new"
    log "took $name block from $src into $SHARED"
  done
done

# --- 3. CLAUDE.md: one import line, no pasted copies of the shared rules ------------------------
if [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ]; then
  cp "$CLAUDE" "$TMP/claude"
  for name in "${MARKERS[@]}"; do
    if grep -qxF "<!-- $name:START -->" "$TMP/claude"; then
      strip_block "$TMP/claude" "$name" > "$TMP/claude.n"; mv "$TMP/claude.n" "$TMP/claude"
    fi
  done
  if ! grep -qxF "$IMPORT_LINE" "$TMP/claude"; then
    { printf '<!-- Shared global rules live in %s (edit there). Claude-only rules go below the import line. -->\n%s\n' \
        "$(tilde "$SHARED")" "$IMPORT_LINE"
      [ -s "$TMP/claude" ] && { echo; cat "$TMP/claude"; }
    } > "$TMP/claude.n"; mv "$TMP/claude.n" "$TMP/claude"
  fi
  if ! cmp -s "$TMP/claude" "$CLAUDE"; then write_file "$CLAUDE" "$TMP/claude" && log "updated $CLAUDE"; fi
fi

# --- 4. build AGENTS.md -------------------------------------------------------------------------
{
  printf '<!-- GENERATED FILE. Do not edit here: edits are overwritten.\n'
  printf '     Edit %s (shared with Claude Code), or %s for Codex-only rules.\n' \
    "$(tilde "$SHARED")" "$(tilde "$CODEX_ONLY")"
  printf '     Rebuilt by grokbot-t3-bridge scripts/sync-global-rules.sh. -->\n\n'
  cat "$SHARED"
  if [ -f "$CODEX_ONLY" ] && grep -q '[^[:space:]]' "$CODEX_ONLY"; then printf '\n'; cat "$CODEX_ONLY"; fi
} | awk '{print} END{}' > "$TMP/agents"
# Exactly one trailing newline.
awk 'NF {for (i=0;i<b;i++) print ""; b=0; print; next} {b++}' "$TMP/agents" > "$TMP/agents.n"; mv "$TMP/agents.n" "$TMP/agents"

if [ ! -f "$AGENTS" ] || ! cmp -s "$TMP/agents" "$AGENTS"; then
  # Someone edited the generated file by hand: keep their version before it is replaced.
  if [ -f "$AGENTS" ] && [ -f "$STATE/last-agents.md" ] && ! cmp -s "$AGENTS" "$STATE/last-agents.md"; then
    mkdir -p "$STATE/unsynced"
    cp -p "$AGENTS" "$STATE/unsynced/AGENTS.md.$(date +%Y%m%d-%H%M%S)"
    log "AGENTS.md had edits outside the marker blocks; copy kept in $STATE/unsynced"
  fi
  write_file "$AGENTS" "$TMP/agents" && log "rebuilt $AGENTS"
fi
cp "$TMP/agents" "$STATE/last-agents.md"
exit 0
