_nix_hug_cached_repos() {
    local hf_cache="${HF_HUB_CACHE:-${HF_HOME:+$HF_HOME/hub}}"
    hf_cache="${hf_cache:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/hub}"
    [[ -d "$hf_cache" ]] || return

    local dir
    for dir in "$hf_cache"/{models,datasets}--*--*/; do
        [[ -d "$dir" ]] || continue
        local name="${dir%/}"
        name="${name##*/}"
        name="${name#models--}"
        name="${name#datasets--}"
        echo "${name/--//}"
    done
}

_nix_hug() {
    local cur prev words cword
    _init_completion || return

    local commands="fetch ls export import import-all scan"
    local global_opts="--debug --help --version"
    local repo_opts="--ref --include --exclude --file --help"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
        return
    fi

    local opts
    case "${words[1]}" in
        fetch) opts="$repo_opts --lfs-url --vendor --dry-run" ;;
        ls | export | import) opts="$repo_opts" ;;
        import-all) opts="-y --yes --help" ;;
        scan) opts="--help" ;;
        *) return ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    elif [[ "${words[1]}" == "import" ]]; then
        COMPREPLY=($(compgen -W "$(_nix_hug_cached_repos)" -- "$cur"))
    fi
}

complete -F _nix_hug nix-hug
