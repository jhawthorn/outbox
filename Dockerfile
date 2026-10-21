FROM docker.io/library/node:24-slim AS assets
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY assets ./assets
RUN pnpm build

FROM docker.io/rubylang/ruby:master-dev-noble AS build
ENV GEM_HOME=/usr/local/bundle BUNDLE_APP_CONFIG=/usr/local/bundle
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without test \
 && bundle install --jobs 4

FROM docker.io/rubylang/ruby:master-noble
ENV GEM_HOME=/usr/local/bundle BUNDLE_APP_CONFIG=/usr/local/bundle
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Fixed uid so the git daemon container (a stock git image sharing the repos
# volume) can run as the same user.
# Ubuntu noble images ship an "ubuntu" user and group at 1000; drop it first.
RUN (id ubuntu >/dev/null 2>&1 && userdel --remove ubuntu || true) \
 && (getent group ubuntu >/dev/null && groupdel ubuntu || true) \
 && groupadd --gid 1000 outbox && useradd --uid 1000 --gid outbox --create-home outbox \
 && mkdir -p /data/repos /data/config.git && chown -R outbox:outbox /data
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=outbox:outbox . .
COPY --from=assets --chown=outbox:outbox /app/public/diffs ./public/diffs

ENV OUTBOX_DATA=/data \
    RACK_ENV=production \
    HOME=/home/outbox
VOLUME /data
EXPOSE 8080
# Starts as root to fix volume ownership, then runs as outbox. See bin/entrypoint.
ENTRYPOINT ["/app/bin/entrypoint"]
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:8080", "config.ru"]
