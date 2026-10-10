# Image for the bot on Debian trixie (Ruby 3.3, standard library only).
#
# Configuration, data and secrets are never baked in: they live in a host
# folder mounted at /bot (config.yml, data/, secret/). Use bin/rubicon-docker
# to build and run it.

FROM debian:trixie-slim AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends ruby ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 \
    HOME=/tmp \
    RUBICON_LOG_LEVEL=info
WORKDIR /app
COPY lib/ lib/
COPY bin/rubicon bin/rubicon-account bin/
# The bot runs as an unprivileged --user, so the (root-owned) code must be
# world-readable whatever the permissions were on the build host. It holds
# no secrets: config, data and the pepper only ever come in via /bot.
RUN chmod -R u=rwX,go=rX /app

# Test stage: "bin/rubicon-docker test" runs the suite on trixie's Ruby.
FROM base AS test
RUN apt-get update \
 && apt-get install -y --no-install-recommends ruby-minitest rake \
 && rm -rf /var/lib/apt/lists/*
COPY Rakefile ./
COPY test/ test/
COPY contrib/plugins/ contrib/plugins/
RUN chmod -R u=rwX,go=rX /app
CMD ["rake", "test"]

# Runtime stage (default). Runs as whatever --user the container is given;
# bin/rubicon refuses to run as root.
FROM base AS runtime
VOLUME /bot
# Healthy = connected to IRC, with server activity (PINGs arrive every few
# minutes) in the last 10 minutes. Reads the bot's status file.
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
  CMD ["ruby", "-rjson", "-e", "s = JSON.parse(File.read('/bot/data/status.json')); exit(s['state'] == 'connected' && Time.now.to_i - s['updated_at_unix'] < 600 ? 0 : 1)"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["ruby", "/app/bin/rubicon"]
CMD ["/bot/config.yml"]
