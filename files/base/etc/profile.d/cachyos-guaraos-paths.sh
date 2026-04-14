# GuaraOS - Global PATH setup

# Prepend user-local and Flatpak bin directories safely
add_to_path() {
    if [ -d "$1" ]; then
        case ":$PATH:" in
            *":$1:"*) ;;
            *) PATH="$1:$PATH" ;;
        esac
    fi
}

add_to_path "$HOME/bin"
add_to_path "$HOME/.local/bin"
add_to_path "$HOME/.cargo/bin"        # Cargo (Rust)
add_to_path "$HOME/.npm-global/bin"   # NPM (if configured for user-local global installs)
add_to_path "$HOME/go/bin"            # Go
add_to_path "/var/lib/flatpak/exports/bin"

export PATH
unset -f add_to_path
