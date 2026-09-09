# Fixture image for the integration scenarios. Built from the gem root:
#
#   docker build -f spec/integration/fixture/Dockerfile -t kicks-liveness-fixture .
#
# The layout inside the image mirrors the repository, so the fixture Gemfile's
# `path: '../../..'` resolves the same way here as it does on a developer's
# machine.
FROM ruby:3.4-slim

ARG AMQP_WORKER_GEM=kicks
ENV LANG=C.UTF-8 \
    BUNDLE_JOBS=4 \
    KICKS_LIVENESS_DIR=/opt/app/tmp/health \
    AMQP_WORKER_GEM=$AMQP_WORKER_GEM

WORKDIR /opt/app

# bunny pulls sorted_set, which pulls rbtree, a native extension, and the slim
# image ships no compiler. Installed before the gems and purged after them, so
# the toolchain does not stay in the image.
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential && \
    rm -rf /var/lib/apt/lists/*


# Everything the gemspec's file list needs, and nothing else.
COPY kicks_liveness.gemspec .yardopts README.md CHANGELOG.md LICENSE.txt ./
COPY lib ./lib
COPY exe ./exe
COPY docs ./docs

# The gem is installed twice on purpose, and the two copies serve the two sides
# of the design:
#
#   * `gem install` puts it in GEM_HOME, which is what makes the documented
#     probe command — plain `ruby -e "require 'kicks_liveness/probe'"`, no
#     bundler, no -I — resolve. A published gem lands there; a `path:` gem in a
#     Gemfile does not, and the probe would raise LoadError. That failure mode
#     is the one docs/KUBERNETES.md warns about, so the image is built to
#     reproduce the working case.
#   * the `path:` entry in the fixture Gemfile is what the worker process boots
#     from, which is how a real application loads it.
#
# Both copies are the same source tree, so there is no version skew to worry
# about.
RUN gem build kicks_liveness.gemspec && \
    gem install ./kicks_liveness-*.gem --no-document && \
    rm ./kicks_liveness-*.gem

COPY spec/integration/fixture ./spec/integration/fixture

WORKDIR /opt/app/spec/integration/fixture
RUN bundle install && \
    apt-get purge -y --auto-remove build-essential

# `rake sneakers:run` is what docs/SETUP.md names as the supported way to boot,
# because it is what builds the ServerEngine supervisor the hooks attach to.
CMD ["bundle", "exec", "rake", "sneakers:run"]
