//! What the hub knows, as plain data: the sessions, the hub's panes, which pane
//! shows which session, and what should be on screen.
//!
//! Nothing here runs tmux. [`crate::hub`] reads the servers into a [`View`],
//! and everything decided from it is decided here, where tests can reach it.

use std::collections::HashMap;

/// Field separator in the formats below. Session names, paths and titles do
/// not hold tabs in practice; a title that did would only lose its tail.
const SEP: char = '\t';

/// `list-sessions` on the sessions' server.
pub const SESSIONS_FORMAT: &str = "#{session_name}\t#{session_created}\t#{session_activity}";
/// `list-panes -a` on the sessions' server: each session's active pane says
/// where it is and what Claude is doing.
pub const ACTIVE_PANES_FORMAT: &str =
    "#{session_name}\t#{window_active}\t#{pane_active}\t#{pane_current_path}\t#{pane_title}";
/// `list-clients` on the sessions' server.
pub const CLIENTS_FORMAT: &str = "#{client_tty}\t#{session_name}";
/// `list-panes -a` on the hub's server.
pub const HUB_PANES_FORMAT: &str =
    "#{pane_id}\t#{window_id}\t#{pane_tty}\t#{pane_dead}\t#{@hub-role}\t#{@hub-session}";

/// What Claude Code is doing in a session, as its status-glyph hooks put it in
/// the pane title: `⋯ 🤖 magpie`, `❓ 🤖 magpie`, `✔ 🤖 magpie`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Claude {
    Working,
    Waiting,
    Done,
}

impl Claude {
    pub fn from_title(title: &str) -> Option<Self> {
        let mut words = title.split_whitespace();
        let glyph = words.next()?;
        if words.next() != Some("🤖") {
            return None;
        }
        match glyph {
            "⋯" => Some(Self::Working),
            "❓" => Some(Self::Waiting),
            "✔" => Some(Self::Done),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub name: String,
    pub created: u64,
    pub activity: u64,
    /// Where its active pane is, which says more than where it started.
    pub path: String,
    pub claude: Option<Claude>,
}

/// Sessions in the order they were started, so a session keeps its number the
/// way a browser tab keeps its place.
pub fn parse_sessions(sessions: &str, active_panes: &str) -> Vec<Session> {
    let mut active: HashMap<&str, (&str, &str)> = HashMap::new();
    for line in active_panes.lines() {
        let fields: Vec<&str> = line.splitn(5, SEP).collect();
        if let [name, "1", "1", path, title] = fields[..] {
            active.insert(name, (path, title));
        }
    }

    let mut found: Vec<Session> = sessions
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split(SEP).collect();
            let [name, created, activity] = fields[..] else {
                return None;
            };
            let (path, title) = active.get(name).copied().unwrap_or_default();
            Some(Session {
                name: name.to_owned(),
                created: created.parse().unwrap_or(0),
                activity: activity.parse().unwrap_or(0),
                path: path.to_owned(),
                claude: Claude::from_title(title),
            })
        })
        .collect();
    found.sort_by(|a, b| a.created.cmp(&b.created).then_with(|| a.name.cmp(&b.name)));
    found
}

/// Which session each client of the sessions' server is looking at, by tty.
pub fn parse_clients(clients: &str) -> HashMap<String, String> {
    clients
        .lines()
        .filter_map(|line| line.split_once(SEP))
        .map(|(tty, session)| (tty.to_owned(), session.to_owned()))
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Sidebar,
    /// Shown when there is no session to show.
    Placeholder,
    /// A pane holding a nested client of the sessions' server.
    Holder,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HubPane {
    pub id: String,
    pub window: String,
    pub tty: String,
    pub dead: bool,
    pub role: Role,
    /// The session the pane was opened for. What its client actually shows
    /// may differ: `dev mag` lands in magpie, and choose-tree inside a session
    /// moves the client elsewhere. That is in [`View::clients`].
    pub intended: Option<String>,
}

pub fn parse_hub_panes(panes: &str) -> Vec<HubPane> {
    panes
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split(SEP).collect();
            let [id, window, tty, dead, role, intended] = fields[..] else {
                return None;
            };
            Some(HubPane {
                id: id.to_owned(),
                window: window.to_owned(),
                tty: tty.to_owned(),
                dead: dead == "1",
                role: match role {
                    "sidebar" => Role::Sidebar,
                    "placeholder" => Role::Placeholder,
                    _ => Role::Holder,
                },
                intended: (!intended.is_empty()).then(|| intended.to_owned()),
            })
        })
        .collect()
}

/// Both servers, read at one moment.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct View {
    pub sessions: Vec<Session>,
    pub panes: Vec<HubPane>,
    /// tty → session, for every client of the sessions' server.
    pub clients: HashMap<String, String>,
    /// The sidebar's own pane id.
    pub sidebar: String,
}

/// What the right-hand side should be showing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wanted {
    /// It is fine as it is.
    Keep,
    Session(String),
    Placeholder,
}

impl View {
    pub fn names(&self) -> Vec<&str> {
        self.sessions.iter().map(|s| s.name.as_str()).collect()
    }

    pub fn has_session(&self, name: &str) -> bool {
        self.sessions.iter().any(|s| s.name == name)
    }

    fn sidebar_window(&self) -> Option<&str> {
        self.panes
            .iter()
            .find(|pane| pane.id == self.sidebar)
            .map(|pane| pane.window.as_str())
    }

    /// The pane beside the sidebar, if there is one.
    pub fn visible(&self) -> Option<&HubPane> {
        let window = self.sidebar_window()?;
        self.panes
            .iter()
            .find(|pane| pane.window == window && pane.id != self.sidebar)
    }

    /// What a pane is showing: its client's session once it has a client, and
    /// until then the one it was opened for.
    pub fn session_of<'a>(&'a self, pane: &'a HubPane) -> Option<&'a str> {
        if pane.role != Role::Holder {
            return None;
        }
        self.clients
            .get(&pane.tty)
            .map(String::as_str)
            .or(pane.intended.as_deref())
    }

    /// Has this holder's client attached yet? Until it has, it may be `dev`
    /// asking whether to start the session.
    pub fn attached(&self, pane: &HubPane) -> bool {
        self.clients.contains_key(&pane.tty)
    }

    /// The session on screen.
    pub fn current(&self) -> Option<&str> {
        self.visible()
            .filter(|pane| !pane.dead)
            .and_then(|pane| self.session_of(pane))
    }

    /// A live pane already showing `session`, the visible one first.
    pub fn pane_for(&self, session: &str) -> Option<&HubPane> {
        let visible = self.visible().map(|pane| pane.id.as_str());
        let mut showing: Vec<&HubPane> = self
            .panes
            .iter()
            .filter(|pane| !pane.dead && self.session_of(pane) == Some(session))
            .collect();
        showing.sort_by_key(|pane| Some(pane.id.as_str()) != visible);
        showing.first().copied()
    }

    /// What should be on the right, given where the hub has been.
    pub fn wanted(&self, history: &History) -> Wanted {
        let fallback = || match history
            .fallback(&self.names())
            .or_else(|| self.most_active())
        {
            Some(name) => Wanted::Session(name),
            None => Wanted::Placeholder,
        };
        let Some(visible) = self.visible().filter(|pane| !pane.dead) else {
            return fallback();
        };
        match visible.role {
            // A session appeared while there was nothing to show: show it.
            Role::Placeholder if !self.sessions.is_empty() => fallback(),
            Role::Placeholder => Wanted::Keep,
            Role::Sidebar => Wanted::Keep,
            // Attached, or still being started by `dev`: leave it be.
            Role::Holder => Wanted::Keep,
        }
    }

    fn most_active(&self) -> Option<String> {
        self.sessions
            .iter()
            .max_by_key(|s| s.activity)
            .map(|s| s.name.clone())
    }

    /// Hidden panes with no reason to exist: dead ones, spare placeholders,
    /// holders whose session is gone, a second holder for one session, and
    /// `dev` prompts nobody is looking at any more.
    pub fn strays(&self) -> Vec<String> {
        let visible = self.visible().map(|pane| pane.id.clone());
        let mut seen: Vec<&str> = self.current().into_iter().collect();
        let mut found = Vec::new();
        for pane in &self.panes {
            if pane.role == Role::Sidebar || Some(&pane.id) == visible.as_ref() {
                continue;
            }
            let stray = pane.dead
                || pane.role == Role::Placeholder
                || !self.attached(pane)
                || match self.session_of(pane) {
                    Some(session) if self.has_session(session) && !seen.contains(&session) => {
                        seen.push(session);
                        false
                    }
                    _ => true,
                };
            if stray {
                found.push(pane.id.clone());
            }
        }
        found
    }
}

/// Where the hub has been, like a browser's back and forward.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct History {
    entries: Vec<String>,
    position: usize,
}

impl History {
    /// Record arriving at `name`. Going somewhere new drops whatever was
    /// forward of here, as a browser does.
    pub fn visit(&mut self, name: &str) {
        if self.entries.get(self.position).map(String::as_str) == Some(name) {
            return;
        }
        if !self.entries.is_empty() {
            self.entries.truncate(self.position + 1);
        }
        self.entries.push(name.to_owned());
        self.position = self.entries.len() - 1;
    }

    /// One step back, past sessions that no longer exist.
    pub fn back(&mut self, live: &[&str]) -> Option<String> {
        let current = self.entries.get(self.position)?.clone();
        let found = (0..self.position).rev().find(|&at| {
            let name = self.entries[at].as_str();
            name != current && live.contains(&name)
        })?;
        self.position = found;
        Some(self.entries[found].clone())
    }

    /// One step forward, past sessions that no longer exist.
    pub fn forward(&mut self, live: &[&str]) -> Option<String> {
        let current = self.entries.get(self.position)?.clone();
        let found = (self.position + 1..self.entries.len()).find(|&at| {
            let name = self.entries[at].as_str();
            name != current && live.contains(&name)
        })?;
        self.position = found;
        Some(self.entries[found].clone())
    }

    /// Where to go when the session on screen goes away: the most recent one
    /// still running, looking back first.
    pub fn fallback(&self, live: &[&str]) -> Option<String> {
        if self.entries.is_empty() {
            return None;
        }
        let back = (0..=self.position).rev();
        let forward = self.position + 1..self.entries.len();
        back.chain(forward)
            .map(|at| self.entries[at].as_str())
            .find(|name| live.contains(name))
            .map(str::to_owned)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(name: &str, created: u64) -> Session {
        Session {
            name: name.into(),
            created,
            activity: created,
            path: String::new(),
            claude: None,
        }
    }

    fn pane(id: &str, window: &str, role: Role, intended: Option<&str>) -> HubPane {
        HubPane {
            id: id.into(),
            window: window.into(),
            tty: format!("/dev/tty{id}"),
            dead: false,
            role,
            intended: intended.map(Into::into),
        }
    }

    /// A hub with the sidebar (%0) in @0, and holders for the given sessions,
    /// the first beside the sidebar and each attached.
    fn hub(sessions: &[&str], holders: &[&str]) -> View {
        let mut panes = vec![pane("%0", "@0", Role::Sidebar, None)];
        let mut clients = HashMap::new();
        for (index, name) in holders.iter().enumerate() {
            let id = format!("%{}", index + 1);
            let window = if index == 0 {
                "@0".into()
            } else {
                format!("@{}", index + 1)
            };
            let holder = pane(&id, &window, Role::Holder, Some(name));
            clients.insert(holder.tty.clone(), name.to_string());
            panes.push(holder);
        }
        View {
            sessions: sessions
                .iter()
                .enumerate()
                .map(|(index, name)| session(name, index as u64))
                .collect(),
            panes,
            clients,
            sidebar: "%0".into(),
        }
    }

    #[test]
    fn claude_s_state_is_read_from_the_title_its_hooks_set() {
        assert_eq!(Claude::from_title("⋯ 🤖 magpie"), Some(Claude::Working));
        assert_eq!(Claude::from_title("❓ 🤖 pasty"), Some(Claude::Waiting));
        assert_eq!(Claude::from_title("✔ 🤖 fresco"), Some(Claude::Done));
        // Not Claude: a shell, gitview, or a title that merely starts alike.
        assert_eq!(Claude::from_title("gitview"), None);
        assert_eq!(Claude::from_title("✔ done"), None);
        assert_eq!(Claude::from_title(""), None);
    }

    #[test]
    fn sessions_come_in_the_order_they_were_started() {
        let listed = "magpie\t300\t310\nmain\t100\t900\nfresco\t200\t200\n";
        let active = "magpie\t1\t1\t/p/magpie\t⋯ 🤖 magpie\n\
                      magpie\t0\t1\t/elsewhere\tzsh\n\
                      main\t1\t1\t/p/gitview\tgitview\n";
        let sessions = parse_sessions(listed, active);
        let names: Vec<&str> = sessions.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["main", "fresco", "magpie"]);
        // Only the active pane of the active window speaks for a session.
        assert_eq!(sessions[2].path, "/p/magpie");
        assert_eq!(sessions[2].claude, Some(Claude::Working));
        assert_eq!(sessions[0].path, "/p/gitview");
        assert_eq!(sessions[0].claude, None);
        // A session with no pane listed is still a session.
        assert_eq!(sessions[1].path, "");
        assert_eq!(sessions[1].activity, 200);
    }

    #[test]
    fn a_title_with_a_tab_in_it_keeps_the_rest_of_the_line() {
        let sessions = parse_sessions("a\t1\t1\n", "a\t1\t1\t/p\t✔ 🤖 a\tmore\n");
        assert_eq!(sessions[0].path, "/p");
    }

    #[test]
    fn hub_panes_carry_their_role_and_the_session_they_were_opened_for() {
        let panes = parse_hub_panes(
            "%0\t@0\t/dev/ttys1\t0\tsidebar\t\n\
             %3\t@0\t/dev/ttys4\t0\t\tmagpie\n\
             %5\t@2\t/dev/ttys6\t1\tplaceholder\t\n",
        );
        assert_eq!(panes.len(), 3);
        assert_eq!(panes[0].role, Role::Sidebar);
        assert_eq!(panes[1].role, Role::Holder);
        assert_eq!(panes[1].intended.as_deref(), Some("magpie"));
        assert!(panes[2].dead);
        assert_eq!(panes[2].role, Role::Placeholder);
    }

    #[test]
    fn the_visible_pane_is_the_one_beside_the_sidebar() {
        let view = hub(&["a", "b"], &["a", "b"]);
        assert_eq!(view.visible().map(|p| p.id.as_str()), Some("%1"));
        assert_eq!(view.current(), Some("a"));
    }

    #[test]
    fn a_client_that_moved_counts_where_it_is_now() {
        // Opened for a, then choose-tree inside it went to b.
        let mut view = hub(&["a", "b"], &["a"]);
        view.clients.insert("/dev/tty%1".into(), "b".into());
        assert_eq!(view.current(), Some("b"));
        assert_eq!(view.pane_for("b").map(|p| p.id.as_str()), Some("%1"));
        assert!(view.pane_for("a").is_none());
    }

    #[test]
    fn a_holder_with_no_client_yet_shows_what_it_was_opened_for() {
        let mut view = hub(&["a"], &["newthing"]);
        view.clients.clear();
        assert_eq!(view.current(), Some("newthing"));
        assert!(!view.attached(view.visible().unwrap()));
        // `dev` may be asking whether to start it: not to be disturbed.
        assert_eq!(view.wanted(&History::default()), Wanted::Keep);
    }

    #[test]
    fn a_visible_session_is_kept() {
        let view = hub(&["a", "b"], &["a"]);
        assert_eq!(view.wanted(&History::default()), Wanted::Keep);
    }

    #[test]
    fn when_the_session_on_screen_ends_the_last_one_visited_takes_its_place() {
        // a was on screen and its pane has gone: exit in its last shell.
        let mut view = hub(&["b", "c"], &[]);
        view.sessions[1].activity = 99;
        let mut history = History::default();
        for name in ["b", "c", "a"] {
            history.visit(name);
        }
        assert_eq!(view.wanted(&history), Wanted::Session("c".into()));
        // With no history, the busiest session.
        view.sessions[0].activity = 500;
        assert_eq!(
            view.wanted(&History::default()),
            Wanted::Session("b".into())
        );
    }

    #[test]
    fn a_dead_visible_pane_is_replaced_by_a_fresh_one() {
        // Its client went, the session did not: open it again.
        let mut view = hub(&["a", "b"], &["a", "b"]);
        view.panes[1].dead = true;
        let mut history = History::default();
        history.visit("b");
        history.visit("a");
        assert_eq!(view.wanted(&history), Wanted::Session("a".into()));
        assert!(view.pane_for("a").is_none(), "the dead pane is not reused");
    }

    #[test]
    fn with_no_sessions_at_all_the_placeholder_is_shown() {
        let view = hub(&[], &[]);
        assert_eq!(view.wanted(&History::default()), Wanted::Placeholder);
    }

    #[test]
    fn a_session_appearing_replaces_the_placeholder() {
        let mut view = hub(&["a"], &[]);
        view.panes.push(pane("%9", "@0", Role::Placeholder, None));
        assert_eq!(
            view.wanted(&History::default()),
            Wanted::Session("a".into())
        );
        view.sessions.clear();
        assert_eq!(view.wanted(&History::default()), Wanted::Keep);
    }

    #[test]
    fn strays_are_hidden_panes_with_no_reason_to_exist() {
        let mut view = hub(&["a", "b", "c"], &["a", "b", "gone", "b"]);
        // %1 a (visible), %2 b, %3 gone (session ended), %4 a second b.
        view.panes.push(pane("%5", "@9", Role::Placeholder, None));
        let mut dead = pane("%6", "@10", Role::Holder, Some("c"));
        dead.dead = true;
        view.clients.insert(dead.tty.clone(), "c".into());
        view.panes.push(dead);
        // A `dev` prompt left behind: never attached.
        view.panes.push(pane("%7", "@11", Role::Holder, Some("d")));
        assert_eq!(view.strays(), ["%3", "%4", "%5", "%6", "%7"]);
    }

    #[test]
    fn a_hidden_holder_for_the_session_on_screen_is_a_stray() {
        let view = hub(&["a"], &["a", "a"]);
        assert_eq!(view.strays(), ["%2"]);
    }

    #[test]
    fn the_sidebar_and_the_visible_pane_are_never_strays() {
        let mut view = hub(&["a"], &["a"]);
        view.clients.clear(); // a `dev` prompt, on screen
        assert!(view.strays().is_empty());
    }

    #[test]
    fn history_goes_back_and_forward_like_a_browser() {
        let mut history = History::default();
        for name in ["a", "b", "c"] {
            history.visit(name);
        }
        let live = ["a", "b", "c"];
        assert_eq!(history.back(&live).as_deref(), Some("b"));
        assert_eq!(history.back(&live).as_deref(), Some("a"));
        assert_eq!(history.back(&live), None);
        assert_eq!(history.forward(&live).as_deref(), Some("b"));
        // Going somewhere new from the middle drops what was forward.
        history.visit("d");
        assert_eq!(history.forward(&["a", "b", "c", "d"]), None);
        assert_eq!(history.back(&["a", "b", "c", "d"]).as_deref(), Some("b"));
    }

    #[test]
    fn visiting_where_you_already_are_changes_nothing() {
        let mut history = History::default();
        history.visit("a");
        history.visit("a");
        assert_eq!(history.back(&["a"]), None);
    }

    #[test]
    fn history_steps_over_sessions_that_have_ended() {
        let mut history = History::default();
        for name in ["a", "b", "c"] {
            history.visit(name);
        }
        assert_eq!(history.back(&["a", "c"]).as_deref(), Some("a"));
        assert_eq!(history.forward(&["a", "c"]).as_deref(), Some("c"));
    }

    #[test]
    fn history_skips_a_repeat_of_where_you_are() {
        // a, b, a: back from the second a is b, not the first a.
        let mut history = History::default();
        for name in ["a", "b", "a"] {
            history.visit(name);
        }
        assert_eq!(history.back(&["a", "b"]).as_deref(), Some("b"));
    }

    #[test]
    fn the_fallback_is_the_most_recent_live_session() {
        let mut history = History::default();
        for name in ["a", "b", "c"] {
            history.visit(name);
        }
        assert_eq!(history.fallback(&["a", "b"]).as_deref(), Some("b"));
        assert_eq!(history.fallback(&["x"]), None);
        assert_eq!(History::default().fallback(&["a"]), None);
    }
}
