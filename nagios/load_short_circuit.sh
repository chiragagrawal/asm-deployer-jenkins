#!/bin/bash

load=2
verbose=0
silent=0
command=""
skip_message=""
skip_exit_code=0
load_avg_file="/proc/loadavg"

function show_help() {
cat << EOF
Usage: ${0##*/} [-hv] [-l LOAD] -c [COMMAND]

Only runs COMMAND when the system load average is below LOAD.

When no COMMAND is given the script will just exit with the appropriate code
so that you can inline it with other commands like:

   ${0##*/} -c 2 -e 1 && do_something

To only run the do_something command when the load average is less than 2

  -h          display this help and exit
  -v          be verbose
  -s          do not produce any output except for errors
  -e CODE     exit as CODE when the execution is being skipped (${skip_exit_code})
  -m MESSAGE  message to print when execution is being skipped
  -f FILE     file to source the load average from, override for testing (${load_avg_file})
  -l LOAD     load average below which to run commands (${load})
  -c COMMAND  command to run
EOF
}

function debug() {
  if [[ $verbose -eq 1 ]]
  then
    echo $1 >&2
  fi
}

function say() {
  if [[ $silent -eq 0 ]]
  then
    echo $1
  fi
}

while getopts "shvl:c:e:m:f:" opt; do
  case $opt in
    h)
      show_help
      exit 1
      ;;
    v)
      verbose=1
      ;;
    s)
      silent=1
      ;;
    c)
      command="${OPTARG}"
      ;;
    l)
      load="${OPTARG}"
      ;;
    e)
      skip_exit_code="${OPTARG}"
      ;;
    m)
      skip_message="${OPTARG}"
      ;;
    f)
      load_avg_file="${OPTARG}"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

if ! printf %f "$load" >/dev/null 2>&1
then
  echo "The load average specified in -l should be a integer or float" >&2
  show_help
  exit 1
fi

if ! printf %d "$skip_exit_code" >/dev/null 2>&1
then
  echo "The exit code specified in -e should be a integer" >&2
  show_help
  exit 1
fi

if [[ ! -f $load_avg_file ]]
then
  echo "The load average file ${load_avg_file} cannot be found" >&2
  show_help
  exit 1
fi

read -d " " system_load < $load_avg_file

debug "System load sourced from ${load_avg_file} is ${system_load} and will be checked against a maximum load of ${load}"
if [[ ! -z $command ]]
then
  debug "Command to be run: ${command}" >&2
fi

if [[ $system_load > $load ]]
then
  if [[ -z $skip_message ]]
  then
    say "Skipping the run due to load average ${system_load} being greater than ${load}"
  else
    say "${skip_message}"
  fi

  exit $skip_exit_code
else
  if [[ -z $command ]]
  then
    debug "No command given so exiting 0 while load below ${load}"
    exit 0
  else
    debug "Running command: ${command}"
    exec $command
  fi
fi
