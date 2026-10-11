FROM ruby:4.0-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without test \
 && bundle install --jobs 4

FROM ruby:4.0-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --system outbox && useradd --system --gid outbox --create-home outbox \
 && mkdir -p /data/repos /data/keys && chown -R outbox:outbox /data
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=outbox:outbox . .

ENV OUTBOX_DATA=/data \
    RACK_ENV=production \
    HOME=/home/outbox
VOLUME /data
EXPOSE 8080
USER outbox
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:8080", "config.ru"]
