# syntax=docker/dockerfile:1

ARG NODE_VERSION=22

# ---------------------------------------------------------------------------
# Stage 1 - build: install ALL dependencies and compile TypeScript to JavaScript.
# Nothing from this stage except the compiled output reaches the final image.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS build
WORKDIR /app

# Copy only the manifests first: this layer (and the install below) is cached
# until dependencies change, not on every source change.
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

COPY tsconfig.json ./
COPY src ./src
RUN yarn build \
    # keep only the compiled JavaScript; sources and source maps are not needed at runtime
    && find src -type f \( -name '*.ts' -o -name '*.map' \) -delete

# ---------------------------------------------------------------------------
# Stage 2 - prod-deps: runtime dependencies only (no typescript, no ts-node-dev).
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS prod-deps
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile --production \
    && yarn cache clean

# ---------------------------------------------------------------------------
# Stage 3 - runtime: the image that is published and run.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS runtime

LABEL org.opencontainers.image.title="posts-api" \
      org.opencontainers.image.description="Sample Express + TypeORM posts API" \
      org.opencontainers.image.licenses="MIT"

# The database connection (TYPEORM_HOST, TYPEORM_PORT, TYPEORM_USERNAME, TYPEORM_PASSWORD,
# TYPEORM_DATABASE) is injected at runtime; src/data-source.js describes everything else.
ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

COPY --from=prod-deps --chown=1000:1000 /app/node_modules ./node_modules
COPY --from=build --chown=1000:1000 /app/src ./src
COPY --chown=1000:1000 package.json ./

# Numeric UID/GID on purpose: Kubernetes can only verify "runAsNonRoot"
# when the user is numeric (1000 is the built-in "node" user of the base image).
USER 1000:1000

EXPOSE 3000

# Exec form: node is PID 1 and receives SIGTERM directly (graceful shutdown).
# Migrations use the same image with a different command:
#   node node_modules/typeorm/cli.js migration:run -d src/data-source.js
CMD ["node", "src/index.js"]
