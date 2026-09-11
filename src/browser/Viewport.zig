// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
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

//! The page's content box, and the desktop it is drawn on.
//!
//! The viewport itself is what `innerWidth`/`innerHeight` report and what CDP's
//! `Emulation.setDeviceMetricsOverride` sets, so it is the one number a caller
//! owns. Everything around it -- the browser window, the display, the usable
//! area of that display -- is derived here, in one place, because a bot check
//! reads all of them and compares them against each other. Kasada takes nine
//! reads of `outerHeight`, six of `screenX`, four of `availHeight` and eleven
//! of `innerHeight` on one x-hyatt load (tools/fingerprint/results
//! /prop-reads-hyatt.json); the answers have to add up.
//!
//! The arrangement described is a maximised Chrome window on macOS, which is
//! what a headed Chrome 151 was measured in:
//!
//!       0                                                        1920
//!     0 +--------------------------- menu bar ---------------------+
//!    33 +---------------------- window (outer) --------------------+
//!       |                    tab strip / omnibox                   |
//!   120 +------------------------ viewport ------------------------+
//!       |                                                          |
//!  1200 +----------------------------------------------------------+
//!
//! Measured numbers, not chosen ones. A headed Chrome 151 on macOS answered
//! screen 1512x982, availTop 33, avail 1512x949, outer 1512x949 at (0, 33) and
//! inner 1512x862 -- the same shape, scaled to that display.

const Viewport = @This();

width: u32,
height: u32,
scale: f32 = 1.0, // for screenshot raster

pub const default = Viewport{
    .width = 1920,
    .height = 1080,
};

/// How much taller the window is than the page inside it: the tab strip, the
/// omnibox and the bookmarks bar stacked up. A constant 87 CSS pixels on
/// Chrome 151 -- the same 87 headed on macOS and under `--headless=new`, and
/// the same 87 at 1024x768, 1280x720, 1920x1080 and 1920x1200, so it does not
/// scale with the window or with the device pixel ratio. The window is no
/// *wider* than the page, so there is no matching width.
pub const shell_height: u32 = 87;

/// The macOS menu bar, which owns the top of the display and is the whole
/// difference between `screen.height` and `screen.availHeight`. 33, read off a
/// headed Chrome 151; the platform picks it, so it is not a round number.
pub const menu_bar_height: u32 = 33;

/// The browser window's outer box. Its width is the page's; its height is the
/// page's plus the browser drawn above it.
pub fn outerWidth(self: *const Viewport) u32 {
    return self.width;
}

pub fn outerHeight(self: *const Viewport) u32 {
    return self.height + shell_height;
}

/// Where the window sits on the display: the origin of the usable area, since
/// the window is maximised into it.
pub fn windowX(_: *const Viewport) u32 {
    return availLeft;
}

pub fn windowY(_: *const Viewport) u32 {
    return availTop;
}

/// The display. Exactly big enough to hold the window and the menu bar above
/// it -- with the default viewport that is 1920x1200, a display a Mac has. A
/// display only as tall as the viewport, which is what this reported before,
/// leaves no room for the window that is supposed to be on it.
pub fn screenWidth(self: *const Viewport) u32 {
    return self.width;
}

pub fn screenHeight(self: *const Viewport) u32 {
    return self.outerHeight() + menu_bar_height;
}

/// The usable area: the display less the menu bar, which comes off the top.
pub const availLeft: u32 = 0;
pub const availTop: u32 = menu_bar_height;

pub fn availWidth(self: *const Viewport) u32 {
    return self.screenWidth();
}

pub fn availHeight(self: *const Viewport) u32 {
    return self.screenHeight() - availTop;
}
