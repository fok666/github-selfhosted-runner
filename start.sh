#!/bin/bash
set -e

if [ -z "$GITHUB_URL" ]; then
  echo 1>&2 "error: missing GITHUB_URL environment variable"
  exit 1
fi

if [ -z "$GITHUB_TOKEN_FILE" ]; then
  if [ -z "$GITHUB_TOKEN" ]; then
    echo 1>&2 "error: missing GITHUB_TOKEN environment variable"
    exit 1
  fi

  GITHUB_TOKEN_FILE=/runner/.token
  echo -n $GITHUB_TOKEN > "$GITHUB_TOKEN_FILE"
fi

unset GITHUB_TOKEN

if [ -n "$RUNNER_WORK_DIRECTORY" ]; then
  mkdir -p "$RUNNER_WORK_DIRECTORY"
fi

export AGENT_ALLOW_RUNASROOT="1"

cleanup() {
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing GitHub Runner..."

    # If the agent has some running jobs, the configuration removal process will fail.
    # So, give it some time to finish the job.
    while true; do
      ./config.sh remove --token $(cat "$GITHUB_TOKEN_FILE") && break

      echo "Retrying in 30 seconds..."
      sleep 30
    done
  fi
}

print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$1${nocolor}"
}

# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE=GITHUB_TOKEN,GITHUB_TOKEN_FILE

print_header "1. Configuring GitHub Runner..."

./config.sh --unattended \
  --name "${RUNNER_NAME:-$(hostname)}" \
  --url "$GITHUB_URL" \
  --token $(cat "$GITHUB_TOKEN_FILE") \
  --labels "${RUNNER_LABELS:-default}" \
  --work "${RUNNER_WORK_DIRECTORY:-_work}" \
  --replace

print_header "2. Running GitHub Runner..."

trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# To be aware of TERM and INT signals call run.sh
# Running it with the --once flag at the end will shut down the agent after the build is executed
./run.sh "$@"
