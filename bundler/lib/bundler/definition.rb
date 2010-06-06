require "digest/sha1"

module Bundler
  class Definition
    attr_reader :dependencies, :platforms

    def self.build(gemfile, lockfile, unlock)
      unlock ||= {}
      gemfile = Pathname.new(gemfile).expand_path

      unless gemfile.file?
        raise GemfileNotFound, "#{gemfile} not found"
      end

      # TODO: move this back into DSL
      builder = Dsl.new
      builder.instance_eval(File.read(gemfile.to_s), gemfile.to_s, 1)
      builder.to_definition(lockfile, unlock)
    end

=begin
    How does the new system work?
    ===
    * Load information from Gemfile and Lockfile
    * Invalidate stale locked specs
      * All specs from stale source are stale
      * All specs that are reachable only through a stale
        dependency are stale.
    * If all fresh dependencies are satisfied by the locked
      specs, then we can try to resolve locally.
=end

    def initialize(lockfile, dependencies, sources, unlock)
      @dependencies, @sources, @unlock = dependencies, sources, unlock
      @specs = nil
      @unlock[:gems] ||= []
      @unlock[:sources] ||= []

      if lockfile && File.exists?(lockfile)
        locked = LockfileParser.new(File.read(lockfile))
        @platforms      = locked.platforms
        @locked_deps    = locked.dependencies
        @last_resolve   = SpecSet.new(locked.specs)
        @locked_sources = locked.sources
      else
        @platforms      = []
        @locked_deps    = []
        @last_resolve   = SpecSet.new([])
        @locked_sources = []
      end

      current_platform = Gem.platforms.map { |p| p.to_generic }.compact.last
      @platforms |= [current_platform]

      converge
    end

    def resolve_remotely!
      raise "Specs already loaded" if @specs
      @specs = resolve_remote_specs
    end

    def specs
      @specs ||= resolve_local_specs
    end

    def last_resolve
      resolve_local_specs unless @specs
      @last_resolve
    end

    def index
      @index ||= Index.build do |idx|
        @sources.each do |s|
          idx.use s.local_specs
        end
      end
    end

    def remote_index
      @remote_index ||= Index.build do |idx|
        @sources.each { |source| idx.use source.specs }
      end
    end

    def no_sources?
      @sources.length == 1 && @sources.first.remotes.empty?
    end

    def groups
      dependencies.map { |d| d.groups }.flatten.uniq
    end

    def to_lock
      out = ""

      sorted_sources.each do |source|
        # Add the source header
        out << source.to_lock
        # Find all specs for this source
        last_resolve.
          select  { |s| s.source == source }.
          sort_by { |s| s.name }.
          each do |spec|
            out << spec.to_lock
        end
        out << "\n"
      end

      out << "PLATFORMS\n"

      platforms.map { |p| p.to_s }.sort.each do |p|
        out << "  #{p}\n"
      end

      out << "\n"
      out << "DEPENDENCIES\n"

      dependencies.
        sort_by { |d| d.name }.
        each do |dep|
          out << dep.to_lock
      end

      out
    end

  private

    def converge
      converge_sources
      converge_dependencies
      converge_locked_specs
    end

    def converge_sources
      @sources = (@locked_sources & @sources) | @sources
      @sources.each do |source|
        source.unlock! if source.respond_to?(:unlock!) && @unlock[:sources].include?(source.name)
      end
    end

    def converge_dependencies
      (@dependencies + @locked_deps).each do |dep|
        if dep.source
          source = @sources.find { |s| dep.source == s }
          raise "Something went wrong, there is no matching source" unless source
          dep.source = source
        end
      end
    end

    def converge_locked_specs
      deps = []

      @dependencies.each do |dep|
        if in_locked_deps?(dep) || satisfies_locked_spec?(dep)
          deps << dep
        end
      end

      converged = []
      @last_resolve.each do |s|
        s.source = @sources.find { |src| s.source == src }

        next if s.source.nil? || @unlock[:sources].include?(s.name)

        converged << s
      end

      @last_resolve = SpecSet.new(converged).for(deps, @unlock[:gems])
    end

    def in_locked_deps?(dep)
      @locked_deps.any? do |d|
        dep == d && dep.source == d.source
      end
    end

    def satisfies_locked_spec?(dep)
      @last_resolve.any? { |s| s.satisfies?(dep) }
    end

    def sorted_sources
      @sources.sort_by do |s|
        # Place GEM at the top
        [ s.is_a?(Source::Rubygems) ? 1 : 0, s.to_s ]
      end
    end

    def resolve(type, idx)
      source_requirements = {}
      dependencies.each do |dep|
        next unless dep.source
        source_requirements[dep.name] = dep.source.send(type)
      end

      # Run a resolve against the locally available gems
      resolve = Resolver.resolve(dependencies, idx, source_requirements, @last_resolve, platforms)
      [resolve, resolve.materialize(type, dependencies)]
    end

    def resolve_local_specs
      @last_resolve, @specs = resolve(:local_specs, index)
      @specs
    end

    # TODO: Improve this logic
    def resolve_remote_specs
      raise "lol" unless @last_resolve.valid_for?(dependencies)
      resolve_local_specs
    rescue #InvalidSpecSet, GemNotFound, PathError
      @last_resolve, @specs = resolve(:specs, remote_index)
      @specs
    end
  end
end
