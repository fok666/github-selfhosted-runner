# Shell & Docker Style Guide (GitHub Runner)

## Shell Scripting (Bash)
- Follow the **Google Shell Style Guide**.
- Start scripts with a shebang: `#!/bin/bash`.
- Use `set -e` or handle errors explicitly.
- Use `local` variables within functions.
- Quote variables: `"${GITHUB_TOKEN}"`.

## Docker
- Pin base image versions.
- Minimize image layers.
- Ensure the ENTRYPOINT script handles runner registration and deregistration securely.
- Avoid printing sensitive tokens to stdout/stderr.

## GitHub Actions Runner Specifics
- Do not run the runner as root unless explicitly required (e.g., for Docker-in-Docker, and even then, consider rootless docker).
- Ensure the startup script checks for runner updates or handles version compatibility.
- Validate `RUNNER_TOKEN` and `REPO_URL` availability before starting.
