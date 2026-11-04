//! Taking over the pane: raw mode, the alternate screen, mouse and focus
//! reporting, and putting it all back, panic or not. Cut down from gitview's
//! terminal.rs.

use std::io::{self, Stdout, Write};
use std::sync::Once;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result};
use ratatui::Frame;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{
    DisableFocusChange, DisableMouseCapture, EnableFocusChange, EnableMouseCapture,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    BeginSynchronizedUpdate, EndSynchronizedUpdate, EnterAlternateScreen, LeaveAlternateScreen,
    disable_raw_mode, enable_raw_mode,
};

static ACTIVE: AtomicBool = AtomicBool::new(false);

pub struct Tui {
    terminal: Terminal<CrosstermBackend<Stdout>>,
}

impl Tui {
    pub fn new() -> Result<Self> {
        install_panic_hook();
        enable_raw_mode().context("enabling raw mode")?;
        // The mouse is ours: in the hub, clicks on the sidebar are meant for
        // the sidebar. Focus reports say whether the keyboard is here.
        execute!(
            io::stdout(),
            EnterAlternateScreen,
            EnableFocusChange,
            EnableMouseCapture
        )
        .context("entering the alternate screen")?;
        ACTIVE.store(true, Ordering::SeqCst);
        let terminal = Terminal::new(CrosstermBackend::new(io::stdout()))
            .context("creating the ratatui terminal")?;
        Ok(Self { terminal })
    }

    /// Draw one frame, as a synchronized update so it is never seen half done.
    pub fn draw<F>(&mut self, render: F) -> Result<()>
    where
        F: FnOnce(&mut Frame),
    {
        let begun = execute!(io::stdout(), BeginSynchronizedUpdate).is_ok();
        let result = self.terminal.draw(render);
        if begun {
            let _ = execute!(io::stdout(), EndSynchronizedUpdate);
        }
        result.context("drawing a frame")?;
        Ok(())
    }
}

impl Drop for Tui {
    fn drop(&mut self) {
        restore();
    }
}

pub fn restore() {
    if !ACTIVE.swap(false, Ordering::SeqCst) {
        return;
    }
    let _ = execute!(io::stdout(), EndSynchronizedUpdate, DisableMouseCapture);
    let _ = disable_raw_mode();
    let _ = execute!(io::stdout(), DisableFocusChange, LeaveAlternateScreen);
    let _ = io::stdout().flush();
}

fn install_panic_hook() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            restore();
            previous(info);
        }));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restore_is_idempotent_and_runs_on_panic() {
        restore();
        restore();
        assert!(!ACTIVE.load(Ordering::SeqCst));

        install_panic_hook();
        ACTIVE.store(true, Ordering::SeqCst);
        let unwound = std::panic::catch_unwind(|| panic!("mid-render failure"));
        assert!(unwound.is_err());
        assert!(!ACTIVE.load(Ordering::SeqCst));
    }
}
