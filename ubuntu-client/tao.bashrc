# Keep the user's aliases, nvm, Conda and other interactive shell settings.
[[ -r $HOME/.bashrc ]] && source "$HOME/.bashrc"
export WIFI2LAN_NETWORK=tao
PS1="\[\e[1;36m\][tao]\[\e[0m\] ${PS1}\[\e]0;Terminal (Tao): \w\a\]"
