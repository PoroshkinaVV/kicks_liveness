# Setup

## Requirements

You need **either** `kicks` (>= 3.0) **or** `sneakers` (>= 2.11). Neither is
declared as a dependency of this gem: at runtime it needs only the `Sneakers`
namespace, and both provide it. Install exactly one — see
[LIMITATIONS.md](LIMITATIONS.md#do-not-install-both-kicks-and-sneakers) for why
having both is worse than it looks.

Those two floors are exact, not aspirational: CI runs the suite against
`kicks 3.0.0` and `sneakers 2.11.0` pinned, alongside the matrix that tracks the
current release of each. A `~>` matrix on its own would only ever prove that the
latest version works.

```ruby
gem 'kicks_liveness'
```

If neither is present, `install!` raises a `LoadError` naming both with their
required versions.

## Installing the hooks

The gem works by prepending two modules — one to `Sneakers::Worker`, one to
`Sneakers::WorkerGroup`. `KicksLiveness.install!` does that, and it must run
before the runner starts. It is idempotent, so calling it twice is harmless.

### Rails

Nothing to do. A Railtie calls `install!` from `to_prepare`.

That is the one path where this gem acts on its own rather than when told, so it
is worth saying how far it has been checked: a production Rails application whose
only kicks_liveness code is the `configure` block below — no `install!` anywhere —
boots its workers with both hooks in place and the probe green. See
[VERIFYING.md](VERIFYING.md#the-scenarios).

The Railtie file is loaded only when `Rails::Railtie` is already defined at the
time this gem is required, which is what `Bundler.require` in
`config/application.rb` gives you. If your application requires this gem
*before* Rails itself is loaded, the Railtie never loads and the hooks are never
installed — call `install!` manually in that case.

### Sinatra, Hanami, Roda, or no framework at all

Call `install!` yourself, before the runner starts:

```ruby
require 'kicks_liveness'

KicksLiveness.install!
```

There is no Rails coupling to work around: outside Rails the Railtie file is
never loaded, and the gem pulls in no Rails code. The web framework is not
involved at all — workers run in their own process, started by
`rake sneakers:run` or your own runner script, and that process usually contains
no web framework.

### Getting the application loaded under `rake sneakers:run`

The line above is the easy half. The half that actually costs people time is
how the application gets into the rake process at all, because outside Rails
nothing loads it for you.

`sneakers/tasks` declares `task :environment` **empty**, precisely so that you
can fill it in. Rake accumulates blocks for the same task rather than replacing
them, so adding your own is the supported way:

```ruby
# Rakefile
require 'sneakers/tasks'

task(:environment) { require_relative 'app' }
```

where `app.rb` is whatever configures Sneakers, calls `install!` and defines (or
requires) the worker classes. In Rails this is already handled — its own
`:environment` task loads the application — which is why the problem only shows
up outside it, usually as `sneakers:run` starting with no workers at all.

This is exactly the wiring the gem's own integration fixture uses
(`spec/integration/fixture/Rakefile`), so it is checked against a real broker on
every run of [VERIFYING.md](VERIFYING.md).

**Hanami 2** differs only in what that block contains: load the app the way
Hanami wants (`require 'hanami/prepare'` for a prepared, not fully booted,
application) and call `install!` after it. There is nothing Hanami-specific in
the gem — as above, the framework is not in the picture, only the question of
which file brings your worker classes into the process.

A minimal standalone runner:

```ruby
require 'sneakers'          # kicks installs this same file
require 'kicks_liveness'
require_relative 'workers/orders_worker'

Sneakers.configure(amqp: ENV.fetch('AMQP_URL'), workers: 2, threads: 10)
KicksLiveness.install!

Sneakers::Runner.new([OrdersWorker]).run
```

## Workers must be started through `Sneakers::Runner`

This is the one real constraint, and it has nothing to do with frameworks.

The monitor thread is started from the hook on
`Sneakers::WorkerGroup#after_fork`, and `WorkerGroup` enters the picture through
`Sneakers::Runner`, which builds a ServerEngine supervisor. If you boot workers
by hand — instantiating worker classes and calling `worker.run` in your own
loop, without ServerEngine — that hook never fires. The registry will fill up,
but nothing writes the mark files, so the probe stays red and the pod is killed.

Use `Sneakers::Runner` (that is what `rake sneakers:run` does), or do not use
this gem.

## Configuration

Everything has a sensible default; in most applications the block is one line.

```ruby
KicksLiveness.configure do |config|
  config.enabled = ENV['RACK_ENV'] != 'test'
end
```

**Do not set `config.logger = Sneakers.logger`.** That is already the default,
and writing it out is worse than leaving it alone, because the default is
resolved *lazily* and the assignment is not. `Sneakers.logger` is `nil` until
`Sneakers.configure` runs, so whether the assignment captures a logger or a
`nil` depends on which file Rails loads first — and initializers load in
alphabetical order, which is not something you chose or want to depend on. An
initializer named `kicks_liveness.rb` sorts *before* `sneakers.rb`; one named
`worker_liveness.rb` sorts after. Same code, different outcome.

Set it only to point somewhere **other** than `Sneakers.logger`:

```ruby
config.logger = Rails.logger
```

| Option | Default | Purpose | Valid values |
|---|---|---|---|
| `logger` | `Sneakers.logger`, resolved lazily | transition and error logs | logger-compatible object |
| `enabled` | `true` | start the monitor thread | `true` or `false` |
| `tick` | `10` | seconds between checks | positive number smaller than `max_age` |
| `startup_grace_ticks` | `6` | unhealthy startup ticks before one ERROR | positive integer |

Invalid combinations are rejected before the monitor starts instead of running
one that is guaranteed to publish stale marks or never report a stalled startup.

`dir` and `max_age` are **not** here — they come from environment variables
only. See
[DESIGN.md](DESIGN.md#what-is-configurable-and-where) for why, and
[KUBERNETES.md](KUBERNETES.md#environment-variables) for the variables.

## Checking that the hooks are in place

In a console of the process that boots your workers:

```ruby
Sneakers::Worker.ancestors.include?(KicksLiveness::Hooks::Worker)       # => true
Sneakers::WorkerGroup.ancestors.include?(KicksLiveness::Hooks::WorkerGroup) # => true
```

Both must be `true` before the runner starts. If either is `false`, either
`install!` has not run, or it ran before `kicks`/`sneakers` was loaded.

Once workers are running, the marks directory is the other half of the answer:

```
$ ls -l /opt/app/tmp/health/
expected
generation
worker-0
worker-1
```

One `worker-<slot>` file per fork, plus `expected` and the current container
`generation`. If `expected` is there and the slot files are not, the workers
have not finished subscribing. A slot that keeps restarting without ever
subscribing also leaves an `attempt-<slot>` file, which is removed as soon as
that slot becomes healthy.
