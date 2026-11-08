// iOS runs the core in the Network Extension, which evaluates profile scripts
// itself; the app links no JavaScript engine, so this only reports that.
const UNSUPPORTED: &str = "Profile scripts are evaluated by the core on this platform";

pub fn evaluate(_script: &str, _config: &str) -> Result<String, String> {
    Err(UNSUPPORTED.to_owned())
}
