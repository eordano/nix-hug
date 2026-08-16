# shellcheck shell=bash
# shellcheck source=/dev/null
source "${NIX_HUG_LIB_DIR}/nix-expr.sh"

show_help() {
  cat <<EOF
${BOLD}nix-hug${NC} - Declarative Hugging Face model management for Nix

${BOLD}USAGE:${NC}
    nix-hug [OPTIONS] <COMMAND> [ARGS]

${BOLD}COMMANDS:${NC}
    fetch           Download model, dataset or space; print a Nix expression
    ls              List repository contents without downloading
    export          Export model/dataset from Nix store to HF cache
    import          Import model/dataset from HF cache to Nix store
    import-all      Import all cached models/datasets into Nix store
    scan            Scan local HuggingFace cache for downloaded models

${BOLD}OPTIONS:${NC}
    --debug     Show detailed execution steps
    --version   Show version information
    --help      Show this help message

${BOLD}EXAMPLES:${NC}
    nix-hug fetch openai-community/gpt2 --include '*.safetensors'
    nix-hug fetch git+ssh://codeberg.org/org/model
    nix-hug ls openai-community/gpt2 --exclude '*.bin'
    nix-hug export openai-community/gpt2
    nix-hug import mistralai/Mistral-7B
    nix-hug import-all -y

Run 'nix-hug <command> --help' for command-specific options.
For more information, visit: https://github.com/eordano/nix-hug
EOF
}

show_fetch_help() {
  cat <<EOF
${BOLD}nix-hug fetch${NC} <URL> [OPTIONS]

Downloads a model, dataset or space and generates a pinned Nix expression.
Prefix a path with datasets/ or spaces/ to skip repository-type detection.

${BOLD}OPTIONS:${NC}
    --ref REF           Git reference (default: main)
    --lfs-url URL       LFS download URL prefix (for git+ URLs)
    --include PATTERN   Include LFS files matching glob
    --exclude PATTERN   Exclude LFS files matching glob
    --file FILENAME     Include specific file by name
    --vendor DIR        Write the file tree (or, for git+ URLs, the LFS
                        pointer list) to DIR and emit an expression that
                        evaluates without network access and reports a
                        stale hash in SRI format
    --dry-run           Show what would be fetched
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug fetch openai-community/gpt2 --include '*.safetensors'
    nix-hug fetch openai-community/gpt2 --dry-run
    nix-hug fetch openai-community/gpt2 --vendor ./trees
    nix-hug fetch git+ssh://codeberg.org/org/model
    nix-hug fetch git+https://codeberg.org/org/repo
    nix-hug fetch git+https://codeberg.org/org/repo --vendor ./trees
EOF
}

show_ls_help() {
  cat <<EOF
${BOLD}nix-hug ls${NC} <URL> [OPTIONS]

Lists files in a Hugging Face repository without downloading.

${BOLD}OPTIONS:${NC}
    --ref REF           Git reference (default: main)
    --include PATTERN   Include LFS files matching glob
    --exclude PATTERN   Exclude LFS files matching glob
    --file FILENAME     Show specific file by name
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug ls openai-community/gpt2 --exclude '*.bin'
    nix-hug ls google-bert/bert-base-uncased --file config.json
EOF
}

show_export_help() {
  cat <<EOF
${BOLD}nix-hug export${NC} <URL> [OPTIONS]

Fetches a model/dataset and copies it into the local HuggingFace cache directory.
This makes the model available to transformers, diffusers, and other HF libraries.
Respects \$HF_HUB_CACHE, \$HF_HOME, and \$XDG_CACHE_HOME env vars.

${BOLD}OPTIONS:${NC}
    --ref REF           Git reference (default: main)
    --include PATTERN   Include files matching glob
    --exclude PATTERN   Exclude files matching glob
    --file FILENAME     Include specific file by name
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug export openai-community/gpt2
    nix-hug export openai-community/gpt2 --include '*.safetensors'
EOF
}

show_import_help() {
  cat <<EOF
${BOLD}nix-hug import${NC} <URL> [OPTIONS]

Imports a model/dataset from the local HuggingFace cache into the Nix store.
Use 'nix-hug scan' to see what's available in your cache.
Respects \$HF_HUB_CACHE, \$HF_HOME, and \$XDG_CACHE_HOME env vars.

${BOLD}OPTIONS:${NC}
    --ref REF           Match a specific revision
    --include PATTERN   Include files matching glob
    --exclude PATTERN   Exclude files matching glob
    --file FILENAME     Include specific file by name
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug import openai-community/gpt2
    nix-hug import openai-community/gpt2 --include '*.safetensors'
EOF
}

show_import_all_help() {
  cat <<EOF
${BOLD}nix-hug import-all${NC} [OPTIONS]

Scans the local HuggingFace cache and imports all models/datasets
not yet in the Nix store. Equivalent to running 'nix-hug import'
for each entry shown by 'nix-hug scan' that isn't already imported.

${BOLD}OPTIONS:${NC}
    -y, --yes       Skip confirmation prompt
    --help          Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug import-all
    nix-hug import-all -y
EOF
}

show_scan_help() {
  cat <<EOF
${BOLD}nix-hug scan${NC}

Lists cached models/datasets from the local HuggingFace cache.
Respects \$HF_HUB_CACHE, \$HF_HOME, and \$XDG_CACHE_HOME env vars.

${BOLD}COLUMNS:${NC}
    SIZE, FILES       Size and file count of that snapshot
    IN STORE          Whether the same repo and revision is already a Nix
                      store path, i.e. whether 'nix-hug import' has work
                      left to do for it
    REFS              Cache refs pointing at that revision

${BOLD}OPTIONS:${NC}
    --help            Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug scan
EOF
}

display_files() {
  local files="$1"
  local header="$2"

  echo "$header"
  echo

  local total_size=0
  local lfs_count=0
  local lfs_size=0

  while IFS=$'\t' read -r path size is_lfs; do
    total_size=$((total_size + size))

    if [[ "$is_lfs" == "true" ]]; then
      lfs_count=$((lfs_count + 1))
      lfs_size=$((lfs_size + size))
      printf "  %-50s %10s   ${DIM}[LFS]${NC}\n" "$path" "$(format_size "$size")"
    else
      printf "  %-50s %10s\n" "$path" "$(format_size "$size")"
    fi
  done < <(echo "$files" | jq -r '.[] | select(.type != "directory") | [.path, (.size // 0 | tostring), (has("lfs") | tostring)] | @tsv')

  echo
  echo -n "Total: $(format_size "$total_size")"
  if [[ $lfs_count -gt 0 ]]; then
    echo " ($lfs_count LFS files: $(format_size "$lfs_size"))"
  else
    echo
  fi
}

print_usage_block() {
  printf 'Usage:\n\n%s;\n' "$1"
}

generate_usage_example() {
  local repo_type="$1" repo_id="$2" ref="$3" filter_json="$4" file_tree_hash="$5"
  local tree_path="${6:-}" git_repo_hash="${7:-}"
  print_usage_block "$(format_fetch_call "  " "nix-hug-lib" "$repo_type" "$repo_id" "$ref" "$filter_json" "$file_tree_hash" "$tree_path" "$git_repo_hash")"
}

suggest_vendor() {
  info "Tip: --vendor DIR writes a lock file of the upstream hashes, like flake.lock: evaluation needs no network, and a stale hash is reported in SRI format."
}

generate_git_usage_example() {
  local git_url="$1" rev="$2" lfs_url="$3" filter_json="$4"
  local lfs_path="${5:-}" git_repo_hash="${6:-}" lfs_json="${7:-}"
  print_usage_block "$(format_git_fetch_call "  " "nix-hug-lib" "$git_url" "$rev" "$lfs_url" "$filter_json" "$lfs_path" "$git_repo_hash" "$lfs_json")"
}

filter_files_json() {
  local files="$1"
  shift
  local filters=("$@")

  local filter_type=""
  local patterns=()
  local file_names=()

  for ((i = 0; i < ${#filters[@]}; i += 2)); do
    local flag="${filters[i]}"
    local pattern="${filters[i + 1]}"

    case "$flag" in
      --include) filter_type="include" ;;
      --exclude) filter_type="exclude" ;;
      --file) filter_type="file" ;;
    esac

    if [[ "$flag" == "--file" ]]; then
      file_names+=("$pattern")
    else
      patterns+=("$(glob_to_regex "$pattern")$")
    fi
  done

  if [[ "$filter_type" == "include" ]]; then
    local pattern_regex
    pattern_regex=$(
      IFS='|'
      echo "${patterns[*]}"
    )
    echo "$files" | jq --arg regex "$pattern_regex" '[.[] | select(.type != "directory") | select((.path | test($regex)) or (has("lfs") | not))]'
  elif [[ "$filter_type" == "exclude" ]]; then
    local pattern_regex
    pattern_regex=$(
      IFS='|'
      echo "${patterns[*]}"
    )
    echo "$files" | jq --arg regex "$pattern_regex" '[.[] | select(.type != "directory") | select((.path | test($regex) | not) or (has("lfs") | not))]'
  elif [[ "$filter_type" == "file" ]]; then
    local names_json
    names_json=$(printf '%s\n' "${file_names[@]}" | jq -R . | jq -s .)
    echo "$files" | jq --argjson names "$names_json" '[.[] | select(.type != "directory") | select(.path as $p | $names | any(. == $p))]'
  else
    echo "$files" | jq '[.[] | select(.type != "directory")]'
  fi
}

display_filtered_files() {
  local files="$1"
  shift
  local filtered
  filtered=$(filter_files_json "$files" "$@")
  echo "Files matching filters: ${*@Q}"
  display_files "$filtered" ""
}
