require 'hashie/hash'
require 'set'
require 'axiom-types'

module Boolean; end

module Hashie
  # A Dash is a 'defined' or 'discrete' Hash, that is, a Hash
  # that has a set of defined keys that are accessible (with
  # optional defaults) and only those keys may be set or read.
  #
  # Dashes are useful when you need to create a very simple
  # lightweight data object that needs even fewer options and
  # resources than something like a DataMapper resource.
  #
  # It is preferrable to a Struct because of the in-class
  # API for defining properties as well as per-property defaults.
  class Dash < Hash
    include Hashie::Extensions::PrettyInspect

    alias_method :to_s, :inspect

    # Defines a property on the Dash. Options are
    # as follows:
    #
    # * <tt>:default</tt> - Specify a default value for this property,
    #   to be returned before a value is set on the property in a new
    #   Dash.
    #
    # * <tt>:required</tt> - Specify the value as required for this
    #   property, to raise an error if a value is unset in a new or
    #   existing Dash.
    #
    def self.property(property_name, options = {})
      properties << property_name

      if options.key?(:default)
        defaults[property_name] = options[:default]
      elsif defaults.key?(property_name)
        defaults.delete property_name
      end

      unless instance_methods.map { |m| m.to_s }.include?("#{property_name}=")
        define_method(property_name) { |&block| self.[](property_name, &block) }
        property_assignment = property_name.to_s.concat('=').to_sym
        define_method(property_assignment) { |value| self.[]=(property_name, value) }
      end

      if defined? @subclasses
        @subclasses.each { |klass| klass.property(property_name, options) }
      end
      required_properties << property_name if options.delete(:required)
      set_constraint(property_name, options.delete(:constraints)) if options.key?(:constraints)
    end

    class << self
      attr_reader :properties, :defaults
      attr_reader :required_properties
      attr_reader :property_constraints

      def constraint_builders
        @@constraint_builders
      end
    end
    instance_variable_set('@properties', Set.new)
    instance_variable_set('@defaults', {})
    instance_variable_set('@required_properties', Set.new)
    instance_variable_set('@property_constraints', {})
    class_variable_set('@@constraint_builders', {})

    def self.inherited(klass)
      super
      (@subclasses ||= Set.new) << klass
      klass.instance_variable_set('@properties', properties.dup)
      klass.instance_variable_set('@defaults', defaults.dup)
      klass.instance_variable_set('@required_properties', required_properties.dup)
      klass.instance_variable_set('@property_constraints', property_constraints.dup)
    end

    # Check to see if the specified property has already been
    # defined.
    def self.property?(name)
      properties.include? name
    end

    # Check to see if the specified property is
    # required.
    def self.required?(name)
      required_properties.include? name
    end

    # Check to see if the specified property is
    # constrained.
    def self.constrained?(name)
      property_constraints.key?(name)
    end

    # Set the constraint for the specified property
    def self.set_constraint(property_name, constraints)
      raw_type           = constraints.key?(:type) ? constraints.delete(:type) : ::Object

      assert_constraint_type_exists!(property_name, raw_type)

      custom_constraints = build_custom_constraints(constraints)

      begin
        constraint_klass   = ::Axiom::Types.const_get(raw_type.to_s)
      rescue NameError
        fail_invalid_constraint_key!(property_name, :type)
      end

      constraint_type    = constraint_klass.new do
        custom_constraints.each do |custom_constraint|
          constraint(&custom_constraint)
        end
      end

      # This is a bit of a hack
      #
      # Axiom allows you to create subtypes of types with constraints
      # and the descendents inherit the constraints.
      #
      # When we build a new Axiom type with a block, if any of the constraints
      # are invalid, we'll get an error but no information about which of
      # the constraints caused it.
      #
      # Instead, we create a type hierarchy with each generation corresponding
      # to one constraint, so we can identify it if it fails
      # this is purely to give a dev-friendly exception message.
      #
      # It could be replaced with a more efficient method that only creates
      # one type, if the ability to detect specific faulty constraints
      # is not required.
      klass = self
      constraints.each_pair do |axiom_constraint, value|
        begin
          constraint_type = constraint_type.new do
            send(axiom_constraint, value)
          end
        rescue NameError, ArgumentError
          klass.fail_invalid_constraint_key!(property_name, axiom_constraint)
        end
      end

      property_constraints[property_name] = constraint_type
    end

    # Register new custom constraint builders
    # A constraint builder is a Proc that returns
    # a new Proc bound with variables
    #
    # See underneath for examples
    def self.register_constraint_builder(name, &block)
      constraint_builders[name] = block
    end

    # Register the 'in' constraint, that ensures the value is
    # included in the specified list
    #
    # class StateMachine < Hashie::Dash
    #   property :current, constraints: { in: [:open,:close,:error] }
    # end
    #
    register_constraint_builder(:in) do |list_of_values|
      ->(value) { list_of_values.include?(value) }
    end

    # Register the exact length constraint
    register_constraint_builder(:length) do |length|
      ->(value) { value.respond_to?(:length) && value.length == length }
    end

    # You may initialize a Dash with an attributes hash
    # just like you would many other kinds of data objects.
    def initialize(attributes = {}, &block)
      super(&block)

      self.class.defaults.each_pair do |prop, value|
        self[prop] = begin
          value.dup
        rescue TypeError
          value
        end
      end

      initialize_attributes(attributes)
      assert_required_attributes_set!
    end

    alias_method :_regular_reader, :[]
    alias_method :_regular_writer, :[]=
    private :_regular_reader, :_regular_writer

    # Retrieve a value from the Dash (will return the
    # property's default value if it hasn't been set).
    def [](property)
      assert_property_exists! property
      value = super(property)
      # If the value is a lambda, proc, or whatever answers to call, eval the thing!
      if value.is_a? Proc
        self[property] = value.call # Set the result of the call as a value
      else
        yield value if block_given?
        value
      end
    end

    # Set a value on the Dash in a Hash-like way. Only works
    # on pre-existing properties.
    def []=(property, value)
      assert_property_required! property, value
      assert_property_exists! property
      assert_property_within_constraints! property, value
      super(property, value)
    end

    def merge(other_hash)
      new_dash = dup
      other_hash.each do |k, v|
        new_dash[k] = block_given? ? yield(k, self[k], v) : v
      end
      new_dash
    end

    def merge!(other_hash)
      other_hash.each do |k, v|
        self[k] = block_given? ? yield(k, self[k], v) : v
      end
      self
    end

    def replace(other_hash)
      other_hash = self.class.defaults.merge(other_hash)
      (keys - other_hash.keys).each { |key| delete(key) }
      other_hash.each { |key, value| self[key] = value }
      self
    end

    def update_attributes!(attributes)
      initialize_attributes(attributes)

      self.class.defaults.each_pair do |prop, value|
        self[prop] = begin
          value.dup
        rescue TypeError
          value
        end if self[prop].nil?
      end
      assert_required_attributes_set!
    end

    private

    def self.build_custom_constraints(constraints)
      [].tap do |custom_constraints|
        constraints.each_pair do |key, value|
          # Is the constraint a pre-built custom constraint?
          if value.is_a?(Proc)
            custom_constraints << constraints.delete(key)

          # Is the constraint a reference to a constraint builder?
          elsif constraint_builders.key?(key)
            custom_constraints << constraint_builders[key].call(constraints.delete(key))
          end
        end
      end
    end

    def initialize_attributes(attributes)
      attributes.each_pair do |att, value|
        self[att] = value
      end if attributes
    end

    def assert_property_exists!(property)
      fail_no_property_error!(property) unless self.class.property?(property)
    end

    def assert_required_attributes_set!
      self.class.required_properties.each do |required_property|
        assert_property_set!(required_property)
      end
    end

    def assert_property_set!(property)
      fail_property_required_error!(property) if send(property).nil?
    end

    def assert_property_required!(property, value)
      fail_property_required_error!(property) if self.class.required?(property) && value.nil?
    end

    def assert_property_within_constraints!(property, value)
      # RuboCop gets it wrong here, as we need to
      # differentiate between nil and false
      #
      # (!value && value == false) would be the alternative, but
      # it's very verbose compared to an explicit check
      # rubocop:disable NonNilCheck
      fail_property_outside_constraints!(property, value) if self.class.constrained?(property) && !value.nil? && !self.class.property_constraints[property].include?(value)
      # rubocop:enable NonNilCheck
    end

    def self.assert_constraint_type_exists!(property, type)
      fail_invalid_constraint_key!(property, :type) unless Axiom::Types.const_defined?(type.to_s) rescue false
    end

    def fail_property_required_error!(property)
      fail ArgumentError, "The property '#{property}' is required for #{self.class.name}."
    end

    def fail_no_property_error!(property)
      fail NoMethodError, "The property '#{property}' is not defined for #{self.class.name}."
    end

    def fail_property_outside_constraints!(property, value)
      fail ArgumentError, "The value '#{value}:#{value.class}' does not meet the constraints of the property '#{property}' for #{self.class.name}."
    end

    def self.fail_invalid_constraint_key!(property, key)
      fail ArgumentError, "The constraint key '#{key}' is invalid for '#{property}' for #{name}."
    end
  end
end
