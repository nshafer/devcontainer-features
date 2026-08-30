# The image CI runs the sandbox and egress-filter suites on, so the container the features are
# developed in is the container they are tested on. `node` and `npx` come with it, and so does the
# non-root `node` user every feature here keys off.
FROM mcr.microsoft.com/devcontainers/javascript-node:20

# What `make lint` and `make test` call, installed at build time on purpose: the sandbox feature
# takes sudo away from the remote user, so a missing tool cannot be installed later from a terminal.
#
#   make        the test runner
#   python3     the JSON parse in `make lint`
#   shellcheck  the first half of `make lint`, and a hard failure in CI
#   iptables    egress-filter's own tests, which read the rules they applied
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        make \
        python3 \
        shellcheck \
        iptables \
    && rm -rf /var/lib/apt/lists/*
