# ==============================================================================
# Build Stage
# ==============================================================================
FROM swift:6.0-jammy AS builder

WORKDIR /build

# Copy entire project
COPY . .

# Compile target executable in release mode
RUN swift build -c release --static-swift-stdlib

# ==============================================================================
# Runtime Stage
# ==============================================================================
FROM swift:6.0-jammy-slim

# Install additional runtime dependencies if needed
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    libsqlite3-0 \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the compiled binary from the builder stage
COPY --from=builder /build/.build/release/TelegramMirrorBot /app/TelegramMirrorBot

# Set default directories (can be overridden via environment variables)
RUN mkdir -p /downloads/temp /downloads/completed

# Set executable entrypoint
ENTRYPOINT ["/app/TelegramMirrorBot"]
