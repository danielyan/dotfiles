//! The right-hand side when there are no sessions: a note saying how to start
//! one. A key pressed here goes to the sidebar, which is where `n` is.

use std::process::Command;

use anyhow::Result;
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use ratatui::layout::{Alignment, Constraint, Layout};
use ratatui::style::Style;
use ratatui::text::Line;
use ratatui::widgets::Paragraph;

use crate::terminal::Tui;
use crate::theme::Theme;

pub fn run(theme: &Theme) -> Result<()> {
    let mut tui = Tui::new()?;
    loop {
        tui.draw(|frame| {
            let [_, middle, _] = Layout::vertical([
                Constraint::Fill(1),
                Constraint::Length(2),
                Constraint::Fill(1),
            ])
            .areas(frame.area());
            frame.render_widget(
                Paragraph::new(vec![
                    Line::styled("No sessions on this machine.", Style::new().fg(theme.text)),
                    Line::styled("n in the list starts one.", Style::new().fg(theme.dim)),
                ])
                .alignment(Alignment::Center),
                middle,
            );
        })?;
        if let Event::Key(key) = event::read()?
            && key.kind == KeyEventKind::Press
        {
            // To the sidebar, which is always the leftmost pane.
            let _ = Command::new("tmux")
                .args(["select-pane", "-t", "{left}"])
                .status();
        }
    }
}
