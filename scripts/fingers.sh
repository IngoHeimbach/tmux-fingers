#!/usr/bin/env bash

eval "$(tmux show-env -g -s | grep ^FINGERS)"

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source $CURRENT_DIR/hints.sh
source $CURRENT_DIR/utils.sh
source $CURRENT_DIR/help.sh
source $CURRENT_DIR/debug.sh

FINGERS_COPY_COMMAND=$(tmux show-option -gqv @fingers-copy-command)
HAS_TMUX_YANK=$([ "$(tmux list-keys | grep -c tmux-yank)" == "0" ]; echo $?)
tmux_yank_copy_command=$(tmux_list_vi_copy_keys | grep -E "(vi-copy|copy-mode-vi) *y" | sed -E 's/.*copy-pipe(-and-cancel)? *"(.*)".*/\2/g')

current_pane_id=$1
fingers_pane_id=$2
fingers_window_id=$2
pane_input_temp=$4
original_rename_setting=$5

yanked_hints=()

BACKSPACE=$'\177'

function rerender() {
  show_hints "$fingers_pane_id" "$compact_state" "$(array_join " " "${yanked_hints[@]}")"
}

# TODO not sure this is truly working
function force_dim_support() {
  tmux set -sa terminal-overrides ",*:dim=\\E[2m"
}

function is_pane_zoomed() {
  local pane_id=$1

  tmux list-panes \
    -F "#{pane_id}:#{?pane_active,active,nope}:#{?window_zoomed_flag,zoomed,nope}" \
    | grep -c "^${pane_id}:active:zoomed$"
}

function zoom_pane() {
  local pane_id=$1

  tmux resize-pane -Z -t "$pane_id"
}

function handle_exit() {
  tmux swap-pane -s "$current_pane_id" -t "$fingers_pane_id"
  [[ $pane_was_zoomed == "1" ]] && zoom_pane "$current_pane_id"
  tmux kill-window -t "$fingers_window_id"
  tmux set-window-option automatic-rename "$original_rename_setting"
  rm -rf "$pane_input_temp" "$pane_output_temp" "$match_lookup_table"
}

function is_valid_input() {
  local input=$1
  local is_valid=1

  if [[ $input == "" ]] || [[ $input == "<ESC>" ]] || [[ $input == "<SPACE>" ]] || [[ $input == "<ENTER>" ]] || [[ $input == "?" ]]; then
    is_valid=1
  else
    for (( i=0; i<${#input}; i++ )); do
      char=${input:$i:1}

      if [[ ! $(is_alpha $char) == "1" ]]; then
        is_valid=0
        break
      fi
    done
  fi

  echo $is_valid
}

function hide_cursor() {
  echo -n $(tput civis)
}

trap "handle_exit" EXIT

compact_state=$FINGERS_COMPACT_HINTS
help_state=0
multi_state=0
prev_multi_state=0

force_dim_support
pane_was_zoomed=$(is_pane_zoomed "$current_pane_id")
show_hints_and_swap $current_pane_id $fingers_pane_id $compact_state
[[ $pane_was_zoomed == "1" ]] && zoom_pane "$fingers_pane_id"

hide_cursor
input=''

function toggle_compact_state() {
  if [[ $compact_state == "0" ]]; then
    compact_state=1
  else
    compact_state=0
  fi
}

function toggle_help_state() {
  if [[ $help_state == "0" ]]; then
    help_state=1
  else
    help_state=0
  fi
}

function copy_result() {
  local result="$1"

  tmux set-buffer "$result"

  if [[ "$OSTYPE" == "linux-gnu" ]]; then
    tmux_yank_prefix="nohup"
  else
    tmux_yank_prefix=""
  fi

  if [ ! -z "$FINGERS_COPY_COMMAND" ]; then
    echo -n "$result" | eval "nohup $FINGERS_COPY_COMMAND" > /dev/null
  fi

  if [[ $HAS_TMUX_YANK = 1 ]]; then
    echo -n "$result" | eval "$tmux_yank_prefix $tmux_yank_copy_command" > /dev/null
  fi
}

function toggle_multi_state() {
  current_window_id=$(tmux list-panes -s -F "#{pane_id}:#{window_id}" | grep "^$current_pane_id" | cut -f2 -d:)

  prev_multi_state=$multi_state
  if [[ $multi_state == "0" ]]; then
    tmux rename-window -t "$current_window_id" "[fingers:multi]"
    multi_state=1
  else
    tmux rename-window -t "$current_window_id" "[fingers]"
    multi_state=0
  fi
}

OLDIFS=$IFS
IFS=''
while read -rsn1 char; do
  is_exiting_multi=""

  # Escape sequence, flush input
  if [[ "$char" == $'\x1b' ]]; then
    read -rsn1 -t 0.1 next_char

    if [[ "$next_char" == "[" ]]; then
      read -rsn1 -t 0.1
      continue
    elif [[ "$next_char" == "" ]]; then
      char="<ESC>"
    else
      continue
    fi
  fi

  if [[ $char == ' ' ]]; then
    char="<SPACE>"
  elif [[ $char == "" ]]; then
    char="<ENTER>"
  fi

  log "char $char"

  if [[ ! $(is_valid_input "$char") == "1" ]]; then
    log "invalid input! :("
    continue
  fi

  prev_help_state="$help_state"
  prev_compact_state="$compact_state"

  if [[ $char == "$BACKSPACE" ]]; then
    input=""
    continue
  elif [[ $char == "<ESC>" ]]; then
    if [[ $help_state == "1" ]]; then
      toggle_help_state
    else
      exit
    fi
  elif [[ $char == "<SPACE>" ]]; then
    toggle_compact_state
  elif [[ $char == "<ENTER>" ]]; then
    toggle_multi_state
    is_exiting_multi=$(expr $prev_multi_state == 1 \& $multi_state == 0)
    log "multi_state '$multi_state'"
    log "is_exiting_multi '$is_exiting_multi'"

    if [[ ! $is_exiting_multi == "1" ]]; then
      log "beep beep next loop"
      continue
    fi
  elif [[ $char == "?" ]]; then
    toggle_help_state
  else
    input="$input$char"
  fi

  if [[ $help_state == "1" ]]; then
    show_help "$fingers_pane_id"
  else
    rerender
  fi

  if [[ "$prev_compact_state" != "$compact_state" ]]; then
    rerender
  fi

  matched_hint=$(lookup_match "$input")


  if [[ ! $is_exiting_multi == "1" ]] && [[ -z $matched_hint ]]; then
    log "beep beep next loop ( no matched hint )"
    continue
  fi

  # not exiting multi-mode
  if [[ ! $is_exiting_multi == "1" ]] && [[ "$multi_state" == "0" ]]; then
    result=$matched_hint
  else
    yanked_hints+=("$input")
    result="$result $matched_hint"
    rerender
  fi

  tmux display-message "$input"

  input=""

  if [[ ! $is_exiting_multi == "1" ]] && [[ -z $result ]]; then
    log "beep beep next loop ( no result )"
    continue
  fi

  if [[ $multi_state == "0" ]] || [[ $is_exiting_multi == "1" ]]; then
    log "copy that! '$result'"
    result=$(echo $result | sed "s/^ *//g" | sed "s/ *$//g")
    copy_result "$result"
    revert_to_original_pane "$current_pane_id" "$fingers_pane_id"
    exit 0
  fi
done < /dev/tty
IFS=$OLDIFS
