//! The hub service: configuration and commands (`cli`), the HTTP server (`serve`), the error
//! envelope (`error`), the long-poll wake-up (`notify`), the device links (`relay`), and the
//! routes (`routes`).

pub mod auth;
pub mod cli;
pub mod error;
pub mod notify;
pub mod relay;
pub mod routes;
pub mod serve;
