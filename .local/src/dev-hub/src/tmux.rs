//! Running tmux, against one of the two servers the hub deals with.
//!
//! The hub is a tmux server of its own (`tmux -L hub`), and the sessions it
//! shows live on another, the default one `dev` uses. The sidebar runs inside
//! the first and must reach the second, which is only a matter of which socket
//! each command goes to.

use std::process::Command;

use anyhow::{Result, bail};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Server {
    /// The server `$TMUX` names: the hub's own, from a pane inside it.
    Inherited,
    /// The default server, where `dev` keeps the sessions.
    Default,
    /// A server of its own (`tmux -L <name>`), which is how tests stay clear
    /// of the real ones.
    Named(String),
}

#[derive(Debug, Clone)]
pub struct Tmux {
    server: Server,
}

impl Tmux {
    pub fn new(server: Server) -> Self {
        Self { server }
    }

    fn command(&self) -> Command {
        let mut command = Command::new("tmux");
        match &self.server {
            Server::Inherited => {}
            Server::Default => {
                // Inside the hub $TMUX names the hub, and tmux would take it.
                command.env_remove("TMUX");
            }
            Server::Named(name) => {
                command.env_remove("TMUX").args(["-L", name]);
            }
        }
        command
    }

    /// The same server, as words for a shell: for the commands tmux itself
    /// starts in a pane.
    pub fn shell(&self) -> String {
        match &self.server {
            Server::Inherited => "tmux".to_owned(),
            Server::Default => "env -u TMUX tmux".to_owned(),
            Server::Named(name) => format!("env -u TMUX tmux -L {}", quote(name)),
        }
    }

    /// Run a command, failing with what tmux said.
    pub fn run(&self, args: &[&str]) -> Result<String> {
        let output = self.command().args(args).output()?;
        if !output.status.success() {
            bail!(
                "tmux {}: {}",
                args.first().unwrap_or(&""),
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    /// Like [`Self::run`], for a question: a server that is not running has
    /// nothing to list, which is an answer rather than a failure.
    pub fn query(&self, args: &[&str]) -> Result<String> {
        let output = self.command().args(args).output()?;
        if output.status.success() {
            return Ok(String::from_utf8_lossy(&output.stdout).into_owned());
        }
        let said = String::from_utf8_lossy(&output.stderr);
        if is_no_server(&said) {
            return Ok(String::new());
        }
        bail!("tmux {}: {}", args.first().unwrap_or(&""), said.trim())
    }
}

/// What tmux says when there is no server on the socket, in its two wordings:
/// no socket file at all, or one nobody is listening on.
fn is_no_server(said: &str) -> bool {
    said.contains("no server running") || said.contains("error connecting to")
}

/// One word for a shell, quoted only when it needs to be.
///
/// `=` counts as needing it: zsh reads a leading `=word` as the path of the
/// command `word`, so an unquoted `attach -t =magpie` dies before tmux runs.
pub fn quote(word: &str) -> String {
    let plain = !word.is_empty()
        && word
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_./:@%+,".contains(c));
    if plain {
        word.to_owned()
    } else {
        format!("'{}'", word.replace('\'', r"'\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_words_are_left_alone() {
        assert_eq!(quote("magpie"), "magpie");
        assert_eq!(quote("/Users/ldan/bin/dev"), "/Users/ldan/bin/dev");
    }

    #[test]
    fn anything_else_is_single_quoted() {
        assert_eq!(quote("=magpie"), "'=magpie'");
        assert_eq!(quote("my proj"), "'my proj'");
        assert_eq!(quote("it's"), r"'it'\''s'");
        assert_eq!(quote("a;rm -rf"), "'a;rm -rf'");
        assert_eq!(quote(""), "''");
    }

    #[test]
    fn both_ways_of_saying_no_server_are_recognised() {
        assert!(is_no_server(
            "no server running on /private/tmp/tmux-501/default"
        ));
        assert!(is_no_server(
            "error connecting to /private/tmp/tmux-501/x (No such file or directory)"
        ));
        assert!(!is_no_server("can't find session: nope"));
    }

    #[test]
    fn the_shell_form_names_the_same_server() {
        assert_eq!(Tmux::new(Server::Inherited).shell(), "tmux");
        assert_eq!(Tmux::new(Server::Default).shell(), "env -u TMUX tmux");
        assert_eq!(
            Tmux::new(Server::Named("t1".into())).shell(),
            "env -u TMUX tmux -L t1"
        );
    }
}
