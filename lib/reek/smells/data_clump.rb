require File.join( File.dirname( File.expand_path(__FILE__)), 'smell_detector')
require File.join(File.dirname(File.dirname(File.expand_path(__FILE__))), 'smell_warning')
require File.join(File.dirname(File.dirname(File.expand_path(__FILE__))), 'source')

#
# Extensions to +Array+ needed by Reek.
#
class Array
  def intersection
    self.inject { |res, elem| elem & res }
  end
end

module Reek
  module Smells

    #
    # A Data Clump occurs when the same two or three items frequently
    # appear together in classes and parameter lists, or when a group
    # of instance variable names start or end with similar substrings.
    #
    # The recurrence of the items often means there is duplicate code
    # spread around to handle them. There may be an abstraction missing
    # from the code, making the system harder to understand.
    #
    # Currently Reek looks for a group of two or more parameters with
    # the same names that are expected by three or more methods of a class.
    #
    class DataClump < SmellDetector

      SMELL_CLASS = self.name.split(/::/)[-1]

      METHODS_KEY = 'methods'
      OCCURRENCES_KEY = 'occurrences'
      PARAMETERS_KEY = 'parameters'

      def self.contexts      # :nodoc:
        [:class, :module]
      end

      # The name of the config field that sets the maximum allowed
      # copies of any clump.
      MAX_COPIES_KEY = 'max_copies'

      DEFAULT_MAX_COPIES = 2

      MIN_CLUMP_SIZE_KEY = 'min_clump_size'
      DEFAULT_MIN_CLUMP_SIZE = 2

      def self.default_config
        super.adopt(
          MAX_COPIES_KEY => DEFAULT_MAX_COPIES,
          MIN_CLUMP_SIZE_KEY => DEFAULT_MIN_CLUMP_SIZE
        )
      end

      def initialize(source, config = DataClump.default_config)
        super(source, config)
      end

      #
      # Checks the given class or module for multiple identical parameter sets.
      # Remembers any smells found.
      #
      def examine_context(ctx)
        @max_copies = value(MAX_COPIES_KEY, ctx, DEFAULT_MAX_COPIES)
        @min_clump_size = value(MIN_CLUMP_SIZE_KEY, ctx, DEFAULT_MIN_CLUMP_SIZE)
        MethodGroup.new(ctx, @min_clump_size, @max_copies).clumps.each do |clump, methods|
          smell = SmellWarning.new('DataClump', ctx.full_name,
            methods.map {|meth| meth.line},
            "takes parameters #{DataClump.print_clump(clump)} to #{methods.length} methods",
            @source, 'DataClump', {
              PARAMETERS_KEY => clump.map {|name| name.to_s},
              OCCURRENCES_KEY => methods.length,
              METHODS_KEY => methods.map {|meth| meth.name}
            })
          @smells_found << smell
          #SMELL: serious duplication
          # SMELL: name.to_s is becoming a nuisance
        end
      end

      def self.print_clump(clump)
        "[#{clump.map {|name| name.to_s}.join(', ')}]"
      end
    end
  end

  # Represents a group of methods
  # @private
  class MethodGroup

    def self.intersection_of_parameters_of(methods)
      methods.map {|meth| meth.arg_names}.intersection
    end

    def initialize(ctx, min_clump_size, max_copies)
      @min_clump_size = min_clump_size
      @max_copies = max_copies
      @candidate_methods = ctx.local_nodes(:defn).select do |meth|
        meth.arg_names.length >= @min_clump_size
      end.map {|defn_node| CandidateMethod.new(defn_node)}
      delete_infrequent_parameters
      delete_small_methods
    end

    def clumps_containing(method, methods, results)
      methods.each do |other_method|
        clump = [method.arg_names, other_method.arg_names].intersection
        if clump.length >= @min_clump_size
          others = methods.select { |other| clump - other.arg_names == [] }
          results[clump] += [method] + others
        end
      end
    end
    
    def collect_clumps_in(methods, results)
      return if methods.length <= @max_copies
      tail = methods[1..-1]
      clumps_containing(methods[0], tail, results)
      collect_clumps_in(tail, results)
    end

    def clumps
      results = Hash.new([])
      collect_clumps_in(@candidate_methods, results)
      results.each_key { |key| results[key].uniq! }
      results
    end

    def delete_small_methods
      @candidate_methods = @candidate_methods.select do |meth|
        meth.arg_names.length >= @min_clump_size
      end
    end

    def delete_infrequent_parameters
      @candidate_methods.each do |meth|
        meth.arg_names.each do |param|
          occurs = @candidate_methods.inject(0) {|sum, cm| cm.arg_names.include?(param) ? sum+1 : sum}
          meth.delete(param) if occurs <= @max_copies
        end
      end
    end
  end

  # A method definition and a copy of its parameters
  # @private
  class CandidateMethod
    def initialize(defn_node)
      @defn = defn_node
      @params = defn_node.arg_names.clone.sort {|first,second| first.to_s <=> second.to_s}
    end

    def arg_names
      @params
    end

    def delete(param)
      @params.delete(param)
    end

    def line
      @defn.line
    end

    def name
      @defn.name.to_s     # BUG: should report the symbols!
    end
  end
end
