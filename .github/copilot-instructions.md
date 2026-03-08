# GitHub Copilot Instructions for GitHub Self-Hosted Runner

## Project Overview

This project builds and publishes multi-profile Docker images for running **GitHub Actions self-hosted runners** on Linux (Ubuntu 24.04). Images are multi-architecture (amd64/arm64), built using a multi-stage Dockerfile optimized for maximum layer reusability, and published to both Docker Hub and GitHub Container Registry (GHCR).

**Key files:**

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build definition (all profiles) |
| `run.sh` | Launches N runner containers on a VM |
| `start.sh` | Entrypoint executed inside the container |
| `stop.sh` | Graceful runner deregistration |
| `test-tools.sh` | Smoke-tests installed tools at build time |
| `vmss_monitor.sh` | Handles Azure VMSS termination events |
| `ec2_monitor.sh` | Handles AWS EC2 spot-interruption notices |
| `checkRunnerVersion.sh` | Fetches latest GitHub Actions Runner release version |
| `ARCHITECTURE.md` | Deep-dive into multi-stage build design |

## Repository Structure

```
.
├── Dockerfile              # Multi-stage build (base → common → … → profiles)
├── run.sh                  # VM-side launcher
├── start.sh                # Container entrypoint
├── stop.sh                 # Graceful shutdown / deregistration
├── test-tools.sh           # Tool smoke tests
├── vmss_monitor.sh         # Azure VMSS termination handler
├── ec2_monitor.sh          # AWS EC2 spot termination handler
├── checkRunnerVersion.sh   # Latest version helper
├── ARCHITECTURE.md         # Build architecture documentation
└── .github/
    ├── copilot-instructions.md
    ├── dependabot.yml
    └── workflows/
        ├── docker-image.yml        # Main CI: build, test, push multi-arch images
        ├── docker-hub-release.yml  # Publish release tags to Docker Hub
        ├── docker-automate.yaml    # Port.io-triggered automation workflow
        └── version-check.yml      # Scheduled upstream version checker
```

## Docker Image Profiles

| Profile | Size | Description | Included Tools |
|---------|------|-------------|----------------|
| **minimal** | ~550 MB | Essential tools only | GitHub Runner, sudo |
| **k8s** | ~850 MB | Kubernetes-focused | + Docker, kubectl, kubelogin, kustomize, Helm, jq, yq |
| **iac** | ~1.75 GB | Infrastructure as Code (bash) | + Docker, Azure CLI, AWS CLI, Terraform, OpenTofu, Terraspace, jq, yq |
| **iac-pwsh** | ~2.25 GB | IaC with PowerShell | + PowerShell (Az + AWS modules) |
| **full** | ~2.45 GB | All tools | k8s + iac-pwsh combined |

### Multi-Stage Build Layer Hierarchy

```
base (Ubuntu 24.04 + GitHub Actions Runner)
└── common (+ sudo)
    ├── minimal  ← PROFILE
    └── docker-tools (+ Docker, jq, yq)
        ├── k8s-tools (+ kubectl, kubelogin, kustomize, Helm)
        │   └── k8s  ← PROFILE
        └── cloud-tools (+ Azure CLI, AWS CLI)
            └── iac-tools (+ Terraform, OpenTofu, Terraspace)
                ├── iac  ← PROFILE
                └── pwsh-tools (+ PowerShell + Az/AWS modules)
                    ├── iac-pwsh  ← PROFILE
                    └── full-tools (+ k8s tools copied)
                        └── full  ← PROFILE
```

The GitHub Actions runner binary is extracted from the official release tarball and `installdependencies.sh` is called during the `base` stage — do not move this to a later stage.

## Common Commands

```bash
# Build a specific profile locally
docker build --target minimal -t github-runner:minimal .
docker build --target full   -t github-runner:full .

# Multi-arch build (requires buildx)
docker buildx build --platform linux/amd64,linux/arm64 --target full \
  -t ghcr.io/fok666/github-selfhosted-runner:latest-full .

# Run runners on a VM (auto-detects CPU count)
./run.sh <IMAGE> <GITHUB_URL> <GITHUB_TOKEN> [LABELS] [COUNT]
# Example:
./run.sh github-runner:2.321.0 https://github.com/myorg/myrepo ghs-xxxx "self-hosted,linux" 4

# Check latest upstream runner version
./checkRunnerVersion.sh

# Smoke-test tools inside a running container
docker exec <CONTAINER> /test-tools.sh
```

## Architecture Patterns & Coding Standards

### Dockerfile Guidelines

- **Stage naming**: use lowercase kebab-case (`base`, `common`, `docker-tools`, etc.)
- **Final profile stages** are named after the profile: `minimal`, `k8s`, `iac`, `iac-pwsh`, `full`
- **COPY --from**: use named stages, never numeric indices
- **ARG scope**: re-declare `ARG TARGETARCH` in any stage that references it; GitHub runner archive uses `x64` for amd64
- **Version pinning**: all tool versions are controlled via `ARG` at the top of the `base` stage
- **Cleanup**: always end `RUN` blocks that call `apt-get` with `&& apt clean && rm -rf /var/lib/apt/lists/*`
- **WORKDIR**: the runner is installed to `/runner`; do not change this — `start.sh` relies on it

```dockerfile
# Pattern for mapping TARGETARCH to runner arch convention
RUN RUNNER_ARCH=$([ "${TARGETARCH}" = "amd64" ] && echo "x64" || echo "arm64") && \
    curl -LsS "https://github.com/actions/runner/releases/download/v${AGENT_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${AGENT_VERSION}.tar.gz" | tar -xz \
    && ./bin/installdependencies.sh
```

### Shell Script Guidelines

- Always start with `#!/bin/bash` and `set -e`
- Validate all required parameters before using them; print `USAGE_HELP` and `exit 1` on failure
- Auto-detect CPU count; cap CPUs per runner at 2 (`MAX_CPU=$((CPU_COUNT > 1 ? 2 : 1))`)
- Use `jq` to safely construct JSON payloads — never string-concatenate JSON
- Token/URL validation: use regex guards (`[[ "$URL" =~ ^https?://... ]]`)

### Workflow Guidelines

- Use specific action versions (`@v6`, `@v4`, etc.) — never `@latest`
- Set `timeout-minutes` on all jobs
- Use `>> $GITHUB_OUTPUT` (not `set-output`) for step outputs
- Matrix strategy for profiles and platforms:
  - **PR builds**: `full` profile only, both `linux/amd64` + `linux/arm64`
  - **Push to main**: all profiles, `linux/amd64` only
- Always use `actions/checkout@v6` as the first step

```yaml
# Correct output pattern
- name: Extract version
  id: ver
  run: echo "version=2.321.0" >> $GITHUB_OUTPUT

- run: echo "Version is ${{ steps.ver.outputs.version }}"
```

## Test-Tools Smoke Test Pattern

`test-tools.sh` uses `command -v <tool>` guards so it is safe to run in any profile:

```bash
if command -v gh &> /dev/null; then
    echo "Testing GitHub CLI..."
    gh --version
    echo "GitHub CLI: OK"
fi
```

When adding a new tool, add a corresponding guarded test block to `test-tools.sh`.

## Versioning & Release

- Runner version is controlled by `ARG AGENT_VERSION=<version>` in the Dockerfile
- To release a new version: update `AGENT_VERSION` in the Dockerfile **or** pass it as a workflow input/repository variable
- Image tags follow the pattern: `latest-<profile>`, `<version>-<profile>`, `<version>-<profile>-<date>`
- `checkRunnerVersion.sh` fetches the latest release from GitHub Releases (redirects to the tag URL)

## VMSS / EC2 Termination Handling

- `vmss_monitor.sh`: polls Azure IMDS (`169.254.169.254`) for `Terminate` scheduled events; calls `stop.sh` and acknowledges the event using `jq`-built JSON
- `ec2_monitor.sh`: polls AWS IMDS for spot-interruption notices; calls `stop.sh`
- `stop.sh`: deregisters the runner from GitHub and stops the container gracefully
- These scripts are designed to run from a cron job or systemd timer on the host VM

## Common Pitfalls

- **TARGETARCH vs runner arch**: GitHub runner archives use `x64` (not `amd64`) — always map with `$([ "${TARGETARCH}" = "amd64" ] && echo "x64" || echo "arm64")`
- **Runner registration token vs PAT**: `run.sh` expects a short-lived registration token (starts with `ghs-` or `ghp-`), not a PAT
- **Layer order**: put the heaviest stable layers earliest (AWS CLI, Azure CLI before Terraform)
- **Do not add tools to `base`**: the base stage is 100% shared; tool installation belongs in dedicated intermediate stages
- **Do not hardcode credentials**: use `${{ secrets.* }}` in workflows; environment variables in shell scripts
- **GHCR visibility**: ensure the package is set to public in GitHub organization/user settings
- **Port.io workflow** (`docker-automate.yaml`): requires `PORT_CLIENT_ID` and `PORT_CLIENT_SECRET` repository secrets

## Adding a New Tool

1. Decide which existing stage to build on (usually `docker-tools` or `cloud-tools`)
2. Create a new intermediate stage (e.g., `my-tool`)
3. Rebuild dependent profile stages referencing the new stage as their base
4. Add a guarded test block in `test-tools.sh`
5. Update profile size estimates in `README.md` and `ARCHITECTURE.md`
6. Update the workflow matrix in `docker-image.yml` to include/test the new tool flag

## Security Considerations

- Never open SSH in Docker images — access via `docker exec` or platform tooling
- `NOPASSWD:ALL` sudo is a conscious trade-off for CI/CD automation; document any changes
- Use `--no-install-recommends` in all `apt-get install` calls to minimize attack surface
- Prefer downloading binaries from official GitHub releases over third-party PPAs
- All tokens must come from environment variables or GitHub Secrets — never bake them into images
- The runner registration token is short-lived; `stop.sh` handles deregistration to avoid orphaned runners

## References

- [GitHub Actions Runner](https://github.com/actions/runner)
- [GitHub Actions Self-Hosted Runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)
- [Docker Hub: fok666/github-runner](https://hub.docker.com/r/fok666/github-runner)
- [GitHub Container Registry](https://ghcr.io/fok666/github-selfhosted-runner)
- [Azure VMSS Scheduled Events](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/scheduled-events)
- [AWS EC2 Spot Interruption Notices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
