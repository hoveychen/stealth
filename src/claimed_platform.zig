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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! What the engine claims to be running on.
//!
//! A constant, and deliberately **not** `builtin.os.tag`. Following the build
//! host looked like honesty and was the opposite: a great deal of what this
//! engine reports about its platform is a recorded table rather than something
//! it can measure, and those tables were all recorded on one machine. A macOS
//! build claiming macOS still handed out a Linux-shaped WebGL string or a
//! macOS-shaped one on a Linux server, because the *tables* do not move with
//! `builtin.os.tag` — only the words did. Pinning the claim makes the tables and
//! the words name the same platform.
//!
//! macOS is the claim, because it is the platform the tables can actually be
//! recorded on. The reference host is a Mac with a real GPU, a full font
//! collection and a full set of installed voices; the Linux reference is a
//! container with no GPU, thirteen fonts and no voice list, so a Linux claim can
//! only ever be as complete as that container is. Two tables — the font and emoji
//! metrics — were recorded here from the start and never had a Linux counterpart,
//! which is what made the earlier Linux claim a claim that half the surface
//! contradicted.
//!
//! Whoever reads this file is usually here because they want to add a claim.
//! Adding one to `Os` is cheap; making it true is not. Every table listed below
//! has to be re-recorded on that platform, and a claim with a missing table is
//! worse than no claim at all — the contradiction is what a detector reads.
//! `--user-agent` still overrides the user-agent string alone, which moves the
//! words without moving anything else; that is the caller's business, not a
//! supported claim.
//!
//! What is keyed off this, all of which a detector can read in one page:
//!
//!   * the user-agent's platform token, and so `navigator.appVersion` (Config)
//!   * `navigator.platform` (Navigator)
//!   * the `Sec-Ch-Ua-Platform` header and `navigator.userAgentData.platform`
//!     (Config, NavigatorUAData)
//!   * the `architecture` and `bitness` high-entropy hints (NavigatorUAData)
//!   * which recorded audio render `startRendering()` replays
//!     (audio/canonical_render.zig)
//!   * the whole driver-dependent half of WebGL — the `WEBGL_debug_renderer_info`
//!     strings, every `getParameter` limit a driver picks, the extension lists,
//!     the shader precisions and the multisample counts (canvas/gpu.zig)

pub const Os = enum {
    macos,
    linux,
};

/// The claim. Everything else in this file follows from it.
pub const claimed: Os = .macos;

/// The parenthesised token in Chrome's reduced user-agent. Since the reduction
/// this comes from a closed set, so it is a complete token rather than an
/// approximation of one.
///
/// The macOS spelling is byte-for-byte what the Chrome 150 install on the
/// reference machine sent, and Chrome says "Intel" there even on Apple silicon.
/// The Linux one is what the official amd64 package sent in a container
/// (tools/fingerprint/linux-chrome.mjs).
pub const user_agent_token = switch (claimed) {
    .macos => "Macintosh; Intel Mac OS X 10_15_7",
    .linux => "X11; Linux x86_64",
};

/// `navigator.platform`.
pub const navigator_platform = switch (claimed) {
    .macos => "MacIntel",
    .linux => "Linux x86_64",
};

/// The spelling the `Sec-Ch-Ua-Platform` hint and
/// `navigator.userAgentData.platform` use — not the same as either of the two
/// above, which is itself a thing to get right.
pub const hint = switch (claimed) {
    .macos => "macOS",
    .linux => "Linux",
};

/// The `architecture` high-entropy hint. Unlike the token above this is not
/// fixed by the OS: Chrome reports the real CPU, so a macOS claim has to pick
/// one, and "arm" is what the reference machine is. The Linux claim says x86
/// because the token beside it says x86_64.
pub const architecture = switch (claimed) {
    .macos => "arm",
    .linux => "x86",
};

/// The `bitness` high-entropy hint.
pub const bitness = switch (claimed) {
    .macos => "64",
    .linux => "64",
};

/// The `platformVersion` high-entropy hint: the OS version, and the one hint
/// whose *empty* value is itself platform-specific. Measured on Chrome 151 on
/// both references — the Mac answers its OS version, and the Linux Chrome in the
/// container answers the empty string, so "" was right for the Linux claim and is
/// a tell under this one.
///
/// This is the reference host's macOS version rather than something read off the
/// running kernel: the whole point of this file is that the claim does not follow
/// the machine.
///
/// Which means it goes stale, and staleness here is not free. `ua_full_version`
/// below tracks the reference Chrome, so a frozen OS version drifts away from a
/// current browser version, and the pair is what a two-arm wire comparison
/// reads: on the reference host, `accept-ch-echo.mjs` had this as the *only*
/// value difference across the nine hints Cloudflare's managed challenge names,
/// header for header and in order. A standing difference on that path costs
/// whoever measures it next the time to rule it out. Re-pin it when the
/// reference host moves: 26.3.1 -> 26.6.2 (`sw_vers`, and Chrome 151 answers the
/// same on that host).
pub const platform_version = switch (claimed) {
    .macos => "26.6.2",
    .linux => "",
};
