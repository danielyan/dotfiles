//! `~/.config/dev/hub.toml`, which may well not exist.
//!
//! ```toml
//! theme = "Vercel"   # any gitview theme name; unset, gitview's own choice
//! width = 30         # the sidebar's width in columns
//! ```

use std::path::{Path, PathBuf};

use serde::Deserialize;

pub const DEFAULT_WIDTH: u16 = 30;
const MIN_WIDTH: u16 = 20;
const MAX_WIDTH: u16 = 60;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub theme: String,
    pub width: u16,
}

#[derive(Debug, Default, Deserialize)]
struct HubFile {
    theme: Option<String>,
    width: Option<u16>,
}

#[derive(Debug, Default, Deserialize)]
struct GitviewFile {
    ui: Option<GitviewUi>,
}

#[derive(Debug, Default, Deserialize)]
struct GitviewUi {
    theme: Option<String>,
}

impl Config {
    /// Read both files from the usual places. A file that is missing or does
    /// not parse is the same as an empty one: a typo in a config should not
    /// stop the hub from starting.
    pub fn load() -> Self {
        let config = config_dir();
        let read = |path: PathBuf| std::fs::read_to_string(path).unwrap_or_default();
        Self::from_texts(
            &read(config.join("dev/hub.toml")),
            &read(config.join("gitview/config.toml")),
        )
    }

    /// The same, from the files' contents.
    pub fn from_texts(hub: &str, gitview: &str) -> Self {
        let hub: HubFile = toml::from_str(hub).unwrap_or_default();
        // The hub follows gitview's theme unless told otherwise, so the two
        // look the same out of the box.
        let gitview_theme = || {
            toml::from_str::<GitviewFile>(gitview)
                .ok()
                .and_then(|file| file.ui)
                .and_then(|ui| ui.theme)
        };
        Self {
            theme: hub
                .theme
                .or_else(gitview_theme)
                .unwrap_or_else(|| "dark".to_owned()),
            width: hub
                .width
                .unwrap_or(DEFAULT_WIDTH)
                .clamp(MIN_WIDTH, MAX_WIDTH),
        }
    }
}

fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| Path::new(&home).join(".config")))
        .unwrap_or_else(|| PathBuf::from(".config"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_configured_is_the_defaults() {
        assert_eq!(
            Config::from_texts("", ""),
            Config {
                theme: "dark".into(),
                width: DEFAULT_WIDTH
            }
        );
    }

    #[test]
    fn gitview_s_theme_is_followed() {
        let gitview = "[ui]\ntheme = \"Vercel\"\n# left_width_pct = 40\n";
        assert_eq!(Config::from_texts("", gitview).theme, "Vercel");
    }

    #[test]
    fn the_hub_s_own_theme_wins() {
        let gitview = "[ui]\ntheme = \"Vercel\"\n";
        assert_eq!(
            Config::from_texts("theme = \"Dracula\"", gitview).theme,
            "Dracula"
        );
    }

    #[test]
    fn a_width_is_kept_within_reason() {
        assert_eq!(Config::from_texts("width = 24", "").width, 24);
        assert_eq!(Config::from_texts("width = 3", "").width, MIN_WIDTH);
        assert_eq!(Config::from_texts("width = 500", "").width, MAX_WIDTH);
    }

    #[test]
    fn a_broken_file_is_ignored_rather_than_fatal() {
        let config = Config::from_texts("width = = 3", "[ui\ntheme =");
        assert_eq!(config, Config::from_texts("", ""));
    }
}
