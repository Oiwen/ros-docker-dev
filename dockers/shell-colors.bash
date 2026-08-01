# Permanent interactive shell colors for the ROS development image.
if ! declare -p BASH_COMPLETION_VERSINFO >/dev/null 2>&1; then
  if [[ -r /usr/share/bash-completion/bash_completion ]]; then
    source /usr/share/bash-completion/bash_completion
  elif [[ -r /etc/bash_completion ]]; then
    source /etc/bash_completion
  fi
fi

if command -v dircolors >/dev/null 2>&1; then
  eval "$(dircolors -b)"
fi

alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

HISTCONTROL=ignoreboth:erasedups
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend checkwinsize

# Up/Down search history using the text already typed on the command line.
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'

PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\] \[\e[1;35m\][${CUSTOM_CONTAINER_NAME:-ros-dev-env}]\[\e[0m\]\$ '
