## 2026-11-02 (sign-in build)

- **D-097 Existing and operator-seeded users are onboarded.** Migration `0005_accounts.sql` sets `onboarded_at = created_at` and `full_name = display_name` for every existing user and leaves existing orgs non-personal, and `b4hub seed` does the same for each user it creates (`orgs::seed`), so a Compose-seeded user never sees onboarding. A new account's `display_name` is empty (the column is `NOT NULL`) until onboarding, or Apple's name as the prefill.
