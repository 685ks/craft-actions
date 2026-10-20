//! Prints its name and version, the way the Craft launcher reads `<app> --version`.

fn main() {
    let version = option_env!("CRAFT_RELEASE_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"));
    let args: Vec<String> = std::env::args().skip(1).collect();
    println!("hello-craft {version}");
    if !args.is_empty() && args[0] != "--version" {
        println!("arguments: {args:?}");
    }
}
