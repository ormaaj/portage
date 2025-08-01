#!/usr/bin/env bash
# Copyright 1999-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2
# shellcheck disable=2128,2185

source "${PORTAGE_BIN_PATH:?}/eapi.sh" || exit

if ___eapi_has_version_functions; then
	source "${PORTAGE_BIN_PATH}/eapi7-ver-funcs.sh" || exit 1
fi

if [[ -v PORTAGE_EBUILD_EXTRA_SOURCE ]]; then
	source "${PORTAGE_EBUILD_EXTRA_SOURCE}" || exit 1
	# We deliberately do not unset PORTABE_EBUILD_EXTRA_SOURCE, so
	# that it keeps being exported in the environment of this
	# process and its child processes. There, for example portage
	# helper like doins, can pick it up and set the PMS variables
	# (usually by sourcing isolated-functions.sh).
fi

# We need this next line for "die" and "assert". It expands
# It _must_ preceed all the calls to die and assert.
shopt -s expand_aliases

assert() {
	# shellcheck disable=2219
	IFS='|' expression=${PIPESTATUS[*]} let '! expression' || die "$@"
}

shopt -s extdebug

# __dump_trace([number of funcs on stack to skip],
#            [whitespacing for filenames],
#            [whitespacing for line numbers])
__dump_trace() {
	local strip=${1:-1} filespacing=$2 linespacing=$3
	local sourcefile funcname lineno n p

	# The __qa_call() function and anything before it are portage internals
	# that the user will not be interested in. Therefore, the stack trace
	# should only show calls that come after __qa_call().
	(( n = ${#FUNCNAME[@]} - 1 ))
	(( p = ${#BASH_ARGV[@]} ))
	while (( n > 0 )) ; do
		[[ "${FUNCNAME[${n}]}" == "__qa_call" ]] && break
		(( p -= ${BASH_ARGC[${n}]} ))
		(( n-- ))
	done
	if (( n == 0 )) ; then
		(( n = ${#FUNCNAME[@]} - 1 ))
		(( p = ${#BASH_ARGV[@]} ))
	fi

	eerror "Call stack:"
	while (( n > ${strip} )) ; do
		funcname=${FUNCNAME[${n} - 1]}
		sourcefile=$(basename "${BASH_SOURCE[${n}]}")
		lineno=${BASH_LINENO[${n} - 1]}
		# Display function arguments
		args=
		if [[ ${#BASH_ARGV[@]} -gt 0 ]]; then
			for (( j = 1 ; j <= ${BASH_ARGC[${n} - 1]} ; ++j )); do
				newarg=${BASH_ARGV[$(( p - j - 1 ))]}
				args="${args:+${args} }'${newarg}'"
			done
			(( p -= ${BASH_ARGC[${n} - 1]} ))
		fi
		eerror "  $(printf "%${filespacing}s" "${sourcefile}"), line $(printf "%${linespacing}s" "${lineno}"):  Called ${funcname}${args:+ ${args}}"
		(( n-- ))
	done
}

nonfatal() {
	if ! ___eapi_has_nonfatal; then
		die "${FUNCNAME}() not supported in this EAPI"
	fi
	if [[ $# -lt 1 ]]; then
		die "${FUNCNAME}(): Missing argument"
	fi

	PORTAGE_NONFATAL=1 "$@"
}

__helpers_die() {
	local retval=$?

	if ___eapi_helpers_can_die && [[ ${PORTAGE_NONFATAL} != 1 ]]; then
		die "$@"
	else
		echo -e "$@" >&2
		return "$(( retval || 1 ))"
	fi
}

die() {
	# restore PATH since die calls basename & sed
	# TODO: make it pure bash
	[[ -n ${_PORTAGE_ORIG_PATH} ]] && PATH=${_PORTAGE_ORIG_PATH}

	set +x # tracing only produces useless noise here
	local IFS=$' \t\n'

	if ___eapi_die_can_respect_nonfatal && [[ $1 == -n ]]; then
		shift
		if [[ ${PORTAGE_NONFATAL} == 1 ]]; then
			[[ $# -gt 0 ]] && eerror "$*"
			return 1
		fi
	fi

	set +e
	if [[ -n "${QA_INTERCEPTORS}" ]]; then
		# die was called from inside inherit. We need to clean up
		# QA_INTERCEPTORS since sed is called below.
		unset -f ${QA_INTERCEPTORS}
		unset QA_INTERCEPTORS
	fi
	local n filespacing=0 linespacing=0
	# setup spacing to make output easier to read
	(( n = ${#FUNCNAME[@]} - 1 ))
	while (( n > 0 )) ; do
		[[ "${FUNCNAME[${n}]}" == "__qa_call" ]] && break
		(( n-- ))
	done
	(( n == 0 )) && (( n = ${#FUNCNAME[@]} - 1 ))
	while (( n > 0 )); do
		sourcefile=${BASH_SOURCE[${n}]} sourcefile=${sourcefile##*/}
		lineno=${BASH_LINENO[${n}]}
		((filespacing < ${#sourcefile})) && filespacing=${#sourcefile}
		((linespacing < ${#lineno}))     && linespacing=${#lineno}
		(( n-- ))
	done

	# When a helper binary dies automatically in EAPI 4 and later, we don't
	# get a stack trace, so at least report the phase that failed.
	local phase_str=
	[[ -n ${EBUILD_PHASE} ]] && phase_str=" (${EBUILD_PHASE} phase)"
	eerror "ERROR: ${CATEGORY}/${PF}::${PORTAGE_REPO_NAME} failed${phase_str}:"
	eerror "  ${*:-(no error message)}"
	eerror
	# __dump_trace is useless when the main script is a helper binary
	local main_index
	(( main_index = ${#BASH_SOURCE[@]} - 1 ))
	if [[ ${BASH_SOURCE[main_index]##*/} == @(ebuild|misc-functions).sh ]]; then
	__dump_trace 2 "${filespacing}" "${linespacing}"
	eerror "  $(printf "%${filespacing}s" "${BASH_SOURCE[1]##*/}"), line $(printf "%${linespacing}s" "${BASH_LINENO[0]}"):  Called die"
	eerror "The specific snippet of code:"
	# This scans the file that called die and prints out the logic that
	# ended in the call to die.  This really only handles lines that end
	# with '|| die' and any preceding lines with line continuations (\).
	# This tends to be the most common usage though, so let's do it.
	# Due to the usage of appending to the hold space (even when empty),
	# we always end up with the first line being a blank (thus the 2nd sed).
	local -a sed_args=(
		# When we get to the line that failed, append it to the hold
		# space, move the hold space to the pattern space, then print
		# out the pattern space and quit immediately.
		-n -e "${BASH_LINENO[0]}{H;g;p;q}"
		# If this line ends with a line continuation, append it to the
		# hold space.
		-e '/\\$/H'
		# If this line does not end with a line continuation, erase the
		# line and set the hold buffer to it (thus erasing the hold
		# buffer in the process).
		-e '/[^\]$/{s:^.*$::;h}'
	)
	sed "${sed_args[@]}" "${BASH_SOURCE[1]}" \
	| sed -e '1d' -e 's:^:RETAIN-LEADING-SPACE:' \
	| while read -r n; do
		eerror "  ${n#RETAIN-LEADING-SPACE}"
	done
	eerror
	fi
	eerror "If you need support, post the output of \`emerge --info '=${CATEGORY}/${PF}::${PORTAGE_REPO_NAME}'\`,"
	eerror "the complete build log and the output of \`emerge -pqv '=${CATEGORY}/${PF}::${PORTAGE_REPO_NAME}'\`."

	# Only call die hooks here if we are executed via ebuild.sh or
	# misc-functions.sh, since those are the only cases where the environment
	# contains the hook functions. When necessary (like for __helpers_die), die
	# hooks are automatically called later by a misc-functions.sh invocation.
	if [[ ${EBUILD_PHASE} != depend && ${BASH_SOURCE[main_index]##*/} == @(ebuild|misc-functions).sh ]]
	then
		local x
		for x in ${EBUILD_DEATH_HOOKS}; do
			${x} "$@"
		done >&2
		: > "${PORTAGE_BUILDDIR}/.die_hooks"
	fi

	if [[ -n ${PORTAGE_LOG_FILE} ]] ; then
		eerror "The complete build log is located at '${PORTAGE_LOG_FILE}'."
		if [[ ${PORTAGE_LOG_FILE} != ${T}/* ]] \
			&& ! contains_word fail-clean "${FEATURES}"
		then
			# Display path to symlink in ${T}, as requested in bug #412865.
			local log_ext=log
			[[ ${PORTAGE_LOG_FILE} != *.log ]] && log_ext+=.${PORTAGE_LOG_FILE##*.}
			eerror "For convenience, a symlink to the build log is located at '${T}/build.${log_ext}'."
		fi
	fi
	if [[ -f "${T}/environment" ]]; then
		eerror "The ebuild environment file is located at '${T}/environment'."
	elif [[ -d "${T}" ]]; then
		{
			set
			export
		} > "${T}/die.env"
		eerror "The ebuild environment file is located at '${T}/die.env'."
	fi
	eerror "Working directory: '$(pwd)'"
	[[ -n ${S} ]] && eerror "S: '${S}'"

	[[ -n ${PORTAGE_EBUILD_EXIT_FILE} ]] && : > "${PORTAGE_EBUILD_EXIT_FILE}"
	[[ -n ${PORTAGE_IPC_DAEMON} ]] && "${PORTAGE_BIN_PATH}"/ebuild-ipc exit 1

	# subshell die support
	if [[ -n ${EBUILD_MASTER_PID} && ${BASHPID} != "${EBUILD_MASTER_PID}" ]] ; then
		kill -s SIGTERM "${EBUILD_MASTER_PID}"
	fi
	exit 1
}

__quiet_mode() {
	[[ ${PORTAGE_QUIET} -eq 1 ]]
}

__vecho() {
	__quiet_mode || echo "$@" >&2
}

# Internal logging function, don't use this in ebuilds
__elog_base() {
	local messagetype=$1
	shift

	if [[ ${EBUILD_PHASE} == depend && -z ${__PORTAGE_ELOG_BANNER_OUTPUT} ]]; then
		# in depend phase, we want to output a banner indicating which
		# package emitted the message
		printf >&2 '\nMessages for package %s%s%s:\n' \
			"${PORTAGE_COLOR_INFO}" "${CATEGORY}/${PF}::${PORTAGE_REPO_NAME}" "${PORTAGE_COLOR_NORMAL}"
		__PORTAGE_ELOG_BANNER_OUTPUT=1
	fi
	[[ -z "${1}" || -z "${T}" || ! -d "${T}/logging" ]] && return 1
	echo -e "$@" | while read -r ; do
		echo "${messagetype} ${REPLY}"
	done >> "${T}/logging/${EBUILD_PHASE:-other}"
	return 0
}

eqawarn() {
	__elog_base QA "$*"
	[[ ${RC_ENDCOL} != "yes" && ${LAST_E_CMD} == "ebegin" ]] && echo >&2
	echo -e "$@" | while read -r ; do
		echo " ${PORTAGE_COLOR_QAWARN}*${PORTAGE_COLOR_NORMAL} ${REPLY}"
	done >&2
	LAST_E_CMD="eqawarn"
	return 0
}

elog() {
	__elog_base LOG "$*"
	[[ ${RC_ENDCOL} != "yes" && ${LAST_E_CMD} == "ebegin" ]] && echo >&2
	echo -e "$@" | while read -r ; do
		echo " ${PORTAGE_COLOR_LOG}*${PORTAGE_COLOR_NORMAL} ${REPLY}"
	done >&2
	LAST_E_CMD="elog"
	return 0
}

einfo() {
	__elog_base INFO "$*"
	[[ ${RC_ENDCOL} != "yes" && ${LAST_E_CMD} == "ebegin" ]] && echo >&2
	echo -e "$@" | while read -r ; do
		echo " ${PORTAGE_COLOR_INFO}*${PORTAGE_COLOR_NORMAL} ${REPLY}"
	done >&2
	LAST_E_CMD="einfo"
	return 0
}

einfon() {
	__elog_base INFO "$*"
	[[ ${RC_ENDCOL} != "yes" && ${LAST_E_CMD} == "ebegin" ]] && echo >&2
	echo -ne " ${PORTAGE_COLOR_INFO}*${PORTAGE_COLOR_NORMAL} $*" >&2
	LAST_E_CMD="einfon"
	return 0
}

ewarn() {
	__elog_base WARN "$*"
	[[ ${RC_ENDCOL} != "yes" && ${LAST_E_CMD} == "ebegin" ]] && echo >&2
	echo -e "$@" | while read -r ; do
		echo " ${PORTAGE_COLOR_WARN}*${PORTAGE_COLOR_NORMAL} ${RC_INDENTATION}${REPLY}"
	done >&2
	LAST_E_CMD="ewarn"
	return 0
}

eerror() {
	__elog_base ERROR "$*"
	[[ ${RC_ENDCOL} != "yes" && ${LAST_E_CMD} == "ebegin" ]] && echo >&2
	echo -e "$@" | while read -r ; do
		echo " ${PORTAGE_COLOR_ERR}*${PORTAGE_COLOR_NORMAL} ${RC_INDENTATION}${REPLY}"
	done >&2
	LAST_E_CMD="eerror"
	return 0
}

ebegin() {
	local msg="$*" dots spaces=${RC_DOT_PATTERN//?/ }
	if [[ -n ${RC_DOT_PATTERN} ]] ; then
		printf -v dots "%$(( COLS - 3 - ${#RC_INDENTATION} - ${#msg} - 7 ))s" ''
		dots=${dots//${spaces}/${RC_DOT_PATTERN}}
		msg="${msg}${dots}"
	else
		msg="${msg} ..."
	fi
	einfon "${msg}"
	[[ ${RC_ENDCOL} == "yes" ]] && echo >&2
	LAST_E_LEN=$(( 3 + ${#RC_INDENTATION} + ${#msg} ))
	LAST_E_CMD="ebegin"
	(( ++__EBEGIN_EEND_COUNT ))
	return 0
}

__eend() {
	local retval=${1:-0} efunc=${2:-eerror} msg
	shift 2

	if [[ ${retval} == "0" ]] ; then
		msg="${PORTAGE_COLOR_BRACKET}[ ${PORTAGE_COLOR_GOOD}ok${PORTAGE_COLOR_BRACKET} ]${PORTAGE_COLOR_NORMAL}"
	else
		if [[ -n $* ]] ; then
			${efunc} "$*"
		fi
		msg="${PORTAGE_COLOR_BRACKET}[ ${PORTAGE_COLOR_BAD}!!${PORTAGE_COLOR_BRACKET} ]${PORTAGE_COLOR_NORMAL}"
	fi

	if [[ ${RC_ENDCOL} == "yes" ]] ; then
		echo -e "${ENDCOL} ${msg}" >&2
	else
		[[ ${LAST_E_CMD} == ebegin ]] || LAST_E_LEN=0
		printf "%$(( COLS - LAST_E_LEN - 7 ))s%b\n" '' "${msg}" >&2
	fi

	return "${retval}"
}

eend() {
	[[ -n ${1} ]] || die "${FUNCNAME}(): Missing argument"
	local retval=${1}
	shift
	if (( --__EBEGIN_EEND_COUNT < 0 )); then
		__EBEGIN_EEND_COUNT=0
		eqawarn "QA Notice: eend called without preceding ebegin in ${FUNCNAME[1]}"
	fi

	__eend "${retval}" eerror "$*"

	LAST_E_CMD="eend"
	return "${retval}"
}

__unset_colors() {
	COLS=80
	ENDCOL=

	PORTAGE_COLOR_BAD=
	PORTAGE_COLOR_BRACKET=
	PORTAGE_COLOR_ERR=
	PORTAGE_COLOR_GOOD=
	PORTAGE_COLOR_HILITE=
	PORTAGE_COLOR_INFO=
	PORTAGE_COLOR_LOG=
	PORTAGE_COLOR_NORMAL=
	PORTAGE_COLOR_QAWARN=
	PORTAGE_COLOR_WARN=
}

__set_colors() {
	# bash's internal COLUMNS variable
	COLS=${COLUMNS:-0}

	# Avoid wasteful stty calls during the "depend" phases.
	# If stdout is a pipe, the parent process can export COLUMNS
	# if it's relevant. Use an extra subshell for stty calls, in
	# order to redirect "/dev/tty: No such device or address"
	# error from bash to /dev/null.
	[[ ${COLS} == 0 && ${EBUILD_PHASE} != depend ]] && \
		COLS=$(set -- $( ( stty size </dev/tty ) 2>/dev/null || echo 24 80 ) ; echo $2)
	(( COLS > 0 )) || (( COLS = 80 ))

	# Now, ${ENDCOL} will move us to the end of the
	# column; regardless of character width
	ENDCOL=$'\e[A\e['$(( COLS - 8 ))'C'
	# shellcheck disable=2034
	if [[ ${PORTAGE_COLORMAP} ]]; then
		# The PORTAGE_COLORMAP environment variable is defined by the
		# doebuild.py unit and is intended to be evaluated as code.
		eval "${PORTAGE_COLORMAP}"
	else
		PORTAGE_COLOR_BAD=$'\e[31;01m'
		PORTAGE_COLOR_BRACKET=$'\e[34;01m'
		PORTAGE_COLOR_ERR=$'\e[31;01m'
		PORTAGE_COLOR_GOOD=$'\e[32;01m'
		PORTAGE_COLOR_HILITE=$'\e[36;01m'
		PORTAGE_COLOR_INFO=$'\e[32m'
		PORTAGE_COLOR_LOG=$'\e[32;01m'
		PORTAGE_COLOR_NORMAL=$'\e[0m'
		PORTAGE_COLOR_QAWARN=$'\e[33m'
		PORTAGE_COLOR_WARN=$'\e[33;01m'
	fi
}

RC_ENDCOL="yes"
RC_INDENTATION=''
RC_DOT_PATTERN=''



if [[ -z ${NO_COLOR} ]] ; then
	case ${NOCOLOR:-false} in
	yes|true)
		__unset_colors
		;;
	no|false)
		__set_colors
		;;
	esac
else
	__unset_colors
fi


if [[ -z ${USERLAND} ]] ; then
	case $(uname -s) in
	*BSD|DragonFly)
		export USERLAND="BSD"
		;;
	*)
		export USERLAND="GNU"
		;;
	esac
fi

if [[ -z ${XARGS} ]] ; then
	if XARGS=$(type -P gxargs); then
		export XARGS+=" -r"
	elif : | xargs -r 2>/dev/null; then
		export XARGS="xargs -r"
	else
		export XARGS="xargs"
	fi
fi

___makeopts_jobs() {
	local LC_ALL LC_COLLATE=C ere jobs

	ere='.*[[:space:]](-[A-Ia-iK-Zk-z]*j[[:space:]]*|--jobs(=|[[:space:]]+))([0-9]+)[[:space:]]'

	if [[ " ${MAKEOPTS} " =~ $ere ]]; then
		jobs=$(( 10#${BASH_REMATCH[3]} ))
	elif jobs=$({ getconf _NPROCESSORS_ONLN || sysctl -n hw.ncpu; } 2>/dev/null); then
		:
	else
		jobs=1
	fi

	printf '%s\n' "${jobs}"
}

# Considers the positional parameters as comprising a simple command, which
# shall be executed for each null-terminated record read from the standard
# input. For each record processed, its value shall be taken as an additional
# parameter to append to the command. Commands shall be executed in parallel,
# with the maximal degree of concurrency being determined by the output of the
# ___makeopts_jobs function. Thus, the behaviour is quite similar to that of
# xargs -0 -L1 -P"$(___makeopts_jobs)".
#
# If no records are read, or if all commands complete successfully, the return
# value shall be 0. Otherwise, the return value shall be that of the last
# reaped command that produced a non-zero exit status. As soon as any command
# fails, no further records shall be read, nor any further commands executed.
___parallel() (
	local max_procs retval arg i

	max_procs=$(___makeopts_jobs)
	retval=0

	while IFS= read -rd '' arg; do
		if (( i >= max_procs )); then
			wait -n
			case $? in
				0) (( i-- )) ;;
				*) retval=$?; (( i-- )); break
			esac
		fi
		"$@" "${arg}" & (( ++i ))
	done

	while (( i-- )); do
		wait -n
		case $? in
			0) ;;
			*) retval=$?
		esac
	done

	return "${retval}"
)

hasq() {
	___eapi_has_hasq || die "'${FUNCNAME}' banned in EAPI ${EAPI}"

	eqawarn "QA Notice: The 'hasq' function is deprecated (replaced by 'has')"
	has "$@"
}

hasv() {
	___eapi_has_hasv || die "'${FUNCNAME}' banned in EAPI ${EAPI}"

	if has "$@" ; then
		echo "$1"
		return 0
	fi
	return 1
}

# Determines whether the first parameter is stringwise equal to any of the
# following parameters. Do NOT use this function for checking whether a word is
# contained by another string. For that, use contains_word() instead.
has() {
	local needle=$1
	shift

	local x
	for x in "$@"; do
		[[ "${x}" = "${needle}" ]] && return 0
	done
	return 1
}

__repo_attr() {
	local in_section exit_status=1 line saved_extglob_shopt=$(shopt -p extglob)
	shopt -s extglob

	while read -r line; do
		if (( ! in_section )) && [[ ${line} == "[$1]" ]]; then
			in_section=1
		elif (( in_section )) && [[ ${line} == "["*"]" ]]; then
			in_section=0
		elif (( in_section )) && [[ ${line} =~ ^${2}[[:space:]]*= ]]; then
			echo "${line##$2*( )=*( )}"
			exit_status=0
			break
		fi
	done <<< "${PORTAGE_REPOSITORIES}"

	eval "${saved_extglob_shopt}"
	return ${exit_status}
}

# eqaquote <string>
#
# outputs parameter escaped for quoting
__eqaquote() {
	local v=${1} esc=''

	# quote backslashes
	v=${v//\\/\\\\}
	# quote the quotes
	v=${v//\"/\\\"}
	# quote newlines
	while read -r; do
		echo -n "${esc}${REPLY}"
		esc='\n'
	done <<<"${v}"
}

# eqatag <tag> [-v] [<key>=<value>...] [/<relative-path>...]
#
# output (to qa.log):
# - tag: <tag>
#   data:
#     <key1>: "<value1>"
#     <key2>: "<value2>"
#   files:
#     - "<path1>"
#     - "<path2>"
__eqatag() {
	local tag i filenames=() data=() verbose=

	if [[ ${1} == -v ]]; then
		verbose=1
		shift
	fi

	tag=${1}
	shift
	[[ -n ${tag} ]] || die "${FUNCNAME}: no tag specified"

	# collect data & filenames
	for i; do
		if [[ ${i} == /* ]]; then
			filenames+=( "${i}" )
			[[ -n ${verbose} ]] && eqawarn "  ${i}"
		elif [[ ${i} == *=* ]]; then
			data+=( "${i}" )
		else
			die "${FUNCNAME}: invalid parameter: ${i}"
		fi
	done

	(
		echo "- tag: ${tag}"
		if [[ ${#data[@]} -gt 0 ]]; then
			echo "  data:"
			for i in "${data[@]}"; do
				echo "    ${i%%=*}: \"$(__eqaquote "${i#*=}")\""
			done
		fi
		if [[ ${#filenames[@]} -gt 0 ]]; then
			echo "  files:"
			for i in "${filenames[@]}"; do
				echo "    - \"$(__eqaquote "${i}")\""
			done
		fi
	) >> "${T}"/qa.log
}

# debug-print() gets called from many places with verbose status information useful
# for tracking down problems. The output is in ${T}/eclass-debug.log.
# You can set ECLASS_DEBUG_OUTPUT to redirect the output somewhere else as well.
# The special "on" setting echoes the information, mixing it with the rest of the
# emerge output.
# You can override the setting by exporting a new one from the console, or you can
# set a new default in make.*. Here the default is "" or unset.
#
# (TODO: in the future, might use e* from /lib/gentoo/functions.sh?)
debug-print() {
	# If ${T} isn't defined, we're in dep calculation mode and
	# shouldn't do anything
	[[ ${EBUILD_PHASE} = depend || ! -d ${T} || ${#} -eq 0 ]] && return 0

	if [[ ${ECLASS_DEBUG_OUTPUT} == on ]]; then
		printf 'debug: %s\n' "${@}" >&2
	elif [[ -n ${ECLASS_DEBUG_OUTPUT} ]]; then
		printf 'debug: %s\n' "${@}" >> "${ECLASS_DEBUG_OUTPUT}"
	fi

	if [[ -w ${T} ]] ; then
		# Default target
		printf '%s\n' "${@}" >> "${T}/eclass-debug.log"

		# Let the portage user own/write to this file
		chgrp "${PORTAGE_GRPNAME:-portage}" "${T}/eclass-debug.log"
		chmod g+w "${T}/eclass-debug.log"
	fi
}

# The following 2 functions are debug-print() wrappers

debug-print-function() {
	debug-print "${1}: entering function, parameters: ${*:2}"
}

debug-print-section() {
	debug-print "now in section ${*}"
}

# Considers the first parameter as a word and the second parameter as a string
# comprising zero or more whitespace-separated words before determining whether
# said word can be matched against any of them. It addresses a use case for
# which the has() function is commonly misappropriated, with maximal efficiency.
contains_word() {
	local IFS
	[[ $1 == +([![:space:]]) && " ${*:2} " == *[[:space:]]"$1"[[:space:]]* ]]
}

# Invoke GNU find(1) in such a way that the paths to be searched are consumed
# as a list of one or more null-terminated records from STDIN. The positional
# parameters shall be conveyed verbatim and are guaranteed to be treated as
# options and/or primaries, provided that the version of GNU findutils is 4.9.0
# or greater. For older versions, no such guarantee is made.
if printf '/\0' | find -files0-from - -maxdepth 0 &>/dev/null; then
	find0() {
		find -files0-from - "$@"
	}
else
	# This is a temporary workaround for the GitHub CI runner, which
	# suffers from an outdated version of findutils, per bug 957550.
	find0() {
		local -a opts paths

		# All of -H, -L and -P are options. If specified, they must
		# precede pathnames and primaries alike.
		while [[ $1 == -[HLP] ]]; do
			opts+=("$1")
			shift
		done
		mapfile -td '' paths
		if (( ${#paths[@]} )); then
			find "${opts[@]}" "${paths[@]}" "$@"
		fi
	}
fi

true
