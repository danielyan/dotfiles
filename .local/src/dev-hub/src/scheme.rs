// Copied from gitview (gitview-tui/src/scheme.rs) so the hub reads the same themes.
//! Terminal colour schemes, in the format Ghostty and its ancestors use.
//!
//! A scheme is not a hub theme: it says what a *terminal* should look like —
//! a background, a foreground, and the sixteen ANSI colours — with nothing to
//! say about diff hunks or ref badges. [`crate::theme::Theme::derive`] turns one
//! into the other.
//!
//! Reading this format rather than inventing one means the several hundred
//! schemes already on most machines work as they are, and a scheme someone has
//! already tuned for their terminal will match the application inside it.

use std::collections::BTreeMap;

use ratatui::style::Color;

/// The sixteen ANSI colours, as most terminals render them, used for any entry
/// a scheme leaves out.
const FALLBACK: [(u8, u8, u8); 16] = [
    (0, 0, 0),
    (170, 0, 0),
    (0, 170, 0),
    (170, 85, 0),
    (0, 0, 170),
    (170, 0, 170),
    (0, 170, 170),
    (170, 170, 170),
    (85, 85, 85),
    (255, 85, 85),
    (85, 255, 85),
    (255, 255, 85),
    (85, 85, 255),
    (255, 85, 255),
    (85, 255, 255),
    (255, 255, 255),
];

/// Names for the sixteen, in their conventional order.
#[allow(dead_code)] // the whole sixteen, named, though not all are used
pub mod ansi {
    pub const BLACK: usize = 0;
    pub const RED: usize = 1;
    pub const GREEN: usize = 2;
    pub const YELLOW: usize = 3;
    pub const BLUE: usize = 4;
    pub const MAGENTA: usize = 5;
    pub const CYAN: usize = 6;
    pub const WHITE: usize = 7;
    pub const BRIGHT_BLACK: usize = 8;
    pub const BRIGHT_RED: usize = 9;
    pub const BRIGHT_GREEN: usize = 10;
    pub const BRIGHT_YELLOW: usize = 11;
    pub const BRIGHT_BLUE: usize = 12;
    pub const BRIGHT_MAGENTA: usize = 13;
    pub const BRIGHT_CYAN: usize = 14;
    pub const BRIGHT_WHITE: usize = 15;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scheme {
    pub background: Color,
    pub foreground: Color,
    /// What the terminal highlights a selection with, if the scheme says.
    pub selection_background: Option<Color>,
    pub palette: [Color; 16],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A scheme with no ground and no ink is not a scheme.
    Incomplete,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Incomplete => f.write_str("no background and foreground"),
        }
    }
}

impl std::error::Error for Error {}

impl Scheme {
    /// Read a scheme.
    ///
    /// Lines are `key = value`, with the palette given one entry at a time as
    /// `palette = 7=#f8f8f2`. Anything unrecognised is ignored: these files
    /// carry cursor and URL colours a terminal cares about and this does not,
    /// and refusing to read a file over a key we have no use for would be
    /// perverse.
    pub fn parse(text: &str) -> Result<Self, Error> {
        let mut background = None;
        let mut foreground = None;
        let mut selection_background = None;
        let mut entries: BTreeMap<usize, Color> = BTreeMap::new();

        for line in text.lines() {
            let line = line.trim();
            // A `#` only starts a comment at the start of a line: everywhere
            // else in this format it starts a colour.
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let (key, value) = (key.trim(), value.trim());

            match key {
                "background" => background = colour(value),
                "foreground" => foreground = colour(value),
                "selection-background" => selection_background = colour(value),
                "palette" => {
                    if let Some((index, hex)) = value.split_once('=')
                        && let (Ok(index), Some(colour)) =
                            (index.trim().parse::<usize>(), colour(hex.trim()))
                        && index < 16
                    {
                        entries.insert(index, colour);
                    }
                }
                _ => {}
            }
        }

        let (Some(background), Some(foreground)) = (background, foreground) else {
            return Err(Error::Incomplete);
        };

        let palette = std::array::from_fn(|index| {
            entries.get(&index).copied().unwrap_or_else(|| {
                let (red, green, blue) = FALLBACK[index];
                Color::Rgb(red, green, blue)
            })
        });

        Ok(Self {
            background,
            foreground,
            selection_background,
            palette,
        })
    }

    pub fn colour(&self, index: usize) -> Color {
        self.palette[index.min(15)]
    }
}

/// `#rrggbb`, `rrggbb`, or `#rgb`.
fn colour(value: &str) -> Option<Color> {
    let digits = value.trim().trim_start_matches('#');
    let expanded;
    let digits = match digits.len() {
        3 => {
            expanded = digits
                .chars()
                .flat_map(|character| [character, character])
                .collect::<String>();
            expanded.as_str()
        }
        6 => digits,
        _ => return None,
    };

    let channel = |at: usize| u8::from_str_radix(&digits[at..at + 2], 16).ok();
    Some(Color::Rgb(channel(0)?, channel(2)?, channel(4)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    const DRACULA: &str = "\
palette = 0=#21222c
palette = 1=#ff5555
palette = 2=#50fa7b
palette = 7=#f8f8f2
palette = 8=#6272a4
background = #282a36
foreground = #f8f8f2
cursor-color = #f8f8f2
selection-background = #44475a
selection-foreground = #ffffff
";

    #[test]
    fn reads_the_format_terminals_already_use() {
        let scheme = Scheme::parse(DRACULA).expect("a scheme");

        assert_eq!(scheme.background, Color::Rgb(0x28, 0x2a, 0x36));
        assert_eq!(scheme.foreground, Color::Rgb(0xf8, 0xf8, 0xf2));
        assert_eq!(
            scheme.selection_background,
            Some(Color::Rgb(0x44, 0x47, 0x5a))
        );
        assert_eq!(scheme.colour(ansi::RED), Color::Rgb(0xff, 0x55, 0x55));
        assert_eq!(scheme.colour(ansi::GREEN), Color::Rgb(0x50, 0xfa, 0x7b));
    }

    #[test]
    fn keys_a_terminal_cares_about_and_we_do_not_are_ignored() {
        // Refusing to read a scheme over a cursor colour would be perverse.
        let scheme = Scheme::parse(DRACULA).expect("a scheme");
        assert_eq!(scheme.foreground, Color::Rgb(0xf8, 0xf8, 0xf2));
    }

    #[test]
    fn a_palette_entry_left_out_falls_back_to_the_conventional_one() {
        let scheme = Scheme::parse(DRACULA).expect("a scheme");
        // Entry 3 was not given.
        let (red, green, blue) = FALLBACK[ansi::YELLOW];
        assert_eq!(scheme.colour(ansi::YELLOW), Color::Rgb(red, green, blue));
    }

    #[test]
    fn a_scheme_with_no_ground_or_ink_is_refused() {
        assert_eq!(Scheme::parse("palette = 1=#ff0000"), Err(Error::Incomplete));
        assert_eq!(
            Scheme::parse("background = #000000"),
            Err(Error::Incomplete)
        );
        assert_eq!(Scheme::parse(""), Err(Error::Incomplete));
    }

    #[test]
    fn colours_may_be_written_several_ways() {
        assert_eq!(colour("#ff8800"), Some(Color::Rgb(255, 136, 0)));
        assert_eq!(colour("ff8800"), Some(Color::Rgb(255, 136, 0)));
        assert_eq!(colour("#f80"), Some(Color::Rgb(255, 136, 0)));
        assert_eq!(colour("  #FF8800  "), Some(Color::Rgb(255, 136, 0)));
        assert_eq!(colour("nonsense"), None);
        assert_eq!(colour("#ff88"), None);
    }

    #[test]
    fn blank_lines_and_comments_are_skipped() {
        let scheme =
            Scheme::parse("\n# a comment\n\nbackground = #101010\nforeground = #e0e0e0\n\n")
                .expect("a scheme");
        assert_eq!(scheme.background, Color::Rgb(0x10, 0x10, 0x10));
    }

    #[test]
    fn a_palette_index_out_of_range_is_ignored_rather_than_fatal() {
        let scheme =
            Scheme::parse("background = #101010\nforeground = #e0e0e0\npalette = 99=#ff0000\n")
                .expect("a scheme");
        assert_eq!(scheme.palette.len(), 16);
    }
}
