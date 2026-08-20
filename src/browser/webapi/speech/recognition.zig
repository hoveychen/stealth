// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Web Speech recognition: the five webkit-prefixed globals CreepJS counts,
//! plus the two unprefixed spellings they alias to and SpeechRecognitionPhrase.
//!
//! Every one of the counted five is a *prefixed alias* of an unprefixed
//! interface -- measured on a headed Chrome 150, `webkitSpeechRecognition ===
//! SpeechRecognition` and friends are all true, and `.name` reports the
//! unprefixed spelling. So there are five window keys here but only two new
//! interface objects beyond the events, and the aliases are declared with the
//! same `constructor_aliases` mechanism `webkitURL` and `webkitMediaStream`
//! already use.
//!
//! The point of the family is not the constructor list, though: it is that a
//! page which calls `start()` has to *fail the way Chrome fails*. There is no
//! microphone here, and there is none in a headless Chrome either -- measured,
//! start() dispatches `error` with `error = "not-allowed"` and then `end`,
//! roughly 50ms later, and the object can be started again afterwards. An
//! engine where the family is simply absent, or where start() does nothing,
//! reads as differently from Chrome as one where it succeeds.
//!
//! Three of the family's interfaces are deliberately NOT here:
//! SpeechRecognitionAlternative, SpeechRecognitionResult and
//! SpeechRecognitionResultList are absent as globals on Chrome 150 (measured),
//! so shipping them would be as loud a signal as missing one. That is also why
//! `new SpeechRecognitionEvent('x').results` is null rather than an empty list:
//! there is no list interface to make one out of, and null is what Chrome
//! answers.
//!
//! Measured on a headed Chrome 150 over http://localhost:8731 --
//! win63-chrome.json, win64-chrome.json, win65-chrome.json, win66-chrome.json,
//! win67-chrome.json.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const URL = @import("../../URL.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const DOMException = @import("../DOMException.zig");
const dictionary = @import("../dictionary.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

/// As `handlerProperty`, for the properties whose setter takes a non-callable
/// and stores null rather than refusing it.
fn handlerPropertyLenient(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.lenientAccessors(T, which);
}

const Execution = js.Execution;
const String = lp.String;

pub fn registerTypes() []const type {
    return &.{
        SpeechRecognition,
        SpeechGrammar,
        SpeechGrammarList,
        SpeechGrammarList.Iterator,
        SpeechRecognitionEvent,
        SpeechRecognitionErrorEvent,
        SpeechRecognitionPhrase,
    };
}

/// WebIDL `float`: unlike `double`, a non-finite value is a TypeError rather
/// than a silent NaN. Measured on both of the places this engine needs it --
/// `addFromUri(uri, NaN)` and `grammar.weight = 'x'` -- Chrome words it "The
/// provided float value is non-finite." and names the operation or property.
fn restrictedFloat(value: ?js.Value, comptime prefix: []const u8, default: f64, exec: *const Execution) !f64 {
    const v = value orelse return default;
    const number = v.toF64() catch return default;
    if (std.math.isFinite(number) == false) {
        return dictionary.throwTypeError(prefix ++ "The provided float value is non-finite.", exec);
    }
    return number;
}

/// WebIDL's wording for a required operation argument that was not passed. The
/// bridge only produces this for constructors, so the operations spell it out.
fn missingArgument(comptime operation: []const u8, exec: *const Execution) anyerror {
    return dictionary.throwTypeError(
        "Failed to execute '" ++ operation ++ "' on 'SpeechGrammarList': 1 argument required, but only 0 present.",
        exec,
    );
}

// ----------------------------------------------------------------------------
// SpeechGrammar / SpeechGrammarList
// ----------------------------------------------------------------------------

/// One grammar in a SpeechGrammarList. Both members are read/write on Chrome
/// 150 (measured: `src` and `weight` are accessors with setters), which is
/// unusual for this family and worth keeping.
pub const SpeechGrammar = struct {
    _src: String = .empty,
    _weight: f64 = 1,

    pub fn constructor() SpeechGrammar {
        return .{};
    }

    pub fn getSrc(self: *const SpeechGrammar) String {
        return self._src;
    }

    pub fn setSrc(self: *SpeechGrammar, src: String.Global) void {
        self._src = src.str;
    }

    pub fn getWeight(self: *const SpeechGrammar) f64 {
        return self._weight;
    }

    pub fn setWeight(self: *SpeechGrammar, value: ?js.Value, exec: *const Execution) !void {
        self._weight = try restrictedFloat(
            value,
            "Failed to set the 'weight' property on 'SpeechGrammar': ",
            self._weight,
            exec,
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SpeechGrammar);

        pub const Meta = struct {
            pub const name = "SpeechGrammar";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const constructor_aliases = [_][]const u8{"webkitSpeechGrammar"};
        };

        pub const src = bridge.accessor(SpeechGrammar.getSrc, SpeechGrammar.setSrc, .{});
        pub const weight = bridge.accessor(SpeechGrammar.getWeight, SpeechGrammar.setWeight, .{});
        pub const constructor = bridge.constructor(SpeechGrammar.constructor, .{});
    };
};

/// The percent-encoding `addFromString` applies before wrapping its argument in
/// a `data:application/xml,` URI. The keep-set is measured character by
/// character over the whole printable ASCII range (probe-win67.js): the
/// unreserved set plus `!`, `(`, `)`, `*` and `/`. It is neither
/// encodeURI's nor encodeURIComponent's -- `'` is escaped where
/// encodeURIComponent keeps it, and `/` is kept where encodeURIComponent
/// escapes it -- which is exactly why it is measured rather than borrowed.
fn keepsUnescaped(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '.', '_', '~', '!', '(', ')', '*', '/' => true,
        else => false,
    };
}

fn dataUri(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const prefix = "data:application/xml,";

    var extra: usize = 0;
    for (source) |c| {
        if (keepsUnescaped(c) == false) extra += 2;
    }

    const buf = try allocator.alloc(u8, prefix.len + source.len + extra);
    @memcpy(buf[0..prefix.len], prefix);

    var i: usize = prefix.len;
    for (source) |c| {
        if (keepsUnescaped(c)) {
            buf[i] = c;
            i += 1;
            continue;
        }
        buf[i] = '%';
        buf[i + 1] = std.fmt.digitToChar(c >> 4, .upper);
        buf[i + 2] = std.fmt.digitToChar(c & 0x0f, .upper);
        i += 3;
    }
    return buf;
}

/// An ordered list of grammars, indexed and iterable. Chrome 150 carries no
/// `values` on the prototype -- only Symbol.iterator (measured) -- so the
/// engine-wide `values`/Symbol.iterator identity gap does not apply here: there
/// is nothing for it to be identical to.
pub const SpeechGrammarList = struct {
    _items: []*SpeechGrammar = &.{},

    pub fn constructor() SpeechGrammarList {
        return .{};
    }

    pub fn getLength(self: *const SpeechGrammarList) u32 {
        return @intCast(self._items.len);
    }

    fn at(self: *const SpeechGrammarList, index: u32) ?*SpeechGrammar {
        if (index >= self._items.len) {
            return null;
        }
        return self._items[index];
    }

    /// The bridge only produces WebIDL's "N argument(s) required" wording for
    /// constructors, so every required operation argument here is read as an
    /// optional value and refused by hand -- the same shape eme.zig and
    /// payment.zig use.
    pub fn item(self: *const SpeechGrammarList, index_: ?js.Value, exec: *const Execution) !?*SpeechGrammar {
        const value = index_ orelse return missingArgument("item", exec);
        // WebIDL `unsigned long`: 1.7 truncates to 1 and -1 wraps to
        // 4294967295, which is out of range and reads back as null (measured).
        return self.at(value.toU32() catch 0);
    }

    fn append(self: *SpeechGrammarList, src: []const u8, weight: f64, exec: *const Execution) !void {
        const arena = exec._factory._arena;
        const grammar = try exec._factory.create(SpeechGrammar{
            ._src = try String.init(arena, src, .{}),
            ._weight = weight,
        });

        const items = try arena.alloc(*SpeechGrammar, self._items.len + 1);
        @memcpy(items[0..self._items.len], self._items);
        items[self._items.len] = grammar;
        self._items = items;
    }

    /// The string is wrapped in a data: URI rather than stored raw -- Chrome
    /// does the wrapping, and a page that reads `list[0].src` back sees the
    /// URI, not what it passed in.
    pub fn addFromString(self: *SpeechGrammarList, source_: ?js.Value, weight_: ?js.Value, exec: *const Execution) !void {
        const value = source_ orelse return missingArgument("addFromString", exec);
        const weight = try restrictedFloat(
            weight_,
            "Failed to execute 'addFromString' on 'SpeechGrammarList': ",
            1,
            exec,
        );
        const uri = try dataUri(exec._factory._arena, try value.toStringSlice());
        return self.append(uri, weight, exec);
    }

    /// The URI is resolved against the document's base, so a relative one comes
    /// back absolute (measured: `addFromUri(7)` reads back as
    /// `http://localhost:8731/7`).
    pub fn addFromUri(self: *SpeechGrammarList, uri_: ?js.Value, weight_: ?js.Value, exec: *const Execution) !void {
        const value = uri_ orelse return missingArgument("addFromUri", exec);
        const weight = try restrictedFloat(
            weight_,
            "Failed to execute 'addFromUri' on 'SpeechGrammarList': ",
            1,
            exec,
        );
        const uri = try value.toStringSlice();
        const frame = exec.js.global.frame;
        const resolved = URL.resolve(exec._factory._arena, frame.base(), uri, .{}) catch uri;
        return self.append(resolved, weight, exec);
    }

    pub fn iterator(self: *SpeechGrammarList, exec: *const js.Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .list = self }, exec);
    }

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        list: *SpeechGrammarList,

        pub fn next(self: *@This(), _: *const js.Execution) ?*SpeechGrammar {
            const index = self.index;
            const grammar = self.list.at(index) orelse return null;
            self.index = index + 1;
            return grammar;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SpeechGrammarList);

        pub const Meta = struct {
            pub const name = "SpeechGrammarList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const constructor_aliases = [_][]const u8{"webkitSpeechGrammarList"};
        };

        pub const length = bridge.accessor(SpeechGrammarList.getLength, null, .{});
        pub const addFromString = bridge.function(SpeechGrammarList.addFromString, .{ .arity = 1 });
        pub const addFromUri = bridge.function(SpeechGrammarList.addFromUri, .{ .arity = 1 });
        pub const item = bridge.function(SpeechGrammarList.item, .{ .arity = 1 });
        pub const constructor = bridge.constructor(SpeechGrammarList.constructor, .{});

        pub const @"[]" = bridge.indexed(SpeechGrammarList.at, getIndexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(SpeechGrammarList.iterator, .{});

        fn getIndexes(self: *SpeechGrammarList, exec: *const js.Execution) !js.Array {
            const len = self.getLength();
            var arr = exec.js.local.?.newArray(len);
            for (0..len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }
    };
};

// ----------------------------------------------------------------------------
// SpeechRecognitionPhrase
// ----------------------------------------------------------------------------

/// Chrome 150's on-device biasing hint, reachable through
/// `recognition.phrases`. It is *not* one of the fifteen keys CreepJS counts --
/// its table predates the interface -- but Chrome 150 has it, and a global the
/// reference browser has is as much a part of the surface as one it lacks.
pub const SpeechRecognitionPhrase = struct {
    _phrase: String,
    _boost: f64,

    pub fn constructor(phrase: String.Global, boost_: ?js.Value, exec: *const Execution) !SpeechRecognitionPhrase {
        return .{
            ._phrase = phrase.str,
            ._boost = try restrictedFloat(
                boost_,
                "Failed to construct 'SpeechRecognitionPhrase': ",
                1,
                exec,
            ),
        };
    }

    pub fn getPhrase(self: *const SpeechRecognitionPhrase) String {
        return self._phrase;
    }

    pub fn getBoost(self: *const SpeechRecognitionPhrase) f64 {
        return self._boost;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SpeechRecognitionPhrase);

        pub const Meta = struct {
            pub const name = "SpeechRecognitionPhrase";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const phrase = bridge.accessor(SpeechRecognitionPhrase.getPhrase, null, .{});
        pub const boost = bridge.accessor(SpeechRecognitionPhrase.getBoost, null, .{});
        pub const constructor = bridge.constructor(SpeechRecognitionPhrase.constructor, .{ .arity = 1 });
    };
};

// ----------------------------------------------------------------------------
// The two events
// ----------------------------------------------------------------------------

fn buildEvent(child: anytype, typ: []const u8, options_: ?js.Value, exec: *const Execution) !*@TypeOf(child) {
    const T = @TypeOf(child);
    const options = try Event.optionsFromJs(options_);
    const arena = try exec.getArena(.tiny, T.JsApi.Meta.name);
    errdefer arena.release();

    const event = try exec._factory.event(arena, try String.init(arena.allocator(), typ, .{}), child);
    Event.populatePrototypes(event, options, false);
    return event;
}

fn readEventType(comptime interface: []const u8, type_: ?js.Value, exec: *const Execution) ![]const u8 {
    const value = type_ orelse return dictionary.throwTypeError(
        "Failed to construct '" ++ interface ++ "': 1 argument required, but only 0 present.",
        exec,
    );
    return value.toStringSlice();
}

/// The event that would carry a transcript. `results` is null here and null in
/// Chrome for a page-constructed event -- see the file header for why there is
/// no result list to hand back.
pub const SpeechRecognitionEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _result_index: u32 = 0,

    const Init = dictionary.Init("SpeechRecognitionEvent", "SpeechRecognitionEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*SpeechRecognitionEvent {
        const typ = try readEventType("SpeechRecognitionEvent", type_, exec);
        const init = try Init.read(options_, exec);
        return buildEvent(SpeechRecognitionEvent{
            ._proto = undefined,
            ._result_index = @intCast(@max(0, try init.long("resultIndex", 0))),
        }, typ, options_, exec);
    }

    pub fn getResultIndex(self: *const SpeechRecognitionEvent) u32 {
        return self._result_index;
    }

    pub fn getResults(_: *const SpeechRecognitionEvent) ?*SpeechGrammarList {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SpeechRecognitionEvent);

        pub const Meta = struct {
            pub const name = "SpeechRecognitionEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const constructor_aliases = [_][]const u8{"webkitSpeechRecognitionEvent"};
        };

        pub const Prototype = Event;

        pub const resultIndex = bridge.accessor(SpeechRecognitionEvent.getResultIndex, null, .{});
        pub const results = bridge.accessor(SpeechRecognitionEvent.getResults, null, .{ .null_as_undefined = false });
        pub const constructor = bridge.constructor(SpeechRecognitionEvent.constructor, .{ .arity = 1 });
    };
};

/// What `start()` produces when there is no microphone. The prefixed global for
/// this one is `webkitSpeechRecognitionError` -- an alias whose name does not
/// match the interface it points at, which is why the pair is worth pinning in
/// a test.
pub const SpeechRecognitionErrorEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _error: []const u8 = "",
    _message: []const u8 = "",

    const Init = dictionary.Init("SpeechRecognitionErrorEvent", "SpeechRecognitionErrorEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*SpeechRecognitionErrorEvent {
        const typ = try readEventType("SpeechRecognitionErrorEvent", type_, exec);
        const init = try Init.read(options_, exec);
        return buildEvent(SpeechRecognitionErrorEvent{
            ._proto = undefined,
            ._error = try init.string("error", "", exec._factory._arena),
            ._message = try init.string("message", "", exec._factory._arena),
        }, typ, options_, exec);
    }

    pub fn initTrusted(code: []const u8, exec: *const Execution) !*SpeechRecognitionErrorEvent {
        const arena = try exec.getArena(.tiny, "SpeechRecognitionErrorEvent.trusted");
        errdefer arena.release();

        const event = try exec._factory.event(arena, comptime String.wrap("error"), SpeechRecognitionErrorEvent{
            ._proto = undefined,
            ._error = code,
            ._message = "",
        });
        Event.populatePrototypes(event, Event.Options{}, true);
        return event;
    }

    pub fn asEvent(self: *SpeechRecognitionErrorEvent) *Event {
        return self._proto;
    }

    pub fn getError(self: *const SpeechRecognitionErrorEvent) []const u8 {
        return self._error;
    }

    pub fn getMessage(self: *const SpeechRecognitionErrorEvent) []const u8 {
        return self._message;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SpeechRecognitionErrorEvent);

        pub const Meta = struct {
            pub const name = "SpeechRecognitionErrorEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const constructor_aliases = [_][]const u8{"webkitSpeechRecognitionError"};
        };

        pub const Prototype = Event;

        pub const @"error" = bridge.accessor(SpeechRecognitionErrorEvent.getError, null, .{});
        pub const message = bridge.accessor(SpeechRecognitionErrorEvent.getMessage, null, .{});
        pub const constructor = bridge.constructor(SpeechRecognitionErrorEvent.constructor, .{ .arity = 1 });
    };
};

// ----------------------------------------------------------------------------
// SpeechRecognition
// ----------------------------------------------------------------------------

/// Chrome's measured delay between `start()` and the permission failure landing
/// as `error` + `end`. The probe buckets to 50ms, so this is the bucket rather
/// than a tuned number: the observable fact is that the pair is asynchronous
/// and that a `stop()` issued in the same task pre-empts it.
const PERMISSION_LATENCY_MS: u32 = 50;

pub const SpeechRecognition = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _grammars: ?*SpeechGrammarList = null,
    _lang: String = .empty,
    _continuous: bool = false,
    _interim_results: bool = false,
    _max_alternatives: u32 = 1,
    _process_locally: bool = false,
    _phrases: ?js.Value.Global = null,

    // A run counter rather than a bool: `stop()` has to be able to cancel a
    // permission check that has not landed yet, and a page can start a second
    // run before a stale task fires.
    _started: bool = false,
    _run: u32 = 0,

    pub fn constructor(exec: *Execution) !*SpeechRecognition {
        const grammars = try exec._factory.create(SpeechGrammarList{});
        return exec._factory.eventTarget(SpeechRecognition{
            ._proto = undefined,
            ._grammars = grammars,
        });
    }

    pub fn asEventTarget(self: *SpeechRecognition) *EventTarget {
        return self._proto;
    }

    /// Chrome 150's on-device model query. Measured with no model installed:
    /// the cloud service answers "available" and the local one "downloadable".
    /// There is no model here either, so the same pair of answers is the honest
    /// one -- and it is the pair a page sees on a stock desktop Chrome.
    pub fn available(options_: ?js.Value, exec: *const Execution) !js.Promise {
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to execute 'available' on 'SpeechRecognition': 1 argument required, but only 0 present.",
            exec,
        );
        const Options = dictionary.MethodReader("SpeechRecognition", "available", "SpeechRecognitionOptions");
        const opts = try Options.readRequired(options, exec);
        const local = try opts.boolean("processLocally", false);
        return exec.js.local.?.resolvePromise(if (local) "downloadable" else "available");
    }

    /// There is nothing to install, and Chrome answers false for a model it did
    /// not manage to install.
    pub fn install(options_: ?js.Value, exec: *const Execution) !js.Promise {
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to execute 'install' on 'SpeechRecognition': 1 argument required, but only 0 present.",
            exec,
        );
        const Options = dictionary.MethodReader("SpeechRecognition", "install", "SpeechRecognitionOptions");
        _ = try Options.readRequired(options, exec);
        return exec.js.local.?.resolvePromise(false);
    }

    pub fn getGrammars(self: *const SpeechRecognition) ?*SpeechGrammarList {
        return self._grammars;
    }

    /// Not nullable: `rec.grammars = null` is a TypeError on Chrome, not a
    /// clear (measured).
    pub fn setGrammars(self: *SpeechRecognition, value: ?*SpeechGrammarList, exec: *const Execution) !void {
        const list = value orelse return dictionary.throwTypeError(
            "Failed to set the 'grammars' property on 'SpeechRecognition': Failed to convert value to 'SpeechGrammarList'.",
            exec,
        );
        self._grammars = list;
    }

    pub fn getLang(self: *const SpeechRecognition) String {
        return self._lang;
    }

    pub fn setLang(self: *SpeechRecognition, lang: String.Global) void {
        self._lang = lang.str;
    }

    pub fn getContinuous(self: *const SpeechRecognition) bool {
        return self._continuous;
    }

    pub fn setContinuous(self: *SpeechRecognition, value: bool) void {
        self._continuous = value;
    }

    pub fn getInterimResults(self: *const SpeechRecognition) bool {
        return self._interim_results;
    }

    pub fn setInterimResults(self: *SpeechRecognition, value: bool) void {
        self._interim_results = value;
    }

    pub fn getMaxAlternatives(self: *const SpeechRecognition) u32 {
        return self._max_alternatives;
    }

    pub fn setMaxAlternatives(self: *SpeechRecognition, value: u32) void {
        self._max_alternatives = value;
    }

    /// `quality` has a setter on Chrome 150 that does not take: 'accurate' and
    /// 'nope' both leave it reading 'command' (measured). So the setter is here
    /// -- its presence is part of the prototype shape -- and it does nothing.
    pub fn getQuality(_: *const SpeechRecognition) []const u8 {
        return "command";
    }

    pub fn setQuality(_: *SpeechRecognition, _: ?js.Value) void {}

    pub fn getProcessLocally(self: *const SpeechRecognition) bool {
        return self._process_locally;
    }

    pub fn setProcessLocally(self: *SpeechRecognition, value: bool) void {
        self._process_locally = value;
    }

    /// Reading `phrases` twice hands back the *same* array on Chrome (measured:
    /// `rec.phrases === rec.phrases`), so the array is created once and kept
    /// rather than rebuilt per read.
    pub fn getPhrases(self: *SpeechRecognition, exec: *const Execution) !js.Value.Global {
        if (self._phrases) |phrases| {
            return phrases;
        }
        const empty = exec.js.local.?.newArray(0);
        const persisted = try empty.toValue().persist();
        self._phrases = persisted;
        return persisted;
    }

    pub fn setPhrases(self: *SpeechRecognition, value: ?js.Value, exec: *const Execution) !void {
        const v = value orelse return;
        if (v.isArray() == false) {
            return dictionary.throwTypeError(
                "Failed to set the 'phrases' property on 'SpeechRecognition': The provided value cannot be converted to a sequence.",
                exec,
            );
        }
        self._phrases = try v.persist();
    }

    /// Starts a run that is going to fail. `start()` on an already-started
    /// object is an InvalidStateError, worded exactly as Chrome words it.
    pub fn start(self: *SpeechRecognition, exec: *Execution) !void {
        if (self._started) {
            return dictionary.throwDom(
                "InvalidStateError",
                "Failed to execute 'start' on 'SpeechRecognition': recognition has already started.",
                exec,
            );
        }
        self._started = true;
        self._run +%= 1;

        const task = try exec._factory.create(PermissionTask{
            .recognition = self,
            .generation = self._run,
            .exec = exec,
        });
        try exec.js.scheduler.add(task, PermissionTask.run, PERMISSION_LATENCY_MS, .{
            .name = "SpeechRecognition.start",
            .finalizer = PermissionTask.cancelled,
        });
    }

    /// Both `stop()` and `abort()` cut a pending run short with a lone `end` and
    /// no error, and both are no-ops on an idle object (measured -- the idle
    /// case emits nothing at all).
    pub fn stop(self: *SpeechRecognition, exec: *Execution) !void {
        return self.finishEarly(exec);
    }

    pub fn abort(self: *SpeechRecognition, exec: *Execution) !void {
        return self.finishEarly(exec);
    }

    fn finishEarly(self: *SpeechRecognition, exec: *Execution) !void {
        if (self._started == false) {
            return;
        }
        self._started = false;
        self._run +%= 1;

        const task = try exec._factory.create(EndTask{ .recognition = self, .exec = exec });
        try exec.js.scheduler.add(task, EndTask.run, 0, .{
            .name = "SpeechRecognition.stop",
            .finalizer = EndTask.cancelled,
        });
    }

    fn dispatchEnd(self: *SpeechRecognition, exec: *Execution) !void {
        const event = try Event.initTrusted(comptime String.wrap("end"), .{}, exec.page);
        return exec.dispatch(self.asEventTarget(), event, null, .{ .context = "SpeechRecognition.end" });
    }

    /// The permission check landing. It is skipped when the run it belongs to
    /// has been superseded, which is what makes `start()` then `stop()` in one
    /// task emit `end` alone.
    const PermissionTask = struct {
        recognition: *SpeechRecognition,
        generation: u32,
        exec: *Execution,

        fn cancelled(ctx: *anyopaque) void {
            const self: *PermissionTask = @ptrCast(@alignCast(ctx));
            self.exec._factory.destroy(self);
        }

        fn run(ctx: *anyopaque) !?u32 {
            const self: *PermissionTask = @ptrCast(@alignCast(ctx));
            defer self.exec._factory.destroy(self);

            const recognition = self.recognition;
            if (recognition._started == false or recognition._run != self.generation) {
                return null;
            }
            recognition._started = false;

            const exec = self.exec;
            const error_event = try SpeechRecognitionErrorEvent.initTrusted("not-allowed", exec);
            try exec.dispatch(
                recognition.asEventTarget(),
                error_event.asEvent(),
                null,
                .{ .context = "SpeechRecognition.error" },
            );
            try recognition.dispatchEnd(exec);
            return null;
        }
    };

    const EndTask = struct {
        recognition: *SpeechRecognition,
        exec: *Execution,

        fn cancelled(ctx: *anyopaque) void {
            const self: *EndTask = @ptrCast(@alignCast(ctx));
            self.exec._factory.destroy(self);
        }

        fn run(ctx: *anyopaque) !?u32 {
            const self: *EndTask = @ptrCast(@alignCast(ctx));
            defer self.exec._factory.destroy(self);
            try self.recognition.dispatchEnd(self.exec);
            return null;
        }
    };

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SpeechRecognition);

        pub const Meta = struct {
            pub const name = "SpeechRecognition";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const constructor_aliases = [_][]const u8{"webkitSpeechRecognition"};
        };

        // Declaration order is the own-property order a page reads back, so it
        // follows Chrome's exactly -- the three operations sit in the middle of
        // the handlers, not after them.
        pub const grammars = bridge.accessor(SpeechRecognition.getGrammars, SpeechRecognition.setGrammars, .{});
        pub const lang = bridge.accessor(SpeechRecognition.getLang, SpeechRecognition.setLang, .{});
        pub const continuous = bridge.accessor(SpeechRecognition.getContinuous, SpeechRecognition.setContinuous, .{});
        pub const interimResults = bridge.accessor(SpeechRecognition.getInterimResults, SpeechRecognition.setInterimResults, .{});
        pub const maxAlternatives = bridge.accessor(SpeechRecognition.getMaxAlternatives, SpeechRecognition.setMaxAlternatives, .{});
        pub const onaudiostart = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onaudiostart).get, handlerPropertyLenient(SpeechRecognition, .onaudiostart).set, .{});
        pub const onsoundstart = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onsoundstart).get, handlerPropertyLenient(SpeechRecognition, .onsoundstart).set, .{});
        pub const onspeechstart = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onspeechstart).get, handlerPropertyLenient(SpeechRecognition, .onspeechstart).set, .{});
        pub const onspeechend = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onspeechend).get, handlerPropertyLenient(SpeechRecognition, .onspeechend).set, .{});
        pub const onsoundend = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onsoundend).get, handlerPropertyLenient(SpeechRecognition, .onsoundend).set, .{});
        pub const onaudioend = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onaudioend).get, handlerPropertyLenient(SpeechRecognition, .onaudioend).set, .{});
        pub const onresult = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onresult).get, handlerPropertyLenient(SpeechRecognition, .onresult).set, .{});
        pub const onnomatch = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onnomatch).get, handlerPropertyLenient(SpeechRecognition, .onnomatch).set, .{});
        pub const onerror = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onerror).get, handlerPropertyLenient(SpeechRecognition, .onerror).set, .{});
        pub const onstart = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onstart).get, handlerPropertyLenient(SpeechRecognition, .onstart).set, .{});
        pub const onend = bridge.accessor(handlerPropertyLenient(SpeechRecognition, .onend).get, handlerPropertyLenient(SpeechRecognition, .onend).set, .{});
        pub const abort = bridge.function(SpeechRecognition.abort, .{});
        pub const start = bridge.function(SpeechRecognition.start, .{});
        pub const stop = bridge.function(SpeechRecognition.stop, .{});
        pub const quality = bridge.accessor(SpeechRecognition.getQuality, SpeechRecognition.setQuality, .{});
        pub const processLocally = bridge.accessor(SpeechRecognition.getProcessLocally, SpeechRecognition.setProcessLocally, .{});
        pub const phrases = bridge.accessor(SpeechRecognition.getPhrases, SpeechRecognition.setPhrases, .{});
        pub const constructor = bridge.constructor(SpeechRecognition.constructor, .{});

        pub const available = bridge.function(SpeechRecognition.available, .{ .static = true, .arity = 1 });
        pub const install = bridge.function(SpeechRecognition.install, .{ .static = true, .arity = 1 });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: SpeechRecognition" {
    try testing.htmlRunner("speech_recognition.html", .{});
}
