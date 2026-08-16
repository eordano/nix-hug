# shellcheck shell=bash
# shellcheck disable=SC2034  # used by sourcing scripts
VERSION="6.0.0"

declare -A LOG_LEVELS=(
  [TRACE]=0
  [DEBUG]=1
  [INFO]=2
  [OK]=3
  [WARN]=4
  [ERROR]=5
)

CURRENT_LOG_LEVEL="${CURRENT_LOG_LEVEL:-${LOG_LEVEL:-INFO}}"

# shellcheck disable=SC2034  # color vars used by sourcing scripts
if [[ -z "${NIX_HUG_COLORS_INITIALIZED:-}" ]]; then
  RED='' GREEN='' BLUE='' YELLOW='' BOLD='' DIM='' NC=''
  if [[ -t 2 ]]; then
    if command -v tput >/dev/null 2>&1; then
      RED=$(tput setaf 1) GREEN=$(tput setaf 2) BLUE=$(tput setaf 4)
      YELLOW=$(tput setaf 3) BOLD=$(tput bold) DIM=$(tput dim) NC=$(tput sgr0)
    else
      RED=$'\033[0;31m' GREEN=$'\033[0;32m' BLUE=$'\033[0;34m'
      YELLOW=$'\033[0;33m' BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'
    fi
  fi
  export NIX_HUG_COLORS_INITIALIZED=1
fi

export TMPDIR="${TMPDIR:-/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"

NIX_STORE="${NIX_STORE_DIR:-/nix/store}"

extract_store_path() {
  local build_output="$1"
  local store_path
  store_path=$(echo "$build_output" | grep "^${NIX_STORE}/" | tail -1)
  if [[ -z "$store_path" ]]; then
    return 1
  fi
  echo "$store_path"
}

log() {
  local lvl=$1 msg=$2
  shift 2

  local current_level_num=${LOG_LEVELS[$CURRENT_LOG_LEVEL]:-1}
  local msg_level_num=${LOG_LEVELS[$lvl]:-0}

  ((msg_level_num < current_level_num)) && return

  local color=""
  case $lvl in
    DEBUG) color=$DIM ;;
    INFO) color=$BLUE ;;
    OK) color=$GREEN ;;
    WARN) color=$YELLOW ;;
    ERROR) color=$RED ;;
  esac

  printf '%s[%s]%s %b\n' "$color" "$lvl" "$NC" "$msg" >&2
}

require_arg() { [[ -n "${1:-}" && "$1" != -* ]] || {
  error "${2:-option} requires an argument"
  return 1
}; }

debug() { log DEBUG "$*"; }
info() { log INFO "$*"; }
ok() { log OK "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }

check_dependencies() {
  [[ -n "${NIX_HUG_DEPS_CHECKED:-}" ]] && return 0

  local deps=(nix jq curl)
  local missing=()

  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required dependencies: ${missing[*]}"
    exit 1
  fi

  if ! curl -s --connect-timeout 5 --max-time 10 https://huggingface.co/ >/dev/null 2>&1; then
    warn "No internet connectivity to Hugging Face - some operations may fail"
  fi

  export NIX_HUG_DEPS_CHECKED=1
}

sanitize_hf_url() {
  local input_url="$1"
  local original_url="$input_url"

  input_url="${input_url#https://huggingface.co/}"
  input_url="${input_url#http://huggingface.co/}"
  input_url="${input_url#hf:}"

  local forced_type=""
  case "$input_url" in
    hf-datasets:* | datasets/*) forced_type="datasets" ;;
    hf-spaces:* | spaces/*) forced_type="spaces" ;;
    models/*) forced_type="models" ;;
  esac
  input_url="${input_url#hf-datasets:}"
  input_url="${input_url#hf-spaces:}"
  input_url="${input_url#datasets/}"
  input_url="${input_url#spaces/}"
  input_url="${input_url#models/}"

  input_url="${input_url%%/tree/*}"
  input_url="${input_url%%/blob/*}"
  input_url="${input_url%%/resolve/*}"
  input_url="${input_url%%/raw/*}"
  input_url="${input_url%%/commit/*}"
  input_url="${input_url%%/discussions/*}"
  input_url="${input_url%%/settings/*}"

  if [[ ! "$input_url" =~ / ]]; then
    error "Please specify the full repository path (e.g., 'stanfordnlp/imdb' or 'openai/gpt2')"
    return 1
  fi

  if [[ ! "$input_url" =~ ^([^/]+)/([^/]+)$ ]]; then
    error "Invalid repository format: $original_url"
    return 1
  fi

  local org="${BASH_REMATCH[1]}"
  local repo="${BASH_REMATCH[2]}"
  local repo_path="$org/$repo"

  if [[ -n "$forced_type" ]]; then
    debug "Repository type given explicitly: $forced_type"
    echo "$forced_type/$repo_path"
    return 0
  fi

  debug "Checking repository type for: $repo_path"

  local kind http_code
  for kind in datasets models spaces; do
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L \
      "https://huggingface.co/api/$kind/$repo_path" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      debug "Detected as $kind repository"
      echo "$kind/$repo_path"
      return 0
    fi
  done

  if [[ "$original_url" =~ dataset ]]; then
    debug "URL contains 'dataset', assuming dataset repository"
    echo "datasets/$repo_path"
    return 0
  fi

  debug "Could not determine type, defaulting to model repository"
  echo "models/$repo_path"
  return 0
}

format_size() {
  local bytes=$1
  if ((bytes < 1024)); then
    echo "${bytes} B"
  elif ((bytes < 1048576)); then
    echo "$((bytes / 1024)) KB"
  elif ((bytes < 1073741824)); then
    awk "BEGIN { printf \"%.1f MB\", $bytes / 1048576 }"
  else
    awk "BEGIN { printf \"%.1f GB\", $bytes / 1073741824 }"
  fi
}

parse_url() {
  local url="$1"

  if [[ "$url" =~ ^(models|datasets|spaces)/([^/]+)/([^/]+)$ ]]; then
    local type="${BASH_REMATCH[1]}"
    local org="${BASH_REMATCH[2]}"
    local repo="${BASH_REMATCH[3]}"
    echo "{\"type\": \"$type\", \"org\": \"$org\", \"repo\": \"$repo\", \"repoId\": \"$type/$org/$repo\"}"
  else
    error "Invalid sanitized URL format: $url (expected {models|datasets|spaces}/org/repo)"
    return 1
  fi
}

resolve_repo() {
  local url="$1"
  local sanitized_url
  sanitized_url=$(sanitize_hf_url "$url") || return 1
  local parsed
  parsed=$(parse_url "$sanitized_url") || return 1
  _repo_id=$(echo "$parsed" | jq -r '.repoId')
  _repo_type=$(echo "$parsed" | jq -r '.type')
  _bare_repo_path=$(get_bare_repo_path "$_repo_id")
  _display_name=$(get_display_name "$_repo_id")
}

get_display_name() {
  local repo_id="$1"
  if [[ "$repo_id" =~ ^models/(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$repo_id"
  fi
}

get_bare_repo_path() {
  local repo_id="$1"
  if [[ "$repo_id" =~ ^(models|datasets|spaces)/(.*)$ ]]; then
    echo "${BASH_REMATCH[2]}"
  else
    echo "$repo_id"
  fi
}

get_flake_path() {
  if [[ -n "${NIX_HUG_FLAKE_PATH:-}" ]]; then
    echo "$NIX_HUG_FLAKE_PATH"
    return 0
  fi

  local current_dir="$PWD"
  while [[ "$current_dir" != "/" ]]; do
    if [[ -f "$current_dir/flake.nix" ]] && grep -q "nix-hug" "$current_dir/flake.nix" 2>/dev/null; then
      echo "$current_dir"
      return 0
    fi
    current_dir="$(dirname "$current_dir")"
  done

  local script_dir
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [[ -f "$script_dir/flake.nix" ]]; then
      echo "$script_dir"
      return 0
    fi
  fi

  error "Could not locate nix-hug flake.nix. Set NIX_HUG_FLAKE_PATH environment variable."
  return 1
}

resolve_ref() {
  local ref="$1" repo_id="$2"
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$ref"
    return 0
  fi
  local api_url="https://huggingface.co/api/$repo_id/revision/$ref"
  local api_response
  api_response=$(curl -sfL "$api_url") || {
    error "Failed to resolve ref '$ref' for $repo_id"
    return 1
  }
  local resolved
  resolved=$(echo "$api_response" | jq -r '.sha // empty') || true
  if [[ -z "$resolved" ]]; then
    error "Could not resolve ref '$ref' to a commit hash"
    return 1
  fi
  debug "Resolved '$ref' to commit hash: $resolved"
  echo "$resolved"
}

glob_to_regex() {
  printf '%s' "$1" | sed 's/\./\\./g; s/\*/\.\*/g; s/\?/\./g'
}

is_git_url() { [[ "$1" == git+* ]]; }

parse_git_url() {
  local input="$1"
  _git_url="" _git_lfs_url="" _git_ref="" _git_org="" _git_repo=""

  local raw="${input#git+}"

  local base_url="$raw" query_string=""
  if [[ "$raw" == *"?"* ]]; then
    base_url="${raw%%\?*}"
    query_string="${raw#*\?}"
  fi

  base_url="${base_url%.git}"
  _git_url="$base_url"

  if [[ -n "$query_string" ]]; then
    local IFS='&'
    for param in $query_string; do
      local key="${param%%=*}" val="${param#*=}"
      case "$key" in
        lfs-url) _git_lfs_url="$val" ;;
        ref) _git_ref="$val" ;;
      esac
    done
  fi

  local host="" path=""
  if [[ "$base_url" =~ ^[a-z]+://([^@]+@)?([^:/]+)(:[0-9]+)?(/.*)?$ ]]; then
    host="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[4]}"
  fi

  if [[ "$path" =~ /([^/]+)/([^/]+)$ ]]; then
    _git_org="${BASH_REMATCH[1]}"
    _git_repo="${BASH_REMATCH[2]}"
  fi

  if [[ -z "$_git_lfs_url" && -n "$host" && -n "$path" ]]; then
    _git_lfs_url="https://${host}${path}/raw/commit"
  fi

  debug "Parsed git URL: url=$_git_url lfsUrl=$_git_lfs_url ref=$_git_ref org=$_git_org repo=$_git_repo"
}

resolve_git_ref() {
  local ref="$1" url="$2"
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$ref"
    return 0
  fi
  local output stderr_file
  stderr_file=$(mktemp)
  output=$(git ls-remote "$url" "$ref" 2>"$stderr_file") || {
    error "Failed to query $url for ref '$ref'"
    [[ -s "$stderr_file" ]] && error "$(cat "$stderr_file")"
    rm -f "$stderr_file"
    return 1
  }
  rm -f "$stderr_file"
  local resolved
  resolved=$(echo "$output" | awk '{print $1; exit}')
  if [[ -z "$resolved" ]]; then
    error "Could not resolve ref '$ref' from $url"
    return 1
  fi
  debug "Resolved git ref '$ref' to: $resolved"
  echo "$resolved"
}

resolve_hf_cache_dir() {
  if [[ -n "${HF_HUB_CACHE:-}" ]]; then
    echo "$HF_HUB_CACHE"
  elif [[ -n "${HF_HOME:-}" ]]; then
    echo "$HF_HOME/hub"
  else
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/hub"
  fi
}

find_valid_store_path() {
  local store_name="$1"
  local existing
  existing=$(echo /nix/store/*-"$store_name")
  if [[ "$existing" != "/nix/store/*-$store_name" ]] &&
    nix-store --check-validity "$existing" 2>/dev/null; then
    echo "$existing"
    return 0
  fi
  return 1
}

store_has_path() {
  local store_name="$1" match
  for match in /nix/store/*-"$store_name"; do
    [[ "$match" == *.drv ]] && continue
    [[ -e "$match" ]] || continue
    nix-store --check-validity "$match" 2>/dev/null && return 0
  done
  return 1
}

store_lfs_materialised() {
  local path="$1"
  local tree="$path/.nix-hug-filetree.json"
  local n=0 f
  [[ -f "$tree" ]] || {
    echo 0
    return 0
  }
  while IFS= read -r f; do
    [[ -n "$f" && -L "$path/$f" ]] && n=$((n + 1))
  done < <(jq -r '.[] | select(has("lfs")) | .path' "$tree" 2>/dev/null)
  echo "$n"
}

find_store_path_by_repo() {
  local org="$1" repo="$2"
  local type match best="" best_n=-1 count=0 n
  for type in model dataset; do
    for match in /nix/store/*-hf-"${type}"-"${org}"-"${repo}"-*; do
      [[ "$match" == *.drv ]] && continue
      [[ -e "$match" ]] || continue
      nix-store --check-validity "$match" 2>/dev/null || continue
      count=$((count + 1))
      n=$(store_lfs_materialised "$match")
      if ((n > best_n)); then
        best_n="$n"
        best="$match"
      fi
    done
  done

  [[ -z "$best" ]] && return 1
  if ((count > 1)); then
    warn "$count builds of $org/$repo are in the store, one per filter set"
    warn "exporting the most complete: $best_n LFS file(s) materialised"
  fi
  echo "$best"
}

parse_bare_repo() {
  local input="$1"
  _type_hint=""
  _org=""
  _repo=""

  local stripped="$input"
  stripped="${stripped#models/}"
  [[ "$stripped" != "$input" ]] && _type_hint="models"
  input="$stripped"
  stripped="${stripped#datasets/}"
  [[ "$stripped" != "$input" ]] && _type_hint="datasets"

  if [[ ! "$stripped" =~ ^([^/]+)/([^/]+)$ ]]; then
    error "Invalid repository format: $stripped (expected org/repo)"
    return 1
  fi
  _org="${BASH_REMATCH[1]}"
  _repo="${BASH_REMATCH[2]}"
}

init_hf_cache_snapshot() {
  local base_dir="$1" type="$2" org="$3" repo="$4" rev="$5"
  local prefix="models"
  [[ "$type" == "dataset" ]] && prefix="datasets"

  local repo_dir="$base_dir/${prefix}--${org}--${repo}"
  local snapshot_dir="$repo_dir/snapshots/$rev"

  mkdir -p "$repo_dir/refs"
  mkdir -p "$snapshot_dir"
  printf '%s' "$rev" >"$repo_dir/refs/main"

  echo "$snapshot_dir"
}
