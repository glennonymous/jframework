###
    A few things to augment Meteor's Tracker.

    We monkey patch the tracker package because
    we want other Meteor packages like "mongo"
    to use the same global object.
###


`
var dummyComputation = Tracker.autorun(function() {});
if (dummyComputation._id !== 1) {
    // A computation was already created by one of the packages that jframework
    // uses, which means it may be too late for our monkey patch to work right.
    console.warn("JFramework's attempt to monkey patch Tracker might not work.");
}

var setCurrentComputation = function (c) {
    Tracker.currentComputation = c;
    Tracker.active = !! c;
};

var _debugFunc = function () {
    return (typeof Meteor !== "undefined" ? Meteor._debug :
    ((typeof console !== "undefined") && console.log ?
        function () { console.log.apply(console, arguments); } :
    function () {}));
};

var _throwOrLog = function (from, e) {
    if (true || throwFirstError) {
        // XXX JFramework - always take this branch
        throw e;
    } else {
        var messageAndStack;
        if (e.stack && e.message) {
            var idx = e.stack.indexOf(e.message);
                if (idx >= 0 && idx <= 10) // allow for "Error: " (at least 7)
                    messageAndStack = e.stack; // message is part of e.stack, as in Chrome
                else
                    messageAndStack = e.message +
                        (e.stack.charAt(0) === '\n' ? '' : '\n') + e.stack; // e.g. Safari
        } else {
            messageAndStack = e.stack || e.message;
        }

        _debugFunc()("Exception from Tracker " + from + " function:",
            messageAndStack, e);
    }
};

var withNoYieldsAllowed = function (f) {
    if ((typeof Meteor === 'undefined') || Meteor.isClient) {
        return f;
    } else {
        return function () {
            var args = arguments;
            Meteor._noYieldsAllowed(function () {
                f.apply(null, args);
            });
        };
    }
};

var nextId = 1;
var pendingComputations = [];

// true if a Tracker.flush is scheduled, or if we are in Tracker.flush now
var willFlush = false;

// true if we are in Tracker.flush now
var inFlush = false;

// true if we are computing a computation now, either first time
// or recompute.  This matches Tracker.active unless we are inside
// Tracker.nonreactive, which nullfies currentComputation even though
// an enclosing computation may still be running.
var inCompute = false;

// true if the _throwFirstError option was passed in to the call
// to Tracker.flush that we are in. When set, throw rather than log the
// first error encountered while flushing. Before throwing the error,
// finish flushing (from a finally block), logging any subsequent
// errors.
var throwFirstError = false;

var afterFlushCallbacks = [];

var requireFlush = function () {
    if (! willFlush) {
        setTimeout(Tracker.flush, 1);
        willFlush = true;
    }
};

// Tracker.Computation constructor is visible but private
// (throws an error if you try to call it)
var constructingComputation = false;

Tracker.Computation = function (f, parent) {
    if (! constructingComputation)
        throw new Error(
            "Tracker.Computation constructor is private; use Tracker.autorun");
    constructingComputation = false;

    var self = this;

    self.stopped = false;

    self.invalidated = false;

    self.firstRun = true;

    self._id = nextId++;
    self._onInvalidateCallbacks = [];

    self._parent = parent;
    self._func = f;
    self._recomputing = false;

    var errored = true;
    try {
        self._compute();
        errored = false;
    } finally {
        self.firstRun = false;
        if (errored)
            self.stop();
    }
};

Tracker.Computation.prototype.onInvalidate = function (f) {
    var self = this;

    if (typeof f !== 'function')
        throw new Error("onInvalidate requires a function");

    // XXX JFramework wrapping with bindEnvironment
    if (Meteor.isServer) {
        f = Meteor.bindEnvironment(f);
    }

    if (self.invalidated) {
        Tracker.nonreactive(function () {
            withNoYieldsAllowed(f)(self);
        });
    } else {
        self._onInvalidateCallbacks.push(f);
    }
};


Tracker.Computation.prototype.invalidate = function () {
    var self = this;
    if (! self.invalidated) {
        // if we're currently in _recompute(), don't enqueue
        // ourselves, since we'll rerun immediately anyway.
        if (! self._recomputing && ! self.stopped) {
        requireFlush();
            pendingComputations.push(this);
        }

        self.invalidated = true;

        // callbacks can't add callbacks, because
        // self.invalidated === true.
        for(var i = 0, f; f = self._onInvalidateCallbacks[i]; i++) {
            Tracker.nonreactive(function () {
                withNoYieldsAllowed(f)(self);
            });
        }
        self._onInvalidateCallbacks = [];
    }
};


Tracker.Computation.prototype.stop = function () {
    if (! this.stopped) {
        this.stopped = true;
        this.invalidate();
    }
};


Tracker.Computation.prototype._compute = function () {
    var self = this;
    self.invalidated = false;

    var previous = Tracker.currentComputation;
    setCurrentComputation(self);
    var previousInCompute = inCompute;
    inCompute = true;
    try {
        withNoYieldsAllowed(self._func)(self);
    } finally {
        setCurrentComputation(previous);
        inCompute = previousInCompute;
    }
};


Tracker.Computation.prototype._recompute = function () {
    var self = this;

    self._recomputing = true;
    try {
        while (self.invalidated && ! self.stopped) {
            try {
                self._compute();
            } catch (e) {
                _throwOrLog("recompute", e);
            }
        }
    } finally {
        self._recomputing = false;
    }
};


Tracker.flush = function (_opts) {
    console.debug("Tracker.flush!");

    if (inFlush)
        throw new Error("Can't call Tracker.flush while flushing");

    if (inCompute)
        throw new Error("Can't flush inside Tracker.autorun");

    inFlush = true;
    willFlush = true;
    throwFirstError = !! (_opts && _opts._throwFirstError);

    var finishedTry = false;
    try {
        while (pendingComputations.length ||
            afterFlushCallbacks.length) {

            // recompute all pending computations
            while (pendingComputations.length) {
                var comp = pendingComputations.shift();
                comp._recompute();
            }

            if (afterFlushCallbacks.length) {
                // XXX JFramework feature
                J.util.sortByKey(afterFlushCallbacks, function (afc) {
                    return afc.sortKey;
                });

                // call one afterFlush callback, which may
                // invalidate more computations
                var afc = afterFlushCallbacks.shift();
                try {
                    afc.func.call(null);
                } catch (e) {
                    _throwOrLog("afterFlush", e);
                }
            }
        }

        finishedTry = true;

    } finally {
        if (! finishedTry) {
            // we're erroring
            inFlush = false; // needed before calling Tracker.flush() again
            Tracker.flush({_throwFirstError: false}); // finish flushing
        }

        willFlush = false;
        inFlush = false;
    }
};


Tracker.autorun = function (f) {
    if (typeof f !== 'function')
        throw new Error('Tracker.autorun requires a function argument');

    // XXX JFramework wrapping with bindEnvironment
    if (Meteor.isServer) {
        f = Meteor.bindEnvironment(f);
    }

    constructingComputation = true;
    var c = new Tracker.Computation(f, Tracker.currentComputation);

    if (Tracker.active)
        Tracker.onInvalidate(function () {
            c.stop();
        });

    return c;
};


Tracker.nonreactive = function (f) {
    var previous = Tracker.currentComputation;
    setCurrentComputation(null);
    try {
        return f();
    } finally {
        setCurrentComputation(previous);
    }
};


Tracker.onInvalidate = function (f) {
    if (! Tracker.active)
        throw new Error("Tracker.onInvalidate requires a currentComputation");

    Tracker.currentComputation.onInvalidate(f);
};


Tracker.afterFlush = function (f, sortKey) {
    // XXX Adding sortKey for JFramework

    if (sortKey == null) {
        sortKey = 0.5;
    }
    if (!(_.isNumber(sortKey) && 0 <= sortKey && sortKey <= 1)) {
        throw new Error("afterFlush sortKey must be a number between 0 and 1 (lower comes first)");
    }

    if (Meteor.isServer) {
        // XXX JFramework wrapping with bindEnvironment
        func = Meteor.bindEnvironment(f);
    } else {
        func = f;
    }

    afterFlushCallbacks.push({func: func, sortKey: sortKey});
    requireFlush();
};
`


class Tracker.Dependency
    ###
        Like Meteor's Tracker.Dependency except that a "creator",
        i.e. a reactive data source, should be able to freely read
        its own reactive values as it's mutating them without
        invalidating itself.
        But the creator should still invalidate if it reads
        its own values which other objects then mutate.
    ###

    constructor: (@creator = Tracker.currentComputation) ->
        @_dependentsById = {}


    depend: (computation) ->
        if not computation?
            return false if not Tracker.active
            computation = Tracker.currentComputation

        id = computation._id
        if id of @_dependentsById
            false
        else
            @_dependentsById[id] = computation
            computation.onInvalidate =>
                delete @_dependentsById[id]
            true


    changed: ->
        for id, computation of @_dependentsById
            unless computation is Tracker.currentComputation is @creator
                @_dependentsById[id].invalidate()


    hasDependents: ->
        not _.isEmpty @_dependentsById
