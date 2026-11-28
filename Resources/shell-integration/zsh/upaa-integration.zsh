# Marks the prompt for the terminal with OSC 133: A where the prompt starts, B where the typed command starts,
# C where the command's output starts. With the marks, libghostty-vt clears the prompt when the width changes instead
# of rewrapping it, so zsh redraws it in place (issue #59). libghostty-vt's C API assumes by default that the shell
# does not redraw, so A says redraw=1. The marks go inside PS1, so zsh writes them again each time it redraws the
# prompt.

_upaa_precmd() {
  builtin emulate -L zsh
  # Tells upaa how many jobs the shell has, in the background or stopped, with its own OSC 7385, so it asks before
  # closing the pane would end them. A job disowned with &! or disown, as themes start their daemons (powerlevel10k's
  # gitstatusd), is not one.
  builtin print -n "\e]7385;jobs=${#jobstates}\a"
  # Themes such as powerlevel10k set PS1 in their own precmd hook, so this one moves itself to the end. Hooks after
  # it may still replace PS1 for this prompt, so this prompt's start is marked directly.
  if [[ ${precmd_functions[-1]} != _upaa_precmd ]]; then
    precmd_functions=(${precmd_functions:#_upaa_precmd} _upaa_precmd)
    builtin print -n '\e]133;A;redraw=1\a'
    return
  fi
  # Mark PS1 as it is now: the unmarked one from last time, or what a theme just set.
  [[ $PS1 != "$_upaa_marked_ps1" ]] || PS1=$_upaa_ps1
  typeset -g _upaa_ps1=$PS1
  PS1=$'%{\e]133;A;redraw=1\a%}'$PS1$'%{\e]133;B\a%}'
  typeset -g _upaa_marked_ps1=$PS1
}

_upaa_preexec() {
  builtin emulate -L zsh
  # Other preexec hooks and the command see PS1 without the marks.
  [[ $PS1 != "$_upaa_marked_ps1" ]] || PS1=$_upaa_ps1
  builtin print -n '\e]133;C\a'
}

builtin zmodload zsh/parameter
typeset -ga precmd_functions preexec_functions
precmd_functions+=(_upaa_precmd)
preexec_functions+=(_upaa_preexec)
