#!/usr/bin/env bash
# License: GNU Affero General Public License Version 3 (GNU AGPLv3), (c) 2024, Marc Gilligan <marcg@ulfnic.com>
set -o errexit


print_stderr() {
	if [[ $1 == '0' ]]; then
		[[ $2 ]] && printf "$2" "${@:3}" 1>&2 || :
	else
		[[ $2 ]] && printf '%s'"$2" "ERROR: ${0##*/}, " "${@:3}" 1>&2 || :
		exit "$1"
	fi
}



# Enforce single running instance
instance_hold_sec=0.05
temp_dir=${TMPDIR:-${XDG_RUNTIME_DIR:-/tmp}}
[[ -d $temp_dir ]] || mkdir --mode 0700 -p "$temp_dir"
block_path=$temp_dir"/mtile.bash__block_${USER}"
[[ -f $block_path ]] && print_stderr 1 'instance already running: '"$(<$block_path)"
trap 'sleep "$instance_hold_sec"; rm -- "$block_path"' EXIT
printf '%s' "$PID" > "$block_path"



type xprop xrandr wmctrl xdotool 1>/dev/null



# Apply defaults to env variables
: ${SPLIT_DEPTH:=1}
: ${DISPLAY_SEG_WIDTH:=2}
: ${DISPLAY_SEG_HEIGHT:=2}



# Declare globals
display_count=0
config_dir=${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}
[[ -d $config_dir ]] || print_stderr 1 '%s\n' 'bad config directory'
[[ -f $config_dir'/mtile.bash/shims' ]] && source -- "${config_dir}/mtile.bash/shims"



set_display_stats() {
	local \
		remainder_re='(^|[ 	])([0123456789]+)x([0123456789]+)\+([0123456789]+)\+([0123456789]+)([ 	]|$)' \
		name state remainder dimensions_re x y offset_x offset_y display_id

	while read -r name state remainder; do
		[[ $remainder =~ $remainder_re ]] || print_stderr 1 'failed to read dimensions of display: '"$name"

		display_id=$(( ++display_count ))
		declare -gA "display_${display_id}=()"
		local -n "display=display_${display_id}"
		display[name]=$name
		display[width]=${BASH_REMATCH[2]}
		display[height]=${BASH_REMATCH[3]}
		display[x]=${BASH_REMATCH[4]}
		display[y]=${BASH_REMATCH[5]}
		display[x2]=$(( display[x] + display[width] ))
		display[y2]=$(( display[y] + display[height] ))

	done < <(xrandr | grep ' connected ')
}



set_mouse_stats() {
	declare -gA mouse=()
	local -a valpairs=($(xdotool getmouselocation --shell))
	for valpair in "${valpairs[@]}"; do
		[[ $valpair == *'='* ]] || continue
		name=${valpair%%=*}
		val=${valpair#*=}
		mouse["${name,,}"]=$val
	done
}



set_window_stats() {
	declare -gA window=()


	local -a valpairs=($(xdotool getactivewindow getwindowname getwindowgeometry --shell))
	for valpair in "${valpairs[@]}"; do
		[[ $valpair == *'='* ]] || continue
		name=${valpair%%=*}
		val=${valpair#*=}
		window["${name,,}"]=$val
	done


	window_xprop_str=$'\n'$( xprop -id "${window[window]}" ) || print_stderr 1 '%s\n' 'failed to run xprop for window id: '"${window[window]}"


	# Error if the window type is wrong and there is a window type
	if [[ $window_xprop_str != *$'\n''_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL'* ]]; then
		[[ $window_xprop_str == *$'\n''_NET_WM_WINDOW_TYPE(ATOM) = '* ]] && print_stderr 1 '%s\n' 'if attribute _NET_WM_WINDOW_TYPE(ATOM) exists in xprop output, value must = _NET_WM_WINDOW_TYPE_NORMAL'
	fi


	re=$'\n''_NET_FRAME_EXTENTS\(CARDINAL\) = ([0-9]*), ([0-9]*), ([0-9]*), ([0-9]*)'
	if [[ $window_xprop_str =~ $re ]]; then
		window[dec_width]=$(( BASH_REMATCH[1] + BASH_REMATCH[2] ))
		window[dec_height]=$(( BASH_REMATCH[3] + BASH_REMATCH[4] ))
	else
		window[dec_width]=0
		window[dec_height]=0
	fi
}



ref_active_display() {
	for (( display_id=$display_count; display_id > 0; display_id-- )) do
		local -n "display=display_${display_id}"
		if (( mouse[x] >= display[x] && mouse[x] <= display[x2] )) && (( mouse[y] >= display[y] && mouse[y] <= display[y2] )); then
			declare -gn "active_display=display_${display_id}"
			break
		fi
	done
}



handle_panel() {
	# exports: tile_x_global tile_y_global tile_width tile_height

	local -n "panel=$1"
	local \
		tile_x tile_y tile_x2 tile_y2 mouse_x mouse_y \
		zone_size


	tile_width=$(( panel[width] / PANEL_SEG_WIDTH ))
	tile_height=$(( panel[height] / PANEL_SEG_HEIGHT ))
	tile_x=$(( ( ( mouse[x] - panel[x] ) / tile_width ) * tile_width ))
	tile_y=$(( ( ( mouse[y] - panel[y] ) / tile_height ) * tile_height ))

	tile_x_global=$(( tile_x + panel[x] ))
	tile_y_global=$(( tile_y + panel[y] ))
	tile_x2=$(( tile_x + tile_width ))
	tile_y2=$(( tile_y + tile_height ))

	mouse_x=$(( mouse[x] - panel[x] ))
	mouse_y=$(( mouse[y] - panel[y] ))


	# === Special Rules ===
	zone_size=30


	if [[ $IS_ROOT ]] && (( mouse_y < 100 )); then
		# Center on x-axis
		tile_x=$(( ( panel[width] / 2 ) - ( tile_width / 2 ) ))
		tile_x_global=$(( panel[x] + tile_x ))

		# Tower mode
		tile_y_global=$(( tile_y_global - tile_y ))
		tile_y=0
		tile_height=$(( panel[height] ))


	elif (( mouse_y > ( panel[height] / 2 ) - zone_size && mouse_y < ( panel[height] / 2 ) + ( zone_size * 2 ) )); then
		if (( mouse_x > ( panel[width] / 2 ) - zone_size && mouse_x < ( panel[width] / 2 ) + ( zone_size * 2 ) )); then
			# Full screen
			tile_x_global=$(( tile_x_global - tile_x ))
			tile_x=0
			tile_width=${panel[width]}
		fi

		# Tower mode
		tile_y_global=$(( tile_y_global - tile_y ))
		tile_y=0
		tile_height=${panel[height]}


	elif (( mouse_x > ( panel[width] / 2 ) - zone_size && mouse_x < ( panel[width] / 2 ) + ( zone_size * 2 ) )); then
		# Moat mode
		tile_x_global=$(( tile_x_global - tile_x ))
		tile_x=0
		tile_width=${panel[width]}


	elif (( SPLIT_DEPTH-- > 0 )); then
		local -A sub_panel=(
			[width]=$tile_width
			[height]=$tile_height
			[x]=$tile_x_global
			[y]=$tile_y_global
			[x2]=$(( tile_width + tile_x_global ))
			[y2]=$(( tile_height + tile_y_global ))
		)
		PANEL_SEG_WIDTH=2 \
		PANEL_SEG_HEIGHT=2 \
		IS_ROOT= \
			handle_panel 'sub_panel'
	fi
}


move_window() {
	local -n 'display=active_display'

	PANEL_SEG_WIDTH=$DISPLAY_SEG_WIDTH \
	PANEL_SEG_HEIGHT=$DISPLAY_SEG_HEIGHT \
	SPLIT_DEPTH=$SPLIT_DEPTH \
	IS_ROOT=1 \
		handle_panel 'active_display'


	# Remove decoration skew
	tile_width=$(( tile_width - window[dec_width] ))
	tile_height=$(( tile_height - window[dec_height] ))


	# Enforce margins
	if [[ $MARGIN_LEFT ]]; then
		left_overage=$(( tile_x_global - ( display[x] + MARGIN_LEFT ) ))
		if (( left_overage < 0 )); then
			tile_x_global=$(( tile_x_global - left_overage ))
			tile_width=$(( tile_width + left_overage ))
		fi
	fi

	if [[ $MARGIN_TOP ]]; then
		top_overage=$(( tile_y_global - ( display[y] + MARGIN_TOP ) ))
		if (( top_overage < 0 )); then
			tile_y_global=$(( tile_y_global - top_overage ))
			tile_height=$(( tile_height + top_overage ))
		fi
	fi

	if [[ $MARGIN_RIGHT ]]; then
		right_overage=$(( tile_x_global + tile_width - ( display[x2] - MARGIN_RIGHT ) ))
		(( right_overage > 0 )) && tile_width=$(( tile_width - right_overage ))
	fi

	if [[ $MARGIN_BOTTOM ]]; then
		bottom_overage=$(( tile_y_global + tile_height - ( display[y2] - MARGIN_BOTTOM ) ))
		(( bottom_overage > 0 )) && tile_height=$(( tile_height - bottom_overage ))
	fi


	declare -F move_window__shim 1>/dev/null && move_window__shim


	if [[ $tile_width == ${window[width]} && $tile_height == ${window[height]} ]]; then
		[[ $tile_x_global == ${window[x]} && $tile_y_global == ${window[y]} ]] && return 0
		xdotool getactivewindow windowmove %@ "$tile_x_global" "$tile_y_global"
		return $?
	fi


	# Remove maximize attributes to insure the window is moveable by xdotool
	wmctrl -r :ACTIVE: -b remove,maximized_vert,maximized_horz


	xdotool getactivewindow windowsize %@ "$tile_width" "$tile_height" windowmove %@ "$tile_x_global" "$tile_y_global"
	sleep 0.001
	xdotool getactivewindow windowsize %@ "$tile_width" "$tile_height" windowmove %@ "$tile_x_global" "$tile_y_global"
}



set_display_stats
set_mouse_stats; ref_active_display
set_window_stats
move_window



