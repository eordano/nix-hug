# Fish completion for nix-hug

# Disable file completions by default
complete -c nix-hug -f

# Helper: true when no subcommand has been given yet
function __nix_hug_no_subcommand
    set -l cmd (commandline -opc)
    for c in fetch ls export import import-all scan
        if contains -- $c $cmd
            return 1
        end
    end
    return 0
end

# Helper: true when the current subcommand matches
function __nix_hug_using_subcommand
    set -l cmd (commandline -opc)
    contains -- $argv[1] $cmd
end

# List cached repos from the HF cache directory
function __nix_hug_cached_repos
    set -l hf_cache
    if set -q HF_HUB_CACHE
        set hf_cache $HF_HUB_CACHE
    else if set -q HF_HOME
        set hf_cache $HF_HOME/hub
    else if set -q XDG_CACHE_HOME
        set hf_cache $XDG_CACHE_HOME/huggingface/hub
    else
        set hf_cache $HOME/.cache/huggingface/hub
    end
    test -d "$hf_cache"; or return

    for dir in $hf_cache/{models,datasets}--*--*/
        test -d "$dir"; or continue
        set -l name (basename $dir)
        # Strip type prefix (models-- or datasets--)
        set -l type (string replace -r '--.*' '' $name)
        set name (string replace -r '^(models|datasets)--' '' $name)
        # Convert first -- to /
        set name (string replace '--' '/' $name)
        echo -e "$name\t$type"
    end
end

# Global options
complete -c nix-hug -n __nix_hug_no_subcommand -l debug -d 'Enable debug output'
complete -c nix-hug -n __nix_hug_no_subcommand -l help -d 'Show help'
complete -c nix-hug -n __nix_hug_no_subcommand -l version -d 'Show version'

# Commands
complete -c nix-hug -n __nix_hug_no_subcommand -a fetch -d 'Fetch a Hugging Face repo into the Nix store'
complete -c nix-hug -n __nix_hug_no_subcommand -a ls -d 'List files in a Hugging Face repo'
complete -c nix-hug -n __nix_hug_no_subcommand -a export -d 'Export model/dataset from Nix store to HF cache'
complete -c nix-hug -n __nix_hug_no_subcommand -a import -d 'Import model/dataset from HF cache to Nix store'
complete -c nix-hug -n __nix_hug_no_subcommand -a import-all -d 'Import all cached models/datasets into Nix store'
complete -c nix-hug -n __nix_hug_no_subcommand -a scan -d 'Scan Hugging Face cache directory'

for sub in fetch ls export import
    complete -c nix-hug -n "__nix_hug_using_subcommand $sub" -l ref -r -d 'Git ref'
    complete -c nix-hug -n "__nix_hug_using_subcommand $sub" -l include -r -d 'Include filter pattern'
    complete -c nix-hug -n "__nix_hug_using_subcommand $sub" -l exclude -r -d 'Exclude filter pattern'
    complete -c nix-hug -n "__nix_hug_using_subcommand $sub" -l file -r -F -d 'Filter file'
    complete -c nix-hug -n "__nix_hug_using_subcommand $sub" -l help -d 'Show help'
end

complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l lfs-url -r -d 'LFS download URL prefix, for git+ URLs'
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l vendor -r -F -d 'Vendor the file tree into DIR for offline evaluation'
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l dry-run -d 'Show what would be fetched'

complete -c nix-hug -n '__nix_hug_using_subcommand import' -a '(__nix_hug_cached_repos)' -d 'Cached repository'

complete -c nix-hug -n '__nix_hug_using_subcommand import-all' -s y -l yes -d 'Skip confirmation prompt'
complete -c nix-hug -n '__nix_hug_using_subcommand import-all' -l help -d 'Show help'

complete -c nix-hug -n '__nix_hug_using_subcommand scan' -l help -d 'Show help'
