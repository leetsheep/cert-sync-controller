# GitHub Actions Workflows

## docker-build.yml

**What it does:**
- Extracts base image name from Dockerfile (e.g. alpine, ubuntu)
- Builds Docker image for amd64/arm64 platforms
- Scans image with Trivy for CVEs (fails on CRITICAL/HIGH)
- Uploads scan results to GitHub Security tab
- Pushes multi-platform image to Docker Hub with base image suffix
- Generates SBOM artifact

**Triggers:**
- Push to main branch → creates `latest` tag
- Git tags (e.g. `1.2.3`) → creates `1.2.3-alpine`, `1.2-alpine`, `1-alpine`, `latest`
- Pull requests (build/scan only, no push)
- Manual dispatch

## helm-release.yml

**What it does:**
- Packages Helm chart
- Publishes chart to GitHub Pages
- Creates GitHub release

**Triggers:**
- Push to main branch with changes in helm/ directory
- Manual dispatch
