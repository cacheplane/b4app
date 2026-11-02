//! Accounts the hub mints for sign-up: generated usernames and org slugs, and the name of a
//! personal org. Neither the username nor the slug is shown to anyone; they only keep the
//! existing uniqueness rules satisfied for accounts nobody named.

/// RFC 4648 base32, lowercased. 32 symbols divide 256, so a byte's low five bits pick one
/// without bias.
pub const BASE32_ALPHABET: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";

/// The name of a personal org until its owner gives a full name.
pub const PLACEHOLDER_ORG_NAME: &str = "My Org";

/// A fresh username: `u-` and eight random base32 characters.
pub fn new_username() -> String {
    prefixed("u-")
}

/// A fresh org slug: `o-` and eight random base32 characters.
pub fn new_org_slug() -> String {
    prefixed("o-")
}

/// "<first word of `full_name`>'s Org", or [`PLACEHOLDER_ORG_NAME`] when the name is blank.
pub fn personal_org_name(full_name: &str) -> String {
    match full_name.split_whitespace().next() {
        Some(first) => format!("{first}'s Org"),
        None => PLACEHOLDER_ORG_NAME.to_string(),
    }
}

/// `prefix` and eight random base32 characters.
///
/// Panics only if the operating system has no source of randomness, like
/// [`crate::tokens::new_token`].
fn prefixed(prefix: &str) -> String {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).expect("the operating system provides randomness");
    let mut made = String::with_capacity(prefix.len() + bytes.len());
    made.push_str(prefix);
    for byte in bytes {
        made.push(BASE32_ALPHABET[usize::from(byte & 0x1f)] as char);
    }
    made
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usernames_and_slugs_are_a_prefix_and_eight_base32_characters() {
        for _ in 0..100 {
            for (made, prefix) in [(new_username(), "u-"), (new_org_slug(), "o-")] {
                assert_eq!(made.len(), 10, "{made}");
                let rest = made.strip_prefix(prefix).expect("the prefix");
                assert!(
                    rest.bytes().all(|b| BASE32_ALPHABET.contains(&b)),
                    "{made} has a character outside the alphabet"
                );
            }
        }
        assert_ne!(new_username(), new_username());
        assert_ne!(new_org_slug(), new_org_slug());
    }

    #[test]
    fn personal_org_names_use_the_first_word_of_the_full_name() {
        assert_eq!(personal_org_name("Brian Love"), "Brian's Org");
        assert_eq!(personal_org_name("  "), "My Org");
        assert_eq!(personal_org_name(""), "My Org");
        assert_eq!(personal_org_name("Zoë"), "Zoë's Org");
        assert_eq!(personal_org_name("  Ada   Lovelace "), "Ada's Org");
        assert_eq!(PLACEHOLDER_ORG_NAME, "My Org");
    }
}
