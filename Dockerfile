FROM docker.io/library/ruby:4.0-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without test \
 && bundle install --jobs 4

FROM docker.io/library/ruby:4.0-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Fixed uid so the git daemon container (a stock git image sharing the repos
# volume) can run as the same user.
RUN groupadd --gid 1000 outbox && useradd --uid 1000 --gid outbox --create-home outbox \
 && mkdir -p /data/repos /data/keys && chown -R outbox:outbox /data
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=outbox:outbox . .

ENV OUTBOX_DATA=/data \
    RACK_ENV=production \
    HOME=/home/outbox
VOLUME /data
EXPOSE 8080
# Starts as root to fix volume ownership, then runs as outbox. See bin/entrypoint.
ENTRYPOINT ["/app/bin/entrypoint"]
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:8080", "config.ru"]
