//! Colours, derived the way gitview derives them.
//!
//! The palettes and the contrast repair are gitview's (gitview-tui/src/theme.rs),
//! cut down to the roles a session list needs, so `theme = "Vercel"` looks the
//! same in both.

use std::path::PathBuf;

use ratatui::style::Color;

use crate::colour::{self, Depth};
use crate::scheme::{Scheme, ansi};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Theme {
    /// The terminal background this palette was chosen against. Never painted:
    /// the pane inherits the terminal's own, translucent or not.
    pub background: Color,
    pub text: Color,
    pub dim: Color,
    pub border: Color,
    pub border_focused: Color,
    pub selection: Color,
    /// The session on screen.
    pub current: Color,
    /// Claude is waiting for you.
    pub waiting: Color,
    /// Claude is working.
    pub working: Color,
    /// Claude has finished.
    pub done: Color,
    pub error: Color,
}

impl Theme {
    pub fn dark() -> Self {
        Self {
            background: Color::Rgb(0x1a, 0x1b, 0x26),
            text: Color::Rgb(0xd4, 0xd4, 0xd4),
            dim: Color::Rgb(0x9a, 0x9a, 0xb0),
            border: Color::Rgb(0x3a, 0x3a, 0x4a),
            border_focused: Color::Rgb(0x7a, 0xa2, 0xf7),
            selection: Color::Rgb(0x3a, 0x42, 0x66),
            current: Color::Rgb(0x7a, 0xa2, 0xf7),
            waiting: Color::Rgb(0xe0, 0xaf, 0x68),
            working: Color::Rgb(0x7a, 0xa2, 0xf7),
            done: Color::Rgb(0x9e, 0xce, 0x6a),
            error: Color::Rgb(0xf7, 0x76, 0x8e),
        }
    }

    pub fn light() -> Self {
        Self {
            background: Color::Rgb(0xfb, 0xfb, 0xfb),
            text: Color::Rgb(0x1f, 0x23, 0x28),
            dim: Color::Rgb(0x5c, 0x63, 0x6d),
            border: Color::Rgb(0xb9, 0xc1, 0xc9),
            border_focused: Color::Rgb(0x09, 0x4b, 0xa8),
            selection: Color::Rgb(0xb2, 0xc2, 0xd8),
            current: Color::Rgb(0x09, 0x4b, 0xa8),
            waiting: Color::Rgb(0x6b, 0x47, 0x00),
            working: Color::Rgb(0x09, 0x4b, 0xa8),
            done: Color::Rgb(0x0d, 0x54, 0x24),
            error: Color::Rgb(0x8b, 0x14, 0x1c),
        }
    }

    pub const NAMES: [&'static str; 2] = ["dark", "light"];

    pub fn named(name: &str) -> Option<Self> {
        match name {
            "dark" => Some(Self::dark()),
            "light" => Some(Self::light()),
            _ => None,
        }
    }

    /// Build a palette out of a terminal colour scheme, repairing anything the
    /// scheme's author never meant to be read on its own background.
    pub fn derive(scheme: &Scheme) -> Self {
        let bg = scheme.background;
        let text = readable(scheme.foreground, &[bg], AA);
        let selection = settle(
            scheme
                .selection_background
                .unwrap_or_else(|| mix(scheme.foreground, bg, 0.86)),
            bg,
            text,
        );
        // Everything drawn on a row may be drawn on the selected one too.
        let colour = |index: usize| readable(scheme.colour(index), &[bg, selection], READABLE);

        Self {
            background: bg,
            text,
            dim: readable(mix(scheme.foreground, bg, 0.45), &[bg, selection], READABLE),
            border: divider(mix(scheme.foreground, bg, 0.80), bg),
            border_focused: colour(ansi::BRIGHT_BLUE),
            selection,
            current: colour(ansi::BRIGHT_BLUE),
            waiting: colour(ansi::YELLOW),
            working: colour(ansi::BLUE),
            done: colour(ansi::GREEN),
            error: colour(ansi::RED),
        }
    }

    #[must_use]
    pub fn map(self, change: impl Fn(Color) -> Color) -> Self {
        Self {
            background: change(self.background),
            text: change(self.text),
            dim: change(self.dim),
            border: change(self.border),
            border_focused: change(self.border_focused),
            selection: change(self.selection),
            current: change(self.current),
            waiting: change(self.waiting),
            working: change(self.working),
            done: change(self.done),
            error: change(self.error),
        }
    }

    /// Bring the whole palette within reach of the terminal, once, at startup.
    #[must_use]
    pub fn adapt(self, depth: Depth) -> Self {
        self.map(|colour| colour::adapt(colour, depth))
    }

    /// Every pair that has to be legible, and what it is drawn on.
    #[cfg(test)]
    pub fn readability(&self) -> Vec<(&'static str, Color, Color)> {
        let bg = self.background;
        vec![
            ("dim", self.dim, bg),
            ("current", self.current, bg),
            ("waiting", self.waiting, bg),
            ("working", self.working, bg),
            ("done", self.done, bg),
            ("error", self.error, bg),
            ("text on selection", self.text, self.selection),
            ("dim on selection", self.dim, self.selection),
            ("waiting on selection", self.waiting, self.selection),
        ]
    }

    #[cfg(test)]
    pub fn faults(&self) -> Vec<(&'static str, f32)> {
        let mut found: Vec<(&'static str, f32)> = self
            .readability()
            .into_iter()
            .map(|(label, fg, bg)| (label, contrast(fg, bg)))
            .filter(|(_, ratio)| *ratio < READABLE)
            .collect();
        let body = contrast(self.text, self.background);
        if body < AA {
            found.push(("text", body));
        }
        found
    }
}

impl Default for Theme {
    fn default() -> Self {
        Self::dark()
    }
}

/// Directories holding colour schemes, nearest first: the same places gitview
/// looks, so a theme name means the same thing to both.
pub fn directories() -> Vec<PathBuf> {
    let mut found = Vec::new();
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        let config = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".config"));
        found.push(config.join("gitview/themes"));
        found.push(config.join("ghostty/themes"));
    }
    found.push(PathBuf::from(
        "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
    ));
    found
}

/// A theme by name, ignoring case: a scheme file first, then the built-ins.
pub fn load(name: &str) -> Option<Theme> {
    let name = name.trim();
    for directory in directories() {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = path.file_name().unwrap_or_default().to_string_lossy();
            if !path.is_file() || !file_name.eq_ignore_ascii_case(name) {
                continue;
            }
            if let Ok(scheme) = std::fs::read_to_string(&path)
                .map_err(|_| ())
                .and_then(|text| Scheme::parse(&text).map_err(|_| ()))
            {
                return Some(Theme::derive(&scheme));
            }
        }
    }
    Theme::NAMES
        .iter()
        .find(|built_in| built_in.eq_ignore_ascii_case(name))
        .and_then(|built_in| Theme::named(built_in))
}

pub const READABLE: f32 = 3.0;
pub const AA: f32 = 4.5;

fn readable(colour: Color, grounds: &[Color], floor: f32) -> Color {
    let Some(&background) = grounds.first() else {
        return colour;
    };
    let target = far_side(background);
    let mut colour = colour;
    for _ in 0..64 {
        let worst = grounds
            .iter()
            .map(|ground| contrast(colour, *ground))
            .fold(f32::INFINITY, f32::min);
        if worst >= floor {
            return colour;
        }
        colour = mix(colour, target, 0.06);
    }
    colour
}

const GROUND_DRIFT: f32 = 1.9;

fn settle(colour: Color, background: Color, ink: Color) -> Color {
    let mut colour = colour;
    for _ in 0..48 {
        let drifted = contrast(colour, background) > GROUND_DRIFT;
        let crowding_the_text = contrast(ink, colour) < READABLE;
        if !drifted && !crowding_the_text {
            return colour;
        }
        colour = mix(colour, background, 0.1);
    }
    colour
}

fn divider(colour: Color, ground: Color) -> Color {
    let mut colour = colour;
    for _ in 0..48 {
        let ratio = contrast(colour, ground);
        if ratio >= READABLE {
            colour = mix(colour, ground, 0.12);
        } else if ratio < 1.3 {
            colour = mix(colour, far_side(ground), 0.06);
        } else {
            break;
        }
    }
    colour
}

fn far_side(ground: Color) -> Color {
    let Color::Rgb(red, green, blue) = ground else {
        return Color::Rgb(255, 255, 255);
    };
    if luminance(red, green, blue) > 0.18 {
        Color::Rgb(0, 0, 0)
    } else {
        Color::Rgb(255, 255, 255)
    }
}

fn mix(from: Color, to: Color, amount: f32) -> Color {
    let (Color::Rgb(fr, fg, fb), Color::Rgb(tr, tg, tb)) = (from, to) else {
        return from;
    };
    let blend = |left: u8, right: u8| {
        (f32::from(left) + (f32::from(right) - f32::from(left)) * amount).round() as u8
    };
    Color::Rgb(blend(fr, tr), blend(fg, tg), blend(fb, tb))
}

/// WCAG contrast, 1 (identical) to 21 (black on white).
pub fn contrast(foreground: Color, background: Color) -> f32 {
    let (Color::Rgb(fr, fg, fb), Color::Rgb(br, bg, bb)) = (foreground, background) else {
        return 21.0;
    };
    let lighter = luminance(fr, fg, fb).max(luminance(br, bg, bb));
    let darker = luminance(fr, fg, fb).min(luminance(br, bg, bb));
    (lighter + 0.05) / (darker + 0.05)
}

fn luminance(red: u8, green: u8, blue: u8) -> f32 {
    let channel = |value: u8| {
        let value = f32::from(value) / 255.0;
        if value <= 0.03928 {
            value / 12.92
        } else {
            ((value + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_built_in_palettes_are_readable() {
        for name in Theme::NAMES {
            let theme = Theme::named(name).expect("built in");
            assert_eq!(theme.faults(), Vec::new(), "{name} has unreadable colours");
        }
    }

    #[test]
    fn a_derived_palette_is_repaired_until_readable() {
        // A scheme whose yellow and blue are nearly the background.
        let scheme = Scheme::parse(
            "background = #101010\nforeground = #e0e0e0\n\
             palette = 3=#141414\npalette = 4=#121212\npalette = 12=#111111\n",
        )
        .expect("a scheme");
        assert_eq!(Theme::derive(&scheme).faults(), Vec::new());
    }

    #[test]
    fn built_in_names_load_whatever_their_case() {
        assert!(load("DARK").is_some());
        assert!(load("  light ").is_some());
        assert!(load("chartreuse-no-such-theme").is_none());
    }

    #[test]
    fn no_colour_leaves_nothing_behind() {
        let theme = Theme::dark().adapt(Depth::None);
        assert_eq!(theme, Theme::dark().map(|_| Color::Reset));
    }
}
