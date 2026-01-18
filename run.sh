#!/bin/bash
set -e

# GitHub Self-Hosted Runner Script
# Reference: https://docs.github.com/en/actions/hosting-your-own-runners

RUNNER_IMAGE="$1"
GITHUB_URL="$2"
GITHUB_TOKEN="$3"
RUNNER_LABELS="${4:-default}"
RUNNER_COUNT="${5}"

USAGE_HELP="Usage: $0 <RUNNER_IMAGE> <GITHUB_URL> <GITHUB_TOKEN> [RUNNER_LABELS] [RUNNER_COUNT]

Parameters:
  RUNNER_IMAGE    - Docker image name for GitHub runner
  GITHUB_URL      - GitHub repository or organization URL
                    Examples:
                      - Repository: https://github.com/owner/repo
                      - Organization: https://github.com/organization
  GITHUB_TOKEN    - GitHub Personal Access Token or registration token
  RUNNER_LABELS   - Comma-separated labels for runner (default: 'default')
  RUNNER_COUNT    - Number of runner instances (default: auto-detect from CPU count)

Example:
  $0 ghcr.io/myorg/runner:latest https://github.com/myorg/myrepo ghp_xxxxxxxxxxxx \"self-hosted,linux\" 4
"

# Validate required parameters
if [ -z "$RUNNER_IMAGE" ]; then
  echo "Error: RUNNER_IMAGE is required"
  echo "$USAGE_HELP"
  exit 1
fi

if [ -z "$GITHUB_URL" ]; then
  echo "Error: GITHUB_URL is required"
  echo "$USAGE_HELP"
  exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
  echo "Error: GITHUB_TOKEN is required"
  echo "$USAGE_HELP"
  exit 1
fi

# Validate GitHub URL format
if [[ ! "$GITHUB_URL" =~ ^https://github\.com/[^/]+(/[^/]+)?$ ]]; then
  echo "Error: Invalid GITHUB_URL format. Must be https://github.com/owner/repo or https://github.com/organization"
  exit 1
fi

# Get total CPU count from the system
CPU_COUNT=$(lscpu -p=CPU | grep -v "^#" | wc -l 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "2")

# Set runner count (use provided value or default to CPU count)
RUNNER_COUNT=${RUNNER_COUNT:-$CPU_COUNT}

# Limit the number of vCPU count per runner to 2 when there are more than 1 vCPU available, cap it to 1 vCPU otherwise
MAX_CPU=$((CPU_COUNT > 1 ? 2 : 1))

# Get the Docker socket endpoint from current context
DOCKER_SOCK_ENDPOINT=$(docker context inspect 2>/dev/null | jq -r '.[]|.Endpoints.docker.Host' || echo "unix:///var/run/docker.sock")

# Extract socket path
DOCKER_SOCK_PATH=${DOCKER_SOCK_ENDPOINT#unix://}
DOCKER_SOCK_PATH=${DOCKER_SOCK_PATH:-/var/run/docker.sock}

echo "Starting $RUNNER_COUNT GitHub self-hosted runner(s)..."
echo "Image: $RUNNER_IMAGE"
echo "GitHub URL: $GITHUB_URL"
echo "Labels: $RUNNER_LABELS"
echo "CPUs per runner: $MAX_CPU"
echo ""

# Launch runners
for R in $(seq 1 "$RUNNER_COUNT"); do
  RUNNER_NAME="runner-$(hostname)-$R"
  WORK_DIR="/mnt/runner${R}/_work"
  CONTAINER_NAME="github-runner-$R"
  
  # Create work directory
  sudo mkdir -p "$WORK_DIR"
  
  echo "Starting runner $R/$RUNNER_COUNT: $RUNNER_NAME"
  
  # Check if container already exists
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "  Removing existing container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
  fi
  
  # Run GitHub runner container
  # SECURITY NOTE: --privileged mode grants extended privileges to the container.
  # This is required for Docker-in-Docker but poses security risks.
  # Consider using rootless Docker or Docker socket mounting as alternatives.
  # If --privileged is not needed for your use case, remove this flag.
  docker run \
    --privileged \
    --tty \
    --detach \
    --cpus="${MAX_CPU}" \
    -e GITHUB_URL="$GITHUB_URL" \
    -e GITHUB_TOKEN="$GITHUB_TOKEN" \
    -e RUNNER_NAME="$RUNNER_NAME" \
    -e RUNNER_LABELS="$RUNNER_LABELS" \
    -e RUNNER_WORK_DIRECTORY="/_work" \
    -v "$DOCKER_SOCK_PATH":/var/run/docker.sock \
    -v "$WORK_DIR":/_work \
    --restart unless-stopped \
    --name "$CONTAINER_NAME" \
    "$RUNNER_IMAGE"
  
  echo "  Container $CONTAINER_NAME started successfully"
done

echo ""
echo "All runners started successfully!"
echo ""
echo "To check runner status:"
echo "  docker ps --filter name=github-runner"
echo ""
echo "To view runner logs:"
echo "  docker logs -f github-runner-1"
echo ""
echo "To stop all runners:"
echo "  ./stop.sh"
