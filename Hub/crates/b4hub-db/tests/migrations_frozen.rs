//! Applied migrations never change. sqlx records each migration's checksum when it runs and
//! refuses to migrate a database whose applied migration has since been edited ("migration N was
//! previously applied but has been modified"), so an edit to a committed migration, even to a
//! comment, stops every deploy at the migrate task. D-174 rewrote a link in a comment of 0007 and
//! did exactly that. This pins every migration's SHA-256: change an applied one and this fails in
//! CI instead; add a new migration and add its line here (`shasum -a 256 <file>`).

use std::collections::BTreeMap;
use std::path::Path;

use sha2::{Digest, Sha256};

/// Each migration as it was applied to the hosted hubs.
const PINNED: &[(&str, &str)] = &[
    (
        "0001_tenancy.sql",
        "6abb124eb30dc2394da93a0addbd1b8107c87edd796165f04867cfa7ee31e4f4",
    ),
    (
        "0002_sync.sql",
        "a7f9ae1383ec1450fc28cf20eec256d5a078fb3f21ecc6af7d0e1f825f2cf3ad",
    ),
    (
        "0003_organisation.sql",
        "de43bce609bc84269d4015deb97f926b46c9b252e079409c837d724e799b7f7b",
    ),
    (
        "0004_relay.sql",
        "ab4f1f2ea72eb80721cbdced194f427ecdf29639d166a42681dde54196175685",
    ),
    (
        "0005_accounts.sql",
        "f348ecac51a9c71b6a7aaf7228a9d961fbb13d7256a799db74d523f2ce67f32b",
    ),
    (
        "0006_settings.sql",
        "bf50c29c91da9065213f4e66ce5e00c88cfc82e1461bbc052b50411270904da9",
    ),
    (
        "0007_apple_handoffs.sql",
        "b26e9ded346bb89791308bc8b26832241ad6b70c9f7f3d96a4ade92a162e2d4d",
    ),
    (
        "0008_instances.sql",
        "3c66c472539d371a329c74973e2e123d7daeb9ca5ba8903fafb4e23b5e19e49a",
    ),
    (
        "0009_soft_delete.sql",
        "db4ffe53b6d4e8e14bddeed40a6ef28e4c5485f310175603d86d59ffb0cbf914",
    ),
    (
        "0010_connection_usage.sql",
        "d2317b92fc14e62349b2f01e55dfed74c769df5b35f342308f38ee94f14d64c0",
    ),
    (
        "0011_thread_delete.sql",
        "2a770783795ed836cf865ac34654e81e78bc7dfefc39c939415f22dad6c37c1a",
    ),
    (
        "0012_push.sql",
        "9891a4acab23618130e1c20bf388408ddb2de28b0857304b6521f66378979ac3",
    ),
    (
        "0013_push_withdrawal.sql",
        "6767c60168819ff249a066ad2dd06ed11f7e28e2e3ceb1623f68039bfeeaa27f",
    ),
    (
        "0014_step_up.sql",
        "2b7c55e59eb25fa6c19b3ab6770256dc9f6c7f00a71be795e0de0f11e302714d",
    ),
    (
        "0015_step_up_code.sql",
        "1f6cc47944a6cec12138535c2ed69d8c9c72bb4b021b7aea4b854dd1eba93c39",
    ),
    (
        "0016_passkey_names.sql",
        "4123a523b9f512b88a078647bffe51a535f8ebab4e7cdf8632c3a356e7c93851",
    ),
    (
        "0017_thread_runtime_choice.sql",
        "d3960ad53eaba095e540e205641c1d4572090a900028360098c06e3b6d24f2c9",
    ),
    (
        "0018_environments.sql",
        "2a7090851b9ae1ff34813a75829203eb41fd1bff364cc8c8dad107ed547b3b48",
    ),
    (
        "0019_view_settings.sql",
        "49767dd9b80516fe99d96a702a528a58c54243b4f9a0d4135627e1140f949fd4",
    ),
    (
        "0020_user_settings_rows.sql",
        "ccf5c0b4cb0ef3230f138887c74df30c25e3756e3ba5245e6e02535b107aff8b",
    ),
    (
        "0021_connection_commands.sql",
        "a0ed9144dafcb5f0243e9d03166e5ab6ecbf1f92f2d80433d0d16608189ba99a",
    ),
];

#[test]
fn applied_migrations_are_unchanged_and_every_migration_is_pinned() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    let mut found = BTreeMap::new();
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|ext| ext == "sql") {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let digest = Sha256::digest(std::fs::read(&path).unwrap());
            let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
            found.insert(name, hex);
        }
    }
    for (name, pinned) in PINNED {
        let actual = found.remove(*name).unwrap_or_else(|| {
            panic!("migration {name} is gone; applied migrations are never removed")
        });
        assert_eq!(
            &actual, pinned,
            "migration {name} changed after it was applied; restore it and put the change in a new migration"
        );
    }
    assert!(
        found.is_empty(),
        "pin the new migration(s) in PINNED: {:?}",
        found.keys().collect::<Vec<_>>()
    );
}
