# Fish completion for geheim
# Install to ~/.config/fish/completions/geheim.fish

# Dynamically load commands from geheim
function __fish_geheim_commands
    geheim commands 2>/dev/null
end

# Get list of entries for completion
function __fish_geheim_entries
    # Only run if PIN is set to avoid interactive prompt
    if set -q PIN
        geheim ls 2>/dev/null | string replace -r ';.*$' '' | string trim
    end
end

# Complete subcommands
complete -c geheim -f -n "__fish_use_subcommand" -a "(__fish_geheim_commands)"

# Complete search terms for commands that need them
complete -c geheim -f -n "__fish_seen_subcommand_from search cat paste export pathexport open edit rm" -a "(__fish_geheim_entries)"

# Complete file paths for import
complete -c geheim -n "__fish_seen_subcommand_from import" -F

# Complete directory paths for import destination
complete -c geheim -n "__fish_seen_subcommand_from import; and __fish_is_nth_token 3" -F -a "(__fish_complete_directories)"

# Force flag for import
complete -c geheim -n "__fish_seen_subcommand_from import; and __fish_is_nth_token 4" -f -a "force"

# Complete directory paths for import_r
complete -c geheim -n "__fish_seen_subcommand_from import_r" -F -a "(__fish_complete_directories)"
