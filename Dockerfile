FROM ruby:3.4

ARG RACK_ENV
RUN mkdir /18xx
WORKDIR /18xx
RUN git config --global --add safe.directory /18xx

# esbuild for this machine's chip: x86 (most PCs) or arm64 (Apple Silicon
# Macs), so the image builds natively on both.
RUN if [ "$RACK_ENV" = "development" ]; \
    then \
      case "$(dpkg --print-architecture)" in \
        arm64) pkg=esbuild-linux-arm64 ;; \
        *) pkg=esbuild-linux-64 ;; \
      esac; \
      curl -sf "https://registry.npmjs.org/$pkg/-/$pkg-0.14.36.tgz" | tar xz; \
      mv package/bin/esbuild /usr/local/bin && rm -rf package; \
    fi;

COPY Gemfile Gemfile.lock ./
RUN if [ "$RACK_ENV" = "production" ]; \
    then bundle config set without 'test development'; \
    fi; \
    bundle install;
COPY . .

CMD bundle exec rake dev_up && \
    bundle exec rerun --background -i 'build/*' -i 'public/*' 'unicorn -c config/unicorn.rb'
