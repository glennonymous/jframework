###
    TODO: Add a @observe() and @observeChanges() just like
    Meteor's collection API. Good for List and AutoList.
###


class J.List
    constructor: (arr = [], equalsFunc = J.util.equals) ->
        unless @ instanceof J.List
            return new J.List arr, equalsFunc

        if arr instanceof J.List
            @tag ?= "constructor copy of (#{arr.tag})"
            arr = arr.getValues()

        unless _.isArray arr
            throw new Meteor.Error "Not an array: #{arr}"

        @equalsFunc = equalsFunc

        fields = {}
        for x, i in arr
            fields[i] = x

        @readOnly = false

        @_dict = J.Dict fields

    _resize: (size) ->
        @_dict.replaceKeys ("#{i}" for i in [0...size])

    clear: ->
        @resize 0

    clone: ->
        # Nonreactive because a clone's fields are their
        # own new piece of application state
        @constructor Tracker.nonreactive => @getValues()

    contains: (value) ->
        # Reactive.
        # The current implementation invalidates somewhat
        # too much.
        # We could make the reactivity more efficient by
        # using a special hashSet of @_containsDeps
        # (one per value argument), but it would be
        # tricky to handle calls to @contains(v)
        # when v isn't J.Dict.encodeKey-able.
        @indexOf(value) >= 0

    deepEquals: (x) ->
        # Reactive
        return false unless x instanceof @constructor
        J.util.deepEquals @toArr(), x.toArr()

    extend: (values) ->
        valuesArr =
            if values instanceof J.List
                values.getValues()
            else values

        adder = {}
        for value, i in valuesArr
            adder["#{@size() + i}"] = value
        @_dict.setOrAdd adder

    find: (f = _.identity) ->
        # Reactive
        for i in [0...@size()]
            x = @get i
            return x if f x

    filter: (f = _.identity) ->
        # Reactive
        filtered = J.List _.filter @map().getValues(), f
        filtered.tag = "filtered #{@tag}"
        filtered

    forEach: (f) ->
        # Reactive
        # Like @map but:
        # - Lets you return undefined
        # - Returns an array, not an AutoList
        UNDEFINED = {}
        mappedList = @map (v, i) ->
            ret = f v, i
            if ret is undefined then UNDEFINED else ret
        for value in mappedList.getValues()
            if value is UNDEFINED then undefined else value

    get: (index) ->
        # Reactive
        unless _.isNumber(index)
            throw new Meteor.Error "Index must be a number"
        try
            @_dict.forceGet "#{index}"
        catch e
            throw e
            # TODO: look for missing-key and throw new Meteor.Error "List index out of range"

    getConcat: (lst) ->
        # Reactive
        if _.isArray lst then lst = J.List lst
        if Tracker.active
            J.AutoList(
                =>
                    @size() + lst.size()
                (i) =>
                    if i < @size()
                        @get i
                    else
                        lst.get i - @size()
            )
        else
            J.List @getValues().concat lst.getValues()

    getReversed: ->
        # Reactive
        @map (value, i) => @get @size() - 1 - i

    getSorted: (keySpec = J.util.sortKeyFunc) ->
        # Reactive
        sortKeys = @map(J.util._makeSortKeyFunc keySpec).getValues() # Good to do this in parallel
        items = _.map @getValues(), (v, i) -> index: i, value: v
        J.List _.map(
            J.util.sortByKey items, (item) -> sortKeys[item.index]
            (item) -> item.value
        )

    getValues: ->
        # Reactive
        @_dict.get "#{i}" for i in [0...@size()]

    join: (separator) ->
        # Reactive
        @map().getValues().join separator

    indexOf: (x, equalsFunc = J.util.equals) ->
        for i in [0...@size()]
            y = @get i
            return i if equalsFunc y, x
        -1

    lazyMap: (f = _.identity) ->
        # Reactive
        if Tracker.active
            J.AutoList(
                => @size()
                (i) => f @get(i), i
                null # This makes it lazy
            )
        else
            J.List @getValues().map f

    map: (f = _.identity) ->
        # Reactive
        # Enables parallel fetching
        if Tracker.active
            if f is _.identity and @ instanceof J.AutoList and @onChange
                @
            else
                mappedAl = J.AutoList(
                    => @size()
                    (i) => f @get(i), i
                    true # This makes it not lazy
                )
                mappedAl.tag = "mapped (#{@tag})"
                mappedAl
        else
            J.List @getValues().map f

    push: (value) ->
        @extend [value]

    resize: (size) ->
        @_resize size

    reverse: ->
        reversedArr = Tracker.nonreactive => @getReversed().toArr()
        @set i, reversedArr[i] for i in [0...reversedArr.length]
        null

    set: (index, value) ->
        if @readOnly
            throw new Meteor.Error "#{@constructor.name} instance is read-only"
        unless _.isNumber(index) and @_dict.hasKey "#{index}"
            throw new Meteor.Error "List index out of range"

        setter = {}
        setter[index] = value
        @_dict.set setter

    setReadOnly: (@readOnly = true, deep = false) ->
        if deep
            @_dict.setReadOnly @readOnly, deep

    sort: (keySpec = J.util.sortKeyFunc) ->
        sortedArr = Tracker.nonreactive => @getSorted(keySpec).toArr()
        @set i, sortedArr[i] for i in [0...sortedArr.length]
        null

    size: ->
        # Reactive
        @_dict.size()

    toArr: ->
        # Reactive
        values = @getValues()

        arr = []
        for value, i in values
            if value instanceof J.Dict
                arr.push value.toObj()
            else if value instanceof J.List
                arr.push value.toArr()
            else
                arr.push value
        arr

    toString: ->
        "List#{J.util.stringify @getValues()}"

    tryGet: (index) ->
        # Reactive
        if @_dict.hasKey "#{index}"
            @get index
        else
            undefined

    @fromDeepArr: (arr) ->
        unless _.isArray arr
            throw new Meteor.Error "Expected an array"

        J.Dict.fromDeepObjOrArr arr