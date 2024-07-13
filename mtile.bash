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



if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3 ) )); then
	print_stderr 1 '%s\n' 'BASH version required >= 4.3 (released 2014)'
fi



if [[ ! $MTILE_BASH__DISABLE_DAEMON_MODE ]]; then
	temp_dir=${TMPDIR:-${XDG_RUNTIME_DIR:-/tmp}}
	fifo_path=$temp_dir"/mtile.bash__signal_${USER}"

	# If an instance is already running, signal it to call activate again and exit early
	if [[ -p $fifo_path ]]; then
		exec 3<>"$fifo_path"
		printf '1' > /dev/fd/3
		exit
	fi

	# Create a named pipe to listen for subsequent script activations
	[[ -d $temp_dir ]] || mkdir --mode 0700 -p -- "$temp_dir"
	mkfifo --mode 0600 -- "$fifo_path"
	trap "[[ -e $fifo_path ]] && rm -f -- ${fifo_path@Q}" EXIT
fi



# Check dependencies
type xprop xrandr wmctrl xdotool 1>/dev/null



# Declare global variables and defaults
declare -A window=()
display_count=0
config_dir=${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}
SPLIT_DEPTH=1
DISPLAY_COLUMNS=2
DISPLAY_ROWS=2
EDGE_PROXIMITY_SIZE=30
CORNER_PROXIMITY_SIZE=$EDGE_PROXIMITY_SIZE
DISABLE_DOCUMENT_MODE=
# Include dump stats in verbosity
[[ $MTILE_BASH__VERBOSE ]] && MTILE_BASH__DUMP_STATS=1



# Source configuration and overwrite defaults
[[ -d $config_dir ]] || print_stderr 1 '%s\n' 'bad config directory'
[[ -f $config_dir'/mtile.bash/shims' ]] && source -- "${config_dir}/mtile.bash/shims"



# Apply environment variables
[[ $MTILE_BASH__SPLIT_DEPTH ]] && SPLIT_DEPTH=$MTILE_BASH__SPLIT_DEPTH
[[ $MTILE_BASH__DISPLAY_COLUMNS ]] && DISPLAY_COLUMNS=$MTILE_BASH__DISPLAY_COLUMNS
[[ $MTILE_BASH__DISPLAY_ROWS ]] && DISPLAY_ROWS=$MTILE_BASH__DISPLAY_ROWS
[[ $MTILE_BASH__EDGE_PROXIMITY_SIZE ]] && EDGE_PROXIMITY_SIZE=$MTILE_BASH__EDGE_PROXIMITY_SIZE
[[ $MTILE_BASH__CORNER_PROXIMITY_SIZE ]] && CORNER_PROXIMITY_SIZE=$MTILE_BASH__CORNER_PROXIMITY_SIZE
[[ $MTILE_BASH__DISABLE_DOCUMENT_MODE ]] && DISABLE_DOCUMENT_MODE=$MTILE_BASH__DISABLE_DOCUMENT_MODE



run_cmd() {
	if [[ $MTILE_BASH__VERBOSE ]]; then
		print_stderr 0 '%s ' "$@"
		print_stderr 0 '\n'
	fi
	"$@"
}



set_epoch_microseconds() {
	EPOCH_MICROSECONDS=${EPOCHREALTIME/.}
	if [[ ! $EPOCH_MICROSECONDS ]]; then
		EPOCH_MICROSECONDS=$(( $(date +%s%N) / 1000 ))
	fi
}



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

		if [[ $MTILE_BASH__DUMP_STATS ]]; then
			for prop in "${!display[@]}"; do
				printf '%s%q\n' "display_${display_id}[${prop}]=" "${display[$prop]}"
			done
		fi
	done < <(xrandr | grep ' connected ')
}



set_mouse_stats() {
	declare -gA mouse=()
	local -a valpairs=($( run_cmd xdotool getmouselocation --shell ))
	for valpair in "${valpairs[@]}"; do
		[[ $valpair == *'='* ]] || continue
		name=${valpair%%=*}
		val=${valpair#*=}
		mouse["${name,,}"]=$val
	done

	if [[ $MTILE_BASH__DUMP_STATS ]]; then
		for prop in "${!mouse[@]}"; do
			printf '%s%q\n' "mouse[${prop}]=" "${mouse[$prop]}"
		done
	fi
}



set_window_stats() {
	local -a valpairs=($( run_cmd xdotool getactivewindow getwindowname getwindowgeometry --shell ))
	for valpair in "${valpairs[@]}"; do
		[[ $valpair == *'='* ]] || continue
		name=${valpair%%=*}
		name=${name,,}
		val=${valpair#*=}
		if [[ $name == 'window' ]] && [[ $val != ${window[window]} ]]; then
			window[__offset_x]=
			window[__offset_y]=
			window[__last_mvarg]=
		fi
		window["$name"]=$val
	done


	# Only fetch decorations if they haven't been fetched before
	if [[ ! ${window[__offset_x]} ]]; then
		# Remove maximized attributes as they prevent moving the window and reading decoration sizes aside from top
		run_cmd wmctrl -r :ACTIVE: -b remove,maximized_vert,maximized_horz


		window_xprop_str=$'\n'$( run_cmd xprop -id "${window[window]}" ) || print_stderr 1 '%s\n' 'failed to run xprop for window id: '"${window[window]}"


		# Error if the window type is wrong and there is a window type
		if [[ $window_xprop_str != *$'\n''_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL'* ]]; then
			[[ $window_xprop_str == *$'\n''_NET_WM_WINDOW_TYPE(ATOM) = '* ]] && print_stderr 1 '%s\n' 'if attribute _NET_WM_WINDOW_TYPE(ATOM) exists in xprop output, value must = _NET_WM_WINDOW_TYPE_NORMAL'
		fi


		re=$'\n''_NET_FRAME_EXTENTS\(CARDINAL\) = ([0-9]*), ([0-9]*), ([0-9]*), ([0-9]*)'
		if [[ $window_xprop_str =~ $re ]]; then
			window[dec_top]=${BASH_REMATCH[3]}
			window[dec_width]=$(( BASH_REMATCH[1] + BASH_REMATCH[2] ))
			window[dec_height]=$(( BASH_REMATCH[3] + BASH_REMATCH[4] ))
		else
			window[dec_width]=0
			window[dec_height]=0
		fi
	fi


	if [[ $MTILE_BASH__DUMP_STATS ]]; then
		for prop in "${!window[@]}"; do
			printf '%s%q\n' "window[${prop}]=" "${window[$prop]}"
		done
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

	if [[ $MTILE_BASH__DUMP_STATS ]]; then
		printf '%s%q\n' "active_display=" "display_${display_id}"
	fi
}



handle_area() {
	# exports: tile_x_global tile_y_global tile_width tile_height

	local -n "area=$1"
	local tile_x tile_y tile_x2 tile_y2 mouse_x mouse_y


	tile_width=$(( area[width] / AREA_COLUMNS ))
	tile_height=$(( area[height] / AREA_ROWS ))
	tile_x=$(( ( ( mouse[x] - area[x] ) / tile_width ) * tile_width ))
	tile_y=$(( ( ( mouse[y] - area[y] ) / tile_height ) * tile_height ))

	tile_x_global=$(( tile_x + area[x] ))
	tile_y_global=$(( tile_y + area[y] ))
	tile_x2=$(( tile_x + tile_width ))
	tile_y2=$(( tile_y + tile_height ))

	mouse_x=$(( mouse[x] - area[x] ))
	mouse_y=$(( mouse[y] - area[y] ))


	if [[ $IS_ROOT && ! $DISABLE_DOCUMENT_MODE ]] && (( mouse_y < 100 )); then
		# Document mode
		if (( mouse_x > ( area[width] / 3 ) && mouse_x < ( area[width] - ( area[width] / 3 ) ) )); then
			# Center on x-axis
			tile_x=$(( ( area[width] / 2 ) - ( tile_width / 2 ) ))
			tile_x_global=$(( area[x] + tile_x ))
		fi

		# Fill vertical
		tile_y_global=$(( tile_y_global - tile_y ))
		tile_y=0
		tile_height=$(( area[height] ))


	elif \
		(( mouse_y > ( area[height] / 2 ) - CORNER_PROXIMITY_SIZE && mouse_y < ( area[height] / 2 ) + CORNER_PROXIMITY_SIZE )) && \
		(( mouse_x > (  area[width] / 2 ) - CORNER_PROXIMITY_SIZE && mouse_x < (  area[width] / 2 ) + CORNER_PROXIMITY_SIZE )); then
		# Fill area
		tile_x_global=$(( tile_x_global - tile_x ))
		tile_x=0
		tile_width=${area[width]}
		tile_y_global=$(( tile_y_global - tile_y ))
		tile_y=0
		tile_height=${area[height]}


	elif (( mouse_y > ( area[height] / 2 ) - EDGE_PROXIMITY_SIZE && mouse_y < ( area[height] / 2 ) + EDGE_PROXIMITY_SIZE )); then
		# Fill vertical
		tile_y_global=$(( tile_y_global - tile_y ))
		tile_y=0
		tile_height=${area[height]}


	elif (( mouse_x > ( area[width] / 2 ) - EDGE_PROXIMITY_SIZE && mouse_x < ( area[width] / 2 ) + EDGE_PROXIMITY_SIZE )); then
		# Fill horizontal
		tile_x_global=$(( tile_x_global - tile_x ))
		tile_x=0
		tile_width=${area[width]}


	elif (( SPLIT_DEPTH-- > 0 )); then
		local -A sub_area=(
			[width]=$tile_width
			[height]=$tile_height
			[x]=$tile_x_global
			[y]=$tile_y_global
			[x2]=$(( tile_width + tile_x_global ))
			[y2]=$(( tile_height + tile_y_global ))
		)
		AREA_COLUMNS=2 \
		AREA_ROWS=2 \
		IS_ROOT= \
			handle_area 'sub_area'
	fi
}



move_window() {
	local -n 'display=active_display'
	local -a cmd


	AREA_COLUMNS=$DISPLAY_COLUMNS \
	AREA_ROWS=$DISPLAY_ROWS \
	SPLIT_DEPTH=$SPLIT_DEPTH \
	IS_ROOT=1 \
		handle_area 'active_display'


	# Remove decoration skew
	tile_width=$(( tile_width - window[dec_width] ))
	tile_height=$(( tile_height - window[dec_height] ))


	# Resize tiles that overlap with margins
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


	# Call shim if present
	declare -F move_window__shim 1>/dev/null && move_window__shim


	# Perform window move and resize if wmctrl mvarg is different from last activation
	wmctrl_mvarg="0,${tile_x_global},${tile_y_global},${tile_width},${tile_height}"
	[[ $wmctrl_mvarg == ${window['__last_mvarg']} ]] && return 0
	window['__last_mvarg']=$wmctrl_mvarg


	if [[ $move_window__enforcer__pid ]]; then
		kill "$move_window__enforcer__pid" &> /dev/null || :
		wait
	fi


	if [[ ! ${window[__offset_x]} ]]; then
		# Create position offsets relative to where the window should be to hangle programs that position before or after decorations
		run_cmd wmctrl -r :ACTIVE: -e "$wmctrl_mvarg"

		set_window_stats
		window[__offset_x]=$(( ( $tile_x_global + ${window[dec_width]} ) - ${window[x]} ))
		window[__offset_y]=$(( ( $tile_y_global + ${window[dec_top]} + ${window[dec_top]} ) - ${window[y]} ))

		move_window__set_offset_mvarg
		if [[ $wmctrl_mvarg != "$wmctrl_offset_mvarg" ]]; then
			run_cmd wmctrl -r :ACTIVE: -e "$wmctrl_offset_mvarg"
		fi

	else
		move_window__set_offset_mvarg
		run_cmd wmctrl -r :ACTIVE: -e "$wmctrl_offset_mvarg"
	fi


	# Correct the position and size of the window repeatedly for a set period to handle resizing race conditions
	move_window__enforcer & # <= note: do not use disown, creates phantom issues under heavy load
	move_window__enforcer__pid=$!
}



move_window__set_offset_mvarg() {
	# Create offset version of wmctrl mvarg
	tile_x_global=$(( tile_x_global + ${window[__offset_x]} ))
	tile_y_global=$(( tile_y_global + ${window[__offset_y]} ))
	wmctrl_offset_mvarg="0,${tile_x_global},${tile_y_global},${tile_width},${tile_height}"
}



move_window__enforcer() {	
	target_window_id=${window[window]}
	set_epoch_microseconds
	next_tick_epoch_us=$EPOCH_MICROSECONDS
	end_epoch_us=$(( EPOCH_MICROSECONDS + 100000 )) # end loop in 0.1 seconds
	tick_us=10000 # tick every .01 seconds
	while :; do
		next_tick_epoch_us=$(( next_tick_epoch_us + tick_us ))


		# Move and resize window if it's stats are incorrect
		if [[ \
			${window[width]} != "$tile_width" || \
			${window[height]} != "$tile_height" || \
			$(( ${window[x]} - ${window[dec_width]} )) != "$tile_x_global" || \
			$(( ${window[y]} - ( ${window[dec_top]} * 2 ) )) != "$tile_y_global" \
		]]; then
			run_cmd wmctrl -r :ACTIVE: -e "$wmctrl_offset_mvarg"
		fi

		(( next_tick_epoch_us >= end_epoch_us )) && break


		# Handle time to next tick
		set_epoch_microseconds
		sleep_for_us=$(( next_tick_epoch_us - EPOCH_MICROSECONDS ))
		(( sleep_for_us <= 0 )) && continue
		printf -v sleep_for_us "%06d" "$sleep_for_us"
		sleep_for_s=${sleep_for_us:0:-6}'.'${sleep_for_us: -6}
		sleep "$sleep_for_s"


		# Refresh window stats and ensure window id hasn't changed
		set_window_stats
		[[ ${window[window]} == "$target_window_id" ]] || break
	done
}



activate() {
	# Define ephemeral stats and move window
	set_mouse_stats; ref_active_display
	set_window_stats
	move_window
}



# Define permanent stats and call activate
set_display_stats
activate



if [[ ! $MTILE_BASH__DISABLE_DAEMON_MODE ]]; then
	# Call activate for every script activcation that occurs within 1 second of last activation
	while read -n 1 -t 1 <> "$fifo_path"; do
		activate
	done
fi



