//! The hub against real tmux: two servers of the tests' own (`tmux -L`), one
//! standing in for the hub and one for the sessions, so nothing here can
//! reach the sessions actually running on this machine.

use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use dev_hub::hub::Hub;
use dev_hub::model::{History, View};
use dev_hub::tmux::{Server, Tmux};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// A tmux server on a socket of its own, killed when dropped.
struct TestServer {
    name: String,
}

impl TestServer {
    fn new(role: &str) -> Self {
        let name = format!(
            "dev-hub-test-{}-{role}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        );
        Self { name }
    }

    fn tmux(&self, args: &[&str]) -> String {
        let output = Command::new("tmux")
            .env_remove("TMUX")
            .args(["-L", &self.name, "-f", "/dev/null"])
            .args(args)
            .output()
            .expect("tmux runs");
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    }

    fn alive(&self) -> bool {
        Command::new("tmux")
            .env_remove("TMUX")
            .args(["-L", &self.name, "list-sessions"])
            .output()
            .is_ok_and(|output| output.status.success())
    }

    fn session(&self, name: &str) {
        self.tmux(&[
            "new-session",
            "-d",
            "-s",
            name,
            "-x",
            "100",
            "-y",
            "30",
            "sleep 600",
        ]);
    }

    fn sessions(&self) -> Vec<String> {
        self.tmux(&["list-sessions", "-F", "#{session_name}"])
            .lines()
            .map(str::to_owned)
            .collect()
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        // kill-server leaves the socket file behind; ask for it while the
        // server can still say where it is. A server that already ended
        // (ending the hub is a test) left one at the same place as its twin.
        let socket = self.tmux(&["display-message", "-p", "#{socket_path}"]);
        let socket = if socket.is_empty() {
            Self::socket_dir().map(|dir| format!("{dir}/{}", self.name))
        } else {
            Some(socket)
        };
        let _ = Command::new("tmux")
            .env_remove("TMUX")
            .args(["-L", &self.name, "kill-server"])
            .output();
        if let Some(socket) = socket {
            let _ = std::fs::remove_file(socket);
        }
    }
}

impl TestServer {
    /// Where this user's tmux sockets live, from the default server's own.
    fn socket_dir() -> Option<String> {
        let probe = TestServer {
            name: format!("dev-hub-test-{}-probe", std::process::id()),
        };
        probe.tmux(&["new-session", "-d", "-s", "probe", "sleep 5"]);
        let path = probe.tmux(&["display-message", "-p", "#{socket_path}"]);
        // Dropping the probe removes its own socket.
        path.rsplit_once('/').map(|(dir, _)| dir.to_owned())
    }
}

struct Fixture {
    sessions: TestServer,
    hub_server: TestServer,
    hub: Hub,
}

/// A hub whose sidebar is a stand-in pane, beside a sessions' server holding
/// the given sessions.
fn fixture(sessions: &[&str]) -> Fixture {
    let real = TestServer::new("sessions");
    for name in sessions {
        real.session(name);
    }
    let hub_server = TestServer::new("hub");
    hub_server.tmux(&[
        "new-session",
        "-d",
        "-s",
        "hub",
        "-n",
        "hub",
        "-x",
        "130",
        "-y",
        "30",
        "sleep 600",
    ]);
    let sidebar = hub_server.tmux(&["list-panes", "-t", "hub:hub", "-F", "#{pane_id}"]);
    let hub = Hub {
        hub: Tmux::new(Server::Named(hub_server.name.clone())),
        sessions: Tmux::new(Server::Named(real.name.clone())),
        sidebar,
        width: 30,
        starter: format!(
            "env -u TMUX tmux -L {} -f /dev/null new-session -A -s",
            real.name
        ),
        placeholder: "sleep 600".into(),
    };
    hub.claim_sidebar().expect("the sidebar is claimed");
    Fixture {
        sessions: real,
        hub_server,
        hub,
    }
}

/// Read until `ready` holds: nested clients take a moment to attach.
fn until(hub: &Hub, what: &str, ready: impl Fn(&View) -> bool) -> View {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let view = hub.observe().expect("both servers read");
        if ready(&view) {
            return view;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {what}: {view:#?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn attached_to(session: &'static str) -> impl Fn(&View) -> bool {
    move |view| {
        view.current() == Some(session) && view.visible().is_some_and(|pane| view.attached(pane))
    }
}

#[test]
fn opening_a_session_shows_it_beside_the_sidebar_attached_for_real() {
    let f = fixture(&["alpha", "beta"]);
    let view = f.hub.observe().unwrap();
    f.hub.open(&view, "alpha", true).unwrap();

    let view = until(&f.hub, "alpha to attach", attached_to("alpha"));
    let visible = view.visible().unwrap();
    // A real client of the sessions' server, on the visible pane's terminal.
    let clients = f
        .sessions
        .tmux(&["list-clients", "-F", "#{client_tty} #{session_name}"]);
    assert!(
        clients.contains(&format!("{} alpha", visible.tty)),
        "{clients}"
    );
    let width = f.hub_server.tmux(&[
        "display-message",
        "-p",
        "-t",
        &f.hub.sidebar,
        "#{pane_width}",
    ]);
    assert_eq!(width, "30");
}

#[test]
fn switching_back_reuses_the_pane_it_had() {
    let f = fixture(&["alpha", "beta"]);
    f.hub
        .open(&f.hub.observe().unwrap(), "alpha", true)
        .unwrap();
    let view = until(&f.hub, "alpha", attached_to("alpha"));
    let alpha_pane = view.visible().unwrap().id.clone();

    f.hub.open(&view, "beta", true).unwrap();
    let view = until(&f.hub, "beta", attached_to("beta"));
    // alpha is still held, out of sight.
    assert_eq!(
        view.pane_for("alpha").map(|p| p.id.clone()),
        Some(alpha_pane.clone())
    );

    f.hub.open(&view, "alpha", true).unwrap();
    let view = until(&f.hub, "alpha again", attached_to("alpha"));
    assert_eq!(view.visible().unwrap().id, alpha_pane, "no reattach");
    // Two sessions visited, two nested clients: nothing piles up.
    let clients = f.sessions.tmux(&["list-clients", "-F", "#{session_name}"]);
    assert_eq!(clients.lines().count(), 2, "{clients}");
}

#[test]
fn when_the_session_on_screen_ends_the_previous_one_takes_its_place() {
    let f = fixture(&["alpha", "beta"]);
    let mut history = History::default();
    for name in ["beta", "alpha"] {
        f.hub.open(&f.hub.observe().unwrap(), name, true).unwrap();
        until(&f.hub, name, |view| {
            view.current() == Some(name) && view.visible().is_some_and(|p| view.attached(p))
        });
        history.visit(name);
    }

    // `exit` in alpha's last shell, as far as the hub can tell.
    f.sessions.tmux(&["kill-session", "-t", "=alpha"]);
    let view = until(&f.hub, "alpha's pane to go", |view| {
        view.visible().is_none()
    });
    f.hub.settle(&view, &history).unwrap();

    let view = until(&f.hub, "beta to come back", attached_to("beta"));
    assert_eq!(view.panes.len(), 2, "sidebar and beta only: {view:#?}");
}

#[test]
fn with_no_sessions_the_placeholder_shows_until_one_appears() {
    let f = fixture(&[]);
    let history = History::default();
    f.hub.settle(&f.hub.observe().unwrap(), &history).unwrap();
    let view = f.hub.observe().unwrap();
    assert_eq!(
        view.visible().map(|p| p.role),
        Some(dev_hub::model::Role::Placeholder)
    );

    f.sessions.session("gamma");
    f.hub.settle(&f.hub.observe().unwrap(), &history).unwrap();
    let view = until(&f.hub, "gamma", attached_to("gamma"));
    // The placeholder made way rather than going into hiding.
    assert_eq!(view.panes.len(), 2, "{view:#?}");
}

#[test]
fn starting_a_session_by_name_goes_through_the_starter() {
    let f = fixture(&["alpha"]);
    f.hub.start(&f.hub.observe().unwrap(), "delta").unwrap();
    until(&f.hub, "delta", attached_to("delta"));
    assert!(f.sessions.sessions().contains(&"delta".to_owned()));
}

#[test]
fn a_hidden_pane_for_a_session_that_ended_is_tidied_away() {
    let f = fixture(&["alpha", "beta"]);
    f.hub.open(&f.hub.observe().unwrap(), "beta", true).unwrap();
    let view = until(&f.hub, "beta", attached_to("beta"));
    f.hub.open(&view, "alpha", true).unwrap();
    let view = until(&f.hub, "alpha", attached_to("alpha"));
    assert_eq!(view.panes.len(), 3);

    f.hub.kill("beta").unwrap();
    let view = until(&f.hub, "beta's pane to go", |view| view.panes.len() == 2);
    // Nothing left to tidy, and alpha stays put.
    assert!(!f.hub.settle(&view, &History::default()).unwrap());
    assert_eq!(f.sessions.sessions(), ["alpha"]);
}

#[test]
fn ending_the_hub_never_ends_a_session() {
    let f = fixture(&["alpha", "beta"]);
    for name in ["alpha", "beta"] {
        f.hub.open(&f.hub.observe().unwrap(), name, true).unwrap();
        until(&f.hub, name, |view| {
            view.current() == Some(name) && view.visible().is_some_and(|p| view.attached(p))
        });
    }

    f.hub.quit().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while f.hub_server.alive() {
        assert!(Instant::now() < deadline, "the hub did not end");
        std::thread::sleep(Duration::from_millis(50));
    }
    // Its nested clients have gone; the sessions have not.
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(f.sessions.sessions(), ["alpha", "beta"]);
    assert_eq!(f.sessions.tmux(&["list-clients"]), "");
}
