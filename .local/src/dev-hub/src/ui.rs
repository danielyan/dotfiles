//! Drawing the sidebar, and finding what a click landed on.
//!
//! ```text
//! ┌ sessions ──────────────────┐
//! │ 1 main                     │
//! │   ~/projects/gitview · 2h  │
//! │▌2 magpie                 ⋯ │
//! │   ~/projects/magpie · now  │
//! │ 3 pasty                  ● │
//! │   ~/projects/pasty · 4d    │
//! │ + new                      │
//! │                            │
//! │ ⏎ open  n new  x kill      │
//! │ ⌥1-9 ⌥{ ⌥} ⌥0  q detach    │
//! └────────────────────────────┘
//! ```

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Widget};

use crate::model::{Claude, Session};
use crate::theme::Theme;

/// Lines each session takes: its name, then where it is and how recently it
/// did anything.
const ROW_HEIGHT: u16 = 2;
/// Lines the hints at the bottom take.
const FOOTER: u16 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Normal,
    /// Typing a name for `n`.
    New(String),
    /// Asking before `x` kills a session.
    Kill(String),
    /// Asking before `Q` ends the hub.
    Quit,
}

pub struct Sidebar<'a> {
    pub sessions: &'a [Session],
    pub current: Option<&'a str>,
    pub cursor: usize,
    pub focused: bool,
    pub mode: &'a Mode,
    pub message: Option<&'a str>,
    pub theme: &'a Theme,
    /// Seconds since the epoch, for the ages.
    pub now: u64,
    pub home: &'a str,
}

/// What a click at a given line of the sidebar means.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hit {
    Session(usize),
    New,
    Nothing,
}

/// The first session drawn, so that the cursor is always in sight.
pub fn scroll(sessions: usize, cursor: usize, rows_fit: usize) -> usize {
    if rows_fit == 0 || sessions <= rows_fit {
        return 0;
    }
    cursor.saturating_sub(rows_fit - 1).min(sessions - rows_fit)
}

/// How many sessions fit, leaving room for `+ new`, a gap and the hints.
fn rows_fit(inner: Rect) -> usize {
    (inner.height.saturating_sub(FOOTER + 2) / ROW_HEIGHT) as usize
}

fn inner(area: Rect) -> Rect {
    Block::bordered().inner(area)
}

/// What line `row` of the sidebar (in screen coordinates) holds.
pub fn hit(area: Rect, sessions: usize, cursor: usize, row: u16) -> Hit {
    let inner = inner(area);
    if row < inner.y || row >= inner.y + inner.height {
        return Hit::Nothing;
    }
    let fit = rows_fit(inner);
    let first = scroll(sessions, cursor, fit);
    let shown = sessions.saturating_sub(first).min(fit);
    let line = row - inner.y;
    let index = (line / ROW_HEIGHT) as usize;
    if index < shown {
        Hit::Session(first + index)
    } else if line == shown as u16 * ROW_HEIGHT {
        Hit::New
    } else {
        Hit::Nothing
    }
}

/// `3m`, `2h`, `4d`: how long ago, at a glance.
pub fn age(now: u64, then: u64) -> String {
    let seconds = now.saturating_sub(then);
    match seconds {
        0..60 => "now".to_owned(),
        60..3600 => format!("{}m", seconds / 60),
        3600..86_400 => format!("{}h", seconds / 3600),
        _ => format!("{}d", seconds / 86_400),
    }
}

/// A path with the home directory as `~`, cut from the left to `width`
/// characters: the end of a path is the part that says which one it is.
pub fn short_path(path: &str, home: &str, width: usize) -> String {
    let path = match path.strip_prefix(home) {
        Some(rest) if !home.is_empty() && (rest.is_empty() || rest.starts_with('/')) => {
            format!("~{rest}")
        }
        _ => path.to_owned(),
    };
    let length = path.chars().count();
    if length <= width {
        return path;
    }
    if width == 0 {
        return String::new();
    }
    let tail: String = path.chars().skip(length - (width - 1)).collect();
    format!("…{tail}")
}

/// A name cut to `width` characters, marking the cut.
fn fit(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_owned();
    }
    if width == 0 {
        return String::new();
    }
    let head: String = text.chars().take(width - 1).collect();
    format!("{head}…")
}

impl Sidebar<'_> {
    fn badge(&self, claude: Option<Claude>) -> Span<'static> {
        let theme = self.theme;
        match claude {
            Some(Claude::Waiting) => Span::styled(
                "●",
                Style::new().fg(theme.waiting).add_modifier(Modifier::BOLD),
            ),
            Some(Claude::Working) => Span::styled("⋯", Style::new().fg(theme.working)),
            Some(Claude::Done) => Span::styled("✔", Style::new().fg(theme.done)),
            None => Span::raw(" "),
        }
    }

    fn footer(&self) -> [Line<'static>; 2] {
        let theme = self.theme;
        let dim = Style::new().fg(theme.dim);
        let ask = Style::new().fg(theme.waiting).add_modifier(Modifier::BOLD);
        if let Some(message) = self.message {
            return [
                Line::styled(message.to_owned(), Style::new().fg(theme.error)),
                Line::styled("any key to dismiss", dim),
            ];
        }
        match self.mode {
            Mode::Normal => [
                Line::styled("⏎ open  n new  x kill", dim),
                Line::styled("⌥1-9 ⌥{ ⌥} ⌥0  q detach", dim),
            ],
            Mode::New(name) => [
                Line::from(vec![
                    Span::styled("new: ", ask),
                    Span::styled(name.clone(), Style::new().fg(theme.text)),
                    Span::styled("▏", dim),
                ]),
                Line::styled("⏎ start  esc cancel", dim),
            ],
            Mode::Kill(name) => [
                Line::styled(format!("kill {name}?"), ask),
                Line::styled("y kill  other keys cancel", dim),
            ],
            Mode::Quit => [
                Line::styled("end the hub?", ask),
                Line::styled("y end it (sessions stay)", dim),
            ],
        }
    }
}

impl Widget for Sidebar<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let theme = self.theme;
        let border = if self.focused {
            theme.border_focused
        } else {
            theme.border
        };
        let title_style = if self.focused {
            Style::new()
                .fg(theme.border_focused)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::new().fg(theme.dim)
        };
        let block = Block::bordered()
            .title(Line::styled(" sessions ", title_style))
            .border_style(Style::new().fg(border));
        let inner = block.inner(area);
        block.render(area, buf);
        if inner.width < 4 || inner.height == 0 {
            return;
        }

        let width = inner.width as usize;
        let fit_rows = rows_fit(inner);
        let first = scroll(self.sessions.len(), self.cursor, fit_rows);
        let mut y = inner.y;
        for (index, session) in self.sessions.iter().enumerate().skip(first).take(fit_rows) {
            let is_current = self.current == Some(session.name.as_str());
            let selected = self.focused && index == self.cursor;
            if selected {
                buf.set_style(
                    Rect::new(inner.x, y, inner.width, ROW_HEIGHT),
                    Style::new().bg(theme.selection),
                );
            }

            let marker = if is_current {
                Span::styled("▌", Style::new().fg(theme.current))
            } else {
                Span::raw(" ")
            };
            let number = if index < 9 {
                format!("{} ", index + 1)
            } else {
                "  ".to_owned()
            };
            let name_style = if is_current {
                Style::new().fg(theme.current).add_modifier(Modifier::BOLD)
            } else {
                Style::new().fg(theme.text)
            };
            // marker, number, name, a space, the badge, and a space to finish.
            let name_width = width.saturating_sub(1 + number.len() + 3);
            let name = fit(&session.name, name_width);
            let pad = name_width.saturating_sub(name.chars().count());
            let first_line = Line::from(vec![
                marker,
                Span::styled(number, Style::new().fg(theme.dim)),
                Span::styled(name, name_style),
                Span::raw(" ".repeat(pad + 1)),
                self.badge(session.claude),
            ]);
            buf.set_line(inner.x, y, &first_line, inner.width);

            let when = age(self.now, session.activity);
            let path_width = width.saturating_sub(3 + 3 + when.len());
            let detail = if session.path.is_empty() {
                when
            } else {
                format!(
                    "{} · {when}",
                    short_path(&session.path, self.home, path_width)
                )
            };
            buf.set_line(
                inner.x,
                y + 1,
                &Line::styled(format!("   {detail}"), Style::new().fg(theme.dim)),
                inner.width,
            );
            y += ROW_HEIGHT;
        }

        let new_line = y;
        if new_line < inner.y + inner.height {
            buf.set_line(
                inner.x,
                new_line,
                &Line::styled(" + new", Style::new().fg(theme.dim)),
                inner.width,
            );
        }

        let footer_top = (inner.y + inner.height).saturating_sub(FOOTER);
        if footer_top > new_line {
            for (offset, line) in self.footer().iter().enumerate() {
                let mut line = line.clone();
                line.spans.insert(0, Span::raw(" "));
                buf.set_line(inner.x, footer_top + offset as u16, &line, inner.width);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Claude;

    fn session(name: &str, path: &str, activity: u64, claude: Option<Claude>) -> Session {
        Session {
            name: name.into(),
            created: 0,
            activity,
            path: path.into(),
            claude,
        }
    }

    fn lines(widget: Sidebar<'_>, width: u16, height: u16) -> Vec<String> {
        let area = Rect::new(0, 0, width, height);
        let mut buf = Buffer::empty(area);
        widget.render(area, &mut buf);
        (0..height)
            .map(|y| {
                (0..width)
                    .map(|x| buf[(x, y)].symbol())
                    .collect::<String>()
                    .trim_end()
                    .to_owned()
            })
            .collect()
    }

    const NOW: u64 = 1_000_000;

    fn sessions() -> Vec<Session> {
        vec![
            session("main", "/Users/me/projects/gitview", NOW - 7200, None),
            session(
                "magpie",
                "/Users/me/projects/magpie",
                NOW,
                Some(Claude::Working),
            ),
            session(
                "pasty",
                "/Users/me/projects/pasty",
                NOW - 4 * 86_400,
                Some(Claude::Waiting),
            ),
        ]
    }

    #[test]
    fn the_sidebar_lists_sessions_with_where_they_are_and_what_claude_is_doing() {
        let theme = Theme::dark();
        let sessions = sessions();
        let drawn = lines(
            Sidebar {
                sessions: &sessions,
                current: Some("magpie"),
                cursor: 1,
                focused: true,
                mode: &Mode::Normal,
                message: None,
                theme: &theme,
                now: NOW,
                home: "/Users/me",
            },
            30,
            14,
        );
        assert_eq!(
            drawn,
            [
                "┌ sessions ──────────────────┐",
                "│ 1 main                     │",
                "│   ~/projects/gitview · 2h  │",
                "│▌2 magpie                 ⋯ │",
                "│   ~/projects/magpie · now  │",
                "│ 3 pasty                  ● │",
                "│   ~/projects/pasty · 4d    │",
                "│ + new                      │",
                "│                            │",
                "│                            │",
                "│                            │",
                "│ ⏎ open  n new  x kill      │",
                "│ ⌥1-9 ⌥{ ⌥} ⌥0  q detach    │",
                "└────────────────────────────┘",
            ]
        );
    }

    #[test]
    fn the_footer_asks_before_killing() {
        let theme = Theme::dark();
        let sessions = sessions();
        let mode = Mode::Kill("pasty".into());
        let drawn = lines(
            Sidebar {
                sessions: &sessions,
                current: None,
                cursor: 0,
                focused: true,
                mode: &mode,
                message: None,
                theme: &theme,
                now: NOW,
                home: "/Users/me",
            },
            30,
            14,
        );
        assert_eq!(drawn[11], "│ kill pasty?                │");
    }

    #[test]
    fn a_name_being_typed_shows_in_the_footer() {
        let theme = Theme::dark();
        let mode = Mode::New("fres".into());
        let drawn = lines(
            Sidebar {
                sessions: &[],
                current: None,
                cursor: 0,
                focused: true,
                mode: &mode,
                message: None,
                theme: &theme,
                now: 0,
                home: "",
            },
            30,
            8,
        );
        assert_eq!(drawn[1], "│ + new                      │");
        assert_eq!(drawn[5], "│ new: fres▏                 │");
    }

    #[test]
    fn a_long_name_is_cut_and_marked() {
        let theme = Theme::dark();
        let long = vec![session(
            "a-session-with-a-very-long-name",
            "",
            0,
            Some(Claude::Done),
        )];
        let drawn = lines(
            Sidebar {
                sessions: &long,
                current: None,
                cursor: 0,
                focused: false,
                mode: &Mode::Normal,
                message: None,
                theme: &theme,
                now: 0,
                home: "",
            },
            30,
            8,
        );
        assert_eq!(drawn[1], "│ 1 a-session-with-a-very… ✔ │");
        assert_eq!(drawn[2], "│   now                      │");
    }

    #[test]
    fn clicks_land_on_sessions_new_or_nothing() {
        let area = Rect::new(0, 0, 30, 14);
        assert_eq!(hit(area, 3, 0, 0), Hit::Nothing); // the border
        assert_eq!(hit(area, 3, 0, 1), Hit::Session(0));
        assert_eq!(hit(area, 3, 0, 2), Hit::Session(0));
        assert_eq!(hit(area, 3, 0, 3), Hit::Session(1));
        assert_eq!(hit(area, 3, 0, 6), Hit::Session(2));
        assert_eq!(hit(area, 3, 0, 7), Hit::New);
        assert_eq!(hit(area, 3, 0, 8), Hit::Nothing);
        assert_eq!(hit(area, 3, 0, 13), Hit::Nothing);
    }

    #[test]
    fn the_list_scrolls_to_keep_the_cursor_in_sight() {
        assert_eq!(scroll(3, 2, 5), 0);
        assert_eq!(scroll(10, 0, 4), 0);
        assert_eq!(scroll(10, 3, 4), 0);
        assert_eq!(scroll(10, 4, 4), 1);
        assert_eq!(scroll(10, 9, 4), 6);
        // A click lands on what is drawn, scrolled or not.
        let area = Rect::new(0, 0, 30, 14); // fits 4
        assert_eq!(hit(area, 10, 9, 1), Hit::Session(6));
    }

    #[test]
    fn ages_read_at_a_glance() {
        assert_eq!(age(100, 100), "now");
        assert_eq!(age(100, 200), "now"); // a clock that moved back
        assert_eq!(age(3600, 0), "1h");
        assert_eq!(age(150, 0), "2m");
        assert_eq!(age(3 * 86_400, 0), "3d");
    }

    #[test]
    fn paths_are_shortened_from_the_left() {
        assert_eq!(short_path("/Users/me/p/x", "/Users/me", 30), "~/p/x");
        assert_eq!(short_path("/Users/me", "/Users/me", 30), "~");
        // A sibling that merely starts the same is not home.
        assert_eq!(short_path("/Users/meg/x", "/Users/me", 30), "/Users/meg/x");
        assert_eq!(
            short_path("/Users/me/projects/magpie", "/Users/me", 10),
            "…ts/magpie"
        );
        assert_eq!(short_path("/x", "", 30), "/x");
    }
}
