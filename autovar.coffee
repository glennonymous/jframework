class J.AutoVar
    @COMPUTING: {name: "J.AutoVar.COMPUTING"}

    constructor: (tag, valueFunc, onChange, options) ->
        ###
            AutoVars default to being "lazy", i.e. not calculated
            until .get().

            onChange:
                A function to call with (oldValue, newValue) when
                the value changes.
                May also pass onChange=true or null.
                If onChange is either a function or true, the
                AutoVar becomes non-lazy.

            options:
                creator: Set a different creator computation.
        ###

        unless @ instanceof J.AutoVar
            return new J.AutoVar tag, valueFunc, onChange, options

        if _.isFunction tag
            # Alternate signature: J.AutoVar(valueFunc, onChange, options)
            options = onChange
            onChange = valueFunc
            valueFunc = tag
            tag = undefined

        unless _.isFunction(valueFunc)
            throw new Meteor.Error "AutoVar must be constructed with valueFunc"

        unless not onChange? or _.isFunction(onChange) or onChange is true
            throw new Meteor.Error "AutoVar onChange must be either null or a function
                or true (true simply forces non-lazy first evaluation): #{onChange}"

        @_id = J.getNextId()
        if J.debugGraph then J.graph[@_id] = @

        @tag = tag
        @valueFunc = valueFunc
        @onChange = onChange ? null
        if options?.creator is undefined
            @creator = Tracker.currentComputation
        else
            @creator = options.creator

        # We can't use @_valueComp.invalidated because when @_valueComp
        # invalidates itself, it schedules it to happen at afterFlush time.
        @_invalidated = false

        @_active = true
        @creator?.onInvalidate =>
            @stop()

        @_var = null
        @_valueComp = null
        if @onChange
            # Truthy onChange means do a non-lazy first run
            # of valueFunc.
            Tracker.afterFlush J.bindEnvironment =>
                if @isActive() and not @_valueComp?
                    @_setupValueComp()


    _setupValueComp: ->
        Tracker.nonreactive => Tracker.autorun J.bindEnvironment (c) =>
            if c.firstRun
                # Important to do this here in case @stop() is called during the
                # first run of the computation.
                @_valueComp = c
                @_valueComp.autoVar = @
                @_valueComp.tag = "#{@toString()} valueComp"

                @_var = new J.Var J.Var.NOT_READY,
                    tag:
                        autoVar: @
                        tag: "Var for AutoVar[#{@_id}](#{J.util.stringifyTag @tag})"
                    creator: @_valueComp
                    onChange: if _.isFunction @onChange then @onChange

            @_invalidated = false
            @_valueComp.onInvalidate =>
                # A different computation invalidated this one
                @_invalidated = true
                # console.log "invalidated", @toString()

            console.log "Recomputing ", @toString()
            try
                # ValueFunc may either return or throw J.Var.NOT_READY
                # or throw J.COMPUTING. It may not return undefined.
                value = @valueFunc.call null, @

            catch e
                if e is J.Var.NOT_READY
                    @_var.set J.Var.NOT_READY
                    return

                else if e is J.AutoVar.COMPUTING
                    console.log "...", @toString(), "got COMPUTING"
                    # We want @_valueComp to invalidate itself, but we want
                    # the recalculation to happen at the end of the flush
                    # queue (FIFO flushing), not right away. That's why
                    # we're using afterFlush.
                    @_invalidated = true
                    Tracker.afterFlush =>
                        # Make sure we haven't already recomputed this.
                        J.assert @_invalidated, "Nothing else should be able
                            to invalidate this. The Vars it accessed should
                            all have stable values."
                        @_valueComp.invalidate()
                    return

                else
                    throw e

            if value is undefined
                throw new Meteor.Error "#{@toString()}.valueFunc must not return undefined."

            console.log "...", @toString(), "recomputed: ", value

            @_var.set value



    get: ->
        unless @isActive()
            console.error()
            throw new Meteor.Error "#{@constructor.name} ##{@_id} is stopped: #{@}."

        if arguments.length
            throw new Meteor.Error "Can't pass argument to AutoVar.get"

        if Meteor.isServer and J._inMethod.get()
            return @valueFunc.call null, @

        if not @_valueComp?
            console.log "GET", @toString(), "[first time]"
            # Getting a lazy AutoVar for the first time
            @_setupValueComp()
            if @_valueComp.invalidated then console.log "#{@toString()} invalidated during first get!"
        else
            console.log "GET", @toString() + (if @_valueComp.invalidated then "(invalidated)" else '')

        if @currentValueMightChange()
            if Tracker.active
                # Add a dependency to the @_var in case its value changes
                # when the recompute is done.
                throw J.AutoVar.COMPUTING
            else
                return undefined

        @_var.get()


    isActive: ->
        @_active


    currentValueMightChange: ->
        # Returns true @_var.value might change between now
        # and the end of the current flush (or the end of
        # hypothetically calling Tracker.flush() now).
        # Note that true doesn't mean the current value
        # *will* change. It's possible that all invalidated
        # dependency values will recompute themselves to have
        # the same value, and thereby stop @_valueComp from
        # ever invalidating.
        if @_invalidated
            return true
        for varId, v of @_valueComp.gets
            if v.creator?.autoVar?
                if v.creator.autoVar.currentValueMightChange()
                    return true
            else if v.creator?
                if v.creator.invalidated
                    return true
        false


    set: ->
        throw new Meteor.Error "There is no AutoVar.set"


    stop: ->
        if @_active
            @_active = false
            @_valueComp?.stop()


    toString: ->
        s = "AutoVar[#{J.util.stringifyTag @tag ? ''}##{@_id}]=#{J.util.stringify @_var?._value}"
        if not @isActive() then s += " (inactive)"
        s