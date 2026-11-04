//! The sidebar of `dev hub`, as a library so the integration tests in tests/
//! can drive the hub against tmux servers of their own.

pub mod app;
pub mod colour;
pub mod config;
pub mod hub;
pub mod model;
pub mod placeholder;
pub mod scheme;
pub mod terminal;
pub mod theme;
pub mod tmux;
pub mod ui;
