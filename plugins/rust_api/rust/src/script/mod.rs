#[cfg(not(target_os = "ios"))]
mod console;
#[cfg(not(target_os = "ios"))]
mod quickjs;
#[cfg(target_os = "ios")]
mod unsupported;

#[cfg(not(target_os = "ios"))]
pub use quickjs::evaluate;
#[cfg(target_os = "ios")]
pub use unsupported::evaluate;
