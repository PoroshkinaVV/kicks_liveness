# Every example that touches the marks directory has to say what the process
# could prove about its own container, because that is what decides the
# behaviour. Named helpers keep the five states readable at the call site.
module Topologies
  def verified_topology(generation = 'mnt:[2]:200')
    KicksLiveness::ContainerGeneration::Result.verified(generation)
  end

  def unverifiable_topology(generation = 'mnt:[2]:200', detail = 'cannot read /proc/1/ns/mnt (Errno::EACCES)')
    KicksLiveness::ContainerGeneration::Result.unverifiable(generation, detail)
  end

  def unsafe_topology(detail = 'PID 1 is in mnt:[4026531840], this process in mnt:[4026532686]')
    KicksLiveness::ContainerGeneration::Result.unsafe(detail)
  end

  def unavailable_topology(detail = 'cannot read /proc/1/stat (Errno::EACCES)')
    KicksLiveness::ContainerGeneration::Result.unavailable(detail)
  end

  def non_linux_topology
    KicksLiveness::ContainerGeneration::Result.non_linux
  end
end

RSpec.configure { |config| config.include Topologies }
