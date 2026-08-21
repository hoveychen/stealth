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

//! `NavigationPrecommitController`: what a `precommitHandler` passed to
//! intercept() is handed, so a page can redirect a navigation before it commits.
//! Illegal to construct, and the only thing that makes one is the navigation
//! machinery running a precommit handler -- which this engine does not do, since
//! Navigation.zig's intercept() never enters the precommit phase.
//!
//! So the interface object and its two methods are the whole surface, which is
//! the part a detector reads. Measured on a headed Chrome 151 with
//! tools/fingerprint/probes/probe-shapes.js and probe-s7-misc.js: both methods
//! take one argument and answer "Illegal invocation" off the prototype, because
//! there is no instance to call them on.

const js = @import("../../js/js.zig");

const NavigationPrecommitController = @This();

_pad: bool = false,

/// Redirect the navigation to another URL. Never reachable: nothing hands a page
/// one of these.
pub fn redirect(_: *NavigationPrecommitController, _: js.Value) void {}

/// Add a second handler to run once the navigation commits.
pub fn addHandler(_: *NavigationPrecommitController, _: js.Value) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationPrecommitController);

    pub const Meta = struct {
        pub const name = "NavigationPrecommitController";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const redirect = bridge.function(NavigationPrecommitController.redirect, .{ .arity = 1 });
    pub const addHandler = bridge.function(NavigationPrecommitController.addHandler, .{ .arity = 1 });
};
