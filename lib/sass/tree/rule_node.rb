require 'pathname'
require 'uri'

module Sass::Tree
  # A static node reprenting a CSS rule.
  #
  # @see Sass::Tree
  class RuleNode < Node
    # The character used to include the parent selector
    PARENT = '&'

    # The CSS selector for this rule,
    # interspersed with {Sass::Script::Node}s
    # representing `#{}`-interpolation.
    # Any adjacent strings will be merged together.
    #
    # @return [Array<String, Sass::Script::Node>]
    attr_accessor :rule

    # The CSS selector for this rule,
    # without any unresolved interpolation
    # but with parent references still intact.
    # It's only set once {Tree::Node#perform} has been called.
    #
    # @return [Selector::CommaSequence]
    attr_accessor :parsed_rules

    # The CSS selector for this rule,
    # without any unresolved interpolation or parent references.
    # It's only set once {Tree::Node#cssize} has been called.
    #
    # @return [Selector::CommaSequence]
    attr_accessor :resolved_rules

    # How deep this rule is indented
    # relative to a base-level rule.
    # This is only greater than 0 in the case that:
    #
    # * This node is in a CSS tree
    # * The style is :nested
    # * This is a child rule of another rule
    # * The parent rule has properties, and thus will be rendered
    #
    # @return [Fixnum]
    attr_accessor :tabs

    # Whether or not this rule is the last rule in a nested group.
    # This is only set in a CSS tree.
    #
    # @return [Boolean]
    attr_accessor :group_end

    # @param rule [Array<String, Sass::Script::Node>]
    #   The CSS rule. See \{#rule}
    def initialize(rule)
      #p rule
      merged = Haml::Util.merge_adjacent_strings(rule)
      #p merged
      @rule = Haml::Util.strip_string_array(merged)
      #p @rule
      @tabs = 0
      try_to_parse_non_interpolated_rules
      super()
    end

    # Compares the contents of two rules.
    #
    # @param other [Object] The object to compare with
    # @return [Boolean] Whether or not this node and the other object
    #   are the same
    def ==(other)
      self.class == other.class && rule == other.rule && super
    end

    # Adds another {RuleNode}'s rules to this one's.
    #
    # @param node [RuleNode] The other node
    def add_rules(node)
      @rule = Haml::Util.strip_string_array(
        Haml::Util.merge_adjacent_strings(@rule + ["\n"] + node.rule))
      try_to_parse_non_interpolated_rules
    end

    # @return [Boolean] Whether or not this rule is continued on the next line
    def continued?
      last = @rule.last
      last.is_a?(String) && last[-1] == ?,
    end

    # @see Node#to_sass
    def to_sass(tabs, opts = {})
      name = selector_to_sass(rule, opts)
      name = "\\" + name if name[0] == ?:
      name.gsub(/^/, '  ' * tabs) + children_to_src(tabs, opts, :sass)
    end

    # @see Node#to_scss
    def to_scss(tabs, opts = {})
      name = selector_to_scss(rule, tabs, opts)
      res = name + children_to_src(tabs, opts, :scss)

      if children.last.is_a?(CommentNode) && children.last.silent
        res.slice!(-3..-1)
        res << "\n" << ('  ' * tabs) << "}\n"
      end

      res
    end

    # Extends this Rule's selector with the given `extends`.
    #
    # @see Node#do_extend
    def do_extend(extends)
      node = dup
      node.resolved_rules = resolved_rules.do_extend(extends)
      node
    end

    protected

    # Computes the CSS for the rule.
    #
    # @param tabs [Fixnum] The level of indentation for the CSS
    # @return [String] The resulting CSS
    def _to_s(tabs)
      output_style = style
      tabs = tabs + self.tabs

      rule_separator = output_style == :compressed ? ',' : ', '
      line_separator =
        case output_style
          when :nested, :expanded; "\n"
          when :compressed; ""
          else; " "
        end
      rule_indent = '  ' * (tabs - 1)
      per_rule_indent, total_indent = [:nested, :expanded].include?(output_style) ? [rule_indent, ''] : ['', rule_indent]

      joined_rules = resolved_rules.members.map {|seq| seq.to_a.join}.join(rule_separator)
      joined_rules.sub!(/\A\s*/, per_rule_indent)
      joined_rules.gsub!(/\s*\n\s*/, "#{line_separator}#{per_rule_indent}")
      total_rule = total_indent << joined_rules

      to_return = ''
      old_spaces = '  ' * (tabs - 1)
      spaces = '  ' * tabs
      if output_style != :compressed
        if @options[:debug_info]
          to_return << debug_info_rule.to_s(tabs) << "\n"
        elsif @options[:line_comments]
          to_return << "#{old_spaces}/* line #{line}"

          if filename
            relative_filename = if @options[:css_filename]
              begin
                Pathname.new(filename).relative_path_from(
                  Pathname.new(File.dirname(@options[:css_filename]))).to_s
              rescue ArgumentError
                nil
              end
            end
            relative_filename ||= filename
            to_return << ", #{relative_filename}"
          end

          to_return << " */\n"
        end
      end

      if output_style == :compact
        properties = children.map { |a| a.to_s(1) }.join(' ')
        to_return << "#{total_rule} { #{properties} }#{"\n" if group_end}"
      elsif output_style == :compressed
        properties = children.map { |a| a.to_s(1) }.join(';')
        to_return << "#{total_rule}{#{properties}}"
      else
        properties = children.map { |a| a.to_s(tabs + 1) }.join("\n")
        end_props = (output_style == :expanded ? "\n" + old_spaces : ' ')
        to_return << "#{total_rule} {\n#{properties}#{end_props}}#{"\n" if group_end}"
      end

      to_return
    end

    # Runs SassScript interpolation in the selector,
    # and then parses the result into a {Sass::Selector::CommaSequence}.
    #
    # @param environment [Sass::Environment] The lexical environment containing
    #   variable and mixin values
    def perform!(environment)
      @parsed_rules ||= parse_selector(run_interp(@rule, environment))
      super
    end

    # Converts nested rules into a flat list of rules.
    #
    # @param extends [Haml::Util::SubsetMap{Selector::Simple => Selector::Sequence}]
    #   The extensions defined for this tree
    # @param parent [RuleNode, nil] The parent node of this node,
    #   or nil if the parent isn't a {RuleNode}
    def _cssize(extends, parent)
      node = super
      rules = node.children.grep(RuleNode)
      props = node.children.reject {|c| c.is_a?(RuleNode) || c.invisible?}

      unless props.empty?
        node.children = props
        rules.each {|r| r.tabs += 1} if style == :nested
        rules.unshift(node)
      end

      rules.last.group_end = true unless parent || rules.empty?

      rules
    end

    # Resolves parent references and nested selectors,
    # and updates the indentation based on the parent's indentation.
    #
    # @param extends [Haml::Util::SubsetMap{Selector::Simple => Selector::Sequence}]
    #   The extensions defined for this tree
    # @param parent [RuleNode, nil] The parent node of this node,
    #   or nil if the parent isn't a {RuleNode}
    # @raise [Sass::SyntaxError] if the rule has no parents but uses `&`
    def cssize!(extends, parent)
      self.resolved_rules = @parsed_rules.resolve_parent_refs(parent && parent.resolved_rules)
      super
    end

    # Returns an error message if the given child node is invalid,
    # and false otherwise.
    #
    # {ExtendNode}s are valid within {RuleNode}s.
    #
    # @param child [Tree::Node] A potential child node.
    # @return [Boolean, String] Whether or not the child node is valid,
    #   as well as the error message to display if it is invalid
    def invalid_child?(child)
      super unless child.is_a?(ExtendNode)
    end

    # A hash that will be associated with this rule in the CSS document
    # if the {file:SASS_REFERENCE.md#debug_info-option `:debug_info` option} is enabled.
    # This data is used by e.g. [the FireSass Firebug extension](https://addons.mozilla.org/en-US/firefox/addon/103988).
    #
    # @return [{#to_s => #to_s}]
    def debug_info
      {:filename => filename && ("file://" + URI.escape(File.expand_path(filename))),
       :line => self.line}
    end

    private

    def try_to_parse_non_interpolated_rules
      if @rule.all? {|t| t.kind_of?(String)}
        @parsed_rules = parse_selector(@rule.join.strip) rescue nil
      end
    end

    def parse_selector(text, line = self.line || 1)
      Sass::SCSS::StaticParser.new(text, line).parse_selector(filename)
    end

    def debug_info_rule
      node = DirectiveNode.new("@media -sass-debug-info")
      debug_info.map {|k, v| [k.to_s, v.to_s]}.sort.each do |k, v|
        rule = RuleNode.new([""])
        rule.resolved_rules = Sass::Selector::CommaSequence.new(
          [Sass::Selector::Sequence.new(
              [Sass::Selector::SimpleSequence.new(
                  [Sass::Selector::Element.new(k.to_s.gsub(/[^\w-]/, "\\\\\\0"), nil)])
              ])
          ])
        prop = PropNode.new([""], "", :new)
        prop.resolved_name = "font-family"
        prop.resolved_value = Sass::SCSS::RX.escape_ident(v.to_s)
        rule << prop
        node << rule
      end
      node.options = @options.merge(:debug_info => false, :line_comments => false, :style => :compressed)
      node
    end
  end
end
