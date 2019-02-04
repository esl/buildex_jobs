# BuildexJobs

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `buildex_jobs` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:repo_jobs, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/repo_jobs](https://hexdocs.pm/repo_jobs).

## General Overview

  - BugsBunny creates a pool of connections to RabbitMQ
  - each connection worker traps exits and links the connection process to it
  - each connection worker creates a pool of channels and links them to it
  - we spawn in the ConsumerSupervisor a given number of GenServers that are going to be our RabbitMQ consumers
  - each consumer is going to get a channel out of the channel pool and is going to subscribe itself as a consumer via Basic.Consume using that channel

## High Level Architecture

it is really similar to the architecture of `RepoPoller` in the sense that we need a pool of connections and channels to RabbitMQ and a pool of workers, in this case, RabbitMQ Consumers; this is because we also use BugsBunny which is our connection layer that both apps uses.

![screen shot 2018-08-29 at 7 22 49 am](https://user-images.githubusercontent.com/1157892/44787334-7a2e5d80-ab5c-11e8-86c4-16f7e5de3275.png)
