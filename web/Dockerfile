# syntax=docker/dockerfile:1

FROM node:22.22-alpine@sha256:e58326d0d441090181ac150dc2078d3e2cf6a0d42e809aebba3ef5880935ffdd AS build

WORKDIR /app

ARG VITE_API_URL=/api/v1
ARG VITE_AUTH_ENABLED=true
ARG VITE_CLERK_PUBLISHABLE_KEY
ENV VITE_API_URL=${VITE_API_URL}
ENV VITE_AUTH_ENABLED=${VITE_AUTH_ENABLED}
ENV VITE_CLERK_PUBLISHABLE_KEY=${VITE_CLERK_PUBLISHABLE_KEY}

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM caddy:2.10-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d

COPY Caddyfile.staging /etc/caddy/Caddyfile
COPY --from=build /app/dist /srv

EXPOSE 8080
