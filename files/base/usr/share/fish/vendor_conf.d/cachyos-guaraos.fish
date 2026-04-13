# Added by GuaraOS build process

# Homebrew setup for fish syntax
if test -x /home/linuxbrew/.linuxbrew/bin/brew
    eval (/home/linuxbrew/.linuxbrew/bin/brew shellenv)
else if test -x /var/home/linuxbrew/.linuxbrew/bin/brew
    eval (/var/home/linuxbrew/.linuxbrew/bin/brew shellenv)
end

# Fish does not natively read /etc/profile.d/ on some setups,
# so we export the Wayland hint here just to be safe for terminal launches.
set -gx ELECTRON_OZONE_PLATFORM_HINT "auto"

# We check if the binaries exist first so fish doesn't throw red errors
if command -v atuin >/dev/null
    atuin init fish | source
end

if command -v starship >/dev/null
    starship init fish | source
end

if command -v zoxide >/dev/null
    zoxide init fish | source
end

if command -v eza >/dev/null
    alias ls='eza --icons'
end
