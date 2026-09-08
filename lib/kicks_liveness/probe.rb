# Probe entry point. Requiring this file performs the check and terminates the
# process, so do not require it from an application.
#
# In a container manifest:
#   command: ["bundle", "exec", "kicks-liveness"]
#
# The gem namespace is deliberately not loaded: this pulls in one
# dependency-free file. Images that install gems in +GEM_HOME+ can invoke this
# file directly as a faster, optional form; see
# docs/KUBERNETES.md#where-your-image-puts-its-gems.
require_relative 'heartbeat'

ok, message = KicksLiveness::Heartbeat.new.check

puts message
exit(ok ? 0 : 1)
