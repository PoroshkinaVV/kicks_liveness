# Fixture application for the integration scenarios in docs/VERIFYING.md.
#
# Deliberately minimal, and deliberately literal: the setup below is the one
# printed in docs/SETUP.md, so running the fixture also checks the instruction.
require 'sneakers'
require 'kicks_liveness'

# `workers` must be set explicitly: the Sneakers default is 4, and the probe
# waits for a mark from every fork the supervisor was told to start.
Sneakers.configure(
  amqp: ENV.fetch('AMQP_URL', 'amqp://guest:guest@localhost:5672'),
  workers: Integer(ENV.fetch('WORKER_COUNT', '1')),
  threads: 2,
  prefetch: 2,
  # A respawn of a fork must be visible in the log, so the supervisor should not
  # give up on it.
  start_worker_delay: 0.2,
  daemonize: false,
  log: $stdout
)
Sneakers.logger.level = Logger::INFO

KicksLiveness.install!

# ServerEngine owns USR2 (reload). This otherwise unused, handled signal lets
# the fixture's PID 1 end itself; an in-namespace SIGKILL would be ignored.
Signal.trap('WINCH') { exit!(137) }

# Two real consumers on two real queues: the health predicate reads
# `worker.queue.channel`, so a stubbed worker would check nothing.
class AlphaWorker
  include Sneakers::Worker

  from_queue 'kicks_liveness.alpha', ack: true

  def work(message)
    Sneakers.logger.info("[alpha] #{message}")
    if message == 'block-drain'
      sleep 0.1 until File.exist?('/opt/app/tmp/release-drain')
    elsif message == 'delay-drain'
      sleep 8
      Sneakers.logger.info('[alpha] delay-drain complete')
    end
    ack!
  end
end

class BetaWorker
  include Sneakers::Worker

  from_queue 'kicks_liveness.beta', ack: true

  def work(message)
    Sneakers.logger.info("[beta] #{message}")
    ack!
  end
end
