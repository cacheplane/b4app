// `sqlx::migrate!` embeds the migrations directory at compile time; without this a newly added
// migration file would not trigger a rebuild.
fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
