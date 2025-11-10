# cert-sync-controller Image
# Contains kubectl, SSH client, and other required tools
FROM alpine:3.18

# System updates
RUN apk --no-cache update && apk --no-cache upgrade

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    openssh-client \
    openssl \
    jq \
    ca-certificates \
    netcat-openbsd

# Install kubectl (multi-platform support)
ARG TARGETARCH
RUN curl -LO "https://dl.k8s.io/release/v1.28.4/bin/linux/${TARGETARCH}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/ && \
    kubectl version --client

# Create non-root user
RUN adduser -D -u 1000 cert-sync

# Set working directory
WORKDIR /app

# Copy entrypoint script
COPY --chown=cert-sync:cert-sync entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Prepare workdir and private temp directory
RUN mkdir -p /home/cert-sync/.kube /home/cert-sync/.ssh /home/cert-sync/.cache/cert-sync \
 && chown -R cert-sync:cert-sync /app /home/cert-sync \
 && chmod 700 /home/cert-sync/.ssh /home/cert-sync/.cache/cert-sync

ENV HOME=/home/cert-sync
ENV KUBECONFIG=/home/cert-sync/.kube/config

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD nc -z localhost 8080 || exit 1

# Switch to non-root user
USER cert-sync

# Default command
ENTRYPOINT ["/app/entrypoint.sh"]

LABEL maintainer="leetsheep"
LABEL org.opencontainers.image.title="cert-sync-controller"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.description="A controller that discovers TLS certificates from Kubernetes Ingress and syncs them to remote"
LABEL org.opencontainers.image.source="https://github.com/leetsheep/"