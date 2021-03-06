###
CoffeeLint

Copyright (c) 2011 Matthew Perpick.
CoffeeLint is freely distributable under the MIT license.
###


# Coffeelint's namespace.
coffeelint = {}

if exports?
    # If we're running in node, export our module and
    # load dependencies.
    coffeelint = exports
    CoffeeScript = require 'coffee-script'
else
    # If we're in the browser, export out module to
    # global scope. Assume CoffeeScript is already
    # loaded.
    this.coffeelint = coffeelint
    CoffeeScript = this.CoffeeScript


# The current version of Coffeelint.
coffeelint.VERSION = "0.4.0"


# CoffeeLint error levels.
ERROR   = 'error'
WARN    = 'warn'
IGNORE  = 'ignore'


# CoffeeLint's default rule configuration.
RULES =

    no_tabs :
        level : ERROR
        message : 'Line contains tab indentation'

    no_trailing_whitespace :
        level : ERROR
        message : 'Line ends with trailing whitespace'

    max_line_length :
        value: 80
        level : ERROR
        message : 'Line exceeds maximum allowed length'

    camel_case_classes :
        level : ERROR
        message : 'Class names should be camel cased'

    indentation :
        value : 2
        level : ERROR
        message : 'Line contains inconsistent indentation'

    no_implicit_braces :
        level : IGNORE
        message : 'Implicit braces are forbidden'

    no_trailing_semicolons:
        level : ERROR
        message : 'Line contains a trailing semicolon'

    no_plusplus:
        level : IGNORE
        message : 'The increment and decrement operators are forbidden'

    no_throwing_strings:
        level : ERROR
        message : 'Throwing strings is forbidden'

    cyclomatic_complexity:
        value : 10
        level : IGNORE
        message : 'The cyclomatic complexity is too damn high'

    no_backticks:
        level : ERROR
        message : 'Backticks are forbidden'

    line_endings:
        level : IGNORE
        value : 'unix' # or 'windows'
        message : 'Line contains incorrect line endings'

    no_implicit_parens :
        level : IGNORE
        message : 'Implicit parens are forbidden'

    space_operators :
        level : IGNORE
        message : 'Operators must be spaced properly'


# Some repeatedly used regular expressions.
regexes =
    trailingWhitespace : /[^\s]+[\t ]+\r?$/
    indentation: /\S/
    camelCase: /^[A-Z][a-zA-Z\d]*$/
    trailingSemicolon: /;$/


# Patch the source properties onto the destination.
extend = (destination, sources...) ->
    for source in sources
        (destination[k] = v for k, v of source)
    return destination

# Patch any missing attributes from defaults to source.
defaults = (source, defaults) ->
    extend({}, defaults, source)


# Create an error object for the given rule with the given
# attributes.
createError = (rule, attrs = {}) ->
    level = attrs.level
    if level not in [IGNORE, WARN, ERROR]
        throw new Error("unknown level #{level}")

    if level in [ERROR, WARN]
        attrs.rule = rule
        return defaults(attrs, RULES[rule])
    else
        null

#
# A class that performs regex checks on each line of the source.
#
class LineLinter

    constructor : (source, config, tokensByLine) ->
        @source = source
        @config = config
        @line = null
        @lineNumber = 0
        @tokensByLine = tokensByLine
        @lines = @source.split('\n')
        @lineCount = @lines.length

    lint : () ->
        errors = []
        for line, lineNumber in @lines
            @lineNumber = lineNumber
            @line = line
            error = @lintLine()
            errors.push(error) if error
        errors

    # Return an error if the line contained failed a rule, null otherwise.
    lintLine : () ->
        return @checkTabs() or
               @checkTrailingWhitespace() or
               @checkLineLength() or
               @checkTrailingSemicolon() or
               @checkLineEndings()

    checkTabs : () ->
        # Only check lines that have compiled tokens. This helps
        # us ignore tabs in the middle of multi line strings, heredocs, etc.
        # since they are all reduced to a single token whose line number
        # is the start of the expression.
        indentation = @line.split(regexes.indentation)[0]
        if @lineHasToken() and '\t' in indentation
            @createLineError('no_tabs')
        else
            null

    checkTrailingWhitespace : () ->
        if regexes.trailingWhitespace.test(@line)
            @createLineError('no_trailing_whitespace')
        else
            null

    checkLineLength : () ->
        rule = 'max_line_length'
        max = @config[rule]?.value
        if max and max < @line.length
            @createLineError(rule)
        else
            null

    checkTrailingSemicolon : () ->
        hasSemicolon = regexes.trailingSemicolon.test(@line)
        [first..., last] = @getLineTokens()
        hasNewLine = last and last.newLine?
        # Don't throw errors when the contents of  multiline strings,
        # regexes and the like end in ";"
        if hasSemicolon and not hasNewLine and @lineHasToken()
            @createLineError('no_trailing_semicolons')
        else
            return null

    checkLineEndings : () ->
        rule = 'line_endings'
        ending = @config[rule]?.value

        return null if not ending or @isLastLine() or not @line

        lastChar = @line[@line.length - 1]
        valid = if ending == 'windows'
            lastChar == '\r'
        else if ending == 'unix'
            lastChar != '\r'
        else
            throw new Error("unknown line ending type: #{ending}")
        if not valid
            return @createLineError(rule, {context:"Expected #{ending}"})
        else
            return null


    createLineError : (rule, attrs = {}) ->
        attrs.lineNumber = @lineNumber + 1 # Lines are indexed by zero.
        attrs.level = @config[rule]?.level
        createError(rule, attrs)

    isLastLine : () ->
        return @lineNumber == @lineCount - 1

    # Return true if the given line actually has tokens.
    lineHasToken : () ->
        return @tokensByLine[@lineNumber]?

    # Return tokens for the given line number.
    getLineTokens : () ->
        @tokensByLine[@lineNumber] || []

#
# A class that performs checks on the output of CoffeeScript's
# lexer.
#
class LexicalLinter

    constructor : (source, config) ->
        @source = source
        @tokens = CoffeeScript.tokens(source)
        @config = config
        @i = 0              # The index of the current token we're linting.
        @tokensByLine = {}  # A map of tokens by line.
        @arrayTokens = []   # A stack tracking the array token pairs.
        @parenTokens = []   # A stack tracking the parens token pairs.
        @callTokens = []   # A stack tracking the call token pairs.
        @lines = source.split('\n')

    # Return a list of errors encountered in the given source.
    lint : () ->
        errors = []
        for token, i in @tokens
            @i = i
            error = @lintToken(token)
            errors.push(error) if error
        errors

    # Return an error if the given token fails a lint check, false
    # otherwise.
    lintToken : (token) ->
        [type, value, lineNumber] = token

        @tokensByLine[lineNumber] ?= []
        @tokensByLine[lineNumber].push(token)
        # CoffeeScript loses line numbers of interpolations and multi-line
        # regexes, so fake it by using the last line number we know.
        @lineNumber = lineNumber or @lineNumber or 0

        # Now lint it.
        switch type
            when "INDENT"                 then @lintIndentation(token)
            when "CLASS"                  then @lintClass(token)
            when "{"                      then @lintBrace(token)
            when "++", "--"               then @lintIncrement(token)
            when "THROW"                  then @lintThrow(token)
            when "[", "]"                 then @lintArray(token)
            when "(", ")"                 then @lintParens(token)
            when "JS"                     then @lintJavascript(token)
            when "CALL_START", "CALL_END" then @lintCall(token)
            when "+", "-"                 then @lintPlus(token)
            when "=", "MATH", "COMPARE", "LOGIC"
                @lintMath(token)
            else null

    # Lint the given array token.
    lintArray : (token) ->
        # Track the array token pairs
        if token[0] == '['
            @arrayTokens.push(token)
        else if token[0] == ']'
            @arrayTokens.pop()
        # Return null, since we're not really linting
        # anything here.
        null

    lintParens : (token) ->
        if token[0] == '('
            p1 = @peek(-1)
            n1 = @peek(1)
            n2 = @peek(2)
            # String interpolations start with '' + so start the type co-ercion,
            # so track if we're inside of one. This is most definitely not
            # 100% true but what else can we do?
            i = n1 and n2 and n1[0] == 'STRING' and n2[0] == '+'
            token.isInterpolation = i
            @parenTokens.push(token)
        else
            @parenTokens.pop()
        # We're not linting, just tracking interpolations.
        null

    isInInterpolation : () ->
        for t in @parenTokens
            return true if t.isInterpolation
        return false

    isInExtendedRegex : () ->
        for t in @callTokens
            return true if t.isRegex
        return false

    lintPlus : (token) ->
        # We can't check this inside of interpolations right now, because the
        # plusses used for the string type co-ercion are marked not spaced.
        return null if @isInInterpolation() or @isInExtendedRegex()

        p = @peek(-1)
        unaries = ['TERMINATOR', '(', '=', '-', '+', ',', 'CALL_START',
                    'INDEX_START', '..', '...', 'COMPARE', 'IF',
                    'THROW', 'LOGIC', 'POST_IF', ':', '[', 'INDENT']
        isUnary = if not p then false else p[0] in unaries
        if (isUnary and token.spaced) or
                    (not isUnary and not token.spaced and not token.newLine)
            @createLexError('space_operators', {context: token[1]})
        else
            null

    lintMath: (token) ->
        if not token.spaced and not token.newLine
            @createLexError('space_operators', {context: token[1]})
        else
            null

    lintCall : (token) ->
        if token[0] == 'CALL_START'
            p = @peek(-1)
            # Track regex calls, to know (approximately) if we're in an
            # extended regex.
            token.isRegex = p and p[0] == 'IDENTIFIER' and p[1] == 'RegExp'
            @callTokens.push(token)
            if token.generated
                return @createLexError('no_implicit_parens')
            else
                return null
        else
            @callTokens.pop()
            return null

    lintBrace : (token) ->
        if token.generated
            # Peek back to the last line break. If there is a class
            # definition, ignore the generated brace.
            i = -1
            loop
                t = @peek(i)
                if not t? or t[0] == 'TERMINATOR'
                    return @createLexError('no_implicit_braces')
                if t[0] == 'CLASS'
                    return null
                i -= 1
        else
            return null

    lintJavascript :(token) ->
        @createLexError('no_backticks')

    lintThrow : (token) ->
        [n1, n2] = [@peek(), @peek(2)]
        # Catch literals and string interpolations, which are wrapped in
        # parens.
        nextIsString = n1[0] == 'STRING' or (n1[0] == '(' and n2[0] == 'STRING')
        @createLexError('no_throwing_strings') if nextIsString

    lintIncrement : (token) ->
        attrs = {context : "found '#{token[0]}'"}
        @createLexError('no_plusplus', attrs)

    # Return an error if the given indentation token is not correct.
    lintIndentation : (token) ->
        [type, numIndents, lineNumber] = token

        return null if token.generated?

        # HACK: CoffeeScript's lexer insert indentation in string
        # interpolations that start with spaces e.g. "#{ 123 }"
        # so ignore such cases. Are there other times an indentation
        # could possibly follow a '+'?
        previous = @peek(-2)
        isInterpIndent = previous and previous[0] == '+'

        # Ignore the indentation inside of an array, so that
        # we can allow things like:
        #   x = ["foo",
        #             "bar"]
        previous = @peek(-1)
        isArrayIndent = @inArray() and previous?.newLine

        # Ignore indents used to for formatting on multi-line expressions, so
        # we can allow things like:
        #   a = b =
        #     c = d
        previousSymbol = @peek(-1)?[0]
        isMultiline = previousSymbol in ['=', ',']

        # Summarize the indentation conditions we'd like to ignore
        ignoreIndent = isInterpIndent or isArrayIndent or isMultiline

        # Compensate for indentation in function invocations that span multiple
        # lines, which can be ignored.
        if @isChainedCall()
            previousLine = @lines[@lineNumber - 1]
            previousIndentation = previousLine.match(/^(\s*)/)[1].length
            numIndents -= previousIndentation

        # Now check the indentation.
        expected = @config['indentation'].value
        if not ignoreIndent and numIndents != expected
            context = "Expected #{expected} " +
                      "got #{numIndents}"
            @createLexError('indentation', {context})
        else
            null

    lintClass : (token) ->
        # TODO: you can do some crazy shit in CoffeeScript, like
        # class func().ClassName. Don't allow that.

        # Don't try to lint the names of anonymous classes.
        return null if token.newLine? or @peek()[0] in ['INDENT', 'EXTENDS']

        # It's common to assign a class to a global namespace, e.g.
        # exports.MyClassName, so loop through the next tokens until
        # we find the real identifier.
        className = null
        offset = 1
        until className
            if @peek(offset + 1)?[0] == '.'
                offset += 2
            else if @peek(offset)?[0] == '@'
                offset += 1
            else
                className = @peek(offset)[1]

        # Now check for the error.
        if not regexes.camelCase.test(className)
            attrs = {context: "class name: #{className}"}
            @createLexError('camel_case_classes', attrs)
        else
            null

    createLexError : (rule, attrs = {}) ->
        attrs.lineNumber = @lineNumber + 1
        attrs.level = @config[rule].level
        attrs.line = @lines[@lineNumber]
        createError(rule, attrs)

    # Return the token n places away from the current token.
    peek : (n = 1) ->
        @tokens[@i + n] || null

    # Return true if the current token is inside of an array.
    inArray : () ->
        return @arrayTokens.length > 0

    # Return true if the current token is part of a property access
    # that is split across lines, for example:
    #   $('body')
    #       .addClass('foo')
    #       .removeClass('bar')
    isChainedCall : () ->
        # Get the index of the second most recent new line.
        lines = (i for token, i in @tokens[..@i] when token.newLine?)

        lastNewLineIndex = if lines then lines[lines.length - 2] else null

        # Bail out if there is no such token.
        return false if not lastNewLineIndex?

        # Otherwise, figure out if that token or the next is an attribute
        # look-up.
        tokens = [@tokens[lastNewLineIndex], @tokens[lastNewLineIndex + 1]]

        return !!(t for t in tokens when t and t[0] == '.').length


# A class that performs static analysis of the abstract
# syntax tree.
class ASTLinter

    constructor : (source, config) ->
        @source = source
        @config = config
        @node = CoffeeScript.nodes(source)
        @errors = []

    lint : () ->
        @lintNode(@node)
        @errors

    # Lint the AST node and return it's cyclomatic complexity.
    lintNode : (node) ->

        # Get the complexity of the current node.
        name = node.constructor.name
        complexity = if name in ['If', 'While', 'For', 'Try']
            1
        else if name == 'Op' and node.operator in ['&&', '||']
            1
        else if name == 'Switch'
            node.cases.length
        else
            0

        # Add the complexity of all child's nodes to this one.
        node.eachChild (childNode) =>
            return false unless childNode
            complexity += @lintNode(childNode)
            return true

        # If the current node is a function, and it's over our limit, add an
        # error to the list.
        rule = @config.cyclomatic_complexity
        if name == 'Code' and complexity >= rule.value
            attrs = {
                context: complexity + 1
                level: rule.level
                line: 0
            }
            error = createError 'cyclomatic_complexity', attrs
            @errors.push error if error

        # Return the complexity for the benefit of parent nodes.
        return complexity


# Merge default and user configuration.
mergeDefaultConfig = (userConfig) ->
    config = {}
    for rule, ruleConfig of RULES
        config[rule] = defaults(userConfig[rule], ruleConfig)
    return config


# Check the source against the given configuration and return an array
# of any errors found. An error is an object with the following
# properties:
#
#   {
#       rule :      'Name of the violated rule',
#       lineNumber: 'Number of the line that caused the violation',
#       level:      'The error level of the violated rule',
#       message:    'Information about the violated rule',
#       context:    'Optional details about why the rule was violated'
#   }
#
coffeelint.lint = (source, userConfig = {}) ->
    config = mergeDefaultConfig(userConfig)

    # Do lexical linting.
    lexicalLinter = new LexicalLinter(source, config)
    lexErrors = lexicalLinter.lint()

    # Do line linting.
    tokensByLine = lexicalLinter.tokensByLine
    lineLinter = new LineLinter(source, config, tokensByLine)
    lineErrors = lineLinter.lint()

    # Do AST linting.
    astErrors = new ASTLinter(source, config).lint()

    # Sort by line number and return.
    errors = lexErrors.concat(lineErrors, astErrors)
    errors.sort((a, b) -> a.lineNumber - b.lineNumber)
    errors

