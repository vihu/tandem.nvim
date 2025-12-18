use log::{self, info};
use log4rs::{
    append::file::FileAppender,
    config::{Appender, Config, Root},
    encode::pattern::PatternEncoder,
};
use nvim_oxi::Dictionary;
use parking_lot::Mutex;
use std::sync::OnceLock;
use tokio::runtime::Runtime;

mod auth;
mod code;
mod crdt;
mod crypto;
mod iroh_client;

/// Global async runtime for P2P operations
static ASYNC_RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> &'static Runtime {
    ASYNC_RUNTIME.get_or_init(|| Runtime::new().expect("Failed to create async runtime"))
}

/// Logger initialization guard
static LOGGER_INIT: OnceLock<Mutex<()>> = OnceLock::new();

fn init_logger() {
    let _guard = LOGGER_INIT.get_or_init(|| {
        let file_appender = FileAppender::builder()
            .encoder(Box::new(PatternEncoder::new(
                "[{l}] {d(%Y-%m-%d %H:%M:%S)} {f}:{L} - {m}\n",
            )))
            .build("/tmp/tandem-nvim.log")
            .expect("Failed to create file appender");

        let log_config = Config::builder()
            .appender(Appender::builder().build("file", Box::new(file_appender)))
            .build(
                Root::builder()
                    .appender("file")
                    .build(log::LevelFilter::Debug),
            )
            .expect("Failed to create log config");

        let _ = log4rs::init_config(log_config);
        log_panics::init();

        Mutex::new(())
    });
}

#[nvim_oxi::plugin]
fn tandem_ffi() -> nvim_oxi::Result<Dictionary> {
    init_logger();
    info!("tandem_ffi plugin loaded");

    let api = Dictionary::from_iter([
        ("auth", nvim_oxi::Object::from(auth::auth_ffi())),
        ("code", nvim_oxi::Object::from(code::code_ffi())),
        ("crdt", nvim_oxi::Object::from(crdt::crdt_ffi())),
        ("crypto", nvim_oxi::Object::from(crypto::crypto_ffi())),
        ("iroh", nvim_oxi::Object::from(iroh_client::iroh_ffi())),
    ]);

    Ok(api)
}
