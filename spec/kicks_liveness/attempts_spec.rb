require 'tmpdir'

RSpec.describe KicksLiveness::Attempts do
  let(:tmp) { Dir.mktmpdir }
  let(:dir) { File.join(tmp, 'health') }

  after { FileUtils.remove_entry(tmp) }

  def attempts(generation = 'mnt:[2]:200') = described_class.new(dir, generation: generation)

  describe 'within one container' do
    it 'counts the starts of a fork that has not become healthy' do
      attempts.record!(0)

      expect(attempts.record!(0).first).to eq(2)
    end

    # The window belongs to the unhealthy run, not to the latest respawn, or a
    # storm would reset it every few hundred milliseconds and never escalate.
    it 'keeps the first start of the run' do
      attempts.record!(0, now: Time.now.utc - 31)

      _count, elapsed = attempts.record!(0)

      expect(elapsed).to be_within(1).of(31)
    end

    it 'forgets the run once the slot has been healthy' do
      attempts.record!(0)
      attempts.clear!(0)

      expect(attempts.record!(0).first).to eq(1)
    end
  end

  # The marks volume survives a container restart; the unhealthy run does not.
  # A replacement container that inherits the counter suppresses its own
  # `started:` line and can report an ERROR counting starts it never took.
  describe 'across a container restart' do
    it 'treats a count from a previous generation as a new run' do
      attempts('mnt:[1]:100').record!(0, now: Time.now.utc - 31)

      count, elapsed = attempts.record!(0)

      expect(count).to eq(1)
      expect(elapsed).to eq(0)
    end

    it 'treats the generation-less counter written by 0.1.2 as a new run' do
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'attempt-0'), "7 #{Time.now.utc.to_i - 300}\n")

      expect(attempts.record!(0).first).to eq(1)
    end

    it 'preserves the count for a respawn in the same container' do
      attempts.record!(0)

      expect(attempts.record!(0).first).to eq(2)
    end
  end

  # Off Linux, and where procfs did not yield a generation, there is nothing
  # honest to write or compare, so the counter keeps its 0.1.1 scope: the marks
  # volume.
  describe 'without a usable generation' do
    subject(:legacy) { described_class.new(dir) }

    it 'counts across restarts, as it did before generations existed' do
      attempts.record!(0)

      expect(legacy.record!(0).first).to eq(2)
    end

    it 'writes a file a generation-scoped container will discard' do
      legacy.record!(0)

      expect(attempts.record!(0).first).to eq(1)
    end
  end
end
