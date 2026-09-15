# CachyOS BoppOS - System-wide shell aliases for interactive sessions
case "$-" in
    *i*) ;;
    *) return ;;
esac

# Modern networking aliases (iproute2 replacements for legacy net-tools)
alias ip='ip -color=auto'
alias ifconfig='ip -color=auto address'
alias ipa='ip -color=auto address'
alias ipb='ip -color=auto -brief address'
alias ipr='ip -color=auto route'
alias route='ip -color=auto route'
alias arp='ip -color=auto neighbor'
alias netstat='ss'
alias ports='ss -tulpn'
