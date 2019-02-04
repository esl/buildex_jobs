# base image elixir to start with
FROM bitwalker/alpine-elixir:1.8

# install docker client
RUN grep "http://dl-cdn.alpinelinux.org/alpine/v3.8/community/" /etc/apk/repositories \
        || echo "http://dl-cdn.alpinelinux.org/alpine/v3.8/community/" >> /etc/apk/repositories

RUN apk update

RUN apk add docker

VOLUME /var/lib/docker

# install hex package manager
RUN mix local.hex --force

# create app folder
RUN mkdir /app
WORKDIR /app
COPY . /app

# setting the environment (prod = PRODUCTION!)
ENV MIX_ENV=prod

# install dependencies (production only)
RUN mix local.rebar --force
RUN mix deps.get --only prod
RUN mix compile

# create release
RUN mix release --name=jobs

ENV REPLACE_OS_VARS=true
ENTRYPOINT ["_build/prod/rel/jobs/bin/jobs"]

# run elixir app
CMD ["help"]
