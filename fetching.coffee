# FIXME: EJSON.stringify doesn't canonically order the keys
# so {a: 5, b: 6} and {b: 6, a: 5} look like different
# querySpecs. More generally, we need a querySpec consolidation.


J.fetching =
    SESSION_ID: "#{parseInt Math.random() * 1000}"

    _requestInProgress: false

    # Latest client-side state and whether it's changed since we
    # last called the server's update method
    _requestersByQs: {} # querySpecString: {computationId: computation}
    _requestsChanged: false

    # Snapshot of what the cursors will be after the next _updateDataQueries returns
    _nextUnmergedQsSet: {} # querySpecString: true
    _nextMergedQsSet: {}

    # Snapshot of what we last successfully asked the server for
    _unmergedQsSet: {} # mergedQuerySpecString: true
    _mergedQsSet: {} # mergedQuerySpecString: true


    isQueryReady: (querySpec) ->
        ###
            TODO: Smart isQueryReady
            Synchronously figure out if it's implied by both @_mergedQuerySet
            and @_nexMergedQuerySet. If so, return true.
            Once this is done, we can probably get rid of the @_unmergedQsSet
            and @_nextUnmergedQuerySet variables.
        ###
        qsString = EJSON.stringify querySpec
        qsString of @_unmergedQsSet and qsString of @_nextUnmergedQsSet


    getMerged: (querySpecs) ->
        # TODO: Client-side query merging
        _.clone querySpecs

    remergeQueries: ->
        return if @_requestInProgress or not @_requestsChanged
        @_requestsChanged = false

        newUnmergedQsStrings = _.keys @_requestersByQs
        newUnmergedQuerySpecs = (EJSON.parse qsString for qsString in newUnmergedQsStrings)
        @_nextUnmergedQsSet = {}
        @_nextUnmergedQsSet[qsString] = true for qsString in newUnmergedQsStrings
        unmergedQsStringsDiff = J.util.diffStrings _.keys(@_unmergedQsSet), _.keys(@_nextUnmergedQsSet)

        newMergedQuerySpecs = @getMerged newUnmergedQuerySpecs
        newMergedQsStrings = (EJSON.stringify querySpec for querySpec in newMergedQuerySpecs)
        @_nextMergedQsSet = {}
        @_nextMergedQsSet[qsString] = true for qsString in newMergedQsStrings
        mergedQsStringsDiff = J.util.diffStrings _.keys(@_mergedQsSet), _.keys(@_nextMergedQsSet)

        addedQuerySpecs = (EJSON.parse qsString for qsString in mergedQsStringsDiff.added)
        deletedQuerySpecs = (EJSON.parse qsString for qsString in mergedQsStringsDiff.deleted)

        return unless addedQuerySpecs.length or deletedQuerySpecs.length

        debug = true
        if debug
            consolify = (querySpec) ->
                obj = _.clone querySpec
                for x in ['selector', 'fields', 'sort']
                    if x of obj then obj[x] = J.util.stringify obj[x]
                obj

            if addedQuerySpecs.length
                console.groupCollapsed("+")
                for qsString in unmergedQsStringsDiff.added
                    for computationId, computation of @_requestersByQs[qsString]
                        if computation.autoVar?
                            console.log computation.autoVar
                        else
                            console.log computation
                console.groupEnd()
                console.debug "    ", consolify(qs) for qs in addedQuerySpecs
            if deletedQuerySpecs.length
                console.debug "-"
                console.debug "    ", consolify(qs) for qs in deletedQuerySpecs

        @_requestInProgress = true
        Meteor.call '_updateDataQueries',
            @SESSION_ID,
            addedQuerySpecs,
            deletedQuerySpecs,
            (error, result) =>
                @_requestInProgress = false
                if error
                    console.error "Fetching error:", error
                    return

                @_unmergedQsSet = _.clone @_nextUnmergedQsSet
                @_mergedQsSet = _.clone @_nextMergedQsSet

                for addedUnmergedQsString in unmergedQsStringsDiff.added
                    for computationId in _.keys @_requestersByQs[addedUnmergedQsString] ? {}
                        @_requestersByQs[addedUnmergedQsString][computationId].invalidate()

                # There may be changes to @_requestersByQs that we couldn't act on
                # until this request was done.
                Tracker.afterFlush (=> @remergeQueries()), Math.POSITIVE_INFINITY


    requestQuery: (querySpec) ->
        qsString = EJSON.stringify querySpec

        if Tracker.active
            # We may not need reactivity per se, since the query should
            # never stop once it's started. But we still want to track
            # which computations need this querySpec.
            computation = Tracker.currentComputation
            # console.log computation.tag, 'requests a query', querySpec.modelName,
            #     querySpec.selector, @isQueryReady querySpec
            @_requestersByQs[qsString] ?= {}
            if computation._id not of @_requestersByQs[qsString]
                @_requestersByQs[qsString][computation._id] = computation
                computation.onInvalidate =>
                    # console.log computation.tag, 'cancels a query', computation.stopped,
                    #     querySpec.modelName, querySpec.selector, @isQueryReady querySpec
                    if qsString of @_requestersByQs
                        delete @_requestersByQs[qsString][computation._id]
                        if _.isEmpty @_requestersByQs[qsString]
                            delete @_requestersByQs[qsString]
                    @_requestsChanged = true
                    Tracker.afterFlush (=> @remergeQueries()), Math.POSITIVE_INFINITY

        if @isQueryReady querySpec
            modelClass = J.models[querySpec.modelName]
            options = {}
            for optionName in ['fields', 'sort', 'skip', 'limit']
                if querySpec[optionName]? then options[optionName] = querySpec[optionName]
            return J.List modelClass.find(querySpec.selector, options).fetch()

        if Tracker.active
            @_requestsChanged = true
            Tracker.afterFlush (=> @remergeQueries()), Math.POSITIVE_INFINITY
            throw J.makeValueNotReadyObject()
        else
            undefined