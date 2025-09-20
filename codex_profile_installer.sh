#!/usr/bin/env bash
# Codex CLI Generic Agent Installer v0.0.2
# Author: ChatGPT
# License: MIT
#
# Adds custom-named Codex CLI agents (Planning/Execution) to your shell rc.
# Features:
#   • Optional GLOBAL wrapper markers for bulk removal
#   • Install interactive and non-interactive
#   • Uninstall single trigger or ALL
#   • Migrate existing per-trigger blocks into GLOBAL wrapper:
#       --migrate-global [--dry-run] [--include-any-version] [--triggers a,b,c]
#
set -euo pipefail

# Robustly manage and clean up temporary files
TMP_FILES=()
cleanup() {
  rm -f "${TMP_FILES[@]}"
}
trap cleanup EXIT

# A wrapper around mktemp that registers the file for cleanup
mktemp_safe() {
  local tmp_file
  tmp_file="$(mktemp)"
  TMP_FILES+=("$tmp_file")
  echo "$tmp_file"
}

_SED_INPLACE_STYLE=""

sed_inplace(){
  if [[ -z "${_SED_INPLACE_STYLE:-}" ]]; then
    if sed --version >/dev/null 2>&1; then
      _SED_INPLACE_STYLE="gnu"
    else
      _SED_INPLACE_STYLE="bsd"
    fi
  fi

  if [[ "$_SED_INPLACE_STYLE" == "bsd" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

VERSION="0.0.2"
USER_TASK_DELIM="========================= USER TASK ========================="
GLOBAL_BEGIN="# BEGIN GENERIC CODEX AGENTS v${VERSION}"
GLOBAL_END="# END GENERIC CODEX AGENTS v${VERSION}"

# ───────────────────────────── Helpers ─────────────────────────────
stderr(){ printf "%s\n" "$*" >&2; }
info(){ stderr "👉 $*"; }
ok(){ stderr "✅ $*"; }
warn(){ stderr "⚠️  $*"; }
err(){ stderr "❌ $*"; }
line(){ stderr "──────────────────────────────────────────────────"; }

require_bash(){
  if [[ -z "${BASH_VERSION:-}" ]]; then
    err "Run with bash:  bash $0"
    exit 1
  fi
  if (( ${BASH_VERSINFO[0]} < 4 )); then
    err "Bash >= 4.0 required. On macOS, install bash via Homebrew (e.g., 'brew install bash') and rerun this script with the newly installed bash (for example: 'bash $0')."
    exit 1
  fi
}

detect_rc(){
  if [[ -n "${ZSH_VERSION-}" ]] || [[ "${SHELL-}" == *"/zsh" ]]; then
    echo "${HOME}/.zshrc"
  else
    [[ -f "${HOME}/.bashrc" ]] && echo "${HOME}/.bashrc" || echo "${HOME}/.bash_profile"
  fi
}

backup_rc(){
  local rc="$1"
  cp "$rc" "${rc}.bak.$(date +%Y%m%d%H%M%S)"
}

safe_range_delete(){
  local file="$1" ; local start="$2" ; local end="$3"

  if ! grep -qE "$start" "$file"; then
    warn "Start marker '${start}' not found in ${file}; nothing to remove."
    return 0
  fi
  if ! grep -qE "$end" "$file"; then
    err "End marker '${end}' missing in ${file}; aborting removal to protect the file."
    return 3
  fi

  local tmp; tmp="$(mktemp_safe)"
  if awk -v s="$start" -v e="$end" '
    $0 ~ s && !in_block { in_block=1; next }
    $0 ~ e && in_block { in_block=0; next }
    !in_block { print }
    END {
      if (in_block) exit 3
    }
  ' "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    local status=$?
    if (( status == 3 )); then
      err "Matched start marker '${start}' but never found '${end}' while editing ${file}; leaving file untouched."
    fi
    return "$status"
  fi
}

insert_before_end(){
  # Insert contents of $2 before GLOBAL_END in $1
  local rc="$1" ; local block_file="$2"
  local tmp; tmp="$(mktemp_safe)"
  awk -v endpat="${GLOBAL_END}" -v block_file="$block_file" '
    $0 ~ endpat {
      while ((getline line < block_file) > 0) {
        print line
      }
      close(block_file)
      print
      next
    }
    { print }
  ' "$rc" > "$tmp"
  mv "$tmp" "$rc"
}

has_global_block(){
  local rc="$1"
  grep -qF "${GLOBAL_BEGIN}" "$rc" && grep -qF "${GLOBAL_END}" "$rc"
}

ensure_global_block(){
  local rc="$1"
  if ! has_global_block "$rc"; then
    {
      echo "${GLOBAL_BEGIN}"
      echo "# (Agents installed by codex_profile_installer v${VERSION} will appear below)"
      echo "${GLOBAL_END}"
    } >> "$rc"
  fi
}

escape_sed_pat(){ echo "$1" | sed 's/[.[\*^$]/\\&/g; s/)/\\)/g; s/(/\\(/g; s/{/\\{/g; s/}/\\}/g; s/|/\\|/g; s/\//\\\//g'; }

detect_awk(){
  if command -v gawk >/dev/null 2>&1; then
    echo "gawk"
    return 0
  fi
  # Check if the system awk supports the 3-argument match()
  if echo "" | awk 'BEGIN{match("a", "b", c)}' >/dev/null 2>&1; then
    echo "awk"
    return 0
  fi
  err "GNU Awk (gawk) not found and system awk is not compatible."
  warn "Please install gawk to use the migration feature (e.g., 'brew install gawk')."
  exit 1
}

# ───────────────────────────── Version Check ─────────────────────────────
check_for_version_mismatch(){
  local rc="$1"
  # This check is not needed if we are already running the migration.
  if [[ ${MODE_MIGRATE:-0} -eq 1 ]]; then
    return 0
  fi
  # Don't run if rc file doesn't exist
  [[ -f "$rc" ]] || return 0

  local found_version
  found_version=$(grep -o -m 1 '# BEGIN GENERIC CODEX AGENTS v[0-9.]*' "$rc" | grep -o 'v[0-9.]*' | tr -d 'v' || true)

  if [[ -n "$found_version" && "$found_version" != "$VERSION" ]]; then
    err "Version Mismatch Detected!"
    line
    warn "This script is version v${VERSION}, but your existing installation is v${found_version}."
    warn "Running install/uninstall with a mismatched version can corrupt your shell configuration."
    line
    info "To upgrade your installation to v${VERSION}, please run the migration command:"
    printf "\n  bash %s --migrate-global --include-any-version\n\n" "$0"

    if [[ ${INTERACTIVE:-1} -eq 0 ]]; then
      if [[ "${AUTO_FORCE_MISMATCH:-0}" != "1" ]]; then
        err "Auto mode aborting due to version mismatch."
        warn "Set AUTO_FORCE_MISMATCH=1 to override this safety check."
        exit 3
      fi
      warn "AUTO_FORCE_MISMATCH=1 detected; continuing despite mismatch."
      return 0
    fi

    local q
    q="$(ask_yes_no "Do you want to abort and run the migration instead?" "Y")"
    if [[ "$q" == "Y" ]]; then
      info "Aborting. Please run the migration command shown above."
      exit 0
    else
      warn "Continuing at your own risk. This may lead to unexpected behavior."
    fi
  fi
}

# ───────────────────────────── Inputs / Flags ─────────────────────────────
INTERACTIVE=1
TRIGGER=""
TYPE=""                # Planning|Execution
MODEL="gpt-5"          # gpt-5 | gpt-5-codex
TIERS=""
FILE_OPENER="vscode"   # vscode|vscode-insiders|windsurf|cursor|none
WS_EXEC="0"
PROFILE_TEXT=""
ENDMARK="$USER_TASK_DELIM"
INSTALL_MODE=""        # overwrite|skip|delete
GROUP_GLOBAL=""        # Y or N

# Uninstall flags
MODE_UNINSTALL=0
UNINSTALL_ALL=0
UNINSTALL_TRIGGER=""

# Migration flags
MODE_MIGRATE=0
DRY_RUN=0
INCLUDE_ANY_VERSION=0
TRIGGERS_FILTER=""   # csv, optional

usage(){
  cat <<EOF
Codex CLI Generic Agent Installer v${VERSION} (alpha)

Install (interactive):
  $0

Install (non-interactive):
  TRIGGER=plan TYPE=Planning MODEL=gpt-5 TIERS=low,mid GROUP_GLOBAL=Y PROFILE_FILE=./kiro.md \\
    $0 --auto --mode overwrite

Uninstall:
  $0 --uninstall --trigger plan
  $0 --uninstall --all

Migrate existing per-trigger blocks into GLOBAL wrapper:
  $0 --migrate-global [--dry-run] [--include-any-version] [--triggers plan,exec]

Flags:
  --auto                      Use environment variables (non-interactive install)
  --mode MODE                 overwrite|skip|delete when a trigger exists
  --uninstall                 Enter uninstall mode (use with --all or --trigger)
  --all                       Remove all generic agents installed by this script
  --trigger NAME              Remove just the agent block for NAME
  --migrate-global            Move loose per-trigger blocks into GLOBAL wrapper
  --dry-run                   With --migrate-global: show actions only
  --include-any-version       With --migrate-global: migrate any version (default: only v${VERSION})
  --triggers CSV              With --migrate-global: only migrate listed triggers (e.g., plan,exec)
  --help                      Show help

Env Vars (install path):
  TRIGGER, TYPE, MODEL, TIERS, FILE_OPENER, WS_EXEC, ENDMARK, PROFILE_FILE, GROUP_GLOBAL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) INTERACTIVE=0; shift ;;
    --mode) INSTALL_MODE="${2:-}"; shift 2 ;;
    --uninstall) MODE_UNINSTALL=1; shift ;;
    --all) UNINSTALL_ALL=1; shift ;;
    --trigger) UNINSTALL_TRIGGER="${2:-}"; shift 2 ;;
    --migrate-global) MODE_MIGRATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --include-any-version) INCLUDE_ANY_VERSION=1; shift ;;
    --triggers) TRIGGERS_FILTER="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

require_bash

ask(){
  local prompt="$1"; local def="${2:-}"; local ans
  read -r -p "$prompt ${def:+[$def]}: " ans || true
  echo "${ans:-$def}"
}

ask_yes_no(){
  local prompt="$1"; local def="${2:-Y}"; local ans
  read -r -p "$prompt [${def}/n]: " ans || true
  ans="${ans:-$def}"
  case "$ans" in Y|y|yes|YES) echo "Y";; *) echo "N";; esac
}

select_model(){
  stderr "Select model:"
  stderr "  1) gpt-5        (min,low,mid,high)"
  stderr "  2) gpt-5-codex  (low,mid,high)"
  local c; read -r -p "Choose [1-2, default 1]: " c || true
  case "${c:-1}" in
    1) echo "gpt-5" ;;
    2) echo "gpt-5-codex" ;;
    *) warn "Unknown, defaulting to gpt-5"; echo "gpt-5" ;;
  esac
}

# Robust tier selection that validates input and reprompts on bad entries
select_tiers(){
  local model="$1"
  local valid_all="min low mid high"
  local valid_codex="low mid high"
  local map_num_gpt5=( "" "min" "low" "mid" "high" "all" )
  local map_num_codex=( "" "" "low" "mid" "high" "all" )

  while true; do
    if [[ "$model" == "gpt-5-codex" ]]; then
      stderr "Install tiers (gpt-5-codex): enter CSV of names or digits: 1=low, 2=mid, 3=high, 4=all"
      read -r -p "Your choice [default: 2]: " c || true
      c="${c:-2}"
      # map digits to names
      if [[ -z "${c//[0-9, ]/}" ]]; then
        local mapped=()
        local invalid=0
        local oifs="$IFS"
        IFS=','
        for num in $c; do
          num="${num//[[:space:]]/}"
          [[ -z "$num" ]] && continue
          case "$num" in
            1) mapped+=("low") ;;
            2) mapped+=("mid") ;;
            3) mapped+=("high") ;;
            4) mapped+=("low" "mid" "high") ;;
            *) invalid=1; break ;;
          esac
        done
        IFS="$oifs"
        if (( invalid == 0 )); then
          c="$(IFS=','; echo "${mapped[*]}")"
        else
          c=""
        fi
      fi
      # normalize CSV
      c="$(echo "$c" | tr '[:upper:]' '[:lower:]' | sed 's/ //g')"
      IFS=',' read -r -a arr <<< "$c"
      # validate
      local out=()
      local ok=1
      for t in "${arr[@]}"; do
        [[ -z "$t" ]] && continue
        if [[ "$t" == "all" ]]; then out=(low mid high); break; fi
        case "$t" in low|mid|high) out+=("$t");; *) ok=0; break;; esac
      done
      if [[ $ok -eq 1 && ${#out[@]} -gt 0 ]]; then
        printf "%s\n" "$(IFS=','; echo "${out[*]}")"
        return 0
      fi
      warn "Invalid tier entry. Try again."
    else
      stderr "Install tiers (gpt-5): enter CSV of names or digits: 1=min, 2=low, 3=mid, 4=high, 5=all"
      read -r -p "Your choice [default: 3]: " c || true
      c="${c:-3}"
      if [[ -z "${c//[0-9, ]/}" ]]; then
        local mapped=()
        local invalid=0
        local oifs="$IFS"
        IFS=','
        for num in $c; do
          num="${num//[[:space:]]/}"
          [[ -z "$num" ]] && continue
          case "$num" in
            1) mapped+=("min") ;;
            2) mapped+=("low") ;;
            3) mapped+=("mid") ;;
            4) mapped+=("high") ;;
            5) mapped+=("min" "low" "mid" "high") ;;
            *) invalid=1; break ;;
          esac
        done
        IFS="$oifs"
        if (( invalid == 0 )); then
          c="$(IFS=','; echo "${mapped[*]}")"
        else
          c=""
        fi
      fi
      c="$(echo "$c" | tr '[:upper:]' '[:lower:]' | sed 's/ //g')"
      IFS=',' read -r -a arr <<< "$c"
      local out=()
      local ok=1
      for t in "${arr[@]}"; do
        [[ -z "$t" ]] && continue
        if [[ "$t" == "all" ]]; then out=(min low mid high); break; fi
        case "$t" in min|low|mid|high) out+=("$t");; *) ok=0; break;; esac
      done
      if [[ $ok -eq 1 && ${#out[@]} -gt 0 ]]; then
        printf "%s\n" "$(IFS=','; echo "${out[*]}")"
        return 0
      fi
      warn "Invalid tier entry. Try again."
    fi
  done
}

select_file_opener(){
  local default_choice="${1:-vscode}"
  local options=("vscode" "vscode-insiders" "windsurf" "cursor" "none")
  local labels=("VS Code" "VS Code Insiders" "Windsurf" "Cursor" "None")
  local default_index=1

  for i in "${!options[@]}"; do
    if [[ "${options[$i]}" == "$default_choice" ]]; then
      default_index=$((i + 1))
      break
    fi
  done

  while true; do
    stderr "Select file opener:"
    for i in "${!options[@]}"; do
      local num=$((i + 1))
      local line="  ${num}) ${options[$i]}"
      if [[ -n "${labels[$i]}" ]]; then
        line+=" (${labels[$i]})"
      fi
      stderr "$line"
    done
    local prompt="Choose [1-${#options[@]}, default ${default_index}: ${options[$((default_index-1))]}]"
    local choice
    read -r -p "$prompt: " choice || true
    choice="${choice:-$default_index}"

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if (( choice >= 1 && choice <= ${#options[@]} )); then
        echo "${options[$((choice-1))]}"
        return 0
      fi
    fi

    choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"
    for opt in "${options[@]}"; do
      if [[ "$choice" == "$opt" ]]; then
        echo "$opt"
        return 0
      fi
    done

    warn "Invalid choice. Please enter a number 1-${#options[@]} or name."
  done
}

read_profile_text(){
  local path="${1:-}" ; local endmark="${2:-__END__}"
  if [[ -n "$path" ]]; then
    [[ -f "$path" ]] || { err "PROFILE_FILE not found: $path"; exit 1; }
    cat "$path"; return 0
  fi

  local clipboard_cmd=()
  if command -v pbpaste >/dev/null 2>&1; then
    clipboard_cmd=(pbpaste)
  elif command -v wl-paste >/dev/null 2>&1; then
    clipboard_cmd=(wl-paste)
  elif command -v xclip >/dev/null 2>&1; then
    clipboard_cmd=(xclip -o)
  fi

  stderr
  stderr "Paste your profile/behavior markdown."
  stderr "Press Ctrl-D on an empty line to finish, or type '${endmark}' if preferred."
  if (( ${#clipboard_cmd[@]} > 0 )); then
    local use_clipboard="" clip_data=""
    read -r -p "Use current clipboard contents? [Y/n]: " use_clipboard || true
    use_clipboard="${use_clipboard:-Y}"
    case "${use_clipboard^^}" in
      Y|YES)
        clip_data="$( "${clipboard_cmd[@]}" 2>/dev/null || true )"
        if [[ -n "${clip_data//[[:space:]]/}" ]]; then
          printf "%s" "$clip_data"
          return 0
        else
          warn "Clipboard was empty or whitespace-only; falling back to manual paste."
        fi
        ;;
    esac
  fi

  local buf="" line tries=0
  while true; do
    buf=""
    local saw_endmark=0
    while IFS= read -r line; do
      if [[ "$line" == "$endmark" ]]; then
        saw_endmark=1
        break
      fi
      buf+="$line"$'\n'
    done || true
    if [[ -n "${buf//[[:space:]]/}" ]]; then
      printf "%s" "$buf"
      return 0
    fi
    if (( saw_endmark == 1 )); then
      warn "No profile text detected before '${endmark}'. Please try again."
    elif [[ -z "$buf" ]]; then
      warn "No profile text detected. Please try again."
    else
      warn "Profile text contained only whitespace. Please try again."
    fi
    tries=$((tries+1))
    if (( tries >= 3 )); then
      err "Profile text was empty after 3 attempts."
      exit 1
    fi
    warn "Paste again or press Ctrl-D when done (attempt ${tries}/3)."
  done
}

validate_trigger(){
  local t="$1"
  [[ -n "$t" ]] || { err "Empty trigger"; return 1; }
  [[ "$t" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { err "Invalid trigger '$t'"; return 1; }
}

validate_type(){
  case "$1" in Planning|Execution) return 0 ;; *) err "TYPE must be Planning or Execution"; return 1 ;; esac
}

validate_model(){
  case "$1" in gpt-5|gpt-5-codex) return 0 ;; *) err "MODEL must be gpt-5 or gpt-5-codex"; return 1 ;; esac
}

validate_tiers(){
  local model="$1" tiers_csv="$2"
  IFS=',' read -r -a tiers <<< "$tiers_csv"
  local out=()
  for t in "${tiers[@]}"; do
    t="$(echo "$t" | xargs)"; [[ -z "$t" ]] && continue
    if [[ "$model" == "gpt-5-codex" ]]; then
      case "$t" in low|mid|high) out+=("$t") ;; min) warn "Ignoring 'min' (unsupported)";; *) warn "Unknown tier '$t'";; esac
    else
      case "$t" in min|low|mid|high) out+=("$t") ;; *) warn "Unknown tier '$t'";; esac
    fi
  done
  [[ ${#out[@]} -gt 0 ]] || out=("mid")
  printf "%s\n" "${out[@]}"
}

# ───────────────────────────── Emit block ─────────────────────────────
emit_agent_block(){
  local trigger="$1" type="$2" model="$3" opener="$4" ws_exec="$5" profile_text="$6" tiers_csv="$7"

  declare -A RZ=([min]="minimal" [low]="low" [mid]="medium" [high]="high")

  IFS=',' read -r -a tiers <<< "$tiers_csv"
  local default_tier="mid" have_mid=0
  for t in "${tiers[@]}"; do [[ "$t" == "mid" ]] && have_mid=1; done
  [[ $have_mid -eq 1 ]] || default_tier="${tiers[0]}"

  local sandbox ask verbosity_planning="low" verbosity_exec="medium" ws_planning="true" ws_execution_default="false"
  [[ "$ws_exec" == "1" ]] && ws_execution_default="true"
  if [[ "$type" == "Planning" ]]; then sandbox="read-only"; ask="untrusted"; else sandbox="workspace-write"; ask="on-request"; fi

  local tmp_block; tmp_block="$(mktemp_safe)"
  {
cat <<EOF
# BEGIN GENERIC CODEX AGENT (${trigger}) v${VERSION}
# Generated: $(date)
# Trigger: ${trigger}
# Type: ${type}
# Model: ${model}
# Tiers: ${tiers[*]}
# Default opener: ${opener}
# Web Search: Planning=ON, Execution=${ws_execution_default}
# Delimiter: ${USER_TASK_DELIM}

# default alias -> chosen default tier
${trigger}() { ${trigger}-${default_tier} "\$@"; }

# track installed agents (space-separated list of triggers)
export CODEX_GENERIC_AGENTS="\${CODEX_GENERIC_AGENTS:-} ${trigger}"

# helper prints only the generic agents installed by this script
if ! type codex-generic-status >/dev/null 2>&1; then
codex-generic-status() {
  echo "📂 Installed Codex agents (generic):"
  for a in \$CODEX_GENERIC_AGENTS; do
    [[ -z "\$a" ]] && continue
    if type "\$a" >/dev/null 2>&1; then
      echo " • \$a (active in this shell)"
    else
      echo " • \$a (inactive here — run 'source <your shell rc>')"
    fi
  done
}
fi

# fall back to generic helper when codex-status is unused elsewhere
if ! type codex-status >/dev/null 2>&1; then
codex-status(){ codex-generic-status "$@"; }
fi
EOF

for tier in "${tiers[@]}"; do
  local rz="${RZ[$tier]}"
  local ws_bool verbosity
  if [[ "$type" == "Planning" ]]; then ws_bool="$ws_planning"; verbosity="$verbosity_planning"; else ws_bool="$ws_execution_default"; verbosity="$verbosity_exec"; fi

cat <<'EOF'
__PROFILE__=$(
cat <<'__CODEX_PROFILE__'
EOF
printf "%s\n" "$profile_text"
cat <<'EOF'
__CODEX_PROFILE__
)

EOF

cat <<EOF
${trigger}-${tier}() {
    if command -v codex >/dev/null 2>&1; then
        local __FO="\${CODEX_FILE_OPENER:-${opener}}"
        local __WS="${ws_bool}"
        local __PROMPT="\${__PROFILE__}

${USER_TASK_DELIM}

USER TASK: \$@"
        codex \\
            --sandbox ${sandbox} \\
            --ask-for-approval ${ask} \\
            --model "${model}" \\
            --config model_reasoning_effort=${rz} \\
            --config model_verbosity=${verbosity} \\
            --config "file_opener=\${__FO}" \\
            --config "tools.web_search=\${__WS}" \\
            "\${__PROMPT}" || return \$?
    else
        echo "❌ Codex CLI not available"; return 127
    fi
}
EOF
done

echo "# END GENERIC CODEX AGENT (${trigger})"
  } > "$tmp_block"

  echo "$tmp_block"
}

# ───────────────────────────── Uninstall logic ─────────────────────────────
uninstall_all(){
  local rc="$1"
  backup_rc "$rc"
  if has_global_block "$rc"; then
    safe_range_delete "$rc" "$(escape_sed_pat "$GLOBAL_BEGIN")" "$(escape_sed_pat "$GLOBAL_END")" || true
  fi
  # remove any stray per-trigger blocks
  local tmp_rc; tmp_rc="$(mktemp_safe)"
  if sed '/# BEGIN GENERIC CODEX AGENT (/,/# END GENERIC CODEX AGENT (/d' "$rc" > "$tmp_rc"; then
    mv "$tmp_rc" "$rc"
  else
    return 1
  fi || true
  ok "Removed all generic codex agents from ${rc}"
}

uninstall_trigger(){
  local rc="$1" trigger="$2"
  backup_rc "$rc"
  local begin="# BEGIN GENERIC CODEX AGENT (${trigger})"
  local end="# END GENERIC CODEX AGENT (${trigger})"
  safe_range_delete "$rc" "$(escape_sed_pat "$begin")" "$(escape_sed_pat "$end")" || {
    warn "No block found for trigger '${trigger}'"
  }
  ok "Removed agent '${trigger}' from ${rc}"
}

# ───────────────────────────── Migration logic ─────────────────────────────

bump_all_versions_in_rc(){
  local rc="$1"
  local VERSION_RE="v[0-9][0-9.]*"

  # Update GLOBAL wrapper versions to the current script VERSION
  # BEGIN / END lines
  if [[ -f "$rc" ]]; then
    # Use portable sed helper for in-place updates
    sed_inplace -e "s/# BEGIN GENERIC CODEX AGENTS ${VERSION_RE}/# BEGIN GENERIC CODEX AGENTS v${VERSION}/g" "$rc" 2>/dev/null || true
    sed_inplace -e "s/# END GENERIC CODEX AGENTS ${VERSION_RE}/# END GENERIC CODEX AGENTS v${VERSION}/g"   "$rc" 2>/dev/null || true
    # Per-trigger BEGIN lines
    # Use perl for robust regex group replacement
    perl -pi -e "s/(# BEGIN GENERIC CODEX AGENT \\([^)]+\\) )${VERSION_RE}/\\1v${VERSION}/" "$rc" 2>/dev/null || true
  fi
}

detect_mixed_versions_and_offer_full_uninstall(){
  local rc="$1"
  [[ ! -f "$rc" ]] && return 0

  # Collect distinct versions in GLOBAL wrappers
  local versions
  versions=$(grep -E '^[[:space:]]*# BEGIN GENERIC CODEX AGENTS v[0-9.]+' "$rc" | sed -E 's/.* (v[0-9.]+)$/\1/' | sort -u || true)

  # Count how many distinct versions we found
  local count
  count=$(printf "%s\n" "$versions" | grep -c . || true)

  if [[ "$count" -gt 1 ]]; then
    echo "⚠️  Detected multiple GENERIC CODEX AGENTS versions in $rc:"
    printf '   • %s\n' $versions
    echo "This can lead to confusing state. You can:"
    echo "  1) Full uninstall (remove ALL generic agent blocks), then reinstall cleanly"
    echo "  2) Skip (not recommended)"
    read -r -p "Proceed with FULL UNINSTALL now? [y/N]: " ans
    case "${ans:-N}" in
      y|Y)
        purge_all_generic_blocks "$rc" || {
          echo "❌ Failed to purge generic blocks from $rc"
          return 1
        }
        echo "✅ Removed all GENERIC CODEX AGENTS blocks from $rc."
        echo "   Open a new shell or run: source \"$rc\""
        return 2  # signal: we already handled cleanup; caller should stop further actions
        ;;
      *)
        echo "👉 Skipping full uninstall."
        ;;
    esac
  fi
  return 0
}

purge_all_generic_blocks(){
  local rc="$1"
  [[ ! -f "$rc" ]] && return 0
  local tmp
  tmp="$(mktemp_safe)"
  # Remove ANY ranges between BEGIN/END GENERIC CODEX AGENTS (any version)
  awk '
    BEGIN{skip=0}
    /^[[:space:]]*# BEGIN GENERIC CODEX AGENTS v[0-9.]+[[:space:]]*$/ {skip=1; next}
    /^[[:space:]]*# END GENERIC CODEX AGENTS v[0-9.]+[[:space:]]*$/   {skip=0; next}
    skip==0 {print}
  ' "$rc" > "$tmp"
  mv "$tmp" "$rc"
}

has_generic_blocks(){
  local rc="$1"
  [[ ! -f "$rc" ]] && return 1
  grep -qE '^[[:space:]]*# BEGIN GENERIC CODEX AGENTS v[0-9.]+' "$rc"
}

interactive_first_install(){
  local rc="$1"
  echo "ℹ️  No existing GENERIC agents found in $rc."
  echo "🧙  Launching interactive first-time installer..."
  echo

  # Prompt basics
  local trigger type model tiers opener ws
  read -r -p "Trigger name [mdexpert]: " trigger; trigger="${trigger:-mdexpert}"
  read -r -p "Agent type (Planning/Execution) [Execution]: " type; type="${type:-Execution}"
  read -r -p "Model [gpt-5-codex]: " model; model="${model:-gpt-5-codex}"
  read -r -p "Tiers (comma-separated) [mid]: " tiers; tiers="${tiers:-mid}"
  read -r -p "Default file opener [vscode-insiders]: " opener; opener="${opener:-vscode-insiders}"
  read -r -p "Enable web search? (true/false) [true]: " ws; ws="${ws:-true}"

  # Prepare wrapper if not present
  if ! grep -qE '^[[:space:]]*# BEGIN GENERIC CODEX AGENTS v[0-9.]+' "$rc"; then
    {
      echo "# BEGIN GENERIC CODEX AGENTS v${VERSION}"
      echo "# (Agents installed by codex_profile_installer v${VERSION} will appear below)"
    } >> "$rc"
  fi

  # Compose profile payload (minimal – user can edit later)
  local now; now="$(date)"
  {
    echo "# BEGIN GENERIC CODEX AGENT (${trigger}) v${VERSION}"
    echo "# Generated: ${now}"
    echo "# Trigger: ${trigger}"
    echo "# Type: ${type}"
    echo "# Model: ${model}"
    echo "# Tiers: ${tiers}"
    echo "# Default opener: ${opener}"
    echo "# Web Search: Planning=ON, Execution=${ws}"
    echo "# Delimiter: ========================= USER TASK ========================="
    echo
    echo "# default alias -> chosen default tier"
    echo "${trigger}() { ${trigger}-$(echo \"$tiers\" | awk -F, '{print $1}') \"\$@\"; }"
    echo
    echo "# track installed agents (space-separated list of triggers)"
    echo "export CODEX_GENERIC_AGENTS=\"\${CODEX_GENERIC_AGENTS:-} ${trigger}\""
    echo
    echo "# helper prints only the generic agents installed by this script"
    echo "if ! type codex-generic-status >/dev/null 2>&1; then"
    echo "codex-generic-status() {"
    echo "  echo \"📂 Installed Codex agents (generic):\""
    echo "  for a in \$CODEX_GENERIC_AGENTS; do"
    echo "    [[ -z \"\$a\" ]] && continue"
    echo "    if type \"\$a\" >/dev/null 2>&1; then"
    echo "      echo \" • \$a (active in this shell)\""
    echo "    else"
    echo "      echo \" • \$a (inactive here — run 'source <your shell rc>')\""
    echo "    fi"
    echo "  done"
    echo "}"
    echo "fi"
    echo
    echo "# fall back to generic helper when codex-status is unused elsewhere"
    echo "if ! type codex-status >/dev/null 2>&1; then"
    echo "codex-status(){ codex-generic-status; }"
    echo "fi"
    echo
    echo "__PROFILE__=\$("
    echo "cat <<'__CODEX_PROFILE__'"
    echo "# ${trigger} profile (starter)"
    echo
    echo "You can customize this embedded profile text later inside your rc."
    echo "__CODEX_PROFILE__"
    echo ")"
    echo
    echo "${trigger}-$(echo \"$tiers\" | awk -F, '{print $1}')() {"
    echo "    if command -v codex >/dev/null 2>&1; then"
    echo "        local __FO=\"\${CODEX_FILE_OPENER:-${opener}}\""
    echo "        local __WS=\"${ws}\""
    echo "        local __PROMPT=\"\${__PROFILE__}"
    echo
    echo "========================= USER TASK ========================="
    echo
    echo "USER TASK: \$@\""
    echo "        codex \\"
    echo "            --sandbox $( [[ \"$type\" == \"Planning\" ]] && echo 'read-only' || echo 'workspace-write' ) \\"
    echo "            --ask-for-approval $( [[ \"$type\" == \"Planning\" ]] && echo 'untrusted' || echo 'on-request' ) \\"
    echo "            --model \"${model}\" \\"
    echo "            --config model_reasoning_effort=medium \\"
    echo "            --config model_verbosity=medium \\"
    echo "            --config \"file_opener=\${__FO}\" \\"
    echo "            --config \"tools.web_search=\${__WS}\" \\"
    echo "            \"\${__PROMPT}\" || return \$?"
    echo "    else"
    echo "        echo \"❌ Codex CLI not available\"; return 127"
    echo "    fi"
    echo "}"
    echo "# END GENERIC CODEX AGENT (${trigger})"
  } >> "$rc"

  # Ensure we close the GLOBAL wrapper once
  if ! grep -qE '^[[:space:]]*# END GENERIC CODEX AGENTS v[0-9.]+' "$rc"; then
    echo "# END GENERIC CODEX AGENTS v${VERSION}" >> "$rc"
  fi

  echo
  echo "✅ Installed '${trigger}' under GENERIC v${VERSION}."
  echo "   Reload with: source \"$rc\""
}

migrate_global(){
  local rc="$1" ; local rc_tmp; rc_tmp="$(mktemp_safe)"
  detect_mixed_versions_and_offer_full_uninstall "$rc"; case $? in 2) return 0;; esac
  if [[ ${INCLUDE_ANY_VERSION:-0} -eq 1 ]]; then bump_all_versions_in_rc "$rc"; fi
  [[ -f "$rc" ]] || { warn "No rc file found at ${rc}"; return 0; }

  local awk_cmd; awk_cmd="$(detect_awk)"

  ensure_global_block "$rc"

  local gb ge
  gb=$(grep -n -F "$GLOBAL_BEGIN" "$rc" | head -n1 | cut -d: -f1 || true)
  ge=$(grep -n -F "$GLOBAL_END" "$rc" | head -n1 | cut -d: -f1 || true)
  if [[ -z "$gb" || -z "$ge" ]]; then
    err "Failed to locate global wrapper after ensuring it."; return 1
  fi

  local ver_pat="v${VERSION}"
  local any_ver_pat='v[0-9][0-9.]*'
  local version_regex="$ver_pat"
  [[ $INCLUDE_ANY_VERSION -eq 1 ]] && version_regex="$any_ver_pat"

  local filter_pat=""
  if [[ -n "$TRIGGERS_FILTER" ]]; then
    local csv="$TRIGGERS_FILTER"
    csv="$(echo "$csv" | sed 's/ //g')"
    filter_pat="("$(echo "$csv" | sed 's/,/|/g')")"
  fi

  local begin_pat end_pat_prefix list_file blocks_file sed_script
  begin_pat="^# BEGIN GENERIC CODEX AGENT [(]([^)]+)[)] ${version_regex}"
  end_pat_prefix="^# END GENERIC CODEX AGENT [(]"
  list_file="$(mktemp_safe)"
  blocks_file="$(mktemp_safe)"
  sed_script="$(mktemp_safe)"

  "$awk_cmd" -v gb="$gb" -v ge="$ge" -v pat_begin="$begin_pat" -v pat_end_prefix="$end_pat_prefix" -v filt="$filter_pat" '
    BEGIN{ in_block=0; start=0; trig=""; }
    {
      line=$0
      if (match(line, pat_begin, m)) {
        in_block=1; start=NR; trig=m[1];
      } else if (in_block && match(line, pat_end_prefix trig "\\)")) {
        end=NR;
        if (!(start>gb && end<ge)) {
          if (filt=="" || trig ~ filt) {
            printf("%d %d %s\n", start, end, trig);
          }
        }
        in_block=0; start=0; trig="";
      }
    }
  ' "$rc" > "$list_file"

  if [[ ! -s "$list_file" ]]; then
    ok "No per-trigger blocks found outside GLOBAL to migrate."
    return 0
  fi

  info "Found the following blocks to migrate:"
  cat "$list_file" | awk '{print " • " $3 "  (lines " $1 "-" $2 ")"}'

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: not modifying ${rc}"
    return 0
  fi

  backup_rc "$rc"

  while read -r s e trig; do
    sed -n "${s},${e}p" "$rc" >> "$blocks_file"
    echo "${s},${e}d" >> "$sed_script"
  done < "$list_file"

  if sed -f "$sed_script" "$rc" > "$rc_tmp"; then
    mv "$rc_tmp" "$rc"
  else
    err "Failed during deletion phase."
    return 1
  fi

  insert_before_end "$rc" "$blocks_file"
  ok "Migrated $(wc -l < "$list_file" | xargs) block(s) into GLOBAL wrapper."
}

# ───────────────────────────── Post-install helper ─────────────────────────────
offer_source_now(){
  local rc="$1" trigger="$2"
  stderr
  if [[ $INTERACTIVE -eq 1 ]]; then
    local q; q="$(ask_yes_no "Run a quick subshell check? (does not affect your current shell)" "Y")"
    if [[ "$q" == "Y" ]]; then
      # We cannot alter the parent shell; run a login-like subshell and report basic checks.
      local sh="${SHELL:-/bin/bash}"
      echo "──────────────── subshell output ────────────────"
      "$sh" -lc "source '${rc}' >/dev/null 2>&1 || true;
        if type ${trigger} >/dev/null 2>&1; then
          echo '✅ Subshell: ${trigger} is available'
        else
          echo '❌ Subshell: ${trigger} NOT found'
        fi;
        if type codex-generic-status >/dev/null 2>&1; then
          echo '📋 Subshell codex-generic-status:';
          codex-generic-status
        elif type codex-status >/dev/null 2>&1; then
          echo '📋 Subshell codex-status:';
          codex-status
        else
          echo 'No codex status helper found in subshell'
        fi"
      echo "──────────────── end subshell output ────────────"
      warn "Subshell check finished. To activate the agent *here*, run:  source '${rc}'"
    else
      info "Reminder: run this to enable your new commands in the current shell:"
      echo "source '${rc}'"
    fi
  else
    info "To enable in your current shell, run:  source '${rc}'"
  fi
}

# ───────────────────────────── Main (install / uninstall / migrate) ─────────────────────────────

_install_agent(){
  local trigger="$1" type="$2" model="$3" opener="$4" ws_exec="$5" profile_text="$6" tiers_csv="$7" group_global="$8" install_mode="$9"

  [[ -n "$profile_text" ]] || { err "Empty profile/behavior text"; return 1; }

  local rc ; rc="$(detect_rc)"
  [[ -f "$rc" ]] || touch "$rc"

  # If the mode is 'skip' and the agent exists, do nothing.
  if [[ "${install_mode:-overwrite}" =~ ^(s|S|skip|SKIP)$ ]] && grep -q "# BEGIN GENERIC CODEX AGENT (${trigger})" "$rc" 2>/dev/null; then
    warn "Keeping existing agent '${trigger}'. No changes."
    offer_source_now "$rc" "$trigger"
    return 0
  fi

  # If we proceed, we are definitely installing. Backup once.
  backup_rc "$rc"

  # If it exists, remove it. We already handled the 'skip' case.
  if grep -q "# BEGIN GENERIC CODEX AGENT (${trigger})" "$rc" 2>/dev/null; then
      safe_range_delete "$rc" "# BEGIN GENERIC CODEX AGENT (${trigger})" "# END GENERIC CODEX AGENT (${trigger})" || {
        err "Failed to remove existing block for '${trigger}'"; return 1; }
  fi

  local block_file ; block_file="$(emit_agent_block "$trigger" "$type" "$model" "$opener" "$ws_exec" "$profile_text" "$tiers_csv")"

  if [[ "${group_global^^}" == "Y" ]]; then
    ensure_global_block "$rc"
    insert_before_end "$rc" "$block_file"
  else
    cat "$block_file" >> "$rc"
  fi
  ok "Installed agent '${trigger}' into ${rc}"
  offer_source_now "$rc" "$trigger"
}

install_interactive(){
  local default_file_opener
  default_file_opener="${CODEX_FILE_OPENER:-$FILE_OPENER}"
  local TRIGGER TYPE MODEL TIERS FILE_OPENER WS_EXEC GROUP_GLOBAL ENDMARK PROFILE_TEXT
  TRIGGER="$(ask 'Enter trigger command (e.g., kiro, plan, exec)')"
  stderr "Select agent type:"
  stderr "  1) Planning"
  stderr "  2) Execution"
  local type_choice; read -r -p "Choose [1-2, default 1]: " type_choice || true
  case "${type_choice:-1}" in
    1|planning|PLAN|Planning) TYPE="Planning" ;;
    2|execution|EXEC|Execution) TYPE="Execution" ;;
    *) warn "Unknown choice, defaulting to Planning"; TYPE="Planning" ;;
  esac
  MODEL="$(select_model)"
  TIERS="$(select_tiers "$MODEL")"
  FILE_OPENER="$(select_file_opener "$default_file_opener")"
  if [[ "$TYPE" == "Execution" ]]; then
    q="$(ask_yes_no 'Default ENABLE web search for Execution agent?' 'N')" ; [[ "$q" == "Y" ]] && WS_EXEC=1 || WS_EXEC=0
  fi
  GROUP_GLOBAL="$(ask_yes_no 'Group this agent under a GLOBAL wrapper for bulk removal?' 'Y')"
  ENDMARK="$USER_TASK_DELIM"
  PROFILE_TEXT="$(read_profile_text "" "$ENDMARK")"

  # Validate
  validate_trigger "$TRIGGER" || exit 1
  validate_type "$TYPE" || exit 1
  validate_model "$MODEL" || exit 1
  mapfile -t VALID_TIERS < <(validate_tiers "$MODEL" "$TIERS") || true
  [[ ${#VALID_TIERS[@]} -gt 0 ]] || VALID_TIERS=("mid")

  local install_mode="overwrite"
  local rc_path_for_check ; rc_path_for_check="$(detect_rc)"
  if grep -q "# BEGIN GENERIC CODEX AGENT (${TRIGGER})" "$rc_path_for_check" 2>/dev/null; then
    local mode
    stderr
    stderr "An agent named '${TRIGGER}' already exists in ${rc_path_for_check}."
    stderr "  [O]verwrite  - Replace the existing block (default)"
    stderr "  [S]kip       - Leave it untouched"
    read -r -p "Choose [O/S, default O]: " mode || true
    case "${mode:-O}" in
      S|s|skip|SKIP) install_mode="skip" ;;
      *) install_mode="overwrite" ;;
    esac
  fi

  local tiers_joined="$(IFS=','; echo "${VALID_TIERS[*]}")"
  _install_agent "$TRIGGER" "$TYPE" "$MODEL" "$FILE_OPENER" "$WS_EXEC" "$PROFILE_TEXT" "$tiers_joined" "$GROUP_GLOBAL" "$install_mode"
}

install_auto(){
  TRIGGER="${TRIGGER:?TRIGGER required}"
  TYPE="${TYPE:?TYPE required}"
  MODEL="${MODEL:-gpt-5}"
  TIERS="${TIERS:-mid}"
  FILE_OPENER="${FILE_OPENER:-vscode}"
  WS_EXEC="${WS_EXEC:-0}"
  ENDMARK="${ENDMARK:-__END__}"
  GROUP_GLOBAL="${GROUP_GLOBAL:-N}"
  [[ -n "${PROFILE_FILE:-}" ]] || { err "PROFILE_FILE required in --auto mode"; exit 2; }
  PROFILE_TEXT="$(read_profile_text "$PROFILE_FILE" "$ENDMARK")"

  # Validate
  validate_trigger "$TRIGGER" || exit 1
  validate_type "$TYPE" || exit 1
  validate_model "$MODEL" || exit 1
  mapfile -t VALID_TIERS < <(validate_tiers "$MODEL" "$TIERS")
  [[ ${#VALID_TIERS[@]} -gt 0 ]] || VALID_TIERS=("mid")
  [[ -n "$PROFILE_TEXT" ]] || { err "Empty profile/behavior text"; exit 1; }

  local tiers_joined="$(IFS=','; echo "${VALID_TIERS[*]}")"
  _install_agent "$TRIGGER" "$TYPE" "$MODEL" "$FILE_OPENER" "$WS_EXEC" "$PROFILE_TEXT" "$tiers_joined" "$GROUP_GLOBAL" "${INSTALL_MODE:-overwrite}"
}

main_uninstall(){
  local rc ; rc="$(detect_rc)"
  [[ -f "$rc" ]] || { warn "No rc file found at ${rc}"; return 0; }
  if [[ $UNINSTALL_ALL -eq 1 ]]; then
    uninstall_all "$rc"
  elif [[ -n "$UNINSTALL_TRIGGER" ]]; then
    uninstall_trigger "$rc" "$UNINSTALL_TRIGGER"
  else
    line
    stderr "Uninstall options:"
    stderr "  1) Remove ALL generic agents"
    stderr "  2) Remove a single trigger"
    read -r -p "Choose [1-2]: " c || true
    case "${c:-1}" in
      1) uninstall_all "$rc" ;;
      2) read -r -p "Enter trigger name: " t || true
         [[ -n "$t" ]] && uninstall_trigger "$rc" "$t" || err "No trigger provided";;
      *) err "Unknown option"; exit 2 ;;
    esac
  fi
}

main_migrate(){
  local rc ; rc="$(detect_rc)"
  [[ -f "$rc" ]] || { warn "No rc file found at ${rc}"; return 0; }
  migrate_global "$rc"
}

FORCE_FIRST_INSTALL=0

main(){
  for arg in "$@"; do
    case "$arg" in
      --force-first-install)
        FORCE_FIRST_INSTALL=1
        ;;
    esac
  done


  line
  stderr "Codex CLI Generic Agent Installer v${VERSION} (alpha)"
  line

  # Detect rc file early for version check, then proceed with main logic.
  local rc; rc="$(detect_rc)"
  check_for_version_mismatch "$rc"
  detect_mixed_versions_and_offer_full_uninstall "$rc"; case $? in 2) return 0;; esac

  if [[ $MODE_UNINSTALL -eq 1 ]]; then
    main_uninstall
  elif [[ $MODE_MIGRATE -eq 1 ]]; then
    main_migrate
  else
    if [[ $INTERACTIVE -eq 1 && "$#" -eq 0 ]]; then
      install_interactive
    else
      install_auto
    fi
  fi
}

main "$@"
