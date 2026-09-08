require 'rails/railtie'

module KicksLiveness
  # Installs the hooks by itself, so a Rails application only needs the
  # configuration block.
  #
  # +to_prepare+ rather than an initializer: an application's lib is normally
  # managed by Zeitwerk and reloadable, and such constants must not be
  # referenced while the application is initialising.
  #
  # @see file:docs/SETUP.md#rails
  # @api private
  class Railtie < ::Rails::Railtie
    initializer 'kicks_liveness.install' do |app|
      app.config.to_prepare { KicksLiveness.install! }
    end
  end
end
