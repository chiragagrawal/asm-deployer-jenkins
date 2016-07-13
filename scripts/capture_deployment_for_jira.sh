#/bin/bash

deployment_id=""
deployment=""
tarout=""

function show_help() {
cat << EOF
Usage: ${0##*/} [-h] -d [DEPLOYMENT]

Captures all hardware, logs and JSON for a deployment and create
a tar file convenient for attatching to support tickets

The output will be in /tmp/deployment_<deployment id>.tgz

  -h            display this help and exit
  -d DEPLOYMENT the deployment ID to capture
EOF
}

function capture() {
  if [ -f "${deployment}" ]; then
    echo "Capturing deployment ${deployment}"
  else
    echo "Cannot find a deployment in ${deployment}" >&2
    exit 1
  fi

  if [ -f "${tarout}" ]; then
    echo "The tar file ${tarout} already exist, cannot continue" >&2
    exit 1
  fi

  _tmpdir="$(mktemp -d)"

  cd /opt/asm-deployer

  SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt RUBYLIB=lib PATH=/opt/jruby-1.7.8/bin:$PATH rake deployment:capture_hardware DEPLOYMENT="${deployment}" OUT="${_tmpdir}"

  tar --transform "s^${_tmpdir}^${deployment_id}^" -czPf "${tarout}" "${_tmpdir}"

  echo
  echo
  echo "Deployment have been saved to ${tarout}"

  cd -
}

if (($# == 0)); then
  show_help
  exit 1
fi

while getopts "d:h" opt;do
  case $opt in
    h)
      show_help
      exit 1
      ;;
    d)
      deployment_id="${OPTARG}"
      deployment="/opt/Dell/ASM/deployments/${OPTARG}/deployment.json"
      tarout="/tmp/deployment_${OPTARG}.tgz"

      capture
      ;;
    \?)
      show_help
      exit 1
      ;;
    :)
      show_help
      exit 1
      ;;
  esac
done
