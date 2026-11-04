//! dev-hub — the sidebar of `dev hub`.
//!
//!   dev-hub               the sidebar, run by `dev hub` in the hub's first pane
//!   dev-hub placeholder   what the right side shows when there is no session
//!
//! Environment, for tests and odd setups:
//!   DEV_HUB_SESSIONS   tmux socket name (-L) of the sessions' server; unset,
//!                      the default server `dev` uses
//!   DEV_HUB_STARTER    command that opens or starts a session by name;
//!                      unset, `dev` (with $TMUX cleared, as dev runs tmux)

use std::time::Duration;

use anyhow::{Context, Result, bail};

use dev_hub::config::Config;
use dev_hub::hub::Hub;
use dev_hub::theme::{self, Theme};
use dev_hub::tmux::{Server, Tmux, quote};
use dev_hub::{app, colour, placeholder, terminal};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        [] => sidebar(),
        ["placeholder"] => placeholder::run(&load_theme(&Config::load())),
        ["-h" | "--help" | "help"] => {
            println!("dev-hub: the sidebar of `dev hub` (run `dev hub`, not this)");
            Ok(())
        }
        _ => Err(anyhow::anyhow!(
            "unknown arguments: {} (dev-hub help)",
            args.join(" ")
        )),
    };
    if let Err(error) = result {
        eprintln!("dev-hub: {error:#}");
        // tmux brings the sidebar back when it exits (hub.tmux.conf). A pause
        // keeps a sidebar that cannot start from doing so in a tight loop, and
        // leaves the error on screen long enough to read.
        std::thread::sleep(Duration::from_secs(2));
        std::process::exit(1);
    }
}

fn load_theme(config: &Config) -> Theme {
    theme::load(&config.theme)
        .unwrap_or_default()
        .adapt(colour::detect())
}

fn sidebar() -> Result<()> {
    if std::env::var_os("TMUX").is_none() {
        bail!("this is the sidebar of the hub, and runs inside it: use `dev hub`");
    }
    let pane = std::env::var("TMUX_PANE").context("TMUX_PANE is not set")?;
    let config = Config::load();
    let home = std::env::var("HOME").unwrap_or_default();
    let sessions = match std::env::var("DEV_HUB_SESSIONS") {
        Ok(name) if !name.is_empty() => Server::Named(name),
        _ => Server::Default,
    };
    let starter = std::env::var("DEV_HUB_STARTER")
        .unwrap_or_else(|_| format!("env -u TMUX {}", quote(&format!("{home}/bin/dev"))));
    let me = std::env::current_exe().context("finding dev-hub itself")?;
    let hub = Hub {
        hub: Tmux::new(Server::Inherited),
        sessions: Tmux::new(sessions),
        sidebar: pane,
        width: config.width,
        starter,
        placeholder: format!("{} placeholder", quote(&me.to_string_lossy())),
    };
    let theme = load_theme(&config);
    let mut tui = terminal::Tui::new()?;
    app::App::new(hub, theme).run(&mut tui)
}
