require 'open3'
require 'tmpdir'

RSpec.describe 'liveness probe' do
  let(:tmp) { Dir.mktmpdir }
  let(:dir) { File.join(tmp, 'health') }
  let(:lib) { File.expand_path('../lib', __dir__) }

  after { FileUtils.remove_entry(tmp) }

  def run_probe(require_path: 'kicks_liveness/probe', env: {})
    out, status = Open3.capture2e(
      { 'KICKS_LIVENESS_DIR' => dir }.merge(env),
      RbConfig.ruby, '-I', lib, '-e', "require '#{require_path}'"
    )
    [out.strip, status.exitstatus]
  end

  def healthy_marks!
    KicksLiveness::Heartbeat.new(dir: dir, max_age: 45).tap do |heartbeat|
      heartbeat.declare!(1)
      heartbeat.touch!(0)
    end
  end

  it 'exits zero and prints the reason when the marks are fresh' do
    healthy_marks!

    expect(run_probe).to eq(['1 process(es) healthy', 0])
  end

  it 'exits one and prints the reason when the worker has not started' do
    message, code = run_probe

    expect(code).to eq(1)
    expect(message).to include('worker has not started yet')
  end

  it 'pulls in no bundler and requires neither kicks nor sneakers' do
    healthy_marks!

    _message, code = run_probe(env: { 'RUBYOPT' => '--disable-gems' })

    expect(code).to eq(0)
  end
end
