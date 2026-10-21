# Out-of-tree kernel module sources, shared by prefetch_extras.sh (which clones them) and build_kernel_modules.sh
# (which builds them from the tarballs prefetch saved). Sourced, not executed.
declare -A KMOD_REPOS=(
    [nct6687d]="https://github.com/Fred78290/nct6687d.git"
    [it87]="https://github.com/frankcrawford/it87.git"
    [xpadneo]="https://github.com/atar-axis/xpadneo.git"
    [xone]="https://github.com/OpenGamingCollective/xonedo.git"
    [zenergy]="https://github.com/BoukeHaarsma23/zenergy.git"
)
