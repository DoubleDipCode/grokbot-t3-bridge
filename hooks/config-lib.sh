#!/bin/bash
# Shared by install.sh, uninstall.sh and notify.sh. Meant to be sourced, not run.
#
# grokbot_load_config <file>
#   Reads the optional local config file (default ~/.grokbot-hooks/config). It is NOT sourced:
#   each line is parsed as KEY=value and only the keys in GROKBOT_CONFIG_KEYS are accepted, so
#   the file cannot run code. Blank lines and # comments are ignored. Values may be wrapped in
#   single or double quotes; nothing inside is expanded, except a leading ~ or $HOME in the
#   directory keys. A real environment variable (non-empty) always wins over the file.
#
# grokbot_resolve_claude_dirs
#   Fills the array CLAUDE_DIRS with the Claude config dirs to touch and CLAUDE_DIRS_MISSING
#   with explicitly named dirs that do not exist. See the function for the rules.

GROKBOT_CONFIG_KEYS="GROKBOT_CLAUDE_DIRS GROKBOT_EXTRA_CLAUDE_DIRS GROKBOT_STALL_MINUTES GROKBOT_STALE_SECONDS GROKBOT_STATE_DIR"

# Expand a leading ~ or $HOME in each colon-separated entry. Prints the rewritten list.
grokbot__expand_home() {
  local list="$1" part out="" sep="" parts
  IFS=: read -r -a parts <<< "$list"
  # Keep a trailing empty list safe on bash 3.2 (empty array under set -u).
  # shellcheck disable=SC2016,SC2088 # the patterns are literal text, not expansions
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '~'|'~/'*) part="$HOME${part#\~}" ;;
      '$HOME'|'$HOME/'*) part="$HOME${part#\$HOME}" ;;
      '${HOME}'|'${HOME}/'*) part="$HOME${part#\$\{HOME\}}" ;;
    esac
    out="$out$sep$part"
    sep=":"
  done
  printf '%s' "$out"
}

grokbot_load_config() {
  local file="$1" line key value
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"          # leading whitespace
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in 'export '*) line="${line#export }"; line="${line#"${line%%[![:space:]]*}"}" ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"             # trailing whitespace
    case " $GROKBOT_CONFIG_KEYS " in *" $key "*) ;; *) continue ;; esac
    [ -z "${!key:-}" ] || continue                   # environment wins
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
      \"*\") [ "${#value}" -ge 2 ] && value="${value:1:${#value}-2}" ;;
      \'*\') [ "${#value}" -ge 2 ] && value="${value:1:${#value}-2}" ;;
      *)
        value="${value%%[[:space:]]#*}"              # trailing " # comment"
        value="${value%"${value##*[![:space:]]}"}"
        ;;
    esac
    case "$key" in
      GROKBOT_CLAUDE_DIRS|GROKBOT_EXTRA_CLAUDE_DIRS|GROKBOT_STATE_DIR) value="$(grokbot__expand_home "$value")" ;;
    esac
    [ -n "$value" ] || continue
    printf -v "$key" '%s' "$value"
  done < "$file"
  return 0
}

# Which Claude Code config dirs to touch, existing ones only, each once (by physical path):
#   GROKBOT_CLAUDE_DIRS set (env or config): exactly those dirs, colon separated, like PATH.
#   otherwise: ~/.claude, $CLAUDE_CONFIG_DIR, and every ~/.claude-* directory that holds a
#   settings.json. Those auto-detected entries must be real directories (a symlinked
#   ~/.claude-foo is skipped, it would only repeat another dir) and backup-looking names
#   (*.bak*, *.backup*, *.old, *.orig) are skipped.
# GROKBOT_EXTRA_CLAUDE_DIRS (colon separated) is added in both cases.
# Dirs named explicitly (any of the above except the ~/.claude-* scan) are used when they exist,
# even without a settings.json; missing ones are listed in CLAUDE_DIRS_MISSING.
grokbot_resolve_claude_dirs() {
  CLAUDE_DIRS=()
  CLAUDE_DIRS_MISSING=()
  local seen=$'\n' dir real parts p base

  grokbot__add_dir() {   # explicit entry: must exist
    dir="${1%/}"
    [ -n "$dir" ] || return 0
    if [ ! -d "$dir" ]; then
      CLAUDE_DIRS_MISSING+=("$dir")
      return 0
    fi
    real="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 0
    case "$seen" in *$'\n'"$real"$'\n'*) return 0 ;; esac
    seen="$seen$real"$'\n'
    CLAUDE_DIRS+=("$dir")
  }

  if [ -n "${GROKBOT_CLAUDE_DIRS:-}" ]; then
    IFS=: read -r -a parts <<< "$GROKBOT_CLAUDE_DIRS"
    for p in ${parts[@]+"${parts[@]}"}; do grokbot__add_dir "$p"; done
  else
    # ~/.claude and CLAUDE_CONFIG_DIR are the usual defaults: only when they exist, silently.
    [ ! -d "$HOME/.claude" ] || grokbot__add_dir "$HOME/.claude"
    [ -z "${CLAUDE_CONFIG_DIR:-}" ] || grokbot__add_dir "$CLAUDE_CONFIG_DIR"
    for dir in "$HOME"/.claude-*; do
      [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/settings.json" ] || continue
      base="${dir##*/}"
      case "$base" in *.bak*|*.backup*|*.old|*.orig|*~) continue ;; esac
      grokbot__add_dir "$dir"
    done
  fi
  if [ -n "${GROKBOT_EXTRA_CLAUDE_DIRS:-}" ]; then
    IFS=: read -r -a parts <<< "$GROKBOT_EXTRA_CLAUDE_DIRS"
    for p in ${parts[@]+"${parts[@]}"}; do grokbot__add_dir "$p"; done
  fi
  unset -f grokbot__add_dir
  return 0
}
