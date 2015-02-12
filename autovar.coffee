###
    TODO:

    Make a J.ReactiveVar class which is like Meteor's ReactiveVar
    but has a bunch of functions powered by finer-grained deps like:
        general:
            equals
        numbers:
            lessThan, greaterThan, lessThanOrEq, greaterThanOrEq
        arrays:
            contains (can keep an object-set for this)
    have J.AutoVar inherit from J.ReactiveVar

###

class J.AutoVar
    @_nextId = 0
    @_byId = {}
    J.a = @_byId

    constructor: (tag, valueFunc, onChange, equalsFunc, wrap) ->
        ###
            AutoVars default to being "lazy", i.e. not calculated
            until .get().

            onChange:
                A function to call with (oldValue, newValue) when
                the value changes.
                May also pass onChange=true or null.
                If onChange is either a function or true, the
                AutoVar becomes non-lazy.
        ###

        @_bindEnvironment = if Meteor.isServer then Meteor.bindEnvironment else _.identity

        unless @ instanceof J.AutoVar
            return new J.AutoVar tag, valueFunc, onChange, equalsFunc, wrap

        if _.isFunction tag
            # Alternate signature: J.AutoVar(valueFunc, onChange, equalsFunc, wrap)
            wrap = equalsFunc
            equalsFunc = onChange
            onChange = valueFunc
            valueFunc = tag
            tag = undefined

        unless _.isFunction(valueFunc)
            throw new Meteor.Error "AutoVar must be constructed with valueFunc"

        unless not onChange? or _.isFunction(onChange) or onChange is true
            throw new Meteor.Error "Invalid onChange argument: #{onChange}"

        @_id = @constructor._nextId
        @constructor._nextId += 1
        @constructor._byId[@_id] = @

        @tag = tag
        @valueFunc = valueFunc
        @onChange = onChange ? null
        @equalsFunc = equalsFunc ? J.util.equals
        @wrap = wrap ? true

        @_var = new ReactiveVar undefined, @equalsFunc
        @_fetchInProgress = false
        @_getting = false
        @_gettersById = {} # computationId: computation

        @active = true
        if Tracker.active then Tracker.onInvalidate => @stop()

        @_valueComp = null
        if @onChange then Tracker.afterFlush @_bindEnvironment =>
            if @active and not @_valueComp?
                @_setupValueComp()

    _deepGet: ->
        ###
            Unwrap any nested AutoVars during get(). This is because
            @valueFunc may get a performance benefit from isolating
            part of its reactive logic in an AutoVar.
        ###
        value = @_var.get()
        if value instanceof J.AutoVar then value.get() else value

    _recompute: ->
        J.assert @active

        oldValue = Tracker.nonreactive => @_deepGet()

        try
            # Pass a @ just like autorun does. This will help in case
            # we ever decide to compute @valueFunc the first time
            # synchronously.
            rawValue = @valueFunc.call null, @

            if @_fetchInProgress
                @_fetchInProgress = false

                # We already make a @_var.set call later. These invalidations
                # are just necessary if the new value is the same as the
                # pre-fetch value.
                for computationId, computation of @_var.dep._dependentsById
                    computation.invalidate()

            if rawValue instanceof J.Dict or rawValue instanceof J.List
                rawValue.tag ?= "contents of (#{@tag}-#{@_id})"

        catch e
            throw e unless Meteor.isClient and e is J.fetching.FETCH_IN_PROGRESS

            if not @_fetchInProgress
                @_fetchInProgress = true

                # While we're either throwing an error or returning
                # undefined, the value of @_var may still be an old
                # value from when we previously succeeded in fetching
                # data. When we succeed in fetching data again, the
                # onChange triggers will act like there was never
                # a gap during which data wasn't available.
                # But we want our dependents to think it's changed
                # so we can achieve the same propagation effect
                # as during a normal client-side value invalidation.
                for computationId, computation of @_var.dep._dependentsById
                    computation.invalidate()

            return

        if rawValue is @constructor._UNDEFINED_WITHOUT_SET
            # This is used for the AutoVars of AutoDict fields
            # that are getting deleted synchronously (ahead of
            # Tracker.flush) because they just realized that
            # keysFunc doesn't include their key.
            return undefined

        else if rawValue is undefined
            throw new Meteor.Error "#{@toString()}.valueFunc must not return undefined."

        newValue = if @wrap then J.Dict._deepReactify rawValue else rawValue

        @_var.set newValue
        console.log @tag, @_id, "recomputed new value of", newValue, newValue?.active

        if _.isFunction(@onChange) and not @equalsFunc oldValue, newValue
            Tracker.afterFlush @_bindEnvironment =>
                if @active
                    # Only call onChange if we're still active, even though
                    # there may be multiple onChange calls queued up from when
                    # we were still active.
                    @onChange.call @, oldValue, newValue

    _setupValueComp: ->
        console.log "_setupValueComp", @tag, @_id, @_valueComp?, (a.tag for a in @constructor._pending)
        J.assert @active

        @_valueComp?.stop()
        Tracker.nonreactive => Tracker.autorun @_bindEnvironment (c) =>
            if c.firstRun
                # Important to do this here in case @stop() is called during the
                # first run of the computation.
                @_valueComp = c
                @_valueComp.tag = "AutoVar #{@tag}-#{@_id}"
                @_valueComp.autoVar = @

            pos = @constructor._pending.indexOf @
            if pos >= 0
                @constructor._pending.splice pos, 1

            @_recompute()

            @_valueComp.onInvalidate =>
                console.log "INVALIDATED", @tag, @_id
                unless @_valueComp.stopped
                    if @ not in @constructor._pending
                        @constructor._pending.push @

            if @_getting and @_fetchInProgress
                # Meteor stops computations that error on their
                # first run, so don't throw an error here.
                throw J.fetching.FETCH_IN_PROGRESS unless @_valueComp.firstRun

        if @_getting and @_fetchInProgress
            # Now throw that error, after Meteor is done
            # setting up the first run.
            throw J.fetching.FETCH_IN_PROGRESS


    get: ->
        unless @active
            console.error()
            throw "#{@constructor.name} ##{@_id} is stopped: #{@}.
                Getter: #{Tracker.currentComputation?.tag} ###{Tracker.currentComputation?._id}"
        if arguments.length
            throw new Meteor.Error "Can't pass argument to AutoVar.get"

        if Meteor.isServer and J._inMethod.get()
            value = @valueFunc.call null, @
            if @wrap
                value = J.Dict._deepReactify value
            if value instanceof J.AutoVar
                value = value.get()
            return value

        if Tracker.active
            # Track _gettersById for debugging
            computation = Tracker.currentComputation
            @_gettersById[computation._id] = computation
            computation.onInvalidate =>
                delete @_gettersById[computation._id]

        console.log "GET", @tag, @_id, @_valueComp?, (a.tag for a in @constructor._pending)
        if @_valueComp?
            # Note that @ itself may or may not be in @constructor._pending now,
            # and it may also find itself in @constructor._pending during the flush.
            @constructor.flush()
        else
            @_getting = true
            try
                @_setupValueComp()
            catch e
                throw e unless Meteor.isClient and e is J.fetching.FETCH_IN_PROGRESS
            @_getting = false

        if @_fetchInProgress
            if Tracker.active
                # Call this just to set up the dependency
                # between @ and the caller.
                @_deepGet()
                throw J.fetching.FETCH_IN_PROGRESS
            else
                return undefined

        @_deepGet()

    set: ->
        throw new Meteor.Error "There is no AutoVar.set"

    setDebug: (@debug) ->

    stop: ->
        if @active
            @active = false
            @_valueComp?.stop()
            pos = @constructor._pending.indexOf @
            if pos >= 0
                @constructor._pending.splice pos, 1

    logDebugInfo: ->
        getters = _.values @_gettersById
        console.groupCollapsed @toString()
        for c in getters
            if c.autoVar?
                c.autoVar.logDebugInfo()
            else
                console.log c.tag
        console.groupEnd()

    toString: ->
        if @tag?
            "AutoVar(#{@tag}-#{@_id}=#{J.util.stringify @_var.get()})"
        else
            "AutoVar(#{@_id=J.util.stringify @_var.get()})"


    @_pending: []

    @flush: ->
        while @_pending.length
            av = @_pending.shift()
            av._setupValueComp()

    # Internal classes return this in @_valueFunc
    # in order to make .get() return undefined
    @_UNDEFINED_WITHOUT_SET = {'AutoVar':'UNDEFINED_WITHOUT_SET'}