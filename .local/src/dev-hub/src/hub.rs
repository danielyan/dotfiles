//! Doing things to the two tmux servers.
//!
//! The hub's window holds the sidebar on the left and one pane on the right.
//! Every session the hub has opened keeps a pane of its own, holding a nested
//! `tmux attach` to it; the ones not on screen wait in hidden windows. Showing
//! a session swaps its pane in, so switching is instant and nothing
//! reattaches. Panes carry `@hub-role` and `@hub-session` options, so all of
//! this can be read back from tmux and the sidebar keeps no state worth losing.
//!
//! Nothing here ever touches the sessions themselves except [`Hub::kill`]:
//! killing a pane, or the whole hub, only ends a nested client.

use anyhow::{Context, Result};

use crate::model::{
    self, ACTIVE_PANES_FORMAT, CLIENTS_FORMAT, HUB_PANES_FORMAT, History, Role, SESSIONS_FORMAT,
    View, Wanted,
};
use crate::tmux::{Tmux, quote};

pub struct Hub {
    /// The hub's own server.
    pub hub: Tmux,
    /// The server the sessions live on.
    pub sessions: Tmux,
    /// The sidebar's pane.
    pub sidebar: String,
    /// The sidebar's width, in columns.
    pub width: u16,
    /// A shell command that attaches to a session, or offers to start it, by
    /// name: `dev`, so a new session resolves names and folders as `dev
    /// <name>` would.
    pub starter: String,
    /// A shell command for the placeholder pane.
    pub placeholder: String,
}

impl Hub {
    /// Read both servers.
    pub fn observe(&self) -> Result<View> {
        let sessions = self
            .sessions
            .query(&["list-sessions", "-F", SESSIONS_FORMAT])?;
        let active = self
            .sessions
            .query(&["list-panes", "-a", "-F", ACTIVE_PANES_FORMAT])?;
        let clients = self
            .sessions
            .query(&["list-clients", "-F", CLIENTS_FORMAT])?;
        let panes = self
            .hub
            .run(&["list-panes", "-a", "-F", HUB_PANES_FORMAT])?;
        Ok(View {
            sessions: model::parse_sessions(&sessions, &active),
            panes: model::parse_hub_panes(&panes),
            clients: model::parse_clients(&clients),
            sidebar: self.sidebar.clone(),
        })
    }

    /// Mark the sidebar's pane as the sidebar, and have tmux bring it back if
    /// it ever exits (see the pane-died hook in hub.tmux.conf).
    pub fn claim_sidebar(&self) -> Result<()> {
        self.hub.run(&[
            "set-option",
            "-p",
            "-t",
            &self.sidebar,
            "@hub-role",
            "sidebar",
        ])?;
        self.hub.run(&[
            "set-option",
            "-p",
            "-t",
            &self.sidebar,
            "remain-on-exit",
            "on",
        ])?;
        Ok(())
    }

    /// A new hidden pane running `command`, marked with its role and session.
    fn hidden(&self, command: &str, role: Role, session: Option<&str>) -> Result<String> {
        let target = format!("{}:", self.hub_session()?);
        let id = self
            .hub
            .run(&[
                "new-window",
                "-d",
                "-P",
                "-F",
                "#{pane_id}",
                "-t",
                &target,
                command,
            ])?
            .trim()
            .to_owned();
        if role == Role::Placeholder {
            self.hub
                .run(&["set-option", "-p", "-t", &id, "@hub-role", "placeholder"])?;
        }
        if let Some(session) = session {
            self.hub
                .run(&["set-option", "-p", "-t", &id, "@hub-session", session])?;
        }
        Ok(id)
    }

    fn hub_session(&self) -> Result<String> {
        Ok(self
            .hub
            .run(&[
                "display-message",
                "-p",
                "-t",
                &self.sidebar,
                "#{session_id}",
            ])?
            .trim()
            .to_owned())
    }

    /// Put `pane` beside the sidebar. Whatever was there goes back into
    /// hiding, or away if it was a placeholder or dead.
    pub fn show(&self, view: &View, pane: &str, focus: bool) -> Result<()> {
        match view.visible() {
            Some(visible) if visible.id == pane => {}
            Some(visible) => {
                self.hub
                    .run(&["swap-pane", "-d", "-s", pane, "-t", &visible.id])?;
                if visible.dead || visible.role == Role::Placeholder {
                    self.hub.run(&["kill-pane", "-t", &visible.id])?;
                }
            }
            None => {
                self.hub
                    .run(&["join-pane", "-h", "-d", "-s", pane, "-t", &self.sidebar])?;
                self.hub.run(&[
                    "resize-pane",
                    "-t",
                    &self.sidebar,
                    "-x",
                    &self.width.to_string(),
                ])?;
            }
        }
        if focus {
            self.hub.run(&["select-pane", "-t", pane])?;
        }
        Ok(())
    }

    /// Show `session`, opening a pane for it if it has none yet.
    pub fn open(&self, view: &View, session: &str, focus: bool) -> Result<()> {
        let pane = match view.pane_for(session) {
            Some(pane) => pane.id.clone(),
            None => {
                let attach = format!(
                    "{} attach -t {}",
                    self.sessions.shell(),
                    quote(&format!("={session}"))
                );
                self.hidden(&attach, Role::Holder, Some(session))?
            }
        };
        self.show(view, &pane, focus)
            .with_context(|| format!("showing {session}"))
    }

    /// Start (or find) a session by name the way `dev <name>` does, on screen,
    /// so its questions are answered there.
    pub fn start(&self, view: &View, name: &str) -> Result<()> {
        let command = format!("{} {}", self.starter, quote(name));
        let pane = self.hidden(&command, Role::Holder, Some(name))?;
        self.show(view, &pane, true)
    }

    fn show_placeholder(&self, view: &View) -> Result<()> {
        let pane = self.hidden(&self.placeholder, Role::Placeholder, None)?;
        self.show(view, &pane, false)
    }

    /// Bring the screen in line with the sessions: replace what has gone,
    /// tidy away what is no longer needed. Returns whether anything changed.
    pub fn settle(&self, view: &View, history: &History) -> Result<bool> {
        let mut changed = false;
        match view.wanted(history) {
            Wanted::Keep => {}
            Wanted::Session(name) => {
                self.open(view, &name, false)?;
                changed = true;
            }
            Wanted::Placeholder => {
                self.show_placeholder(view)?;
                changed = true;
            }
        }
        // Strays are judged on what is there now.
        let view = if changed {
            self.observe()?
        } else {
            view.clone()
        };
        for pane in view.strays() {
            // Already gone is fine: a client can exit between the two reads.
            let _ = self.hub.run(&["kill-pane", "-t", &pane]);
            changed = true;
        }
        Ok(changed)
    }

    /// End a session, and everything running in it.
    pub fn kill(&self, session: &str) -> Result<()> {
        self.sessions
            .run(&["kill-session", "-t", &format!("={session}")])?;
        Ok(())
    }

    pub fn focus_sidebar(&self) -> Result<()> {
        self.hub.run(&["select-pane", "-t", &self.sidebar])?;
        Ok(())
    }

    pub fn focus_session(&self, view: &View) -> Result<()> {
        if let Some(visible) = view.visible() {
            self.hub.run(&["select-pane", "-t", &visible.id])?;
        }
        Ok(())
    }

    /// Leave the hub running, as detaching from any tmux session does.
    pub fn detach(&self) -> Result<()> {
        self.hub.run(&["detach-client"])?;
        Ok(())
    }

    /// End the hub. Every nested client goes with it; the sessions do not.
    pub fn quit(&self) -> Result<()> {
        self.hub.run(&["kill-server"])?;
        Ok(())
    }
}
