#!/usr/bin/env bash
# Codex CLI Generic Agent Installer v0.0.1 (alpha)
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

VERSION="0.0.1"
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
    err "Bash >= 4.0 required. On macOS: brew install bash && /opt/homebrew/bin/bash $0"
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
  local tmp="${file}.tmp.$$"
  if sed "/${start}/,/${end}/d" "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"; return 1
  fi
}

insert_before_end(){
  # Insert contents of $2 before GLOBAL_END in $1
  local rc="$1" ; local block_file="$2"
  local tmp="${rc}.tmp.$$"
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
        c="$(echo "$c" | sed -E 's/1/low/g; s/2/mid/g; s/3/high/g; s/4/low,mid,high/g')"
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
        c="$(echo "$c" | sed -E 's/1/min/g; s/2/low/g; s/3/mid/g; s/4/high/g; s/5/min,low,mid,high/g')"
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
  stderr
  stderr "Paste your profile/behavior markdown."
  stderr "Finish with a line containing only: ${endmark}"
  local buf="" line tries=0
  while true; do
    buf=""
    while IFS= read -r line; do
      [[ "$line" == "$endmark" ]] && break
      buf+="$line"$'\n'
    done
    if [[ -n "$buf" ]]; then
      printf "%s" "$buf"
      return 0
    fi
    tries=$((tries+1))
    if (( tries >= 3 )); then
      err "Profile text was empty after 3 attempts."
      exit 1
    fi
    warn "Empty profile text. Please paste again (attempt ${tries}/3)."
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

  local tmp_block; tmp_block="$(mktemp)"
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
  sed -i'' '/# BEGIN GENERIC CODEX AGENT (/,/# END GENERIC CODEX AGENT (/d' "$rc" || true
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
migrate_global(){
  local rc="$1" ; local rc_tmp="${rc}.work.$$"
  [[ -f "$rc" ]] || { warn "No rc file found at ${rc}"; return 0; }

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

  local list_file blocks_file sed_script
  list_file="$(mktemp)"
  blocks_file="$(mktemp)"
  sed_script="$(mktemp)"

  awk -v gb="$gb" -v ge="$ge" -v ver="$version_regex" -v filt="$filter_pat" '
    BEGIN{ in_block=0; start=0; trig=""; }
    {
      line=$0
      if (match(line, "^# BEGIN GENERIC CODEX AGENT \\(([^)]+)\\) " ver, m)) {
        in_block=1; start=NR; trig=m[1];
      } else if (in_block && match(line, "^# END GENERIC CODEX AGENT \\(" trig "\\)")) {
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
    rm -f "$list_file" "$blocks_file" "$sed_script"
    return 0
  fi

  info "Found the following blocks to migrate:"
  cat "$list_file" | awk '{print " • " $3 "  (lines " $1 "-" $2 ")"}'

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "Dry-run: not modifying ${rc}"
    rm -f "$list_file" "$blocks_file" "$sed_script"
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
    rm -f "$rc_tmp" "$list_file" "$blocks_file" "$sed_script"
    err "Failed during deletion phase."
    return 1
  fi

  insert_before_end "$rc" "$blocks_file"
  ok "Migrated $(wc -l < "$list_file" | xargs) block(s) into GLOBAL wrapper."
  rm -f "$list_file" "$blocks_file" "$sed_script"
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

  local rc ; rc="$(detect_rc)"
  [[ -f "$rc" ]] || touch "$rc"
  backup_rc "$rc"

  # Overwrite/Skip/Delete handling for same trigger
  if grep -q "# BEGIN GENERIC CODEX AGENT (${TRIGGER})" "$rc" 2>/dev/null; then
    local mode
    stderr
    stderr "An agent named '${TRIGGER}' already exists in ${rc}."
    stderr "  [O]verwrite  - Replace the existing block (default)"
    stderr "  [S]kip       - Leave it untouched"
    stderr "  [D]elete+Add - Remove then install fresh"
    read -r -p "Choose [O/S/D, default O]: " mode || true
    case "${mode:-O}" in
      S|s|skip|SKIP) warn "Keeping existing agent '${TRIGGER}'. No changes."; offer_source_now "$rc" "$TRIGGER"; return 0 ;;
      D|d|delete|DELETE|O|o|overwrite|OVERWRITE)
        safe_range_delete "$rc" "# BEGIN GENERIC CODEX AGENT (${TRIGGER})" "# END GENERIC CODEX AGENT (${TRIGGER})" || {
          err "Failed to remove existing block for '${TRIGGER}'"; exit 1; }
      ;;
      *) ;;
    esac
  fi

  # Build agent block
  local tiers_joined="$(IFS=','; echo "${VALID_TIERS[*]}")"
  local block_file ; block_file="$(emit_agent_block "$TRIGGER" "$TYPE" "$MODEL" "$FILE_OPENER" "$WS_EXEC" "$PROFILE_TEXT" "$tiers_joined")"

  # Write either under GLOBAL wrapper or appended to rc
  if [[ "${GROUP_GLOBAL^^}" == "Y" ]]; then
    ensure_global_block "$rc"
    insert_before_end "$rc" "$block_file"
  else
    cat "$block_file" >> "$rc"
  fi

  rm -f "$block_file"
  ok "Installed agent '${TRIGGER}' into ${rc}"
  offer_source_now "$rc" "$TRIGGER"
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

  local rc ; rc="$(detect_rc)"
  [[ -f "$rc" ]] || touch "$rc"
  backup_rc "$rc"

  # Mode for existing trigger
  case "${INSTALL_MODE:-overwrite}" in
    skip|SKIP|s|S) if grep -q "# BEGIN GENERIC CODEX AGENT (${TRIGGER})" "$rc" 2>/dev/null; then warn "Keeping existing agent '${TRIGGER}'"; offer_source_now "$rc" "$TRIGGER"; return 0; fi ;;
    delete|DELETE|d|D|overwrite|OVERWRITE|o|O)
      if grep -q "# BEGIN GENERIC CODEX AGENT (${TRIGGER})" "$rc" 2>/dev/null; then
        safe_range_delete "$rc" "# BEGIN GENERIC CODEX AGENT (${TRIGGER})" "# END GENERIC CODEX AGENT (${TRIGGER})" || true
      fi ;;
    *) ;;
  esac

  local tiers_joined="$(IFS=','; echo "${VALID_TIERS[*]}")"
  local block_file ; block_file="$(emit_agent_block "$TRIGGER" "$TYPE" "$MODEL" "$FILE_OPENER" "$WS_EXEC" "$PROFILE_TEXT" "$tiers_joined")"

  if [[ "${GROUP_GLOBAL^^}" == "Y" ]]; then
    ensure_global_block "$rc"
    insert_before_end "$rc" "$block_file"
  else
    cat "$block_file" >> "$rc"
  fi
  rm -f "$block_file"
  ok "Installed agent '${TRIGGER}' into ${rc}"
  offer_source_now "$rc" "$TRIGGER"
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

main(){
  line
  stderr "Codex CLI Generic Agent Installer v${VERSION} (alpha)"
  line

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
