# GuaraOS - Global Homebrew Setup

if [ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [ -x "/var/home/linuxbrew/.linuxbrew/bin/brew" ]; then
    eval "$(/var/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
