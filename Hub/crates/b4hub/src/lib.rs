//! The hub service: configuration and commands (`cli`), the HTTP server (`serve`), the error
//! envelope (`error`), the long-poll wake-up (`notify`), the device links (`relay`), and the
//! routes (`routes`).

pub mod apple;
pub mod auth;
pub mod auth_limits;
pub mod cli;
pub mod config;
pub mod error;
pub mod instances;
pub mod logging;
pub mod maintenance;
pub mod notify;
pub mod relay;
pub mod request_log;
pub mod routes;
pub mod serve;
