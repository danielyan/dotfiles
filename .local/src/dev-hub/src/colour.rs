// Copied from gitview (gitview-tui/src/colour.rs) so the hub looks the same.
//! What the terminal can actually show, and how to meet it there.
//!
//! Every colour in a [`crate::theme::Theme`] is 24-bit, because that is how the
//! palettes were chosen. crossterm will happily emit a truecolor escape at a
//! terminal that cannot read one, which does not fail — it simply produces a
//! colour nobody picked. So the palette is converted once, at startup, to
//! whatever the terminal is able to render.

use ratatui::style::Color;

/// How much colour the terminal can show.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Depth {
    /// 24-bit. What the palettes are written in.
    TrueColor,
    /// The xterm 256-colour palette: a 6×6×6 cube and a grey ramp.
    Indexed,
    /// The original sixteen.
    Ansi,
    /// None at all — `NO_COLOR`, or a terminal that says it is dumb.
    None,
}

/// Read the terminal's abilities from the environment.
pub fn detect() -> Depth {
    from_environment(
        std::env::var_os("NO_COLOR").is_some_and(|value| !value.is_empty()),
        std::env::var("COLORTERM").ok().as_deref(),
        std::env::var("TERM").ok().as_deref(),
    )
}

/// The same, from values rather than the environment.
///
/// `NO_COLOR` is honoured whatever else is set: it is the one signal that says
/// what the person wants rather than what the terminal can do.
pub fn from_environment(no_color: bool, colorterm: Option<&str>, term: Option<&str>) -> Depth {
    if no_color {
        return Depth::None;
    }
    if matches!(term, None | Some("") | Some("dumb")) {
        return Depth::None;
    }
    if colorterm.is_some_and(|value| value.contains("truecolor") || value.contains("24bit")) {
        return Depth::TrueColor;
    }
    if term.is_some_and(|value| value.contains("256color")) {
        return Depth::Indexed;
    }
    Depth::Ansi
}

/// Bring a colour within reach of the terminal.
pub fn adapt(colour: Color, depth: Depth) -> Color {
    let Color::Rgb(red, green, blue) = colour else {
        // Anything already indexed or named is within reach by definition.
        return match depth {
            Depth::None => Color::Reset,
            _ => colour,
        };
    };
    match depth {
        Depth::TrueColor => colour,
        Depth::Indexed => Color::Indexed(nearest_indexed(red, green, blue)),
        Depth::Ansi => nearest_ansi(red, green, blue),
        Depth::None => Color::Reset,
    }
}

/// The levels the xterm colour cube is built from.
const CUBE: [u8; 6] = [0, 95, 135, 175, 215, 255];

/// Nearest entry in the xterm 256-colour palette.
///
/// Both halves are tried — the colour cube and the grey ramp — because a grey
/// is much better served by the ramp's twenty-four steps than by the six the
/// cube can manage.
fn nearest_indexed(red: u8, green: u8, blue: u8) -> u8 {
    let level = |value: u8| {
        CUBE.iter()
            .enumerate()
            .min_by_key(|(_, step)| distance_1d(**step, value))
            .map_or(0, |(index, _)| index)
    };
    let (r, g, b) = (level(red), level(green), level(blue));
    let cube = 16 + 36 * r + 6 * g + b;
    let cube_error = distance((CUBE[r], CUBE[g], CUBE[b]), (red, green, blue));

    // The ramp runs 8, 18, … 238 at indices 232 through 255.
    let average = (u32::from(red) + u32::from(green) + u32::from(blue)) / 3;
    let step = ((average as i32 - 8) / 10).clamp(0, 23) as u8;
    let grey = 8 + 10 * u32::from(step);
    let grey_error = distance((grey as u8, grey as u8, grey as u8), (red, green, blue));

    if grey_error < cube_error {
        232 + step
    } else {
        cube as u8
    }
}

/// The sixteen, as most terminals actually render them.
const ANSI: [(Color, (u8, u8, u8)); 16] = [
    (Color::Black, (0, 0, 0)),
    (Color::Red, (170, 0, 0)),
    (Color::Green, (0, 170, 0)),
    (Color::Yellow, (170, 85, 0)),
    (Color::Blue, (0, 0, 170)),
    (Color::Magenta, (170, 0, 170)),
    (Color::Cyan, (0, 170, 170)),
    (Color::Gray, (170, 170, 170)),
    (Color::DarkGray, (85, 85, 85)),
    (Color::LightRed, (255, 85, 85)),
    (Color::LightGreen, (85, 255, 85)),
    (Color::LightYellow, (255, 255, 85)),
    (Color::LightBlue, (85, 85, 255)),
    (Color::LightMagenta, (255, 85, 255)),
    (Color::LightCyan, (85, 255, 255)),
    (Color::White, (255, 255, 255)),
];

fn nearest_ansi(red: u8, green: u8, blue: u8) -> Color {
    ANSI.iter()
        .min_by_key(|(_, rgb)| distance(*rgb, (red, green, blue)))
        .map_or(Color::Reset, |(colour, _)| *colour)
}

fn distance_1d(left: u8, right: u8) -> u32 {
    let difference = i32::from(left) - i32::from(right);
    (difference * difference) as u32
}

fn distance(left: (u8, u8, u8), right: (u8, u8, u8)) -> u32 {
    distance_1d(left.0, right.0) + distance_1d(left.1, right.1) + distance_1d(left.2, right.2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_color_beats_everything_the_terminal_claims() {
        // It says what the person wants, not what the hardware can do.
        assert_eq!(
            from_environment(true, Some("truecolor"), Some("xterm-256color")),
            Depth::None
        );
    }

    #[test]
    fn colorterm_is_how_a_terminal_admits_to_truecolor() {
        for value in ["truecolor", "24bit"] {
            assert_eq!(
                from_environment(false, Some(value), Some("xterm-256color")),
                Depth::TrueColor
            );
        }
    }

    #[test]
    fn a_256_colour_term_without_colorterm_gets_the_indexed_palette() {
        assert_eq!(
            from_environment(false, None, Some("xterm-256color")),
            Depth::Indexed
        );
        assert_eq!(
            from_environment(false, Some("something-else"), Some("screen-256color")),
            Depth::Indexed
        );
    }

    #[test]
    fn anything_else_gets_the_original_sixteen() {
        assert_eq!(from_environment(false, None, Some("xterm")), Depth::Ansi);
        assert_eq!(from_environment(false, None, Some("vt100")), Depth::Ansi);
    }

    #[test]
    fn a_dumb_or_absent_terminal_gets_nothing() {
        assert_eq!(from_environment(false, None, Some("dumb")), Depth::None);
        assert_eq!(from_environment(false, None, Some("")), Depth::None);
        assert_eq!(from_environment(false, None, None), Depth::None);
    }

    #[test]
    fn truecolor_leaves_a_colour_exactly_as_it_was() {
        let colour = Color::Rgb(0x7a, 0xa2, 0xf7);
        assert_eq!(adapt(colour, Depth::TrueColor), colour);
    }

    #[test]
    fn no_colour_erases_everything_including_what_was_already_indexed() {
        assert_eq!(adapt(Color::Rgb(1, 2, 3), Depth::None), Color::Reset);
        assert_eq!(adapt(Color::Indexed(42), Depth::None), Color::Reset);
        assert_eq!(adapt(Color::Red, Depth::None), Color::Reset);
    }

    #[test]
    fn the_cube_corners_map_to_themselves() {
        // Pure black and pure white are in the cube exactly.
        assert_eq!(
            adapt(Color::Rgb(0, 0, 0), Depth::Indexed),
            Color::Indexed(16)
        );
        assert_eq!(
            adapt(Color::Rgb(255, 255, 255), Depth::Indexed),
            Color::Indexed(231)
        );
        // And so is a cube level in every channel.
        assert_eq!(
            adapt(Color::Rgb(95, 175, 215), Depth::Indexed),
            Color::Indexed(16 + 36 + 6 * 3 + 4)
        );
    }

    #[test]
    fn a_grey_uses_the_ramp_rather_than_the_cube() {
        // The ramp has twenty-four steps where the cube has six, so a grey the
        // cube would round badly lands much closer.
        let Color::Indexed(index) = adapt(Color::Rgb(0x7a, 0x7a, 0x7a), Depth::Indexed) else {
            panic!("expected an indexed colour");
        };
        assert!(
            (232..=255).contains(&index),
            "{index} is not on the grey ramp"
        );
    }

    #[test]
    fn every_indexed_result_is_a_real_palette_entry() {
        for red in (0..=255u8).step_by(17) {
            for green in (0..=255u8).step_by(17) {
                for blue in (0..=255u8).step_by(17) {
                    let Color::Indexed(index) = adapt(Color::Rgb(red, green, blue), Depth::Indexed)
                    else {
                        panic!("expected an indexed colour");
                    };
                    assert!(index >= 16, "{index} strays into the system colours");
                }
            }
        }
    }

    #[test]
    fn the_sixteen_are_matched_by_eye() {
        assert_eq!(adapt(Color::Rgb(0, 0, 0), Depth::Ansi), Color::Black);
        assert_eq!(adapt(Color::Rgb(255, 255, 255), Depth::Ansi), Color::White);
        assert_eq!(adapt(Color::Rgb(200, 20, 20), Depth::Ansi), Color::Red);
        // A muted green lands on the dim one, a bright one on the light.
        assert_eq!(adapt(Color::Rgb(40, 200, 40), Depth::Ansi), Color::Green);
        assert_eq!(
            adapt(Color::Rgb(100, 240, 100), Depth::Ansi),
            Color::LightGreen
        );
        assert_eq!(adapt(Color::Rgb(30, 30, 200), Depth::Ansi), Color::Blue);
    }

    #[test]
    fn every_depth_produces_only_what_that_depth_can_show() {
        // The point of the whole module: nothing escapes wearing a colour the
        // terminal cannot render.
        for value in [0u8, 37, 128, 200, 255] {
            let colour = Color::Rgb(value, 255 - value, value / 2);

            assert!(matches!(adapt(colour, Depth::TrueColor), Color::Rgb(..)));
            assert!(matches!(adapt(colour, Depth::Indexed), Color::Indexed(_)));
            assert_eq!(adapt(colour, Depth::None), Color::Reset);

            let ansi = adapt(colour, Depth::Ansi);
            assert!(
                ANSI.iter().any(|(named, _)| *named == ansi),
                "{ansi:?} is not one of the sixteen"
            );
        }
    }
}
