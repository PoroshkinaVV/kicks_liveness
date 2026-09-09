RSpec.describe KicksLiveness::Hooks do
  before { KicksLiveness.install! }

  describe 'Hooks::WorkerGroup' do
    # ServerEngine#create_worker mixes WorkerGroup into the singleton class of
    # the instance with extend, rather than including it in a class. This checks
    # that a prepend to the module still sits ahead of it in the lookup chain.
    it 'sits ahead of Sneakers::WorkerGroup when extended into an instance' do
      worker = Object.new
      worker.extend(Sneakers::WorkerGroup)

      ancestors = worker.singleton_class.ancestors

      expect(ancestors.index(described_class::WorkerGroup)).to be < ancestors.index(Sneakers::WorkerGroup)
    end
  end

  # The monitor is started from after_fork rather than from run, so that the
  # application's own after_fork hook has already run before we resolve the
  # expected consumer count. That ordering only holds as long as the worker gem
  # keeps calling after_fork first, which is what this guards: on an upgrade
  # that changes the order, this spec fails instead of production.
  describe 'the ordering contract with the worker gem' do
    subject(:group) do
      instance = group_class.new
      instance.extend(Sneakers::WorkerGroup)
      # WorkerGroup#initialize is what normally builds the flag; extending a
      # bare instance skips it, and a flag that reports "set" makes run return
      # instead of blocking until shutdown.
      instance.instance_variable_set(:@stop_flag, stop_flag)
      instance
    end

    let(:order) { [] }
    let(:stop_flag) { Object.new.tap { |flag| flag.define_singleton_method(:wait_for_set) { |_timeout| true } } }

    let(:group_class) do
      recorder = ->(event) { order << event }

      Class.new do
        define_method(:kicks_liveness_record) { |event| recorder.call(event) }

        def worker_id = 0

        # config[:worker_classes] records the moment it is read, which is when
        # the expected consumer count gets resolved.
        def config
          {
            workers: 1,
            worker_classes: lambda do
              kicks_liveness_record(:worker_classes_resolved)
              []
            end
          }
        end
      end
    end

    before { allow(KicksLiveness).to receive(:start!) { order << :monitor_started } }

    it 'resolves the consumer count only after the application after_fork hook' do
      Sneakers::CONFIG[:hooks][:after_fork] = -> { order << :app_after_fork }

      group.run

      # The point of the whole arrangement: whatever the application does in
      # after_fork has already happened before any of our code runs.
      expect(order.first).to eq(:app_after_fork)
      expect(order.index(:app_after_fork)).to be < order.index(:worker_classes_resolved)
      # The set is resolved twice — once here for the count, once by the worker
      # gem to build the workers from it. Both call the same callable, and
      # resolving it is idempotent: define_consumer hands back a constant that
      # is already defined.
      expect(order.count(:worker_classes_resolved)).to eq(2)
    ensure
      Sneakers::CONFIG[:hooks][:after_fork] = nil
    end
  end

  describe 'Hooks::WorkerGroup#kicks_liveness_expected_consumers' do
    subject(:count) { group.send(:kicks_liveness_expected_consumers) }

    let(:group_class) do
      Class.new do
        attr_writer :worker_classes

        def config
          { worker_classes: @worker_classes }
        end
      end
    end

    let(:group) do
      instance = group_class.new
      instance.worker_classes = worker_classes
      instance.extend(KicksLiveness::Hooks::WorkerGroup)
      instance
    end

    context 'when the set is a plain array of classes (sneakers:run)' do
      let(:worker_classes) { [Class.new, Class.new, Class.new] }

      it 'counts the array' do
        expect(count).to eq(3)
      end
    end

    # Under sneakers:active_job this is an
    # AdvancedSneakersActiveJob::WorkersRegistry — a callable, not an array.
    context 'when the set is callable (sneakers:active_job)' do
      let(:worker_classes) { -> { [Class.new, Class.new] } }

      it 'resolves it by calling it' do
        expect(count).to eq(2)
      end
    end
  end

  # The probe observes the worker and must not be able to break it.
  describe 'Hooks::WorkerGroup, when the monitor could not start' do
    subject(:group) do
      instance = broken_class.new
      instance.extend(KicksLiveness::Hooks::WorkerGroup)
      instance
    end

    let(:broken_class) do
      Class.new do
        attr_reader :app_hook_ran

        def worker_id = 0
        def config = { workers: 1, worker_classes: -> { raise 'resolving the set failed' } }
        def after_fork = @app_hook_ran = true
      end
    end

    it 'lets the fork carry on' do
      expect { group.after_fork }.not_to raise_error
      expect(group.app_hook_ran).to be(true)
    end

    it 'lets the fork carry on when reporting the failure raises too' do
      broken_logger = instance_double(FakeLogger)
      allow(broken_logger).to receive(:error).and_raise(RuntimeError, 'logger failed')
      allow(KicksLiveness.config).to receive(:resolved_logger).and_return(broken_logger)

      expect { group.after_fork }.not_to raise_error
      expect(group.app_hook_ran).to be(true)
    end
  end

  describe 'Hooks::WorkerGroup#stop' do
    subject(:group) do
      instance = group_class.new
      instance.extend(KicksLiveness::Hooks::WorkerGroup)
      instance
    end

    let(:group_class) do
      Class.new do
        attr_reader :stopped

        def stop = @stopped = true
      end
    end

    # A graceful shutdown empties the registry as each worker unsubscribes.
    # Unless the monitor is told that this is deliberate, it reports a fault on
    # every deploy.
    it 'marks the shutdown as deliberate before the workers unsubscribe' do
      expect { group.stop }.to change(KicksLiveness::Registry, :stopping?).from(false).to(true)
      expect(group.stopped).to be(true)
    end
  end

  describe 'Hooks::Worker' do
    it 'sits ahead of Sneakers::Worker in worker classes' do
      klass = Class.new { include Sneakers::Worker }

      ancestors = klass.ancestors

      expect(ancestors.index(described_class::Worker)).to be < ancestors.index(Sneakers::Worker)
    end
  end
end
