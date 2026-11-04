//! The sidebar's loop: read the servers, draw, act on keys and clicks.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use ratatui::crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
    MouseEventKind,
};
use ratatui::layout::Rect;

use crate::hub::Hub;
use crate::model::{History, View};
use crate::terminal::Tui;
use crate::theme::Theme;
use crate::ui::{self, Hit, Mode, Sidebar};

/// How often the servers are read when nothing is happening: often enough
/// that a session started or ended elsewhere shows up promptly.
const TICK: Duration = Duration::from_secs(1);
/// How long an error stays on screen if nobody dismisses it.
const MESSAGE_FOR: Duration = Duration::from_secs(8);

/// What a key or click asks for, before anything is done about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Intent {
    Up,
    Down,
    /// Open the session at the cursor.
    Open,
    /// Open the session numbered this (from 0).
    Jump(usize),
    Back,
    Forward,
    /// Hand the keyboard back to the session on screen.
    ToSession,
    StartNew,
    AskKill,
    AskQuit,
    Detach,
    Type(char),
    Erase,
    Confirm,
    Cancel,
    Nothing,
}

/// What a key means in a mode. Alt combinations arrive from the hub's own
/// key bindings (hub.tmux.conf) as well as from typing here, which is how ⌥3
/// works from inside a session.
pub fn intent(mode: &Mode, key: KeyEvent) -> Intent {
    if key.kind == KeyEventKind::Release {
        return Intent::Nothing;
    }
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    match mode {
        Mode::Normal => match key.code {
            KeyCode::Char(digit @ '1'..='9') => Intent::Jump(digit as usize - '1' as usize),
            KeyCode::Char('{' | '[') => Intent::Back,
            KeyCode::Char('}' | ']') => Intent::Forward,
            // ⌥0 is the hub saying "sidebar": it already is.
            KeyCode::Char('0') if alt => Intent::Nothing,
            _ if alt || ctrl => Intent::Nothing,
            KeyCode::Up | KeyCode::Char('k') => Intent::Up,
            KeyCode::Down | KeyCode::Char('j') => Intent::Down,
            KeyCode::Enter | KeyCode::Right | KeyCode::Char('l') => Intent::Open,
            KeyCode::Esc | KeyCode::Left | KeyCode::Tab | KeyCode::Char('h') => Intent::ToSession,
            KeyCode::Char('n') => Intent::StartNew,
            KeyCode::Char('x' | 'd') => Intent::AskKill,
            KeyCode::Char('q') => Intent::Detach,
            KeyCode::Char('Q') => Intent::AskQuit,
            _ => Intent::Nothing,
        },
        Mode::New(_) => match key.code {
            KeyCode::Enter => Intent::Confirm,
            KeyCode::Esc => Intent::Cancel,
            KeyCode::Backspace => Intent::Erase,
            KeyCode::Char('u') if ctrl => Intent::Cancel,
            KeyCode::Char(c) if !ctrl && !alt => Intent::Type(c),
            _ => Intent::Nothing,
        },
        Mode::Kill(_) | Mode::Quit => match key.code {
            KeyCode::Char('y' | 'Y') => Intent::Confirm,
            _ => Intent::Cancel,
        },
    }
}

pub struct App {
    hub: Hub,
    view: View,
    history: History,
    cursor: usize,
    mode: Mode,
    focused: bool,
    message: Option<(String, Instant)>,
    theme: Theme,
    home: String,
    /// Where the sidebar was last drawn, for clicks.
    area: Rect,
}

impl App {
    pub fn new(hub: Hub, theme: Theme) -> Self {
        Self {
            hub,
            view: View::default(),
            history: History::default(),
            cursor: 0,
            mode: Mode::Normal,
            focused: true,
            message: None,
            theme,
            home: std::env::var("HOME").unwrap_or_default(),
            area: Rect::default(),
        }
    }

    pub fn run(mut self, tui: &mut Tui) -> Result<()> {
        self.hub.claim_sidebar()?;
        self.refresh();
        // Opening the hub lands in a session, as a browser lands on a tab.
        if self.view.current().is_some() {
            let _ = self.hub.focus_session(&self.view);
            self.focused = false;
        }
        let mut next_tick = Instant::now() + TICK;
        loop {
            if let Some((_, since)) = &self.message
                && since.elapsed() > MESSAGE_FOR
            {
                self.message = None;
            }
            self.draw(tui)?;

            let wait = next_tick.saturating_duration_since(Instant::now());
            if event::poll(wait)? {
                let quit = self.handle(event::read()?);
                if quit {
                    return Ok(());
                }
            }
            if Instant::now() >= next_tick {
                self.refresh();
                next_tick = Instant::now() + TICK;
            }
        }
    }

    fn draw(&mut self, tui: &mut Tui) -> Result<()> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let message = self.message.as_ref().map(|(text, _)| text.as_str());
        let mut area = Rect::default();
        tui.draw(|frame| {
            area = frame.area();
            frame.render_widget(
                Sidebar {
                    sessions: &self.view.sessions,
                    current: self.view.current(),
                    cursor: self.cursor,
                    focused: self.focused,
                    mode: &self.mode,
                    message,
                    theme: &self.theme,
                    now,
                    home: &self.home,
                },
                area,
            );
        })?;
        self.area = area;
        Ok(())
    }

    /// Read the servers, record where the hub is, and put right whatever has
    /// gone. Failures are shown, not fatal: the next tick tries again.
    fn refresh(&mut self) {
        let result = (|| -> Result<()> {
            self.view = self.hub.observe()?;
            if self.hub.settle(&self.view, &self.history)? {
                self.view = self.hub.observe()?;
            }
            if let Some(current) = self.view.current()
                && self.view.has_session(current)
            {
                self.history.visit(current);
            }
            Ok(())
        })();
        if let Err(error) = result {
            self.fail(error);
        }
        if !self.focused {
            self.follow_current();
        }
        self.cursor = self.cursor.min(self.view.sessions.len().saturating_sub(1));
    }

    /// Keep the cursor on the session on screen while the keyboard is
    /// elsewhere, so coming back to the sidebar starts from there.
    fn follow_current(&mut self) {
        if let Some(index) = self
            .view
            .current()
            .and_then(|current| self.view.sessions.iter().position(|s| s.name == current))
        {
            self.cursor = index;
        }
    }

    fn fail(&mut self, error: anyhow::Error) {
        self.message = Some((format!("{error:#}"), Instant::now()));
    }

    /// Act on one event. Returns true when the sidebar should exit.
    fn handle(&mut self, event: Event) -> bool {
        match event {
            Event::FocusGained => self.focused = true,
            Event::FocusLost => {
                self.focused = false;
                self.mode = Mode::Normal;
                self.follow_current();
            }
            Event::Mouse(mouse) => self.click(mouse),
            Event::Key(key) => {
                if self.message.take().is_some() && key.kind != KeyEventKind::Release {
                    return false;
                }
                return self.act(intent(&self.mode, key));
            }
            _ => {}
        }
        false
    }

    fn click(&mut self, mouse: MouseEvent) {
        match mouse.kind {
            MouseEventKind::ScrollUp => self.act_quietly(Intent::Up),
            MouseEventKind::ScrollDown => self.act_quietly(Intent::Down),
            MouseEventKind::Down(MouseButton::Left) => {
                self.message = None;
                match ui::hit(self.area, self.view.sessions.len(), self.cursor, mouse.row) {
                    Hit::Session(index) => {
                        self.mode = Mode::Normal;
                        self.cursor = index;
                        self.act_quietly(Intent::Open);
                    }
                    Hit::New => self.act_quietly(Intent::StartNew),
                    Hit::Nothing => {}
                }
            }
            _ => {}
        }
    }

    fn act_quietly(&mut self, intent: Intent) {
        let _ = self.act(intent);
    }

    fn act(&mut self, intent: Intent) -> bool {
        let result = self.try_act(intent);
        match result {
            Ok(quit) => quit,
            Err(error) => {
                self.fail(error);
                false
            }
        }
    }

    fn try_act(&mut self, intent: Intent) -> Result<bool> {
        let count = self.view.sessions.len();
        match intent {
            Intent::Nothing => {}
            Intent::Up => self.cursor = self.cursor.saturating_sub(1),
            Intent::Down => self.cursor = (self.cursor + 1).min(count.saturating_sub(1)),
            Intent::Open => {
                if let Some(session) = self.view.sessions.get(self.cursor) {
                    let name = session.name.clone();
                    self.go(&name)?;
                }
            }
            Intent::Jump(index) => {
                if let Some(session) = self.view.sessions.get(index) {
                    self.cursor = index;
                    let name = session.name.clone();
                    self.go(&name)?;
                }
            }
            Intent::Back | Intent::Forward => {
                let live = self.view.names();
                let target = if intent == Intent::Back {
                    self.history.back(&live)
                } else {
                    self.history.forward(&live)
                };
                if let Some(name) = target {
                    self.hub.open(&self.view, &name, true)?;
                    self.after_switch();
                }
            }
            Intent::ToSession => {
                self.hub.focus_session(&self.view)?;
            }
            Intent::StartNew => {
                self.hub.focus_sidebar()?;
                self.mode = Mode::New(String::new());
            }
            Intent::AskKill => {
                if let Some(session) = self.view.sessions.get(self.cursor) {
                    self.mode = Mode::Kill(session.name.clone());
                }
            }
            Intent::AskQuit => self.mode = Mode::Quit,
            Intent::Detach => self.hub.detach()?,
            Intent::Type(c) => {
                if let Mode::New(name) = &mut self.mode {
                    name.push(c);
                }
            }
            Intent::Erase => {
                if let Mode::New(name) = &mut self.mode {
                    name.pop();
                }
            }
            Intent::Cancel => self.mode = Mode::Normal,
            Intent::Confirm => {
                let mode = std::mem::replace(&mut self.mode, Mode::Normal);
                match mode {
                    Mode::New(name) => {
                        let name = name.trim();
                        if self.view.has_session(name) {
                            self.go(name)?;
                        } else if !name.is_empty() {
                            self.hub.start(&self.view, name)?;
                            self.after_switch();
                        }
                    }
                    Mode::Kill(name) => {
                        self.hub.kill(&name)?;
                        // The pane on screen goes with it; settle picks the
                        // session to show instead.
                        self.refresh();
                    }
                    Mode::Quit => {
                        self.hub.quit()?;
                        return Ok(true);
                    }
                    Mode::Normal => {}
                }
            }
        }
        Ok(false)
    }

    /// Show a session and hand it the keyboard, as clicking a tab does.
    fn go(&mut self, name: &str) -> Result<()> {
        self.hub.open(&self.view, name, true)?;
        self.history.visit(name);
        self.after_switch();
        Ok(())
    }

    fn after_switch(&mut self) {
        self.focused = false;
        self.refresh();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn alt(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::ALT)
    }

    #[test]
    fn the_hub_s_alt_keys_jump_and_go_back_and_forward() {
        let normal = Mode::Normal;
        assert_eq!(intent(&normal, alt('1')), Intent::Jump(0));
        assert_eq!(intent(&normal, alt('9')), Intent::Jump(8));
        assert_eq!(intent(&normal, alt('{')), Intent::Back);
        assert_eq!(intent(&normal, alt('}')), Intent::Forward);
        assert_eq!(intent(&normal, alt('0')), Intent::Nothing);
        // Other alt keys are nobody's business here.
        assert_eq!(intent(&normal, alt('n')), Intent::Nothing);
    }

    #[test]
    fn plain_keys_in_the_sidebar() {
        let normal = Mode::Normal;
        assert_eq!(intent(&normal, key(KeyCode::Char('3'))), Intent::Jump(2));
        assert_eq!(intent(&normal, key(KeyCode::Char('['))), Intent::Back);
        assert_eq!(intent(&normal, key(KeyCode::Char(']'))), Intent::Forward);
        assert_eq!(intent(&normal, key(KeyCode::Down)), Intent::Down);
        assert_eq!(intent(&normal, key(KeyCode::Char('k'))), Intent::Up);
        assert_eq!(intent(&normal, key(KeyCode::Enter)), Intent::Open);
        assert_eq!(intent(&normal, key(KeyCode::Esc)), Intent::ToSession);
        assert_eq!(intent(&normal, key(KeyCode::Char('n'))), Intent::StartNew);
        assert_eq!(intent(&normal, key(KeyCode::Char('x'))), Intent::AskKill);
        assert_eq!(intent(&normal, key(KeyCode::Char('q'))), Intent::Detach);
        assert_eq!(intent(&normal, key(KeyCode::Char('Q'))), Intent::AskQuit);
        // ctrl-c is not a way out: the sidebar is the hub.
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(intent(&normal, ctrl_c), Intent::Nothing);
    }

    #[test]
    fn typing_a_name_takes_every_character_even_the_command_keys() {
        let typing = Mode::New("ma".into());
        assert_eq!(intent(&typing, key(KeyCode::Char('n'))), Intent::Type('n'));
        assert_eq!(intent(&typing, key(KeyCode::Char('q'))), Intent::Type('q'));
        assert_eq!(intent(&typing, key(KeyCode::Char('1'))), Intent::Type('1'));
        assert_eq!(intent(&typing, key(KeyCode::Backspace)), Intent::Erase);
        assert_eq!(intent(&typing, key(KeyCode::Enter)), Intent::Confirm);
        assert_eq!(intent(&typing, key(KeyCode::Esc)), Intent::Cancel);
    }

    #[test]
    fn only_y_confirms_a_kill_or_a_quit() {
        for mode in [Mode::Kill("a".into()), Mode::Quit] {
            assert_eq!(intent(&mode, key(KeyCode::Char('y'))), Intent::Confirm);
            assert_eq!(intent(&mode, key(KeyCode::Char('n'))), Intent::Cancel);
            assert_eq!(intent(&mode, key(KeyCode::Enter)), Intent::Cancel);
        }
    }

    #[test]
    fn key_releases_are_ignored() {
        let mut release = key(KeyCode::Char('x'));
        release.kind = KeyEventKind::Release;
        assert_eq!(intent(&Mode::Normal, release), Intent::Nothing);
    }
}
