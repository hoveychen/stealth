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

//! `navigator.geolocation` and the three interfaces its callbacks receive.
//!
//! The four types live one directory down, one per file, because they carry
//! real state now; this module is the registration point the bridge and
//! `Navigator` import.
//!
//! **Nothing is delivered unless the operator says so.** With the permission
//! left at its default -- which is what a page gets unless CDP moved it -- a
//! request is registered and then never answered: no position, no error. That
//! is a measured Chrome state, not a shortcut. On the reference Chrome the
//! permission prompt stayed up and neither callback had run after four seconds
//! (win21b), and inventing a denial the page can see instantly is a louder tell
//! than a prompt nobody answered: a real user's browser does not decide in
//! zero milliseconds.
//!
//! `Emulation.setGeolocationOverride` plus an explicit
//! `Browser.grantPermissions` is the way to get a position out of it, which is
//! exactly the pair Puppeteer and Playwright send. An explicit denial
//! (`Browser.setPermission … denied`) answers PERMISSION_DENIED, because there
//! the operator has said what the prompt would have said.

pub const Geolocation = @import("geolocation/Geolocation.zig");
pub const GeolocationPosition = @import("geolocation/GeolocationPosition.zig");
pub const GeolocationCoordinates = @import("geolocation/GeolocationCoordinates.zig");
pub const GeolocationPositionError = @import("geolocation/GeolocationPositionError.zig");

pub fn registerTypes() []const type {
    return &.{
        Geolocation,
        GeolocationPosition,
        GeolocationCoordinates,
        GeolocationPositionError,
    };
}
