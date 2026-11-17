#!/bin/bash
# shellcheck disable=SC2015,SC2016
# Global rules sync + installer against a temporary HOME. Touches nothing outside it.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset GLOBAL_RULES_FILE GLOBAL_RULES_CODEX_ONLY CODEX_AGENTS_FILE CLAUDE_MD_FILE GLOBAL_RULES_STATE_DIR
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.agents" "$HOME/.claude-work" "$HOME/.codex-t3"
fail() { echo "FAIL: $*"; exit 1; }
SYNC="$HOME/.grokbot-hooks/sync-global-rules.sh"

AT='<!-- ATOLL:GLOBAL-INSTRUCTIONS:START -->
## Atoll

Use the atoll skill.
<!-- ATOLL:GLOBAL-INSTRUCTIONS:END -->'
CI='<!-- CI-RUN-NOTIFICATIONS:START -->
## CI notifications

Read the CI skill.
<!-- CI-RUN-NOTIFICATIONS:END -->'
printf '%s\n\n## Style\nBe brief.\n\n# T3 CI guidance\n\nFor CI, read the skill.\n\n%s\n\n## No Docker\n- Never start Docker.\n' "$AT" "$CI" > "$HOME/.agents/global-rules.md"
# Old hand-kept files: AGENTS had Atoll + Style, CLAUDE had the CI header; both had the rest.
printf '%s\n\n## Style\nBe brief.\n\n%s\n\n## No Docker\n- Never start Docker.\n' "$AT" "$CI" > "$HOME/.codex/AGENTS.md"
printf '# T3 CI guidance\n\nFor CI, read the skill.\n\n%s\n\n## No Docker\n- Never start Docker.\n' "$CI" > "$HOME/.claude/CLAUDE.md"
chmod 600 "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md"
ln -s "$HOME/.claude/CLAUDE.md" "$HOME/.claude-work/CLAUDE.md"
ln -s "$HOME/.codex/AGENTS.md" "$HOME/.codex-t3/AGENTS.md"
cp "$HOME/.codex/AGENTS.md" "$TMP/old-agents"; cp "$HOME/.claude/CLAUDE.md" "$TMP/old-claude"

# A CLAUDE.md with a rule that is not in the shared file must stop the installer and stay untouched.
cp "$HOME/.claude/CLAUDE.md" "$TMP/claude-keep"; echo 'Only in Claude.' >> "$HOME/.claude/CLAUDE.md"
if bash "$REPO/scripts/install-global-rules.sh" --no-launchd >/dev/null 2>&1; then fail 'installer accepted a CLAUDE.md with a rule the shared file lacks'; fi
grep -qx 'Only in Claude.' "$HOME/.claude/CLAUDE.md" || fail 'installer changed CLAUDE.md before stopping'
cp "$TMP/claude-keep" "$HOME/.claude/CLAUDE.md"; rm -f "$HOME"/.claude/CLAUDE.md.bak-pre-sync "$HOME"/.codex/AGENTS.md.bak-pre-sync   # the failed run backed up the edited file

# Install.
bash "$REPO/scripts/install-global-rules.sh" --no-launchd >/dev/null
grep -qxF '@~/.agents/global-rules.md' "$HOME/.claude/CLAUDE.md" || fail 'CLAUDE.md has no import line'
[ "$(grep -c 'No Docker' "$HOME/.claude/CLAUDE.md")" = 0 ] || fail 'CLAUDE.md still holds a copy of the rules'
cmp -s "$HOME/.claude/CLAUDE.md.bak-pre-sync" "$TMP/old-claude" || fail 'CLAUDE backup differs from the original'
cmp -s "$HOME/.codex/AGENTS.md.bak-pre-sync" "$TMP/old-agents" || fail 'AGENTS backup differs from the original'
head -n1 "$HOME/.codex/AGENTS.md" | grep -q 'GENERATED FILE' || fail 'AGENTS.md has no generated header'
[ ! -L "$HOME/.codex/AGENTS.md" ] && [ ! -L "$HOME/.claude/CLAUDE.md" ] || fail 'a rules file became a symlink'
# No rule lost: every non-blank old line is in the effective rules (CLAUDE.md imports the shared file).
for old in "$TMP/old-agents" "$TMP/old-claude"; do
  while IFS= read -r l; do
    grep -qxF -- "$l" "$HOME/.agents/global-rules.md" || fail "rule lost: $l"
  done < <(grep -v '^[[:space:]]*$' "$old")
done
while IFS= read -r l; do grep -qxF -- "$l" "$HOME/.codex/AGENTS.md" || fail "AGENTS.md misses: $l"; done < <(grep -v '^[[:space:]]*$' "$HOME/.agents/global-rules.md")
[ "$(grep -c 'ATOLL:GLOBAL-INSTRUCTIONS:START' "$HOME/.codex/AGENTS.md")" = 1 ] || fail 'Atoll block missing or duplicated'

# Idempotent: second run writes nothing.
sum1="$(cat "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.agents/global-rules.md" | shasum)"
m1="$(stat -f %m "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md")"
sleep 1; bash "$SYNC"; bash "$REPO/scripts/install-global-rules.sh" --no-launchd >/dev/null
[ "$(cat "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.agents/global-rules.md" | shasum)" = "$sum1" ] || fail 'second run changed content'
[ "$(stat -f %m "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md")" = "$m1" ] || fail 'second run rewrote a file'
[ "$(find "$HOME/.codex" -maxdepth 1 -name "AGENTS.md.bak*" | wc -l | tr -d ' ')" = 1 ] || fail 'second run made another backup'

# Editing the shared file reaches AGENTS.md; the symlinked copy sees it too.
echo '- New rule.' >> "$HOME/.agents/global-rules.md"; bash "$SYNC"
grep -qxF -- '- New rule.' "$HOME/.codex-t3/AGENTS.md" || fail 'shared edit did not reach AGENTS.md'

# Atoll installer re-run: it rewrites its block in AGENTS.md; the sync keeps it and passes it on.
sed -i '' 's/Use the atoll skill\./Use the atoll skill v2./' "$HOME/.codex/AGENTS.md"
bash "$SYNC"
grep -qF 'atoll skill v2.' "$HOME/.agents/global-rules.md" || fail 'Atoll block change was not kept in the shared file'
grep -qF 'atoll skill v2.' "$HOME/.codex/AGENTS.md" || fail 'Atoll block change lost from AGENTS.md'
[ ! -d "$HOME/.agents/.global-rules-sync/unsynced" ] || fail 'a block-only change was treated as a hand edit'

# CI notifier re-run appends its block to CLAUDE.md (and updates AGENTS.md): sync takes it and cleans CLAUDE.md.
printf '\n<!-- CI-RUN-NOTIFICATIONS:START -->\n## CI notifications\n\nRead the new CI skill.\n<!-- CI-RUN-NOTIFICATIONS:END -->\n' >> "$HOME/.claude/CLAUDE.md"
bash "$SYNC"
grep -qF 'new CI skill.' "$HOME/.agents/global-rules.md" || fail 'CI block not kept in the shared file'
grep -qF 'new CI skill.' "$HOME/.codex/AGENTS.md" || fail 'CI block not in AGENTS.md'
! grep -q 'CI-RUN-NOTIFICATIONS' "$HOME/.claude/CLAUDE.md" || fail 'CLAUDE.md kept a pasted CI block'
[ "$(grep -c 'CI-RUN-NOTIFICATIONS:START' "$HOME/.agents/global-rules.md")" = 1 ] || fail 'CI block duplicated in the shared file'

# Import line removed (file reset by something else): sync puts it back.
printf 'Claude only line.\n' > "$HOME/.claude/CLAUDE.md"; bash "$SYNC"
grep -qxF '@~/.agents/global-rules.md' "$HOME/.claude/CLAUDE.md" && grep -qx 'Claude only line.' "$HOME/.claude/CLAUDE.md" || fail 'import not restored or Claude-only line lost'

# Codex-only rules: in AGENTS.md only.
printf '## Codex only\nUse codex things.\n' > "$HOME/.agents/codex-only.md"; bash "$SYNC"
grep -qx 'Use codex things.' "$HOME/.codex/AGENTS.md" || fail 'codex-only rule missing from AGENTS.md'
! grep -q 'codex things' "$HOME/.agents/global-rules.md" "$HOME/.claude/CLAUDE.md" || fail 'codex-only rule leaked'

# A hand edit of the generated file is replaced, but a copy is kept.
echo 'hand edit' >> "$HOME/.codex/AGENTS.md"; bash "$SYNC"
! grep -q 'hand edit' "$HOME/.codex/AGENTS.md" || fail 'hand edit not replaced'
grep -rq 'hand edit' "$HOME/.agents/.global-rules-sync/unsynced" || fail 'hand edit not kept'

# A secret-like line stops the sync, changes nothing and is not printed.
before="$(shasum < "$HOME/.codex/AGENTS.md")"
echo 'api_key = zzzz-not-printed-12345' >> "$HOME/.agents/global-rules.md"
rc=0; OUT="$(bash "$SYNC" 2>&1)" || rc=$?
[ "$rc" = 3 ] || fail "secret not refused (rc=$rc)"
case "$OUT" in *zzzz-not-printed*) fail 'sync printed the secret' ;; esac
[ "$(shasum < "$HOME/.codex/AGENTS.md")" = "$before" ] || fail 'AGENTS.md changed despite the secret'
echo ok
