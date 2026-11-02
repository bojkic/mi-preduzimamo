# syntax=docker/dockerfile:1
ARG RUBY_IMAGE=ruby:3.4.12-slim-bookworm@sha256:a0636a941ef86063f17b343f6c96f271f8eeedd76febf035bb6d57bc5024682b
FROM ${RUBY_IMAGE} AS build
ENV GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 BUNDLE_FROZEN=true
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates curl xz-utils libpq-dev libicu-dev libvips libjpeg62-turbo-dev libpng-dev libwebp-dev pkg-config && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://nodejs.org/dist/v22.23.4/node-v22.23.4-linux-x64.tar.xz -o /tmp/node.tar.xz && echo '1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce  /tmp/node.tar.xz' | sha256sum -c - && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 && rm /tmp/node.tar.xz
RUN curl -fsSL https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-35.tar.gz -o /tmp/im.tar.gz && echo '40b6fefa88fe16ca5a4b3d3db5133eaebfb0157f21f98530bde8aec5dd5b0776  /tmp/im.tar.gz' | sha256sum -c - && tar xzf /tmp/im.tar.gz -C /tmp && cd /tmp/ImageMagick-7.1.2-35 && ./configure --prefix=/opt/im --disable-docs --without-perl --without-x --with-quantum-depth=8 && make -j2 && make install && echo /opt/im/lib > /etc/ld.so.conf.d/mi-im.conf && ldconfig && rm -rf /tmp/im.tar.gz /tmp/ImageMagick-7.1.2-35
ENV PATH=/opt/im/bin:/usr/local/bin:/usr/bin:/bin
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN gem install bundler -v 2.6.9 --no-document && bundle _2.6.9_ install --jobs 2 --retry 2
COPY package.json package-lock.json ./
RUN npm ci --include=dev --no-audit --no-fund
COPY . .
ARG MI_APP_BUILD_REVISION
RUN MI_APP_BUILD_REVISION="$MI_APP_BUILD_REVISION" bundle exec ruby installation/build_identity.rb
RUN SECRET_KEY_BASE_DUMMY=1 SECRET_KEY_BASE=build-only-not-runtime DECIDIM_API_JWT_SECRET=build-only-not-runtime RAILS_ENV=production NODE_OPTIONS=--max-old-space-size=2048 bin/rails assets:precompile

FROM ${RUBY_IMAGE} AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git libpq5 libicu72 libvips libjpeg62-turbo libpng16-16 libwebp7 libwebpmux3 libwebpdemux2 libgomp1 libltdl7 tzdata && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /usr/local/bin/node /usr/local/bin/node
COPY --from=build /opt/im /opt/im
COPY --from=build /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && echo /opt/im/lib > /etc/ld.so.conf.d/mi-im.conf && ldconfig
ENV PATH=/opt/im/bin:/usr/local/bin:/usr/bin:/bin
WORKDIR /app
COPY --from=build /app /app
# Frontend dependencies/build caches are not runtime inputs after compilation.
RUN rm -rf node_modules tmp/cache tmp/shakapacker
ARG MI_RUNTIME_UID=1000
RUN groupadd -g ${MI_RUNTIME_UID} mi && useradd -u ${MI_RUNTIME_UID} -g mi -m mi && mkdir -p storage tmp/pids log shared/sockets shared/pids shared/log && chown -R mi:mi storage tmp log shared
ARG MI_APP_BUILD_REVISION
LABEL org.opencontainers.image.revision=$MI_APP_BUILD_REVISION
ENV RAILS_ENV=production RACK_ENV=production BUNDLE_FROZEN=true MI_RUNTIME_STATE_DIR=/app/tmp
USER mi
# Fail the image build if copied native gems cannot load under the runtime user.
RUN bundle exec ruby -e 'require "charlock_holmes"; require "pg"; require "vips"'
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "installation/puma.rb"]

FROM runtime AS demo
COPY installation/demo/00_profile.rb /app/config/initializers/mi_demo_profile.rb
COPY installation/demo/10_phone_capture.rb /app/config/initializers/mi_demo_phone_capture.rb
